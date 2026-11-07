// The listings of grassfield-portal's Open and Save panels (FolderModel.chooser; ADR-0035 D-4, docs/specs/system-dialogs.md
// section 1): over a real KIO listing of a scratch folder, the files a panel cannot take are dimmed and never selected, a
// panel that takes one item keeps one, a folder panel dims every file, and the Applications location dims every application
// but those Choose Application takes.
// Part of files-kio-tests (a scratch home).
#include "filesapp.h"
#include "applicationslogic.h"
#include "filelogic.h"
#include "foldermodel.h"
#include "placesmodel.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QClipboard>
#include <QGuiApplication>
#include <QJSEngine>
#include <QMimeData>
#include <QSettings>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <KApplicationTrader>
#include <KIO/FileUndoManager>
#include <KService>
#include <KSycoca>

#include <gtest/gtest.h>

#include <algorithm>
#include <functional>
#include <tuple>

namespace {

class FolderChooserTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        for (const char *name : {"a.txt", "b.png", "report.PDF"}) {
            QFile f(m_dir.filePath(QString::fromLatin1(name)));
            ASSERT_TRUE(f.open(QIODevice::WriteOnly));
            f.write("x");
        }
        ASSERT_TRUE(QDir(m_dir.path()).mkdir(QStringLiteral("sub")));
        m_model.setUrl(QUrl::fromLocalFile(m_dir.path()));
        QDeadlineTimer deadline(10000);
        while ((m_model.loading() || m_model.count() < 4) && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        ASSERT_EQ(m_model.count(), 4);
    }

    int row(const char *name)
    {
        for (int r = 0; r < m_model.count(); ++r)
            if (m_model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    }

    bool dimmed(const char *name) { return m_model.data(m_model.index(row(name), 0), FolderModel::DimmedRole).toBool(); }

    QTemporaryDir m_dir;
    FolderModel m_model;
};

} // namespace

TEST_F(FolderChooserTest, FilesOnlyWithoutAPanel)
{
    for (const char *name : {"a.txt", "b.png", "report.PDF", "sub"})
        EXPECT_FALSE(dimmed(name)) << name;
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.select(row("b.png"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 2);
}

TEST_F(FolderChooserTest, ThePanelsFilterDimsAndRefuses)
{
    m_model.setChooser({{QStringLiteral("globs"), QStringList{QStringLiteral("*.txt"), QStringLiteral("*.pdf")}}, {QStringLiteral("single"), true}});
    EXPECT_FALSE(dimmed("a.txt"));
    EXPECT_TRUE(dimmed("b.png"));
    EXPECT_FALSE(dimmed("report.PDF")); // a glob ignores case
    EXPECT_FALSE(dimmed("sub"));        // folders open
    m_model.select(row("b.png"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 0);
    m_model.select(row("a.txt"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedUrls(), QList<QUrl>{QUrl::fromLocalFile(m_dir.filePath(QStringLiteral("a.txt")))});
    // A click on a dimmed item does nothing (macOS; integrator nested pass of f9a25ce, NIT: it cleared Choose Application's
    // preselected application). A key that lands there selects nothing: no selection out of sight for Return (review of
    // step 5c, MINOR 2).
    m_model.select(row("b.png"), Qt::NoModifier, true);
    EXPECT_EQ(m_model.selectedUrls(), QList<QUrl>{QUrl::fromLocalFile(m_dir.filePath(QStringLiteral("a.txt")))});
    EXPECT_EQ(m_model.currentRow(), row("a.txt"));
    m_model.select(row("b.png"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 0);
    EXPECT_EQ(m_model.currentRow(), row("b.png"));
    m_model.select(row("a.txt"), Qt::NoModifier, true);
    // One item at most: Ctrl and Shift are plain clicks, Select All does nothing.
    m_model.select(row("report.PDF"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.select(row("sub"), Qt::ShiftModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 1);
}

TEST_F(FolderChooserTest, MimeTypesAndSeveralItems)
{
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("image/*")}}});
    EXPECT_TRUE(dimmed("a.txt"));
    EXPECT_FALSE(dimmed("b.png"));
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 2); // the picture and the folder
    // A new filter drops from the selection what the panel can no longer take.
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("text/plain")}}});
    EXPECT_EQ(m_model.selectedCount(), 1);
    EXPECT_FALSE(dimmed("a.txt"));
}

TEST_F(FolderChooserTest, AFolderPanelDimsEveryFile)
{
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}});
    EXPECT_EQ(m_model.selectedCount(), 0);
    for (const char *name : {"a.txt", "b.png", "report.PDF"})
        EXPECT_TRUE(dimmed(name)) << name;
    EXPECT_FALSE(dimmed("sub"));
    m_model.select(row("sub"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
}

// The Applications location (grassfield-apps:/, Files' launchers) in a panel: every application is dimmed and never selected,
// whatever the filter (an application is a launcher, not a file an application can open). Its entry in the scratch home.
TEST(FolderChooserApplications, EveryApplicationIsDimmedInAPanel)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    QFile entry(dir + QStringLiteral("/org.example.PanelEditor.desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write("[Desktop Entry]\nType=Application\nName=Panel Editor\nExec=true\n");
    entry.close();
    FolderModel model;
    model.setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [&model] {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String("Panel Editor"))
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while (rowOf() < 0 && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    const int row = rowOf();
    ASSERT_GE(row, 0);
    EXPECT_TRUE(model.isApplications());
    EXPECT_FALSE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool()); // Files: an application opens
    model.setChooser({{QStringLiteral("globs"), QStringList{QStringLiteral("*")}}});
    EXPECT_TRUE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool());
    model.select(row, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 0);
    model.setChooser({{QStringLiteral("foldersOnly"), true}});
    EXPECT_TRUE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool());
    QFile::remove(entry.fileName());
}

