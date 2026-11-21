#include <QCommandLineParser>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QLibraryInfo>
#include <QQuickWindow>
#include <QGuiApplication>
#include <QImageReader>
#include <QQmlApplicationEngine>
#include <QTextStream>
#include <QUrl>

#include <memory>

#include "translationloader.h"
#include "globalmenu.h"
#include "keywindow.h"
#include "windowchrome.h"
#include "previewapp.h"
#include "previewlogic.h"
#include "textrender.h"

#ifndef GRASSFIELD_PREVIEW_QML_DIR
#define GRASSFIELD_PREVIEW_QML_DIR "/usr/share/grassfield/preview/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    QElapsedTimer t0; // GRASSFIELD_PREVIEW_TIMING=1 prints the time to the first frame and to the folder list on stderr
    t0.start();
    // QtPdf's views are Qt Quick Controls: they use the Grassfield style (ui/Grassfield, installed next to Grassfield.Ui) when
    // that module is installed, the Basic style otherwise (and for every control the Grassfield style does not cover). The
    // style is chosen here, for this app only, never for the session (GF-085); an explicit environment value wins.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QStringList roots = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots += qEnvironmentVariable("QML2_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots << QLibraryInfo::path(QLibraryInfo::QmlImportsPath);
        bool installed = false;
        for (const QString &root : std::as_const(roots))
            installed = installed || QFileInfo::exists(root + QStringLiteral("/Grassfield/qmldir"));
        qputenv("QT_QUICK_CONTROLS_STYLE", installed ? "Grassfield" : "Basic");
        if (installed && qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_FALLBACK_STYLE"))
            qputenv("QT_QUICK_CONTROLS_FALLBACK_STYLE", "Basic");
    }
    // Untrusted images: bound every decoder (also QML Image and AnimatedImage) to this much memory.
    QImageReader::setAllocationLimit(preview::kAllocationLimitMb);

    QGuiApplication app(argc, argv);
    // The app's static text is rasterised natively (ADR-0039 Q5, step 19): distance-field glyphs carry 8 to 20 % less ink than
    // macOS's, so text read greyer and softer; no app text is scaled or animated (an item that is sets its own renderType).
    grassfield::apps::applyTextRenderType(); // native unless GRASSFIELD_TEXT_RENDER says otherwise (textrender.h)
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: windows that draw their own chrome (QML property gfChromeRole) are tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-preview"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("View images, PDF documents, text, audio and video (read only)"));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption glanceOption(QStringLiteral("glance"), QObject::tr("Show a quick, floating look at the files (Space or Esc closes it)."));
    parser.addOption(glanceOption);
    const QCommandLineOption startOption(QStringLiteral("start"), QObject::tr("Show file number <n> of the given files first (0 is the first)."), QStringLiteral("n"));
    parser.addOption(startOption);
    parser.addPositionalArgument(QStringLiteral("files"), QObject::tr("Local files or file: URLs."), QStringLiteral("[files...]"));
    parser.process(app);

    const bool glance = parser.isSet(glanceOption);
    // Wayland app_id: matches org.grassfield.Preview.desktop; Glance has its own (window rule).
    app.setDesktopFileName(glance ? QStringLiteral("org.grassfield.Preview.Glance") : QStringLiteral("org.grassfield.Preview"));

    const preview::Arguments args = preview::resolveArguments(parser.positionalArguments(), QDir::currentPath());
    QTextStream err(stderr);
    for (const QString &message : args.errors)
        err << "grassfield-preview: " << message << Qt::endl;

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // windows down still see it (no TypeError on close).
    // One file opened: the other files of its folder can be browsed (previous/next), in the order Grassfield Files shows
    // them, like the arrow keys of a file manager. The viewer browses images; a Glance every kind it can show.
    // The opened file is shown at once; the folder is listed in a worker thread and the arrows and "n of N" follow.
    const bool browsing = args.paths.size() == 1 && (glance ? preview::classify(args.paths.constFirst()) != preview::Kind::Unsupported
                                                             : preview::classify(args.paths.constFirst()) == preview::Kind::Image);
    // --start <n> only applies to the files named on the command line.
    PreviewApp backend(args.paths, args.errors, glance, browsing ? 0 : qMax(0, parser.value(startOption).toInt()), browsing);
    const preview::BrowseKinds browseKinds = glance ? preview::BrowseKinds::Previewable : preview::BrowseKinds::ImagesOnly;

    QQmlApplicationEngine engine;
    // ADR-0039 step 17: the window keeps its key look while a shell menu or the Control Center holds the keyboard (keywindow.h).
    new grassfield::apps::KeyWindow(&engine);
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    // addImportPath puts a path before the ones searched so far, so the system directory above would shadow the tree's own
    // Grassfield.Ui in a dev session: add QML_IMPORT_PATH (dev scripts point it at the tree's ui/) after it, in reverse so
    // that its first entry is searched first.
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("preview"), new PreviewImageProvider(&backend));

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_PREVIEW_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_PREVIEW_QML_DIR);

    QVariantMap initial{{QStringLiteral("backend"), QVariant::fromValue(&backend)}};
    // Global menu (T1): the viewer exports its menus only while the registrar is there (globalmenu.h). A Glance is a
    // panel without menus of its own.
    if (!glance)
        initial.insert(QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable());
    engine.setInitialProperties(initial);
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(glance ? QStringLiteral("Glance.qml") : QStringLiteral("Viewer.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    // The registrar may appear later (an app started before the bridge) or restart: the viewer's menus follow it.
    if (!glance)
        grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    // The folder is listed after the first frame: the opened file never waits for it (the listing shares the MIME
    // database lock with the GUI thread, so it must not compete with the first render).
    if (browsing) {
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
        if (window) {
            auto started = std::make_shared<bool>(false);
            // Once: the connection goes with the first frame, or every later frame would post a call that returns at once.
            auto connection = std::make_shared<QMetaObject::Connection>();
            *connection = QObject::connect(window, &QQuickWindow::frameSwapped, &backend, [&backend, browseKinds, started, connection, &t0] {
                if (*started)
                    return;
                *started = true;
                if (qEnvironmentVariableIsSet("GRASSFIELD_PREVIEW_TIMING"))
                    fprintf(stderr, "TIMING first-frame %lld ms\n", static_cast<long long>(t0.elapsed()));
                backend.startBrowse(browseKinds);
                QObject::disconnect(*connection);
            });
        } else {
            backend.startBrowse(browseKinds);
        }
        if (qEnvironmentVariableIsSet("GRASSFIELD_PREVIEW_TIMING"))
            QObject::connect(&backend, &PreviewApp::listingChanged, &backend, [&t0, &backend] {
                if (!backend.listing())
                    fprintf(stderr, "TIMING list-ready %lld ms files=%d\n", static_cast<long long>(t0.elapsed()), static_cast<int>(backend.files().size()));
            });
    }
    return app.exec();
}
