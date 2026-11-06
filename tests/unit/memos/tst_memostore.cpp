// Grassfield Memos' store and text helpers (ADR-0051 D-3, D-4): round trip, privacy re-asserted at every launch, atomic
// writes, forward-only migration, a newer schema refused and untouched, an unreadable file set aside, every entry checked,
// no memo text in any log line, HTML cleaned of images and links, the Font menu's styles and the plain paste.
#include "memoformatter.h"
#include "memostore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>
#include <QTemporaryDir>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>

#include <gtest/gtest.h>

#include <sys/stat.h>

using namespace memos;

namespace {

constexpr QFileDevice::Permissions kPrivateFile = QFileDevice::ReadOwner | QFileDevice::WriteOwner;
constexpr QFileDevice::Permissions kPrivateDir = QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner;
const QString kSecret = QStringLiteral("SENTINEL-memo-text-7f3a");

QFileDevice::Permissions modeOf(const QString &path)
{
    // Only the bits the store sets (owner, group, other); QFile also reports the "user" bits, which follow the owner's.
    return QFileInfo(path).permissions()
        & (QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner | QFileDevice::ReadGroup | QFileDevice::WriteGroup
           | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther | QFileDevice::ExeOther);
}

QByteArray readAll(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

void writeAll(const QString &path, const QByteArray &bytes)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
    f.write(bytes);
}

Memo memo(const QString &html, const QString &color = QStringLiteral("blue"))
{
    Memo m;
    m.id = newId();
    m.color = color;
    m.html = html;
    m.width = 250;
    m.height = 180;
    m.hasPosition = true;
    m.x = -40;
    m.y = 300;
    m.created = QDateTime::fromString(QStringLiteral("2026-11-05T10:00:00Z"), Qt::ISODate);
    m.modified = QDateTime::fromString(QStringLiteral("2026-11-05T10:05:00Z"), Qt::ISODate);
    return m;
}

QStringList g_messages;
void collect(QtMsgType, const QMessageLogContext &, const QString &message)
{
    g_messages.append(message);
}

struct LogCapture
{
    QtMessageHandler previous;
    LogCapture()
    {
        g_messages.clear();
        previous = qInstallMessageHandler(collect);
    }
    ~LogCapture() { qInstallMessageHandler(previous); }
};

} // namespace

TEST(MemoStore, DataDirFollowsXdgDataHome)
{
    EXPECT_EQ(MemoStore::dataDir(QStringLiteral("/d"), QStringLiteral("/home/u")), QStringLiteral("/d/grassfield/memos"));
    EXPECT_EQ(MemoStore::dataDir(QString(), QStringLiteral("/home/u")), QStringLiteral("/home/u/.local/share/grassfield/memos"));
    // A relative value is ignored, as the XDG specification says.
    EXPECT_EQ(MemoStore::dataDir(QStringLiteral("rel"), QStringLiteral("/home/u")), QStringLiteral("/home/u/.local/share/grassfield/memos"));
}

TEST(MemoStore, RoundTripKeepsEveryField)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/grassfield/memos");
    MemoStore store(dir);
    EXPECT_EQ(store.open(240, 200), OpenState::Ok);
    EXPECT_TRUE(store.memos().isEmpty());
    Memo a = memo(QStringLiteral("<p><b>first</b></p>"));
    Memo b = memo(QStringLiteral("second"), QStringLiteral("grey"));
    b.hasPosition = false;
    b.collapsed = true;
    b.translucent = true;
    ASSERT_TRUE(store.save({a, b}));
    const QJsonObject root = QJsonDocument::fromJson(readAll(store.filePath())).object();
    EXPECT_EQ(root.value(QStringLiteral("schema")).toInt(), kSchema);
    EXPECT_FALSE(root.value(QStringLiteral("memos")).toArray().at(1).toObject().contains(QStringLiteral("x")));

    MemoStore again(dir);
    EXPECT_EQ(again.open(240, 200), OpenState::Ok);
    ASSERT_EQ(again.memos().size(), 2);
    EXPECT_TRUE(again.memos().at(0) == a);
    EXPECT_TRUE(again.memos().at(1) == b);
}

