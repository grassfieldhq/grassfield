// The glue of Files' data-changing commands (review of PR #98): over real files in a scratch folder, FilesApp's
// Get Info permissions (setAccess, applyToEnclosed), Delete Immediately (deletePermanently), Make Alias, New Folder with
// Selection and Rename N Items; each command that renames or makes several things is ONE undo step, and nothing is replaced.
// Real KIO jobs where the commands use them; part of files-kio-tests (a scratch home).
#include "filesapp.h"
#include "applicationslogic.h"
#include "filelogic.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QThread>
#include <QVariantMap>

#include <KIO/FileUndoManager>

#include <gtest/gtest.h>

#include <sys/stat.h>

namespace
{
bool waitFor(const std::function<bool()> &done, int ms = 15000)
{
    QDeadlineTimer deadline(ms);
    while (!done() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    return done();
}

void write(const QString &path, const QByteArray &bytes = QByteArray("x"))
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray read(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

bool present(const QString &path)
{
    return QFileInfo::exists(path) || QFileInfo(path).isSymLink();
}

unsigned modeOf(const QString &path)
{
    struct stat st{};
    return ::stat(QFile::encodeName(path).constData(), &st) == 0 ? unsigned(st.st_mode & 07777) : 0xffffffffu;
}

bool setMode(const QString &path, unsigned mode)
{
    return ::chmod(QFile::encodeName(path).constData(), mode) == 0;
}

QUrl url(const QString &path)
{
    return QUrl::fromLocalFile(path);
}

// Records what a command tells the user.
struct Told {
    explicit Told(FilesApp &app) { QObject::connect(&app, &FilesApp::operationFailed, &app, [this](const QString &m) { messages << m; }); }
    QStringList messages;
};

// A scratch folder per test; the undo history of this process is emptied of KIO jobs still running.
class FileOps : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        // Other tests of this binary may have left commands in KIO's history: what counts is what changes.
        m_kioUndoBefore = KIO::FileUndoManager::self()->isUndoAvailable();
        m_serialBefore = KIO::FileUndoManager::self()->currentCommandSerialNumber();
    }
    QString d(const char *name = "") const { return m_dir.filePath(QString::fromLatin1(name)); }
    QTemporaryDir m_dir;
    bool m_kioUndoBefore = false;
    quint64 m_serialBefore = 0;
};
} // namespace

TEST_F(FileOps, SetAccessChangesOnlyTheUsersOwnPlainItemsThroughThePinnedItem)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("f.txt"));
    ASSERT_TRUE(setMode(d("f.txt"), 0644));
    int changed = 0;
    QObject::connect(&app, &FilesApp::permissionsChanged, &app, [&changed](const QUrl &) { ++changed; });

    // Others: no access; group: read and write.
    app.setAccess(url(d("f.txt")), 2, 0);
    EXPECT_EQ(modeOf(d("f.txt")), 0640u);
    app.setAccess(url(d("f.txt")), 1, 3);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u);
    EXPECT_EQ(changed, 2) << "the window is told to read the item again";
    const QVariantMap p = app.permissionsOf(url(d("f.txt")));
    EXPECT_TRUE(p.value(QStringLiteral("editable")).toBool());

    // Not a valid row or privilege: nothing changes.
    app.setAccess(url(d("f.txt")), 3, 0);
    app.setAccess(url(d("f.txt")), 0, 9);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u);

    // An alias keeps its own permissions and the original's are not touched through it (O_NOFOLLOW).
    ASSERT_TRUE(QFile::link(d("f.txt"), d("link")));
    const QVariantMap l = app.permissionsOf(url(d("link")));
    EXPECT_FALSE(l.value(QStringLiteral("editable")).toBool());
    EXPECT_FALSE(l.value(QStringLiteral("reason")).toString().isEmpty());
    app.setAccess(url(d("link")), 0, 0);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u) << "the link's target is left alone";

    // System items and other people's items are shown, never changed.
    EXPECT_FALSE(app.permissionsOf(QUrl::fromLocalFile(QStringLiteral("/proc/self"))).value(QStringLiteral("editable")).toBool());
    const unsigned env = modeOf(QStringLiteral("/usr/bin/env"));
    EXPECT_FALSE(app.permissionsOf(QUrl::fromLocalFile(QStringLiteral("/usr/bin/env"))).value(QStringLiteral("editable")).toBool()) << "owned by root";
    app.setAccess(QUrl::fromLocalFile(QStringLiteral("/usr/bin/env")), 2, 0);
    EXPECT_EQ(modeOf(QStringLiteral("/usr/bin/env")), env);
    // A server's item has no permissions to show.
    EXPECT_FALSE(app.permissionsOf(QUrl(QStringLiteral("sftp://host/file"))).value(QStringLiteral("valid")).toBool());
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}