// Choose Application (grassfield-portal's AppChooser, ADR-0035 D-5, step 5b): the applications the chooser names by desktop id
// are taken, the others dimmed and never selected; `allApplications` takes every one.
TEST(FolderChooserApplications, ChooseApplicationTakesTheNamedOnes)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    for (const char *id : {"org.example.ChooserEditor", "org.example.ChooserViewer"}) {
        QFile entry(dir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QByteArray("[Desktop Entry]\nType=Application\nName=") + QByteArray(id).mid(12) + "\nExec=true\n");
    }
    FolderModel model;
    model.setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [&model](const char *name) {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while ((rowOf("ChooserEditor") < 0 || rowOf("ChooserViewer") < 0) && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    const int editor = rowOf("ChooserEditor");
    const int viewer = rowOf("ChooserViewer");
    ASSERT_GE(editor, 0);
    ASSERT_GE(viewer, 0);
    const auto dimmed = [&model](int row) { return model.data(model.index(row, 0), FolderModel::DimmedRole).toBool(); };
    model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true},
                      {QStringLiteral("applications"), QStringList{QStringLiteral("org.example.ChooserEditor")}}});
    EXPECT_FALSE(dimmed(editor));
    EXPECT_TRUE(dimmed(viewer));
    model.select(viewer, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 0) << "a dimmed application is never selected";
    model.select(editor, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 1);
    model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}, {QStringLiteral("allApplications"), true}});
    EXPECT_FALSE(dimmed(editor));
    EXPECT_FALSE(dimmed(viewer));
    for (const char *id : {"org.example.ChooserEditor", "org.example.ChooserViewer"})
        QFile::remove(dir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
}

// Choose Application lists its candidates even when the Apps grid hides them (`listed`; NoDisplay=true: imv, Omarchy's image
// viewer, which the Open With submenu offers), under Recommended and under All Applications; the location in Files itself keeps
// the grid's list. The panel then selects the type's default application in it (FilePanel.preselect: FolderModel::expect).
TEST(FolderChooserApplications, ChooseApplicationListsTheCandidatesTheGridHides)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    const QString hiddenId = QStringLiteral("org.example.ChooserHiddenViewer");
    const QString shownId = QStringLiteral("org.example.ChooserShownViewer");
    const auto writeEntry = [&dir](const QString &id, const QByteArray &name, const QByteArray &extra) {
        QFile entry(dir + QLatin1Char('/') + id + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write("[Desktop Entry]\nType=Application\nName=" + name + "\nExec=true\n" + extra);
    };
    writeEntry(hiddenId, "HiddenViewer", "NoDisplay=true\n");
    writeEntry(shownId, "ShownViewer", "");
    const auto rowOf = [](FolderModel &model, const char *name) {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    };
    const auto waitFor = [](const std::function<bool()> &done) {
        QDeadlineTimer deadline(10000);
        while (!done() && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        return done();
    };

    // Files' own Applications location: the grid's list, without the NoDisplay one.
    FolderModel files;
    files.setUrl(ApplicationsLogic::locationUrl());
    ASSERT_TRUE(waitFor([&] { return rowOf(files, "ShownViewer") >= 0; }));
    EXPECT_LT(rowOf(files, "HiddenViewer"), 0) << "the location in Files lists what the Apps grid lists";

    // A Choose Application panel's listing: the chooser is set before the location (BrowserTab.createModel), as the panel does.
    FolderModel panel;
    const QVariantMap recommended{{QStringLiteral("foldersOnly"), true},
                                  {QStringLiteral("single"), true},
                                  {QStringLiteral("applications"), QStringList{hiddenId}},
                                  {QStringLiteral("listed"), QStringList{hiddenId}}};
    panel.setChooser(recommended);
    panel.setUrl(ApplicationsLogic::locationUrl());
    ASSERT_TRUE(waitFor([&] { return !panel.loading() && rowOf(panel, "HiddenViewer") >= 0; })) << "the NoDisplay candidate is listed";
    const int hidden = rowOf(panel, "HiddenViewer");
    EXPECT_FALSE(panel.data(panel.index(hidden, 0), FolderModel::DimmedRole).toBool()) << "and can be chosen";
    EXPECT_TRUE(panel.data(panel.index(rowOf(panel, "ShownViewer"), 0), FolderModel::DimmedRole).toBool());
    panel.expect(ApplicationsLogic::entryUrl(hiddenId), false);
    ASSERT_TRUE(waitFor([&] { return panel.selectedCount() == 1; })) << "the panel's preselection takes it";
    EXPECT_EQ(panel.selectedUrls(), QList<QUrl>{ApplicationsLogic::entryUrl(hiddenId)});

    // All Applications keeps it listed.
    QVariantMap all = recommended;
    all.insert(QStringLiteral("applications"), QStringList{});
    all.insert(QStringLiteral("allApplications"), true);
    panel.setChooser(all);
    QCoreApplication::processEvents(QEventLoop::AllEvents, 200);
    ASSERT_TRUE(waitFor([&] { return rowOf(panel, "HiddenViewer") >= 0 && rowOf(panel, "ShownViewer") >= 0; }));

    // A chooser that names it later (the frontend's UpdateChoices) lists it again: the listing made without it is made again.
    FolderModel late;
    late.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}});
    late.setUrl(ApplicationsLogic::locationUrl());
    ASSERT_TRUE(waitFor([&] { return !late.loading() && rowOf(late, "ShownViewer") >= 0; }));
    EXPECT_LT(rowOf(late, "HiddenViewer"), 0);
    late.setChooser(recommended);
    EXPECT_TRUE(waitFor([&] { return rowOf(late, "HiddenViewer") >= 0; })) << "listed once the chooser names it";

    QFile::remove(dir + QLatin1Char('/') + hiddenId + QStringLiteral(".desktop"));
    QFile::remove(dir + QLatin1Char('/') + shownId + QStringLiteral(".desktop"));
}