TEST(MemoStore, PrivacyIsReassertedAtEveryOpenAndWrite)
{
    QTemporaryDir tmp;
    const QString dir = tmp.path() + QStringLiteral("/memos");
    MemoStore store(dir);
    store.open(240, 200);
    EXPECT_EQ(modeOf(dir), kPrivateDir);
    ASSERT_TRUE(store.save({memo(QStringLiteral("x"))}));
    EXPECT_EQ(modeOf(store.filePath()), kPrivateFile);

    // An older build, a restored backup or the user widened them: the next launch narrows them again.
    QFile::setPermissions(dir, kPrivateDir | QFileDevice::ReadGroup | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::ExeOther);
    QFile::setPermissions(store.filePath(), kPrivateFile | QFileDevice::ReadGroup | QFileDevice::ReadOther);
    MemoStore relaunch(dir);
    EXPECT_EQ(relaunch.open(240, 200), OpenState::Ok);
    EXPECT_EQ(modeOf(dir), kPrivateDir);
    EXPECT_EQ(modeOf(store.filePath()), kPrivateFile);

    QFile::setPermissions(store.filePath(), kPrivateFile | QFileDevice::ReadOther);
    ASSERT_TRUE(relaunch.save(relaunch.memos()));
    EXPECT_EQ(modeOf(store.filePath()), kPrivateFile);
}

TEST(MemoStore, WritesAreAtomic)
{
    QTemporaryDir tmp;
    MemoStore store(tmp.path());
    store.open(240, 200);
    ASSERT_TRUE(store.save({memo(QStringLiteral("old"))}));
    const QByteArray before = readAll(store.filePath());
    // Only the file: no temporary file is left beside it.
    EXPECT_EQ(QDir(tmp.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("memos.json")});

    // A write that fails before its rename leaves the previous file whole, and no temporary file.
    store.injectWriteFault(true);
    EXPECT_FALSE(store.save({memo(QStringLiteral("new"))}));
    EXPECT_FALSE(store.errorString().isEmpty());
    EXPECT_EQ(readAll(store.filePath()), before);
    EXPECT_EQ(QDir(tmp.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("memos.json")});
    store.injectWriteFault(false);
    EXPECT_TRUE(store.save({memo(QStringLiteral("new"))}));
    EXPECT_NE(readAll(store.filePath()), before);
}

TEST(MemoStore, NewerSchemaIsRefusedAndNeverRewritten)
{
    QTemporaryDir tmp;
    const QString file = tmp.path() + QStringLiteral("/memos.json");
    const QByteArray newer = QByteArrayLiteral("{\"schema\": 2, \"memos\": [{\"id\": \"x\", \"html\": \"keep me\", \"shape\": \"round\"}]}");
    writeAll(file, newer);
    MemoStore store(tmp.path());
    EXPECT_EQ(store.open(240, 200), OpenState::Newer);
    EXPECT_TRUE(store.readOnly());
    EXPECT_TRUE(store.memos().isEmpty());
    EXPECT_EQ(store.foundSchema(), 2);
    EXPECT_FALSE(store.save({memo(QStringLiteral("would overwrite"))}));
    EXPECT_EQ(readAll(file), newer);
    // Its privacy is still asserted (that changes no byte).
    EXPECT_EQ(modeOf(file), kPrivateFile);
    // Nothing else was written beside it.
    EXPECT_EQ(QDir(tmp.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("memos.json")});
}