TEST_F(FileOps, ApplyToEnclosedReachesEveryItemButNeverFollowsALink)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("outside.txt"));
    ASSERT_TRUE(setMode(d("outside.txt"), 0644));
    write(d("root/file1.txt"));
    write(d("root/sub/file2.txt"));
    ASSERT_TRUE(setMode(d("root/file1.txt"), 0644));
    ASSERT_TRUE(setMode(d("root/sub/file2.txt"), 0666));
    ASSERT_TRUE(QFile::link(d("outside.txt"), d("root/to-outside")));
    ASSERT_TRUE(setMode(d("root"), 0755));
    // The folder's own privileges first: others get nothing.
    app.setAccess(url(d("root")), 2, 0);
    EXPECT_EQ(modeOf(d("root")), 0750u);

    int told1 = 0;
    QObject::connect(&app, &FilesApp::permissionsChanged, &app, [&told1](const QUrl &) { ++told1; });
    app.applyToEnclosed(url(d("root")));
    ASSERT_TRUE(waitFor([&] { return told1 > 0; })) << "the window is told when chmod ended";
    EXPECT_EQ(modeOf(d("root/file1.txt")) & 07, 0u) << "others lost their access to the files inside";
    EXPECT_EQ(modeOf(d("root/sub/file2.txt")) & 07, 0u) << "at any depth";
    EXPECT_EQ(modeOf(d("root/sub")) & 07, 0u);
    EXPECT_EQ(modeOf(d("outside.txt")), 0644u) << "a link inside is not followed";
    // Not a folder, a link or a system item: nothing runs.
    told1 = 0;
    app.applyToEnclosed(url(d("root/file1.txt")));
    app.applyToEnclosed(url(d("root/to-outside")));
    app.applyToEnclosed(QUrl::fromLocalFile(QStringLiteral("/proc")));
    QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
    EXPECT_EQ(told1, 0);
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}

TEST_F(FileOps, DeleteImmediatelyDeletesAnyItemAndNeverAnApplication)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"));
    write(d("folder/inner/b.txt"));
    write(d("keep.txt"));
    // Not in the Trash, a file and a folder with content: both go, the neighbour stays.
    app.deletePermanently({url(d("a.txt")), url(d("folder"))});
    ASSERT_TRUE(waitFor([&] { return !present(d("a.txt")) && !present(d("folder")); }));
    EXPECT_TRUE(present(d("keep.txt")));
    EXPECT_EQ(KIO::FileUndoManager::self()->currentCommandSerialNumber(), m_serialBefore) << "never undoable: nothing was recorded";
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore);
    EXPECT_TRUE(told.messages.isEmpty());
    // An application of the Applications location is refused with the permission message, whatever the window asked.
    app.deletePermanently({ApplicationsLogic::entryUrl(QStringLiteral("org.example.Nothing"))});
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("permission")));
    // Nothing to delete: nothing happens.
    app.deletePermanently({});
    EXPECT_EQ(told.messages.size(), 1);
}