// A Choose Application panel's longer list never becomes the location's: Get Info on Applications counts what the location
// lists (FilesApp::applicationsCount), also after a panel listed a candidate the grid hides (review of fac5bff3, NIT: the
// last listing won and the count grew by one).
TEST(FolderChooserApplications, APanelsListIsNotTheLocationsCount)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    const QString hiddenId = QStringLiteral("org.example.CountHiddenViewer");
    {
        QFile entry(dir + QLatin1Char('/') + hiddenId + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write("[Desktop Entry]\nType=Application\nName=CountHiddenViewer\nExec=true\nNoDisplay=true\n");
    }
    const auto waitFor = [](const std::function<bool()> &done) {
        QDeadlineTimer deadline(10000);
        while (!done() && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        return done();
    };
    FilesApp app(QList<QUrl>{});
    auto *location = qobject_cast<FolderModel *>(app.createFolderModel(&app));
    ASSERT_NE(location, nullptr);
    location->setUrl(ApplicationsLogic::locationUrl());
    ASSERT_TRUE(waitFor([&] { return !location->loading() && location->count() > 0 && app.applicationsCount() > 0; }));
    const int listed = app.applicationsCount();
    EXPECT_EQ(listed, location->count()) << "the location's own rows";
    auto *panel = qobject_cast<FolderModel *>(app.createFolderModel(&app));
    ASSERT_NE(panel, nullptr);
    panel->setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true},
                       {QStringLiteral("applications"), QStringList{hiddenId}}, {QStringLiteral("listed"), QStringList{hiddenId}}});
    panel->setUrl(ApplicationsLogic::locationUrl());
    ASSERT_TRUE(waitFor([&] { return !panel->loading() && panel->count() == location->count() + 1; })) << "the panel lists one more";
    QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
    EXPECT_EQ(app.applicationsCount(), listed) << "Get Info still counts the location's list";
    QFile::remove(dir + QLatin1Char('/') + hiddenId + QStringLiteral(".desktop"));
}

// New Folder of a Save panel (FilesApp::makeFolder): a taken name, a folder's or a file's, is told by KIO's own error, since
// the panels never look at the disk on the GUI thread first (ADR-0035 4b-18; re-review of 6b26afc); a new name is made; an
// invalid one is refused at once.
TEST(PanelNewFolder, ATakenNameIsToldByKio)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("taken")));
    QFile file(dir.filePath(QStringLiteral("a file")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    FilesApp app(QList<QUrl>{});
    QJSEngine engine;
    engine.globalObject().setProperty(QStringLiteral("out"), engine.newArray());
    const QJSValue record = engine.evaluate(QStringLiteral("(function (url, error) { out.push({url: url, error: error}); })"));
    ASSERT_TRUE(record.isCallable());
    const auto make = [&](const QString &name) {
        const int before = engine.globalObject().property(QStringLiteral("out")).property(QStringLiteral("length")).toInt();
        app.makeFolder(QUrl::fromLocalFile(dir.path()), name, record);
        QDeadlineTimer deadline(10000);
        while (engine.globalObject().property(QStringLiteral("out")).property(QStringLiteral("length")).toInt() == before && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        return engine.globalObject().property(QStringLiteral("out")).property(quint32(before));
    };
    const QString takenMessage = QStringLiteral("The name “%1” is already taken. Please choose a different name.");
    QJSValue answer = make(QStringLiteral("taken"));
    EXPECT_EQ(answer.property(QStringLiteral("url")).toString(), QString());
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), takenMessage.arg(QStringLiteral("taken")));
    answer = make(QStringLiteral("a file"));
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), takenMessage.arg(QStringLiteral("a file")));
    answer = make(QStringLiteral("fresh"));
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), QString());
    EXPECT_EQ(QUrl(answer.property(QStringLiteral("url")).toString()), QUrl::fromLocalFile(dir.filePath(QStringLiteral("fresh"))));
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("fresh"))).isDir());
    answer = make(QStringLiteral("a/b"));
    EXPECT_TRUE(answer.property(QStringLiteral("error")).toString().startsWith(QStringLiteral("The name “a/b” can’t be used.")));
}