TEST(MemoStore, OlderSchemaIsMigratedForwardOnceWithItsOriginalKept)
{
    QTemporaryDir tmp;
    const QString file = tmp.path() + QStringLiteral("/memos.json");
    const QString id = newId();
    const QByteArray v1 = QStringLiteral("{\"schema\": 1, \"memos\": [{\"id\": \"%1\", \"color\": \"green\", \"html\": \"hello\", "
                                         "\"width\": 300, \"height\": 220}]}")
                              .arg(id)
                              .toUtf8();
    writeAll(file, v1);
    // A schema 2 of tomorrow: its step records that it ran.
    int ran = 0;
    Migrations steps{{1, [&ran](QJsonObject &doc) {
                          ++ran;
                          doc.insert(QStringLiteral("migratedFrom"), 1);
                          return true;
                      }}};
    MemoStore store(tmp.path(), 2, steps);
    EXPECT_EQ(store.open(240, 200), OpenState::Migrated);
    EXPECT_EQ(ran, 1);
    ASSERT_EQ(store.memos().size(), 1);
    EXPECT_EQ(store.memos().at(0).id, id);
    EXPECT_EQ(store.memos().at(0).color, QStringLiteral("green"));
    EXPECT_EQ(store.memos().at(0).width, 300);
    const QJsonObject written = QJsonDocument::fromJson(readAll(file)).object();
    EXPECT_EQ(written.value(QStringLiteral("schema")).toInt(), 2);
    EXPECT_EQ(written.value(QStringLiteral("migratedFrom")).toInt(), 1);
    const QString backup = file + QStringLiteral(".schema-1");
    EXPECT_EQ(readAll(backup), v1);
    EXPECT_EQ(modeOf(backup), kPrivateFile);
    EXPECT_EQ(modeOf(file), kPrivateFile);

    // The next launch reads schema 2 as it is: no second migration, the backup untouched.
    MemoStore again(tmp.path(), 2, steps);
    EXPECT_EQ(again.open(240, 200), OpenState::Ok);
    EXPECT_EQ(ran, 1);
    EXPECT_EQ(readAll(backup), v1);
}

TEST(MemoStore, AMissingOrFailingStepRefusesWithoutWriting)
{
    QTemporaryDir tmp;
    const QString file = tmp.path() + QStringLiteral("/memos.json");
    const QByteArray v1 = QByteArrayLiteral("{\"schema\": 1, \"memos\": []}");
    writeAll(file, v1);
    MemoStore noStep(tmp.path(), 3, Migrations{{1, [](QJsonObject &) { return true; }}}); // 2 -> 3 is missing
    EXPECT_EQ(noStep.open(240, 200), OpenState::Unreadable);
    EXPECT_TRUE(noStep.readOnly());
    EXPECT_EQ(readAll(file), v1);
    MemoStore failing(tmp.path(), 2, Migrations{{1, [](QJsonObject &) { return false; }}});
    EXPECT_EQ(failing.open(240, 200), OpenState::Unreadable);
    EXPECT_EQ(readAll(file), v1);
    // Schema 0 or below has no step either.
    writeAll(file, QByteArrayLiteral("{\"schema\": 0, \"memos\": []}"));
    MemoStore zero(tmp.path());
    EXPECT_EQ(zero.open(240, 200), OpenState::Unreadable);
}

TEST(MemoStore, AnUnreadableFileIsSetAsideAndTheStoreStartsEmpty)
{
    for (const QByteArray &bad : {QByteArrayLiteral("{not json"), QByteArrayLiteral("[1,2]"), QByteArrayLiteral("{\"memos\": []}"),
                                  QByteArrayLiteral("{\"schema\": \"1\"}")}) {
        QTemporaryDir tmp;
        const QString file = tmp.path() + QStringLiteral("/memos.json");
        writeAll(file, bad);
        MemoStore store(tmp.path());
        EXPECT_EQ(store.open(240, 200), OpenState::SetAside) << bad.constData();
        EXPECT_FALSE(store.readOnly());
        EXPECT_FALSE(QFileInfo::exists(file));
        const QStringList aside = QDir(tmp.path()).entryList({QStringLiteral("memos.json.unreadable-*")}, QDir::Files);
        ASSERT_EQ(aside.size(), 1);
        EXPECT_EQ(readAll(tmp.path() + QLatin1Char('/') + aside.first()), bad);
        EXPECT_EQ(modeOf(tmp.path() + QLatin1Char('/') + aside.first()), kPrivateFile);
        EXPECT_TRUE(store.save({memo(QStringLiteral("fresh"))}));
    }
}