TEST_F(FileOps, MakeAliasIsOneUndoStepAndNeverReplacesAName)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("report.txt"), "r");
    write(d("notes.txt"), "n");
    write(d("report.txt alias"), "the user's own file");
    app.makeAlias({url(d("report.txt")), url(d("notes.txt"))}, nullptr);
    EXPECT_TRUE(told.messages.isEmpty());
    EXPECT_EQ(read(d("report.txt alias")), QByteArray("the user's own file")) << "a name that exists is never replaced";
    EXPECT_EQ(QFileInfo(d("report.txt alias 2")).symLinkTarget(), d("report.txt"));
    EXPECT_EQ(QFileInfo(d("notes.txt alias")).symLinkTarget(), d("notes.txt"));
    EXPECT_TRUE(app.canUndo());
    // One Undo removes both aliases (the Finder's one step per command); the originals stay.
    app.undo();
    EXPECT_FALSE(present(d("report.txt alias 2")));
    EXPECT_FALSE(present(d("notes.txt alias")));
    EXPECT_EQ(read(d("report.txt")), QByteArray("r"));
    EXPECT_EQ(read(d("report.txt alias")), QByteArray("the user's own file"));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "the command was ONE step";
    EXPECT_TRUE(app.canRedo());
    app.redo();
    EXPECT_TRUE(QFileInfo(d("report.txt alias 2")).isSymLink());
    EXPECT_TRUE(QFileInfo(d("notes.txt alias")).isSymLink());
    EXPECT_FALSE(app.canRedo());
    // An item on a server has no alias here.
    app.makeAlias({QUrl(QStringLiteral("sftp://host/file"))}, nullptr);
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("on this computer")));
    // An application is refused.
    app.makeAlias({ApplicationsLogic::entryUrl(QStringLiteral("org.example.Nothing"))}, nullptr);
    EXPECT_EQ(told.messages.size(), 2);
}

TEST_F(FileOps, NewFolderWithSelectionIsOneUndoStep)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    write(d("New Folder With Items/old.txt"), "o");
    app.newFolderWithItems({url(d("a.txt")), url(d("b.txt"))}, url(m_dir.path()), nullptr);
    EXPECT_TRUE(told.messages.isEmpty());
    // The name is taken: the next one is made, the items move into it, the other folder is untouched.
    EXPECT_EQ(read(d("New Folder With Items 2/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("New Folder With Items 2/b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("a.txt")));
    EXPECT_EQ(read(d("New Folder With Items/old.txt")), QByteArray("o"));
    // One Undo: the items back, the new folder gone.
    app.undo();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("New Folder With Items 2")));
    EXPECT_TRUE(present(d("New Folder With Items/old.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "the command was ONE step, not a folder and a move";
    app.redo();
    EXPECT_EQ(read(d("New Folder With Items 2/a.txt")), QByteArray("a"));
    // Items of another folder are refused before anything is made.
    write(d("elsewhere/c.txt"), "c");
    app.newFolderWithItems({url(d("elsewhere/c.txt"))}, url(m_dir.path()), nullptr);
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("items of the shown folder")));
    EXPECT_TRUE(present(d("elsewhere/c.txt")));
    EXPECT_FALSE(present(d("New Folder With Items 3")));
}