// An application Files cannot start: the message names it as the Applications location shows it (the name of the row, told
// apart from an app of the same name) and through FileLogic::displayName, so a bidirectional override in a Name= never
// reaches the banner. Exec= is a program that does not exist.
TEST(ApplicationLaunch, TheFailureNamesTheRowsNameCleaned)
{
    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    qunsetenv("GRASSFIELD_SESSION"); // not a real session: the program is started as it is, so that a missing one fails
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    const QString name = QStringLiteral("Invoice‮fdp.sh");
    QFile entry(dir + QStringLiteral("/org.example.BidiLaunch.desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=/nonexistent/grassfield-test-binary\n").arg(name).toUtf8());
    entry.close();
    FilesApp app(QList<QUrl>{});
    auto *model = qobject_cast<FolderModel *>(app.createFolderModel(&app));
    ASSERT_NE(model, nullptr);
    model->setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [model, &name] {
        for (int r = 0; r < model->count(); ++r)
            if (model->nameAt(r) == name)
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while (rowOf() < 0 && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    ASSERT_GE(rowOf(), 0);
    // The launch reads KDE's service cache, which looks at the folders at most every 1.5 s: another test of this run may have
    // opened it before the entry was written (tst_applicationchooser.cpp, tst_kiodialogs.cpp's OpenUrlJob).
    deadline = QDeadlineTimer(15000);
    while (!KService::serviceByMenuId(QStringLiteral("org.example.BidiLaunch.desktop")) && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(100);
        KSycoca::self()->ensureCacheValid();
    }
    QStringList failures;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&failures](const QString &message) { failures << message; });
    app.launchApplication(ApplicationsLogic::entryUrl(QStringLiteral("org.example.BidiLaunch")));
    ASSERT_EQ(failures.size(), 1);
    EXPECT_FALSE(failures.first().contains(QChar(0x202E))) << failures.first().toStdString();
    EXPECT_EQ(failures.first(), QStringLiteral("“%1” could not be started.").arg(FileLogic::displayName(model->nameAt(rowOf()))));
    QFile::remove(entry.fileName());
}

namespace {
// Runs the event loop until `done` or 10 s.
bool waitFor(const std::function<bool()> &done)
{
    QDeadlineTimer deadline(10000);
    while (!done() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    return done();
}

QStringList selectedNames(const FolderModel &model)
{
    QStringList out;
    for (int r : model.selectedRows())
        out << model.nameAt(r);
    return out;
}
} // namespace

// The column view's wish (FolderModel::expectAlone): the folder its next column shows, selected alone once the column's
// listing has it. Owner report 2026-11-07 ("in Columns view the selection sometimes goes back to the previous folder"): the
// column view used expect(), whose calls build one selection, so a wish still waiting for a slow listing joined the folder
// the user chose meanwhile, and became the current row the next arrow key started from. A folder made after the wish stands
// for an item a slow listing brings late.
TEST(ColumnWish, AWishWaitingForTheListingNeverComesBackOverTheUsersChoice)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("chosen")));
    FolderModel model;
    model.setUrl(QUrl::fromLocalFile(dir.path()));
    ASSERT_TRUE(waitFor([&] { return !model.loading() && model.count() == 1; }));
    const auto url = [&](const char *name) { return QUrl::fromLocalFile(dir.filePath(QString::fromLatin1(name))); };
    const auto rowOf = [&](const char *name) {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    };
    const auto make = [&](const char *name) {
        return QDir(dir.path()).mkdir(QString::fromLatin1(name)) && waitFor([&] { return rowOf(name) >= 0; });
    };

    // expect() as the column view called it: the late folder joins the user's choice and becomes the current row.
    model.expect(url("before"), false);
    model.select(rowOf("chosen"), 0, true);
    model.expect(url("chosen"), false);
    ASSERT_TRUE(make("before"));
    QCoreApplication::processEvents();
    EXPECT_EQ(selectedNames(model), (QStringList{QStringLiteral("before"), QStringLiteral("chosen")})) << "expect() still builds one selection (a drop's items)";
    EXPECT_EQ(model.currentRow(), rowOf("before"));

    // expectAlone(): the new wish replaces the old one; the late folder changes nothing.
    model.select(rowOf("chosen"), 0, true);
    model.expectAlone(url("late"));
    model.select(rowOf("chosen"), 0, true);
    model.expectAlone(url("chosen"));
    ASSERT_TRUE(make("late"));
    QCoreApplication::processEvents();
    EXPECT_EQ(selectedNames(model), QStringList{QStringLiteral("chosen")});
    EXPECT_EQ(model.currentRow(), rowOf("chosen"));

    // A selection made in the listing drops a wish by itself (Select All, a click that leaves the location).
    model.expectAlone(url("dropped"));
    model.select(rowOf("chosen"), 0, true);
    ASSERT_TRUE(make("dropped"));
    QCoreApplication::processEvents();
    EXPECT_EQ(selectedNames(model), QStringList{QStringLiteral("chosen")});
    model.expectAlone(url("emptied"));
    model.expectAlone(QUrl());
    ASSERT_TRUE(make("emptied"));
    QCoreApplication::processEvents();
    EXPECT_EQ(selectedNames(model), QStringList{QStringLiteral("chosen")}) << "an empty URL drops the wish";

    // Alone, a wish selects its folder alone once listed and asks the view to show it.
    int revealed = -1;
    QObject::connect(&model, &FolderModel::revealRequested, &model, [&](int row, bool) { revealed = row; });
    model.expectAlone(url("next"));
    ASSERT_TRUE(make("next"));
    ASSERT_TRUE(waitFor([&] { return selectedNames(model) == QStringList{QStringLiteral("next")}; })) << selectedNames(model).join(QLatin1Char(',')).toStdString();
    EXPECT_EQ(revealed, rowOf("next"));
    // Already listed: at once.
    model.expectAlone(url("chosen"));
    EXPECT_EQ(selectedNames(model), QStringList{QStringLiteral("chosen")});
}