TEST(MemoStore, IoErrorsAndHugeFilesAreRefusedUntouched)
{
    QTemporaryDir tmp;
    // A directory where the file should be.
    QDir().mkpath(tmp.path() + QStringLiteral("/memos.json"));
    MemoStore blocked(tmp.path());
    EXPECT_EQ(blocked.open(240, 200), OpenState::Unreadable);
    EXPECT_FALSE(blocked.save({}));

    QTemporaryDir big;
    const QString file = big.path() + QStringLiteral("/memos.json");
    {
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        ASSERT_TRUE(f.resize(kMaxFileBytes + 1)); // sparse
    }
    MemoStore huge(big.path());
    EXPECT_EQ(huge.open(240, 200), OpenState::Unreadable);
    EXPECT_EQ(QFileInfo(file).size(), kMaxFileBytes + 1);
}

TEST(MemoStore, EveryEntryIsCheckedAndRepaired)
{
    QTemporaryDir tmp;
    const QString good = newId();
    const QByteArray doc = QStringLiteral(
                               "{\"schema\": 1, \"memos\": ["
                               "{\"id\": \"../../etc\", \"color\": \"chartreuse\", \"width\": 5, \"height\": 99999, \"x\": 1.5, \"y\": 3},"
                               "\"not a memo\","
                               "{\"id\": \"%1\", \"color\": \"pink\", \"x\": -20, \"y\": 40, \"collapsed\": true, \"floating\": \"yes\"},"
                               "{\"id\": \"%1\"}"
                               "]}")
                               .arg(good)
                               .toUtf8();
    writeAll(tmp.path() + QStringLiteral("/memos.json"), doc);
    MemoStore store(tmp.path());
    EXPECT_EQ(store.open(240, 200), OpenState::Ok);
    ASSERT_EQ(store.memos().size(), 3);
    const Memo &a = store.memos().at(0);
    EXPECT_TRUE(isId(a.id));
    EXPECT_EQ(a.color, defaultColor());
    EXPECT_EQ(a.width, kMinSide);
    EXPECT_EQ(a.height, kMaxSide);
    EXPECT_FALSE(a.hasPosition); // x is not an integer
    const Memo &b = store.memos().at(1);
    EXPECT_EQ(b.id, good);
    EXPECT_EQ(b.color, QStringLiteral("pink"));
    EXPECT_EQ(b.width, 240);
    EXPECT_EQ(b.height, 200);
    EXPECT_TRUE(b.hasPosition);
    EXPECT_EQ(b.x, -20);
    EXPECT_EQ(b.y, 40);
    EXPECT_TRUE(b.collapsed);
    // The same id twice: the second gets one of its own.
    EXPECT_NE(store.memos().at(2).id, good);
    EXPECT_TRUE(isId(store.memos().at(2).id));
}

TEST(MemoStore, ColoursAndIds)
{
    EXPECT_EQ(colorNames(), (QStringList{QStringLiteral("yellow"), QStringLiteral("blue"), QStringLiteral("green"), QStringLiteral("pink"),
                                          QStringLiteral("purple"), QStringLiteral("grey")}));
    EXPECT_EQ(defaultColor(), QStringLiteral("yellow"));
    EXPECT_FALSE(isColorName(QStringLiteral("Yellow")));
    const QString a = newId();
    EXPECT_TRUE(isId(a));
    EXPECT_NE(a, newId());
    EXPECT_FALSE(isId(a.toUpper()));
    EXPECT_FALSE(isId(a.left(31)));
}