TEST_F(FileOps, RenameNItemsIsAllOrNothingAndOneUndoStep)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    for (const char *n : {"a.txt", "b.txt", "c.txt"})
        write(d(n), QByteArray(n));
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);        // Add Text
    add.insert(QStringLiteral("addText"), QStringLiteral("-new"));
    add.insert(QStringLiteral("where"), 0);       // after the name
    EXPECT_EQ(app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr), QString());
    for (const char *n : {"a-new.txt", "b-new.txt", "c-new.txt"})
        EXPECT_TRUE(present(d(n))) << n;
    EXPECT_FALSE(present(d("a.txt")));
    // One Undo puts all three back.
    EXPECT_TRUE(app.canUndo());
    app.undo();
    for (const char *n : {"a.txt", "b.txt", "c.txt"})
        EXPECT_EQ(read(d(n)), QByteArray(n)) << n;
    EXPECT_FALSE(present(d("b-new.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "N renames were ONE step";
    app.redo();
    EXPECT_TRUE(present(d("c-new.txt")));
    app.undo();

    // A name taken on the disk by something else: nothing at all is renamed, and the user is told.
    write(d("b-new.txt"), "the user's own file");
    const QString why = app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr);
    EXPECT_TRUE(why.contains(QStringLiteral("already taken"))) << why.toStdString();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a.txt"));
    EXPECT_EQ(read(d("c.txt")), QByteArray("c.txt"));
    EXPECT_FALSE(present(d("a-new.txt")));
    EXPECT_FALSE(present(d("c-new.txt")));
    EXPECT_EQ(read(d("b-new.txt")), QByteArray("the user's own file")) << "never replaced";
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "a refused command records nothing";
    // A source that vanished since the window listed it: the others are not renamed either.
    ASSERT_TRUE(QFile::remove(d("b-new.txt")));
    ASSERT_TRUE(QFile::remove(d("b.txt")));
    EXPECT_FALSE(app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr).isEmpty());
    EXPECT_EQ(read(d("a.txt")), QByteArray("a.txt"));
    EXPECT_EQ(read(d("c.txt")), QByteArray("c.txt"));
    EXPECT_FALSE(present(d("a-new.txt")));
    EXPECT_FALSE(present(d("c-new.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore);
}

TEST_F(FileOps, UndoFollowsTheOrderOfTheCommandsWhoeverRecordedThem)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("one.txt"), "1");
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    // A single rename (a KIO job, recorded by KIO), then a batch (Files' own command), then an alias.
    app.rename(url(d("one.txt")), QStringLiteral("uno.txt"), nullptr);
    ASSERT_TRUE(waitFor([&] { return present(d("uno.txt")); }));
    ASSERT_TRUE(waitFor([&] { return KIO::FileUndoManager::self()->isUndoAvailable(); }));
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);
    add.insert(QStringLiteral("addText"), QStringLiteral("-x"));
    ASSERT_EQ(app.renameItems({url(d("a.txt")), url(d("b.txt"))}, add, nullptr), QString());
    app.makeAlias({url(d("uno.txt"))}, nullptr);
    ASSERT_TRUE(present(d("uno.txt alias")));
    // Undo, newest first: the alias, the batch, then the single rename (KIO's).
    app.undo();
    EXPECT_FALSE(present(d("uno.txt alias")));
    EXPECT_TRUE(present(d("a-x.txt")));
    app.undo();
    EXPECT_TRUE(present(d("a.txt")));
    EXPECT_TRUE(present(d("b.txt")));
    EXPECT_FALSE(present(d("a-x.txt")));
    EXPECT_TRUE(present(d("uno.txt")));
    EXPECT_TRUE(app.canUndo());
    app.undo();
    ASSERT_TRUE(waitFor([&] { return present(d("one.txt")); }));
    EXPECT_FALSE(present(d("uno.txt")));
    ASSERT_TRUE(waitFor([&] { return app.canRedo(); }));
    // Redo goes back in the order undo went.
    app.redo();
    ASSERT_TRUE(waitFor([&] { return present(d("uno.txt")); }));
    app.redo();
    EXPECT_TRUE(present(d("a-x.txt")));
    app.redo();
    EXPECT_TRUE(QFileInfo(d("uno.txt alias")).isSymLink());
    EXPECT_FALSE(app.canRedo());
    // A new command ends the redo history.
    app.undo();
    EXPECT_TRUE(app.canRedo());
    app.makeAlias({url(d("a-x.txt"))}, nullptr);
    EXPECT_FALSE(app.canRedo());
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}

