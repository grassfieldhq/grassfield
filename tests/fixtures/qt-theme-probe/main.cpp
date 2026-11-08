// Test fixture for ADR-0054 (tests/integration/qt_platform_theme.sh): what a Qt Widgets application gets
// from its platform theme. Run it offscreen.
//   qt-theme-probe            prints one `key=value` line each: the theme's class, the file dialog helper's class (the one a
//                             QFileDialog would get), the palette's window and text colours, the default font, the colour scheme
//   qt-theme-probe --dialog   opens QFileDialog::getExistingDirectory() (the native dialog; the portal backend of the test answers the folder it shows) and prints `chosen=<path>`
#include <QtCore/QDeadlineTimer>
#include <QtCore/QEventLoop>
#include <QtCore/QThread>
#include <QtCore/QTimer>
#include <QtGui/QFont>
#include <QtGui/QGuiApplication>
#include <QtGui/QPalette>
#include <QtGui/QStyleHints>
#include <QtWidgets/QApplication>
#include <QtWidgets/QFileDialog>
#include <cstdio>
#include <cxxabi.h>
#include <memory>
#include <private/qguiapplication_p.h>
#include <qpa/qplatformdialoghelper.h>
#include <qpa/qplatformtheme.h>
#include <typeinfo>

// The portal theme asks the portal for the FileChooser's version asynchronously when it starts; a dialog created before the answer
// falls back to the base theme's. A real application has run its event loop long before a user opens a dialog.
static void settle()
{
    QDeadlineTimer deadline(1500);
    while (!deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(20);
    }
}

static QString className(const std::type_info &type)
{
    int status = 0;
    std::unique_ptr<char, void (*)(void *)> name(abi::__cxa_demangle(type.name(), nullptr, nullptr, &status), std::free);
    return status == 0 && name ? QString::fromUtf8(name.get()) : QString::fromUtf8(type.name());
}

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    const QStringList args = app.arguments();
    settle();
    if (args.contains(QStringLiteral("--dialog"))) {
        QTimer::singleShot(30000, &app, [] {
            std::puts("chosen=TIMEOUT");
            std::fflush(stdout);
            std::exit(3);
        });
        const QString path = QFileDialog::getExistingDirectory(nullptr, QStringLiteral("Choose"));
        std::printf("chosen=%s\n", path.toUtf8().constData());
        return 0;
    }
    QPlatformTheme *theme = QGuiApplicationPrivate::platformTheme();
    std::printf("theme=%s\n", theme ? className(typeid(*theme)).toUtf8().constData() : "none");
    if (theme != nullptr) {
        std::printf("native-file-dialog=%d\n", theme->usePlatformNativeDialog(QPlatformTheme::FileDialog) ? 1 : 0);
        std::unique_ptr<QPlatformDialogHelper> helper(theme->createPlatformDialogHelper(QPlatformTheme::FileDialog));
        std::printf("file-dialog-helper=%s\n", helper ? className(typeid(*helper)).toUtf8().constData() : "none");
    }
    const QPalette palette = QGuiApplication::palette();
    std::printf("window=%s\n", palette.color(QPalette::Window).name().toUtf8().constData());
    std::printf("text=%s\n", palette.color(QPalette::WindowText).name().toUtf8().constData());
    std::printf("base=%s\n", palette.color(QPalette::Base).name().toUtf8().constData());
    std::printf("font=%s\n", QGuiApplication::font().family().toUtf8().constData());
    std::printf("color-scheme=%d\n", static_cast<int>(QGuiApplication::styleHints()->colorScheme()));
    return 0;
}