// Sidebar Favorites (FP-27; owner report 2026-11-07, "there is no way to pin a folder in the sidebar"): Add to Sidebar keeps
// the folders among the items (KIO says which are; a file is refused with the banner's message), lists them after the standard
// places and keeps them in QSettings; Remove from Sidebar takes a folder of the user's away and hides a standard place, which
// Add to Sidebar lists again. The folders themselves are never touched.
TEST(SidebarFavorites, AddToSidebarKeepsFoldersAndRemoveHidesStandardPlaces)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Projects")));
    QFile file(dir.filePath(QStringLiteral("note.txt")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    const QUrl projects = QUrl::fromLocalFile(dir.filePath(QStringLiteral("Projects")));
    FilesApp app(QList<QUrl>{});
    auto *places = qobject_cast<PlacesModel *>(app.places());
    ASSERT_NE(places, nullptr);
    QStringList failures;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&](const QString &message) { failures << message; });

    app.addToSidebar({projects, QUrl::fromLocalFile(dir.filePath(QStringLiteral("note.txt")))}, -1);
    ASSERT_TRUE(waitFor([&] { return places->pinnedCount() == 1 && !failures.isEmpty(); }));
    EXPECT_EQ(failures, QStringList{QStringLiteral("Only folders can be added to the sidebar.")});
    const QModelIndex row = places->index(places->firstPinnedRow(), 0);
    EXPECT_EQ(places->data(row, PlacesModel::KindRole).toString(), QStringLiteral("pinned"));
    EXPECT_EQ(places->data(row, PlacesModel::UrlRole).toUrl(), projects);
    EXPECT_EQ(places->data(row, PlacesModel::NameRole).toString(), QStringLiteral("Projects"));
    EXPECT_EQ(places->data(row, PlacesModel::SectionRole).toString(), QStringLiteral("favorites"));
    EXPECT_TRUE(app.inSidebar(projects));
    EXPECT_EQ(QSettings(QStringLiteral("Grassfield"), QStringLiteral("Files")).value(QStringLiteral("sidebar/favorites")).toStringList(), QStringList{projects.toString()});

    // Once only; then gone again (the folder stays on disk).
    app.addToSidebar({QUrl(projects.toString() + QLatin1Char('/'))}, 0);
    QCoreApplication::processEvents();
    EXPECT_EQ(places->pinnedCount(), 1);
    app.removeFromSidebar(projects);
    EXPECT_EQ(places->pinnedCount(), 0);
    EXPECT_FALSE(app.inSidebar(projects));
    EXPECT_TRUE(QFileInfo(projects.toLocalFile()).isDir());

    // A standard place: hidden, then listed again by Add to Sidebar.
    const QUrl home = QUrl::fromLocalFile(QDir::homePath());
    ASSERT_TRUE(app.inSidebar(home));
    app.removeFromSidebar(home);
    EXPECT_FALSE(app.inSidebar(home));
    EXPECT_EQ(QSettings(QStringLiteral("Grassfield"), QStringLiteral("Files")).value(QStringLiteral("sidebar/hidden")).toStringList(), QStringList{home.toString()});
    app.addToSidebar({home}, -1);
    EXPECT_TRUE(app.inSidebar(home));
    EXPECT_EQ(places->pinnedCount(), 0) << "listed again in its own place, not as a folder of the user's";
}