// Go to Folder's Return (FP-76; review of PR #98): what is typed wins when it exists, so "/" and "~/" open the root and the home
// folder themselves while the "Go to:" list of the same text has their subfolders; a partial name has no target (the panel then
// completes it); a missing path has none and no match. The panel's use of this is tests/unit/tst_filesgoto.qml.
TEST_F(FileOps, GoToFolderTargetsAreTheTypedFolderWhenItExists)
{
    FilesApp app(QList<QUrl>{});
    const QString home = QDir::homePath(); // the scratch home of this binary
    ASSERT_TRUE(QDir().mkpath(home + QStringLiteral("/Documents")));
    ASSERT_TRUE(QDir().mkpath(home + QStringLiteral("/Desktop")));
    write(home + QStringLiteral("/notes.txt"));
    const QUrl base = url(home);
    const auto folderOf = [&](const QString &text) { return app.goToTarget(text, base).value(QStringLiteral("folder")).toUrl(); };
    const auto selectOf = [&](const QString &text) { return app.goToTarget(text, base).value(QStringLiteral("select")).toUrl(); };

    EXPECT_EQ(folderOf(QStringLiteral("/")), url(QStringLiteral("/"))) << "the root itself, not /bin";
    EXPECT_EQ(folderOf(QStringLiteral("~/")), url(home)) << "the home folder itself, not ~/Desktop";
    EXPECT_EQ(folderOf(QStringLiteral("~")), url(home));
    EXPECT_EQ(folderOf(QStringLiteral("~/Documents")), url(home + QStringLiteral("/Documents"))) << "an existing folder without a trailing slash";
    EXPECT_EQ(folderOf(QStringLiteral("~/Documents/")), url(home + QStringLiteral("/Documents")));
    EXPECT_EQ(folderOf(QStringLiteral("Documents")), url(home + QStringLiteral("/Documents"))) << "relative to the shown folder";
    // A file opens its folder with the file selected.
    EXPECT_EQ(folderOf(QStringLiteral("~/notes.txt")), url(home));
    EXPECT_EQ(selectOf(QStringLiteral("~/notes.txt")), url(home + QStringLiteral("/notes.txt")));
    // Partial or missing: no target (the panel completes the first, tells the second).
    EXPECT_TRUE(folderOf(QStringLiteral("~/Doc")).isEmpty());
    EXPECT_TRUE(folderOf(QStringLiteral("~/Nowhere")).isEmpty());
    EXPECT_TRUE(folderOf(QStringLiteral("/nowhere/at/all")).isEmpty());
    EXPECT_TRUE(folderOf(QString()).isEmpty());

    // The list of the same texts: "~/" lists the home's subfolders (which is why Return must not take the first), "~/Doc"
    // completes to Documents.
    QStringList names;
    QString answeredFor;
    QObject::connect(&app, &FilesApp::folderCompletions, &app, [&](const QString &text, const QVariantList &matches) {
        answeredFor = text;
        names.clear();
        for (const QVariant &m : matches)
            names << m.toMap().value(QStringLiteral("name")).toString();
    });
    app.completeFolder(QStringLiteral("~/"), base);
    ASSERT_TRUE(waitFor([&] { return answeredFor == QStringLiteral("~/"); }));
    EXPECT_TRUE(names.contains(QStringLiteral("Desktop")));
    EXPECT_TRUE(names.contains(QStringLiteral("Documents")));
    app.completeFolder(QStringLiteral("~/Doc"), base);
    ASSERT_TRUE(waitFor([&] { return answeredFor == QStringLiteral("~/Doc"); }));
    EXPECT_EQ(names, QStringList{QStringLiteral("Documents")});
    app.completeFolder(QStringLiteral("~/Nowhere"), base);
    ASSERT_TRUE(waitFor([&] { return answeredFor == QStringLiteral("~/Nowhere"); }));
    EXPECT_TRUE(names.isEmpty());
}