TEST(MemoStore, NoMemoTextEverReachesALogOrAnError)
{
    LogCapture capture;
    QStringList errors;
    {
        QTemporaryDir tmp;
        writeAll(tmp.path() + QStringLiteral("/memos.json"), QStringLiteral("{\"schema\": 9, \"memos\": [{\"html\": \"%1\"}]}").arg(kSecret).toUtf8());
        MemoStore s(tmp.path());
        s.open(240, 200);
        s.save({memo(kSecret)});
        errors << s.errorString();
    }
    {
        QTemporaryDir tmp;
        writeAll(tmp.path() + QStringLiteral("/memos.json"), QStringLiteral("{\"schema\": 1, \"memos\": [{\"html\": \"%1\"").arg(kSecret).toUtf8());
        MemoStore s(tmp.path());
        s.open(240, 200);
        errors << s.errorString();
    }
    {
        QTemporaryDir tmp;
        writeAll(tmp.path() + QStringLiteral("/memos.json"),
                 QStringLiteral("{\"schema\": 1, \"memos\": [\"%1\", {\"html\": \"%1\"}]}").arg(kSecret).toUtf8());
        MemoStore s(tmp.path(), 2, Migrations{{1, [](QJsonObject &) { return true; }}});
        s.open(240, 200);
        s.injectWriteFault(true);
        s.save({memo(kSecret)});
        errors << s.errorString();
        MemoStore refused(tmp.path(), 3, {});
        refused.open(240, 200);
        errors << refused.errorString();
    }
    EXPECT_FALSE(g_messages.isEmpty()); // the cases above did log (the check below is not vacuous)
    for (const QString &m : std::as_const(g_messages))
        EXPECT_FALSE(m.contains(kSecret)) << qPrintable(m);
    for (const QString &e : std::as_const(errors))
        EXPECT_FALSE(e.contains(kSecret)) << qPrintable(e);
}

TEST(MemoStore, TheTemporaryFileIsPrivateBeforeItsRename)
{
    QTemporaryDir tmp;
    MemoStore store(tmp.path());
    store.open(240, 200);
    QStringList seen;
    store.setBeforeCommitHook([&] {
        // The bytes are in the temporary file now: it must already be 0600 (a mode set after the write, or only after the
        // rename, leaves the memo text readable by others meanwhile). QSaveFile may use an unnamed file (O_TMPFILE), so the
        // file is found among this process's open descriptors, by the directory it lives in.
        for (const QFileInfo &fd : QDir(QStringLiteral("/proc/self/fd")).entryInfoList(QDir::Files | QDir::System | QDir::NoDotAndDotDot)) {
            const QString target = fd.symLinkTarget();
            if (!target.startsWith(tmp.path() + QLatin1Char('/')) || target == tmp.path() + QStringLiteral("/memos.json"))
                continue;
            seen << target;
            struct stat st {};
            EXPECT_EQ(::stat(qPrintable(fd.filePath()), &st), 0);
            EXPECT_EQ(st.st_mode & 0777, 0600u) << qPrintable(target);
            EXPECT_GT(st.st_size, 0) << "the bytes are written before the check";
        }
        return true;
    });
    // The widest umask a session could have, and an older file that others could read: neither leaks into the new file.
    ASSERT_TRUE(store.save({memo(QStringLiteral("old"))}));
    store.setBeforeCommitHook(nullptr);
    QFile::setPermissions(store.filePath(), kPrivateFile | QFileDevice::ReadGroup | QFileDevice::ReadOther);
    const mode_t previous = ::umask(0);
    seen.clear();
    store.setBeforeCommitHook([&] {
        for (const QFileInfo &fd : QDir(QStringLiteral("/proc/self/fd")).entryInfoList(QDir::Files | QDir::System | QDir::NoDotAndDotDot)) {
            const QString target = fd.symLinkTarget();
            if (!target.startsWith(tmp.path() + QLatin1Char('/')) || target == tmp.path() + QStringLiteral("/memos.json"))
                continue;
            seen << target;
            struct stat st {};
            EXPECT_EQ(::stat(qPrintable(fd.filePath()), &st), 0);
            EXPECT_EQ(st.st_mode & 0777, 0600u) << qPrintable(target);
        }
        return true;
    });
    const bool ok = store.save({memo(QStringLiteral("x"))});
    ::umask(previous);
    ASSERT_TRUE(ok);
    EXPECT_EQ(seen.size(), 1);
    EXPECT_EQ(modeOf(store.filePath()), kPrivateFile);
}