// Cut (owner request 2026-11-07, decision F-18): Cut fades the items (FolderModel's cut role) until Paste moves them through
// KIO's paste, which empties the clipboard, and Edit > Undo takes the move back; a cut from a GNOME file manager
// (x-special/gnome-copied-files) is a cut too; a new Copy and Esc (cancelCut) cancel it. Offscreen, the clipboard is the
// process's own. Each move is undone before the next step, so KIO's undo history is left as it was found.
TEST(CutAndPaste, CutFadesAndPasteMovesWhateverManagerCut)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    for (const char *name : {"a.txt", "b.txt", "c.txt"}) {
        QFile f(dir.filePath(QString::fromLatin1(name)));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(name);
    }
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("to")));
    const auto url = [&](const QString &rel) { return QUrl::fromLocalFile(dir.filePath(rel)); };
    const auto here = [&](const char *rel) { return QFileInfo::exists(dir.filePath(QString::fromLatin1(rel))); };
    FilesApp app(QList<QUrl>{});
    QStringList told;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&](const QString &message) { told << message; });
    auto *model = qobject_cast<FolderModel *>(app.createFolderModel(&app));
    ASSERT_NE(model, nullptr);
    model->setUrl(QUrl::fromLocalFile(dir.path()));
    ASSERT_TRUE(waitFor([&] { return !model->loading() && model->count() == 4; }));
    const auto cutShown = [&](const char *name) {
        for (int r = 0; r < model->count(); ++r)
            if (model->nameAt(r) == QLatin1String(name))
                return model->data(model->index(r, 0), FolderModel::CutRole).toBool();
        return false;
    };
    const auto undoMove = [&](const char *back) {
        if (!waitFor([&] { return app.canUndo(); }))
            return false;
        app.undo();
        return waitFor([&] { return here(back); });
    };

    app.copyToClipboard({url(QStringLiteral("a.txt"))}, true);
    EXPECT_TRUE(app.cutPending());
    EXPECT_TRUE(cutShown("a.txt"));
    EXPECT_FALSE(cutShown("b.txt"));
    // Both conventions are on the clipboard, for the other file managers.
    const QMimeData *data = QGuiApplication::clipboard()->mimeData();
    EXPECT_EQ(data->data(QStringLiteral("application/x-kde-cutselection")), QByteArray("1"));
    EXPECT_TRUE(data->data(QStringLiteral("x-special/gnome-copied-files")).startsWith("cut\n"));
    app.paste(url(QStringLiteral("to")), nullptr);
    ASSERT_TRUE(waitFor([&] { return here("to/a.txt") && !app.cutPending(); }));
    EXPECT_FALSE(here("a.txt")) << "moved, not copied";
    EXPECT_FALSE(app.canPaste()) << "a cut is pasted once";
    EXPECT_TRUE(undoMove("a.txt")) << "Undo takes the move back; told: " << told.join(QLatin1Char('|')).toStdString();
    EXPECT_FALSE(here("to/a.txt"));

    // A GNOME file manager's cut: Files moves it too, and fades it meanwhile.
    auto *gnome = new QMimeData;
    gnome->setUrls({url(QStringLiteral("b.txt"))});
    gnome->setData(QStringLiteral("x-special/gnome-copied-files"), "cut\n" + url(QStringLiteral("b.txt")).toEncoded());
    QGuiApplication::clipboard()->setMimeData(gnome);
    EXPECT_FALSE(app.cutPending()) << "Nautilus's cut fades here but is not Files' to cancel (integrator review, L1)";
    ASSERT_TRUE(waitFor([&] { return cutShown("b.txt"); }));
    app.paste(url(QStringLiteral("to")), nullptr);
    ASSERT_TRUE(waitFor([&] { return here("to/b.txt"); }));
    EXPECT_FALSE(here("b.txt"));
    EXPECT_TRUE(undoMove("b.txt")) << "told: " << told.join(QLatin1Char('|')).toStdString();

    // A new Copy cancels the cut; so does Esc (cancelCut), which empties the clipboard.
    app.copyToClipboard({url(QStringLiteral("c.txt"))}, true);
    ASSERT_TRUE(waitFor([&] { return cutShown("c.txt"); }));
    app.copyToClipboard({url(QStringLiteral("c.txt"))}, false);
    EXPECT_FALSE(app.cutPending());
    EXPECT_FALSE(cutShown("c.txt"));
    app.copyToClipboard({url(QStringLiteral("c.txt"))}, true);
    EXPECT_TRUE(app.cutPending());
    app.cancelCut();
    EXPECT_FALSE(app.cutPending());
    EXPECT_FALSE(app.canPaste());
    EXPECT_FALSE(cutShown("c.txt"));
    EXPECT_TRUE(here("c.txt")) << "cancelling moves nothing";
}