// A failed undo keeps the command on the stack (review of PR #98, mutant U3), a command of KIO's ends Files' redo history (U4), a
// New Folder with Selection that fails records nothing (U5), and a rollback that failed too says which items stayed changed and
// keeps them undoable.
TEST_F(FileOps, AFailedUndoKeepsTheCommandAndAKioCommandEndsTheRedoHistory)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("report.txt"), "r");
    app.makeAlias({url(d("report.txt"))}, nullptr);
    ASSERT_TRUE(QFileInfo(d("report.txt alias")).isSymLink());
    // The user replaced the alias by a file of their own: the undo is refused, nothing is removed, the command stays.
    ASSERT_TRUE(QFile::remove(d("report.txt alias")));
    write(d("report.txt alias"), "mine");
    app.undo();
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("can’t be undone")));
    EXPECT_EQ(read(d("report.txt alias")), QByteArray("mine"));
    EXPECT_TRUE(app.canUndo());
    EXPECT_FALSE(app.canRedo()) << "nothing was undone";
    // Put the alias back: the same command undoes now.
    ASSERT_TRUE(QFile::remove(d("report.txt alias")));
    ASSERT_TRUE(QFile::link(d("report.txt"), d("report.txt alias")));
    app.undo();
    EXPECT_FALSE(present(d("report.txt alias")));
    ASSERT_TRUE(app.canRedo());
    // A command of KIO's (a single rename) ends the redo history at once.
    app.rename(url(d("report.txt")), QStringLiteral("rapport.txt"), nullptr);
    EXPECT_FALSE(app.canRedo());
    ASSERT_TRUE(waitFor([&] { return present(d("rapport.txt")); }));
    app.redo();
    EXPECT_FALSE(present(d("report.txt alias"))) << "the old redo is gone";
}

TEST_F(FileOps, AFailedNewFolderWithSelectionRecordsNothing)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    ASSERT_TRUE(QFile::remove(d("b.txt"))); // gone since the window listed it
    // Other tests of this binary may have left steps in the history: what counts is that this command adds none.
    const quint64 serial = KIO::FileUndoManager::self()->currentCommandSerialNumber();
    const QString undoBefore = app.undoText();
    app.newFolderWithItems({url(d("a.txt")), url(d("b.txt"))}, url(m_dir.path()), nullptr);
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("Nothing was changed")));
    EXPECT_FALSE(present(d("New Folder With Items"))) << "the folder was made and taken away again";
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_EQ(app.undoText(), undoBefore) << "no undo step for a command that did nothing";
    EXPECT_EQ(KIO::FileUndoManager::self()->currentCommandSerialNumber(), serial);
    app.undo(); // nothing of this command to undo: no folder comes back from nowhere, a.txt stays where it is
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
}

TEST_F(FileOps, ARollbackThatFailedToSaysWhatStayedChangedAndKeepsItUndoable)
{
    FilesApp app(QList<QUrl>{});
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    write(d("c.txt"), "c");
    ASSERT_TRUE(QFile::remove(d("b.txt"))); // the second rename fails; the first cannot be put back (the folder is read-only by then)
    BatchOps::setStepHook([&](int step) {
        if (step == 0)
            ::chmod(QFile::encodeName(m_dir.path()).constData(), 0500);
    });
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);
    add.insert(QStringLiteral("addText"), QStringLiteral("-x"));
    const QString why = app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr);
    BatchOps::setStepHook({});
    ::chmod(QFile::encodeName(m_dir.path()).constData(), 0700);
    EXPECT_TRUE(why.contains(QStringLiteral("These stayed changed"))) << why.toStdString();
    EXPECT_TRUE(why.contains(QStringLiteral("a-x.txt"))) << "it names the item";
    EXPECT_FALSE(why.contains(QStringLiteral("Nothing was changed")));
    EXPECT_EQ(read(d("a-x.txt")), QByteArray("a"));
    // What stayed done is one undo step.
    ASSERT_TRUE(app.canUndo());
    EXPECT_EQ(app.undoText(), QStringLiteral("Undo Rename 1 Item")) << "the singular";
    app.undo();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_FALSE(present(d("a-x.txt")));
}