TEST(MemoStore, EntriesThatWouldBeDroppedAreKeptAsideFirst)
{
    // Review of the memos slice: a shaped file whose "memos" is not a list, or holds entries that are not memos, would be
    // emptied (or thinned) by the next save. The original is kept beside it first, as a migration keeps its original.
    const QString id = newId();
    for (const QByteArray &doc : {QByteArrayLiteral("{\"schema\": 1, \"memos\": {\"a\": 1}}"),
                                  QStringLiteral("{\"schema\": 1, \"memos\": [7, {\"id\": \"%1\", \"html\": \"kept\"}]}").arg(id).toUtf8()}) {
        QTemporaryDir tmp;
        writeAll(tmp.path() + QStringLiteral("/memos.json"), doc);
        MemoStore store(tmp.path());
        EXPECT_EQ(store.open(240, 200), OpenState::Ok) << doc.constData();
        const QStringList kept = QDir(tmp.path()).entryList({QStringLiteral("memos.json.dropped-*")}, QDir::Files);
        ASSERT_EQ(kept.size(), 1) << doc.constData();
        EXPECT_EQ(readAll(tmp.path() + QLatin1Char('/') + kept.first()), doc);
        EXPECT_EQ(modeOf(tmp.path() + QLatin1Char('/') + kept.first()), kPrivateFile);
        EXPECT_TRUE(store.save(store.memos()));
    }
    // A clean file keeps nothing aside.
    QTemporaryDir clean;
    writeAll(clean.path() + QStringLiteral("/memos.json"), QByteArrayLiteral("{\"schema\": 1, \"memos\": []}"));
    MemoStore store(clean.path());
    EXPECT_EQ(store.open(240, 200), OpenState::Ok);
    EXPECT_TRUE(QDir(clean.path()).entryList({QStringLiteral("memos.json.dropped-*")}, QDir::Files).isEmpty());
}

TEST(MemoText, CleanHtmlDropsBackgroundImages)
{
    // Review of the memos slice: a table's, a cell's, a frame's or a paragraph's background URL survived cleanHtml, and Qt Quick
    // would load it.
    const QString cleaned = cleanHtml(QStringLiteral(
        "<body background=\"http://body.invalid/b.png\"><table background=\"http://table.invalid/t.png\" bgcolor=\"#ff0\"><tr>"
        "<td background=\"http://cell.invalid/c.png\">cell</td></tr></table>"
        "<p style=\"background-image: url(http://para.invalid/p.png)\">para</p>"
        "<p><span style=\"background-image: url(http://span.invalid/s.png)\">span</span></p></body>"));
    for (const char *host : {"body.invalid", "table.invalid", "cell.invalid", "para.invalid", "span.invalid"})
        EXPECT_FALSE(cleaned.contains(QLatin1String(host))) << host << "\n" << qPrintable(cleaned);
    QTextDocument doc;
    doc.setHtml(cleaned);
    EXPECT_TRUE(doc.toPlainText().contains(QStringLiteral("cell")));
    EXPECT_TRUE(doc.toPlainText().contains(QStringLiteral("para")));
    EXPECT_TRUE(doc.toPlainText().contains(QStringLiteral("span")));
}

TEST(MemoText, CleanHtmlDropsImagesAndLinksKeepsTheText)
{
    const QString cleaned = cleanHtml(QStringLiteral("<p>before <img src=\"http://example.invalid/track.png\"> after "
                                                     "<a href=\"http://example.invalid/\">link text</a> <b>bold</b></p>"));
    EXPECT_FALSE(cleaned.contains(QStringLiteral("<img")));
    EXPECT_FALSE(cleaned.contains(QStringLiteral("example.invalid")));
    EXPECT_FALSE(cleaned.contains(QStringLiteral("href")));
    QTextDocument doc;
    doc.setHtml(cleaned);
    EXPECT_EQ(doc.toPlainText(), QStringLiteral("before  after link text bold"));
    EXPECT_TRUE(cleaned.contains(QStringLiteral("font-weight")));
}