// Default applications (owner report 2026-11-07, decision F-19): in the Grassfield session Change All… writes the session's own
// list, grassfield-mimeapps.list (never mimeapps.list, which the Omarchy session reads); Get Info and Open With answer the
// choice at once and Open With lists it first, marked; KService reads the session's list; outside the session the choice goes
// to mimeapps.list as before. Two scratch applications for PNG pictures.
TEST(DefaultApplications, ChangeAllInTheSessionWritesTheSessionsOwnList)
{
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    const QString config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    ASSERT_TRUE(QDir().mkpath(apps) && QDir().mkpath(config));
    for (const char *id : {"org.example.ViewerA", "org.example.ViewerB"}) {
        QFile f(apps + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray("[Desktop Entry]\nType=Application\nName=") + id + "\nExec=/bin/true %f\nMimeType=image/png;\n");
    }
    QFile generic(config + QStringLiteral("/mimeapps.list"));
    ASSERT_TRUE(generic.open(QIODevice::WriteOnly));
    const QByteArray omarchy = "[Default Applications]\nimage/png=org.example.ViewerA.desktop;\n";
    generic.write(omarchy);
    generic.close();
    QTemporaryDir docs;
    ASSERT_TRUE(docs.isValid());
    QFile picture(docs.filePath(QStringLiteral("picture.png")));
    ASSERT_TRUE(picture.open(QIODevice::WriteOnly));
    picture.close();
    const QUrl doc = QUrl::fromLocalFile(picture.fileName());
    const QString type = QStringLiteral("image/png");
    const QByteArray desktop = qgetenv("XDG_CURRENT_DESKTOP");
    qputenv("XDG_CURRENT_DESKTOP", "Grassfield:Hyprland");
    FilesApp app(QList<QUrl>{});
    ASSERT_TRUE(waitFor([&] {
        KSycoca::self()->ensureCacheValid();
        return app.defaultApplication(type) == QLatin1String("org.example.ViewerA.desktop");
    })) << app.defaultApplication(type).toStdString();

    EXPECT_TRUE(app.setDefaultApplication(type, QStringLiteral("org.example.ViewerB.desktop")));
    EXPECT_EQ(app.defaultApplication(type), QStringLiteral("org.example.ViewerB.desktop")) << "answered at once";
    const QVariantList listed = app.applicationsFor({doc});
    ASSERT_FALSE(listed.isEmpty());
    EXPECT_EQ(listed.first().toMap().value(QStringLiteral("id")).toString(), QStringLiteral("org.example.ViewerB.desktop")) << "the default first";
    EXPECT_TRUE(listed.first().toMap().value(QStringLiteral("isDefault")).toBool());
    EXPECT_EQ(std::count_if(listed.cbegin(), listed.cend(), [](const QVariant &v) { return v.toMap().value(QStringLiteral("isDefault")).toBool(); }), 1);
    QFile session(config + QStringLiteral("/grassfield-mimeapps.list"));
    ASSERT_TRUE(session.open(QIODevice::ReadOnly));
    EXPECT_EQ(session.readAll(), QByteArray("[Default Applications]\nimage/png=org.example.ViewerB.desktop;\n"));
    session.close();
    ASSERT_TRUE(generic.open(QIODevice::ReadOnly));
    EXPECT_EQ(generic.readAll(), omarchy) << "the Omarchy session's list is untouched";
    generic.close();
    ASSERT_TRUE(waitFor([&] {
        KSycoca::self()->ensureCacheValid();
        const KService::Ptr s = KApplicationTrader::preferredService(type);
        return s && s->storageId() == QLatin1String("org.example.ViewerB.desktop");
    })) << "KService reads the session's list";

    // Outside the session: mimeapps.list, as before.
    qputenv("XDG_CURRENT_DESKTOP", "Hyprland");
    EXPECT_TRUE(app.setDefaultApplication(type, QStringLiteral("org.example.ViewerB.desktop")));
    ASSERT_TRUE(generic.open(QIODevice::ReadOnly));
    EXPECT_TRUE(generic.readAll().contains("image/png=org.example.ViewerB.desktop"));
    generic.close();
    if (desktop.isNull())
        qunsetenv("XDG_CURRENT_DESKTOP");
    else
        qputenv("XDG_CURRENT_DESKTOP", desktop);
    QFile::remove(config + QStringLiteral("/grassfield-mimeapps.list"));
    QFile::remove(config + QStringLiteral("/mimeapps.list"));
    for (const char *id : {"org.example.ViewerA", "org.example.ViewerB"})
        QFile::remove(apps + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
}

// Integrator review of c5dac3f3 (M1, L1, L3): a paste empties the clipboard only when it still holds this very cut (something
// copied while a slow move ran stays); Esc cancels only a cut Files wrote (another file manager's cut is not Files' to
// empty); cut items pasted into their own folder stay where they are and stay cut (KIO would refuse a move onto itself).
TEST(CutAndPaste, TheClipboardIsOnlyEverEmptiedForFilesOwnCut)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    for (const char *name : {"a.txt", "b.txt", "c.txt"}) {
        QFile f(dir.filePath(QString::fromLatin1(name)));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(name);
    }
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("to")));
    const auto url = [&](const QString &rel) { return QUrl::fromLocalFile(dir.filePath(rel)); };
    const auto here = [&](const char *rel) { return QFileInfo::exists(dir.filePath(QString::fromLatin1(rel))); };
    FilesApp app(QList<QUrl>{});
    QStringList told;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&](const QString &message) { told << message; });
    QClipboard *clipboard = QGuiApplication::clipboard();
    const auto undoMove = [&](const char *back) {
        if (!waitFor([&] { return app.canUndo(); }))
            return false;
        app.undo();
        return waitFor([&] { return here(back); });
    };

    // M1: a password copied while the move runs stays on the clipboard.
    app.copyToClipboard({url(QStringLiteral("a.txt"))}, true);
    app.paste(url(QStringLiteral("to")), nullptr);
    clipboard->setText(QStringLiteral("a password copied meanwhile"));
    ASSERT_TRUE(waitFor([&] { return here("to/a.txt") && !here("a.txt"); }));
    QCoreApplication::processEvents();
    ASSERT_TRUE(waitFor([&] { return app.canUndo(); })) << "the move ended";
    EXPECT_EQ(clipboard->text(), QStringLiteral("a password copied meanwhile")) << "the newer content is not emptied";
    EXPECT_TRUE(undoMove("a.txt")) << told.join(QLatin1Char('|')).toStdString();

    // L1: another file manager's cut fades its items but is not Files' to cancel.
    auto *gnome = new QMimeData;
    gnome->setUrls({url(QStringLiteral("b.txt"))});
    gnome->setData(QStringLiteral("x-special/gnome-copied-files"), "cut\n" + url(QStringLiteral("b.txt")).toEncoded());
    clipboard->setMimeData(gnome);
    EXPECT_FALSE(app.cutPending()) << "Nautilus's cut, not Files'";
    app.cancelCut();
    EXPECT_TRUE(app.canPaste()) << "Esc in Files leaves another application's clipboard alone";
    // Files' own cut is pending, until something else is copied with the same items but without Files' mark.
    app.copyToClipboard({url(QStringLiteral("b.txt"))}, true);
    EXPECT_TRUE(app.cutPending());
    auto *dolphin = new QMimeData;
    dolphin->setUrls({url(QStringLiteral("b.txt"))});
    dolphin->setData(QStringLiteral("application/x-kde-cutselection"), "1");
    clipboard->setMimeData(dolphin);
    EXPECT_FALSE(app.cutPending()) << "Dolphin's cut of the same item is Dolphin's";

    // L3: cut items pasted into their own folder: nothing moves, no conflict, and the cut stays for another folder.
    app.copyToClipboard({url(QStringLiteral("c.txt"))}, true);
    told.clear();
    const quint64 serial = KIO::FileUndoManager::self()->currentCommandSerialNumber();
    app.paste(QUrl::fromLocalFile(dir.path()), nullptr);
    for (int i = 0; i < 20; ++i)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 10);
    EXPECT_TRUE(here("c.txt"));
    EXPECT_TRUE(app.cutPending()) << "still cut";
    EXPECT_EQ(KIO::FileUndoManager::self()->currentCommandSerialNumber(), serial) << "no move was started";
    EXPECT_TRUE(told.isEmpty()) << "no conflict: " << told.join(QLatin1Char('|')).toStdString();
    app.paste(url(QStringLiteral("to")), nullptr);
    ASSERT_TRUE(waitFor([&] { return here("to/c.txt") && !app.cutPending(); })) << "then pasted elsewhere it moves";
    EXPECT_FALSE(app.canPaste()) << "and its own cut is consumed";
    EXPECT_TRUE(told.isEmpty()) << told.join(QLatin1Char('|')).toStdString();
    EXPECT_TRUE(undoMove("c.txt"));
}