// A command whose undo stops half way keeps only the steps that were not undone (review of PR #98, A3): what was undone is not
// undone twice, and Undo again finishes it.
TEST_F(FileOps, APartlyUndoneCommandKeepsOnlyTheStepsNotUndone)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);
    add.insert(QStringLiteral("addText"), QStringLiteral("-x"));
    ASSERT_EQ(app.renameItems({url(d("a.txt")), url(d("b.txt"))}, add, nullptr), QString());
    ASSERT_EQ(app.undoText(), QStringLiteral("Undo Rename 2 Items"));
    // The undo puts b-x.txt back (its newest step first), then the folder turns read-only and a-x.txt cannot move.
    BatchOps::setStepHook([&](int step) {
        if (step == 0)
            ::chmod(QFile::encodeName(m_dir.path()).constData(), 0500);
    });
    app.undo();
    BatchOps::setStepHook({});
    ::chmod(QFile::encodeName(m_dir.path()).constData(), 0700);
    // The failing step reverted the one done before it (the folder is read-only: it could not), so one step stays undone.
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("Part of it was undone")));
    const bool bBack = present(d("b.txt"));
    EXPECT_TRUE(bBack);
    EXPECT_TRUE(present(d("a-x.txt")));
    EXPECT_EQ(app.undoText(), QStringLiteral("Undo Rename 2 Items")) << "the command stays on the stack";
    // Undo again: only the step not undone runs (a second b-x.txt -> b.txt would fail), and the command is finished.
    app.undo();
    EXPECT_EQ(told.messages.size(), 1) << told.messages.last().toStdString();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("a-x.txt")));
    EXPECT_TRUE(app.canRedo());
}

// The Copy window of a paste (FP-68): KIO's PasteJob forwards no amounts, so a pasted copy showed a bar that stayed empty and no
// "X of Y" line. Files follows the copy the paste runs inside: the published job tells the bytes, and names the items asked for
// and the folder they go to.
TEST_F(FileOps, APastedCopyShowsItsAmountsInTheCopyWindow)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    // The rows wait 250 ms before they are published, and a copy of this size ends sooner on a fast disk (tmpfs): the
    // test shortens that wait, which is not what it checks (it checks that the amounts reach the row).
    app.setProgressDelayForTests(1);
    const QByteArray block(1024, 'x');
    for (int i = 0; i < 8000; ++i)
        write(d("src/big/f") + QString::number(i), block);
    QDir().mkpath(d("dst"));
    app.copyToClipboard({url(d("src/big"))}, false);
    app.paste(url(d("dst")), nullptr);
    bool shown = false;
    QString detail;
    QString title;
    int percent = -1;
    waitFor([&] {
        const QVariantList rows = app.jobs();
        if (!rows.isEmpty()) {
            const QVariantMap row = rows.first().toMap();
            const QString line = row.value(QStringLiteral("detail")).toString();
            // The first row with amounts (a row before the sub-copy is found says "Preparing…").
            if (line.contains(QStringLiteral(" of "))) {
                shown = true;
                detail = line;
                title = row.value(QStringLiteral("title")).toString();
                percent = row.value(QStringLiteral("percent")).toInt();
            }
        }
        return shown || (rows.isEmpty() && present(d("dst/big/f7999")));
    });
    EXPECT_TRUE(shown) << "the paste published no amounts";
    EXPECT_TRUE(title.contains(QStringLiteral("big"))) << title.toStdString();
    EXPECT_TRUE(title.contains(QStringLiteral("dst"))) << title.toStdString();
    EXPECT_GE(percent, 0);
    // Let the job end before the scratch folder goes.
    waitFor([&] { return app.jobs().isEmpty() && present(d("dst/big/f7999")); }, 60000);
    EXPECT_TRUE(told.messages.isEmpty());
}

// A drop that is no move: on the folder the item is in (the release over the source's own column), or of a folder on itself or
// into its own tree. Nothing is moved or copied, no job runs, and a folder dropped into itself says why.
TEST_F(FileOps, ADropOnTheSourcesOwnPlaceMovesNothing)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    write(d("dir/b.txt"), "b");
    QDir().mkpath(d("dir/sub"));
    app.drop({url(d("a.txt"))}, url(m_dir.path()), nullptr);
    app.drop({url(d("dir"))}, url(d("dir")), nullptr);
    app.drop({url(d("dir"))}, url(d("dir/sub")), nullptr);
    EXPECT_TRUE(app.jobs().isEmpty());
    EXPECT_EQ(told.messages.size(), 2) << "the two drops into itself say so, the one on its own folder is quiet";
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("dir/b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("dir/sub/dir")));
    EXPECT_FALSE(present(d("dir/dir")));
}