TEST(MemoText, FirstLineSkipsEmptyLines)
{
    EXPECT_EQ(firstLine(QStringLiteral("<p></p><p>  Groceries </p><p>milk</p>")), QStringLiteral("Groceries"));
    EXPECT_EQ(firstLine(QString()), QString());
}

TEST(MemoText, FontStylesToggleOnTheSelection)
{
    QTextDocument doc;
    doc.setPlainText(QStringLiteral("hello world"));
    MemoFormatter::toggleBold(&doc, 0, 5);
    QTextCursor c(&doc);
    c.setPosition(3);
    EXPECT_EQ(c.charFormat().fontWeight(), QFont::Bold);
    c.setPosition(8);
    EXPECT_NE(c.charFormat().fontWeight(), QFont::Bold);
    MemoFormatter::toggleBold(&doc, 0, 5);
    c.setPosition(3);
    EXPECT_NE(c.charFormat().fontWeight(), QFont::Bold);
    // An empty selection styles the word at the cursor.
    MemoFormatter::toggleItalic(&doc, 8, 8);
    c.setPosition(9);
    EXPECT_TRUE(c.charFormat().fontItalic());
    c.setPosition(3);
    EXPECT_FALSE(c.charFormat().fontItalic());
    MemoFormatter::toggleUnderline(&doc, 0, 11);
    c.setPosition(10);
    EXPECT_TRUE(c.charFormat().fontUnderline());
}

TEST(MemoText, SizesStepAndStayInRange)
{
    QTextDocument doc;
    doc.setPlainText(QStringLiteral("abc"));
    MemoFormatter::changeSize(&doc, 0, 3, 1, 13, 9, 15);
    QTextCursor c(&doc);
    c.setPosition(2);
    EXPECT_EQ(c.charFormat().intProperty(QTextFormat::FontPixelSize), 14);
    MemoFormatter::changeSize(&doc, 0, 3, 5, 13, 9, 15);
    c.setPosition(2);
    EXPECT_EQ(c.charFormat().intProperty(QTextFormat::FontPixelSize), 15);
    MemoFormatter::changeSize(&doc, 0, 1, -20, 13, 9, 15);
    c.setPosition(1);
    EXPECT_EQ(c.charFormat().intProperty(QTextFormat::FontPixelSize), 9);
    c.setPosition(3);
    EXPECT_EQ(c.charFormat().intProperty(QTextFormat::FontPixelSize), 15);
}

TEST(MemoText, BulletedListOnAndOff)
{
    QTextDocument doc;
    doc.setPlainText(QStringLiteral("one\ntwo\nthree"));
    MemoFormatter::toggleList(&doc, 0, 6);
    EXPECT_NE(doc.findBlockByNumber(0).textList(), nullptr);
    EXPECT_NE(doc.findBlockByNumber(1).textList(), nullptr);
    EXPECT_EQ(doc.findBlockByNumber(2).textList(), nullptr);
    MemoFormatter::toggleList(&doc, 0, 6);
    EXPECT_EQ(doc.findBlockByNumber(0).textList(), nullptr);
    EXPECT_EQ(doc.findBlockByNumber(1).textList(), nullptr);
}

TEST(MemoText, PasteIsAlwaysPlainText)
{
    QTextDocument doc;
    doc.setPlainText(QStringLiteral("ab"));
    const int end = MemoFormatter::insertPlain(&doc, 1, 1, QStringLiteral("<img src=\"http://x.invalid/a.png\"><b>B</b>\r\nC\x01"));
    EXPECT_EQ(doc.toPlainText(), QStringLiteral("a<img src=\"http://x.invalid/a.png\"><b>B</b>\nCb"));
    EXPECT_EQ(end, 1 + 34 + 8 + 2); // after "C": the tag, the bold markup, the line end and C, as typed characters
    // A selection is replaced.
    MemoFormatter::insertPlain(&doc, 0, doc.characterCount() - 1, QStringLiteral("z"));
    EXPECT_EQ(doc.toPlainText(), QStringLiteral("z"));
    EXPECT_FALSE(doc.toHtml().contains(QStringLiteral("<img")));
}