// Integrator review, L4: items dropped at the edge of a Favorites place (an add-to-sidebar gap) that hold no folder go into
// that place instead of being refused; folders still join Favorites, and nothing falls back then.
TEST(SidebarFavorites, AnEdgeDropWithNoFolderGoesIntoThePlace)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Folder")));
    QFile file(dir.filePath(QStringLiteral("note.txt")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    FilesApp app(QList<QUrl>{});
    auto *places = qobject_cast<PlacesModel *>(app.places());
    ASSERT_NE(places, nullptr);
    QStringList told;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&](const QString &message) { told << message; });
    QList<std::tuple<QString, QList<QUrl>, QUrl>> fallbacks;
    QObject::connect(&app, &FilesApp::sidebarDropFallback, &app, [&](const QString &token, const QList<QUrl> &urls, const QUrl &destination) {
        fallbacks.append({token, urls, destination});
    });
    const QUrl documents = QUrl::fromLocalFile(QDir::homePath() + QStringLiteral("/Documents"));
    const QUrl note = QUrl::fromLocalFile(dir.filePath(QStringLiteral("note.txt")));
    app.addToSidebar({note}, 0, documents, QStringLiteral("t1"));
    ASSERT_TRUE(waitFor([&] { return !fallbacks.isEmpty(); }));
    EXPECT_EQ(std::get<0>(fallbacks.first()), QStringLiteral("t1"));
    EXPECT_EQ(std::get<1>(fallbacks.first()), QList<QUrl>{note});
    EXPECT_EQ(std::get<2>(fallbacks.first()), documents);
    EXPECT_TRUE(told.isEmpty()) << "no refusal banner";
    EXPECT_EQ(places->pinnedCount(), 0);
    // A folder among them: it joins, nothing falls back.
    const QUrl folder = QUrl::fromLocalFile(dir.filePath(QStringLiteral("Folder")));
    app.addToSidebar({folder, note}, 0, documents, QStringLiteral("t2"));
    ASSERT_TRUE(waitFor([&] { return places->pinnedCount() == 1; }));
    EXPECT_EQ(fallbacks.size(), 1);
    app.removeFromSidebar(folder);
    // A search location is never a sidebar folder (File > Add to Sidebar is dimmed there); a removed standard place is one.
    EXPECT_FALSE(app.sidebarCandidate(QUrl(QStringLiteral("grassfield-search:/?q=x"))));
    EXPECT_TRUE(app.sidebarCandidate(folder));
}