// Move Item Here has a drop's checks: into the items' own folder nothing happens (KIO raised a conflict sheet for a move
// onto itself), and a folder moved into its own tree says why. No job runs.
TEST_F(FileOps, MoveItemHereOnTheItemsOwnPlaceMovesNothing)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    QDir().mkpath(d("dir/sub"));
    app.copyToClipboard({url(d("a.txt"))}, false);
    app.moveHere(url(m_dir.path()), nullptr);
    EXPECT_TRUE(app.jobs().isEmpty());
    EXPECT_TRUE(told.messages.isEmpty()) << "its own folder is quiet";
    app.copyToClipboard({url(d("dir"))}, false);
    app.moveHere(url(d("dir/sub")), nullptr);
    EXPECT_TRUE(app.jobs().isEmpty());
    EXPECT_EQ(told.messages.size(), 1) << "into itself says so";
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_FALSE(present(d("dir/sub/dir")));
}

// Duplicate twice in a row: the second run does not take the name the first one chose while that copy is not made yet (it
// raised a conflict sheet). Two copies, no message.
TEST_F(FileOps, DuplicateTwiceInARowGivesTwoCopies)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("dup/a.txt"), "a");
    app.duplicate({url(d("dup/a.txt"))}, nullptr);
    app.duplicate({url(d("dup/a.txt"))}, nullptr);
    const auto entries = [&] { return QDir(d("dup")).entryList(QDir::Files | QDir::NoDotAndDotDot); };
    EXPECT_TRUE(waitFor([&] { return entries().size() == 3; })) << entries().join(QLatin1Char(' ')).toStdString();
    EXPECT_TRUE(told.messages.isEmpty());
}

// Share > Send with LocalSend… (ADR-0045 OC-13): FilesApp runs nothing but Omarchy's vector with existing local paths, and a
// development session runs nothing at all (systemd-run --user would open LocalSend on the owner's real desktop; security
// review LOW 2). The dev refusal comes before LocalSend is looked up, so the test needs no LocalSend.
TEST_F(FileOps, SendWithLocalSendRefusesOtherVectorsAndADevSession)
{
    const QByteArray devBefore = qgetenv("GRASSFIELD_DEV");
    const QByteArray sessionBefore = qgetenv("GRASSFIELD_SESSION");
    const bool hadDev = qEnvironmentVariableIsSet("GRASSFIELD_DEV");
    const bool hadSession = qEnvironmentVariableIsSet("GRASSFIELD_SESSION");
    qputenv("GRASSFIELD_DEV", "1");
    qunsetenv("GRASSFIELD_SESSION");
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"));
    const QStringList prefix = {QStringLiteral("systemd-run"), QStringLiteral("--user"), QStringLiteral("--quiet"), QStringLiteral("--collect"),
                                QStringLiteral("localsend"), QStringLiteral("--headless"), QStringLiteral("send")};
    app.sendWithLocalSend(QStringList{QStringLiteral("sh"), QStringLiteral("-c"), QStringLiteral("true")});
    app.sendWithLocalSend(prefix + QStringList{QStringLiteral("relative.txt")});
    app.sendWithLocalSend(prefix + QStringList{d("missing.txt")});
    EXPECT_EQ(told.messages.size(), 3) << "another program, a relative path, a missing item: refused";
    told.messages.clear();
    app.sendWithLocalSend(prefix + QStringList{d("a.txt")});
    ASSERT_EQ(told.messages.size(), 1) << "a dev session sends nothing";
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("development session"))) << told.messages.first().toStdString();
    hadDev ? qputenv("GRASSFIELD_DEV", devBefore) : qunsetenv("GRASSFIELD_DEV");
    hadSession ? qputenv("GRASSFIELD_SESSION", sessionBefore) : qunsetenv("GRASSFIELD_SESSION");
}
