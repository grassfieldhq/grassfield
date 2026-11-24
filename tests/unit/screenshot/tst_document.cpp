// The document model, Done and Revert, the atomic replacement and the history entry (slice B2).
#include "atomicfile.h"
#include "capturehistory.h"
#include "document.h"
#include "layers.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <memory>

#include <sys/stat.h>
#include <unistd.h>

using namespace screenshot;

namespace {

QByteArray readAll(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

int modeOf(const QString &path)
{
    struct stat st;
    return ::stat(QFile::encodeName(path).constData(), &st) == 0 ? int(st.st_mode & 07777) : -1;
}

// The exporter of these tests: a 3 x 3 red square for every layer, so that the exported picture differs from the original.
QImage markExporter(const QImage &original, const Layers &layers)
{
    QImage out = original.convertToFormat(QImage::Format_ARGB32);
    QPainter p(&out);
    p.fillRect(0, 0, layers.isEmpty() ? 0 : 3, 3, Qt::red);
    return out;
}

Layers oneLayer()
{
    return {Layer{1, "rectangle", QJsonObject{{"x", 1}, {"y", 2}, {"w", 3}, {"h", 4}}}};
}

class DocumentTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        m_pics = m_dir.path() + "/pics";
        ASSERT_TRUE(QDir().mkpath(m_pics));
        m_history = std::make_unique<CaptureHistory>(m_dir.path() + "/state/capture-history");
        QImage image(40, 30, QImage::Format_ARGB32);
        image.fill(QColor(10, 20, 30));
        m_file = m_pics + "/Screenshot.png";
        ASSERT_TRUE(image.save(m_file, "PNG"));
        m_original = readAll(m_file);
    }

    QStringList picsListing() const { return QDir(m_pics).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden, QDir::Name); }

    QTemporaryDir m_dir;
    QString m_pics;
    QString m_file;
    QByteArray m_original;
    std::unique_ptr<CaptureHistory> m_history;
};

} // namespace

TEST_F(DocumentTest, OpensAPng)
{
    Document doc(m_history.get());
    QString why;
    ASSERT_TRUE(doc.open(m_file, &why)) << why.toStdString();
    EXPECT_EQ(doc.original().size(), QSize(40, 30));
    EXPECT_TRUE(doc.layers().isEmpty());
    EXPECT_FALSE(doc.dirty());
    EXPECT_FALSE(doc.canRevert());
    EXPECT_FALSE(doc.entry().has_value());
}

TEST_F(DocumentTest, RefusesWhatIsNotAPng)
{
    Document doc(m_history.get());
    QFile f(m_pics + "/words.png");
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("hello");
    f.close();
    QString why;
    EXPECT_FALSE(doc.open(m_pics + "/words.png", &why));
    EXPECT_FALSE(why.isEmpty());
    EXPECT_FALSE(doc.open(m_pics + "/missing.png", &why));
    EXPECT_FALSE(doc.isOpen());
}

TEST_F(DocumentTest, DoneWithoutChangesWritesNothing)
{
    Document doc(m_history.get());
    ASSERT_TRUE(doc.open(m_file));
    EXPECT_TRUE(doc.done());
    EXPECT_EQ(readAll(m_file), m_original);
    EXPECT_FALSE(QFileInfo::exists(m_history->root())) << "no history entry for an untouched picture";
}

TEST_F(DocumentTest, DoneReplacesTheFileAndWritesTheHistoryEntry)
{
    ::chmod(QFile::encodeName(m_file).constData(), 0640);
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    EXPECT_TRUE(doc.dirty());
    QString why;
    ASSERT_TRUE(doc.done(&why)) << why.toStdString();
    EXPECT_FALSE(doc.dirty());
    EXPECT_TRUE(doc.canRevert());

    // The file holds the exported picture, with its own mode, and nothing else is left beside it.
    EXPECT_NE(readAll(m_file), m_original);
    QImage saved(m_file);
    EXPECT_EQ(saved.pixelColor(1, 1), QColor(Qt::red));
    EXPECT_EQ(saved.pixelColor(10, 10), QColor(10, 20, 30));
    EXPECT_EQ(modeOf(m_file), 0640);
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"}) << "no hidden temporary file is left";

    // The history entry: the original as captured, the layers, the index line, the modes.
    ASSERT_TRUE(doc.entry().has_value());
    const HistoryEntry e = *doc.entry();
    EXPECT_TRUE(CaptureHistory::validId(e.id));
    EXPECT_EQ(readAll(m_history->originalPath(e.id)), m_original);
    Layers stored;
    ASSERT_TRUE(layersFromJson(readAll(m_history->layersPath(e.id)), &stored));
    EXPECT_EQ(stored, oneLayer());
    const QList<HistoryEntry> all = m_history->entries();
    ASSERT_EQ(all.size(), 1);
    EXPECT_EQ(all[0].path, m_file);
    EXPECT_EQ(all[0].kind, "shot");
    EXPECT_EQ(all[0].width, 40);
    EXPECT_EQ(all[0].height, 30);
    EXPECT_EQ(all[0].original, CaptureHistory::sha256(m_original));
    EXPECT_EQ(all[0].current, CaptureHistory::sha256(readAll(m_file)));
    EXPECT_EQ(modeOf(m_history->root()), 0700);
    EXPECT_EQ(modeOf(m_history->root() + "/" + e.id), 0700);
    EXPECT_EQ(modeOf(m_history->root() + "/index.json"), 0600);
    EXPECT_EQ(modeOf(m_history->originalPath(e.id)), 0600);
    EXPECT_EQ(modeOf(m_history->layersPath(e.id)), 0600);
    // No recognised text, no other field than the documented ones.
    const QJsonObject line = QJsonDocument::fromJson(readAll(m_history->root() + "/index.json")).object().value("entries").toArray()[0].toObject();
    EXPECT_EQ(line.keys(), (QStringList{"cur", "h", "id", "kind", "orig", "path", "time", "w"}));
}

TEST_F(DocumentTest, AtomicSaveLeavesNoPartialFileAfterAForcedFailure)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());

    // A failure after the temporary file is complete and before the rename (a full disk, a crash, a refused replacement).
    QString seen;
    doc.setBeforeRename([&seen](const QString &hidden) {
        seen = hidden;
        return false;
    });
    QString why;
    EXPECT_FALSE(doc.done(&why));
    EXPECT_FALSE(why.isEmpty());
    EXPECT_FALSE(seen.isEmpty()) << "the hook saw the complete hidden file";
    EXPECT_EQ(QFileInfo(seen).dir().path(), m_pics) << "next to the target, so that the rename is atomic";
    EXPECT_TRUE(QFileInfo(seen).fileName().startsWith('.')) << "hidden";
    EXPECT_EQ(readAll(m_file), m_original) << "the target keeps its old bytes whole";
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"}) << "and the hidden file is gone";
    EXPECT_TRUE(doc.dirty()) << "the edits are not lost";

    // Once the cause is gone, the same document saves.
    doc.setBeforeRename({});
    EXPECT_TRUE(doc.done(&why)) << why.toStdString();
    EXPECT_NE(readAll(m_file), m_original);
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"});
}

TEST_F(DocumentTest, AtomicSaveInAFolderThatCannotBeWrittenLeavesTheFileAlone)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    ASSERT_EQ(::chmod(QFile::encodeName(m_pics).constData(), 0500), 0);
    if (::access(QFile::encodeName(m_pics + "/x").constData(), W_OK) == 0 || ::geteuid() == 0) {
        ::chmod(QFile::encodeName(m_pics).constData(), 0700);
        GTEST_SKIP() << "the folder stays writable (root)";
    }
    QString why;
    EXPECT_FALSE(doc.done(&why));
    EXPECT_FALSE(why.isEmpty());
    ::chmod(QFile::encodeName(m_pics).constData(), 0700);
    EXPECT_EQ(readAll(m_file), m_original);
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"});
    ASSERT_TRUE(doc.entry().has_value()) << "the original is in the history before the file is touched";
    EXPECT_EQ(readAll(m_history->originalPath(doc.entry()->id)), m_original);
}

TEST_F(DocumentTest, RevertRestoresTheOriginal)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    ASSERT_TRUE(doc.done());
    ASSERT_NE(readAll(m_file), m_original);
    ASSERT_TRUE(doc.canRevert());
    const QString id = doc.entry()->id;

    QString why;
    ASSERT_TRUE(doc.revert(&why)) << why.toStdString();
    EXPECT_EQ(readAll(m_file), m_original) << "the file's bytes are the captured ones again";
    EXPECT_TRUE(doc.layers().isEmpty());
    EXPECT_FALSE(doc.dirty());
    EXPECT_FALSE(doc.canRevert());
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"});
    EXPECT_EQ(m_history->entries()[0].current, QString()) << "the index no longer calls the file an edited result";
    Layers stored;
    ASSERT_TRUE(layersFromJson(readAll(m_history->layersPath(id)), &stored));
    EXPECT_TRUE(stored.isEmpty());
    EXPECT_EQ(readAll(m_history->originalPath(id)), m_original) << "the original stays for the next edit";

    // A second round keeps the same entry and the same original.
    doc.setLayers(oneLayer());
    ASSERT_TRUE(doc.done());
    EXPECT_EQ(doc.entry()->id, id);
    ASSERT_TRUE(doc.revert());
    EXPECT_EQ(readAll(m_file), m_original);
    EXPECT_EQ(m_history->entries().size(), 1);
}

TEST_F(DocumentTest, RevertOfAnUneditedPictureRefuses)
{
    Document doc(m_history.get());
    ASSERT_TRUE(doc.open(m_file));
    QString why;
    EXPECT_FALSE(doc.revert(&why));
    EXPECT_FALSE(why.isEmpty());
    EXPECT_EQ(readAll(m_file), m_original);
}

TEST_F(DocumentTest, RevertFailureKeepsTheEditedFile)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    ASSERT_TRUE(doc.done());
    const QByteArray edited = readAll(m_file);
    doc.setBeforeRename([](const QString &) { return false; });
    EXPECT_FALSE(doc.revert());
    EXPECT_EQ(readAll(m_file), edited);
    EXPECT_EQ(picsListing(), QStringList{"Screenshot.png"});
    EXPECT_TRUE(doc.canRevert());
}

TEST_F(DocumentTest, ReopeningAnEditedPictureFindsTheOriginalAndTheLayers)
{
    {
        Document doc(m_history.get());
        doc.setExporter(markExporter);
        ASSERT_TRUE(doc.open(m_file));
        doc.setLayers(oneLayer());
        ASSERT_TRUE(doc.done());
    }
    Document again(m_history.get());
    again.setExporter(markExporter);
    QString why;
    ASSERT_TRUE(again.open(m_file, &why)) << why.toStdString();
    EXPECT_EQ(again.layers(), oneLayer()) << "the layers come back";
    EXPECT_FALSE(again.dirty());
    EXPECT_TRUE(again.canRevert());
    QByteArray originalBytes;
    {
        QBuffer b(&originalBytes);
        b.open(QIODevice::WriteOnly);
        again.original().save(&b, "PNG");
    }
    EXPECT_EQ(again.original().pixelColor(1, 1), QColor(10, 20, 30)) << "editing goes on from the capture, not from the flattened file";
    ASSERT_TRUE(again.revert());
    EXPECT_EQ(readAll(m_file), m_original);
}

TEST_F(DocumentTest, AFileChangedElsewhereIsNeverReplaced)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    QImage other(40, 30, QImage::Format_ARGB32);
    other.fill(Qt::green);
    ASSERT_TRUE(other.save(m_file, "PNG"));
    const QByteArray theirs = readAll(m_file);
    QString why;
    EXPECT_FALSE(doc.done(&why));
    EXPECT_NE(why.indexOf("changed"), -1) << why.toStdString();
    EXPECT_EQ(readAll(m_file), theirs);
}

TEST_F(DocumentTest, ANewCaptureAtTheSamePathDoesNotGetAnotherPicturesOriginal)
{
    {
        Document doc(m_history.get());
        doc.setExporter(markExporter);
        ASSERT_TRUE(doc.open(m_file));
        doc.setLayers(oneLayer());
        ASSERT_TRUE(doc.done());
    }
    QImage fresh(40, 30, QImage::Format_ARGB32);
    fresh.fill(Qt::yellow);
    ASSERT_TRUE(fresh.save(m_file, "PNG"));
    Document doc(m_history.get());
    ASSERT_TRUE(doc.open(m_file));
    EXPECT_FALSE(doc.entry().has_value());
    EXPECT_FALSE(doc.canRevert());
    EXPECT_EQ(doc.original().pixelColor(5, 5), QColor(Qt::yellow));
}

TEST_F(DocumentTest, AFileEditedAgainOnTopOfTheHistoryEntryReplacesThatEntry)
{
    Document doc(m_history.get());
    doc.setExporter(markExporter);
    ASSERT_TRUE(doc.open(m_file));
    doc.setLayers(oneLayer());
    ASSERT_TRUE(doc.done());
    const QString first = doc.entry()->id;
    QImage fresh(40, 30, QImage::Format_ARGB32);
    fresh.fill(Qt::yellow);
    ASSERT_TRUE(fresh.save(m_file, "PNG"));
    Document next(m_history.get());
    next.setExporter(markExporter);
    ASSERT_TRUE(next.open(m_file));
    next.setLayers(oneLayer());
    ASSERT_TRUE(next.done());
    EXPECT_NE(next.entry()->id, first);
    EXPECT_EQ(m_history->entries().size(), 1) << "one entry per picture file";
    EXPECT_FALSE(QFileInfo::exists(m_history->root() + "/" + first)) << "the folder of the replaced entry is removed";
}

// ---- the atomic replacement on its own ----

TEST(AtomicFile, ReplacesAndKeepsTheModeOfTheTarget)
{
    QTemporaryDir dir;
    const QString path = dir.path() + "/f.bin";
    {
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("old");
    }
    ::chmod(QFile::encodeName(path).constData(), 0604);
    QString why;
    ASSERT_TRUE(atomicWrite(path, "brand new bytes", -1, &why)) << why.toStdString();
    EXPECT_EQ(readAll(path), QByteArray("brand new bytes"));
    EXPECT_EQ(modeOf(path), 0604);
    ASSERT_TRUE(atomicWrite(path, "x", 0600, &why));
    EXPECT_EQ(modeOf(path), 0600);
    EXPECT_EQ(QDir(dir.path()).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden), QStringList{"f.bin"});
}

TEST(AtomicFile, NewFileDefaultsToPrivate)
{
    QTemporaryDir dir;
    ASSERT_TRUE(atomicWrite(dir.path() + "/new", "data"));
    EXPECT_EQ(modeOf(dir.path() + "/new"), 0600);
}

TEST(AtomicFile, MissingFolderFailsCleanly)
{
    QTemporaryDir dir;
    QString why;
    EXPECT_FALSE(atomicWrite(dir.path() + "/nope/f", "x", -1, &why));
    EXPECT_FALSE(why.isEmpty());
}

TEST(AtomicFile, ALinkAtTheTargetIsReplacedNotFollowed)
{
    QTemporaryDir dir;
    const QString victim = dir.path() + "/victim";
    {
        QFile f(victim);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("keep");
    }
    ASSERT_TRUE(QFile::link(victim, dir.path() + "/link"));
    ASSERT_TRUE(atomicWrite(dir.path() + "/link", "new"));
    EXPECT_EQ(readAll(victim), QByteArray("keep")) << "rename replaces the link itself";
    EXPECT_FALSE(QFileInfo(dir.path() + "/link").isSymLink());
}

// ---- the history store ----

TEST(CaptureHistoryStore, ReadsOnlyPrivateRegularFiles)
{
    QTemporaryDir dir;
    CaptureHistory history(dir.path() + "/h");
    HistoryEntry e;
    ASSERT_TRUE(history.add("/tmp/x.png", "bytes", QSize(2, 2), &e));
    EXPECT_EQ(history.readOriginal(e.id), QByteArray("bytes"));
    // Mode 0644: refused. A link: refused (the index too: history then starts empty).
    ::chmod(QFile::encodeName(history.originalPath(e.id)).constData(), 0644);
    EXPECT_TRUE(history.readOriginal(e.id).isEmpty());
    const QString index = history.root() + "/index.json";
    const QByteArray good = readAll(index);
    ASSERT_FALSE(good.isEmpty());
    QFile::remove(index);
    ASSERT_TRUE(QFile::link(dir.path() + "/elsewhere.json", index));
    EXPECT_TRUE(history.entries().isEmpty());
}

TEST(CaptureHistoryStore, DropsEntriesWithAnInvalidIdOrField)
{
    QTemporaryDir dir;
    CaptureHistory history(dir.path() + "/h");
    ASSERT_TRUE(QDir().mkpath(history.root()));
    const QString digest(64, 'a');
    const auto line = [&digest](const QString &id) {
        return QJsonObject{{"id", id}, {"kind", "shot"}, {"path", "/p.png"}, {"time", 1}, {"w", 2}, {"h", 2}, {"orig", digest}, {"cur", ""}};
    };
    const QJsonObject root{{"v", 1},
                           {"entries", QJsonArray{line("0123456789abcdef"), line("../../etc/passwd"), line("0123456789ABCDEF"), line("short")}}};
    ASSERT_TRUE(atomicWrite(history.root() + "/index.json", QJsonDocument(root).toJson(), 0600));
    const QList<HistoryEntry> all = history.entries();
    ASSERT_EQ(all.size(), 1);
    EXPECT_EQ(all[0].id, "0123456789abcdef");
    EXPECT_TRUE(history.originalPath("../x").isEmpty());
    EXPECT_TRUE(history.readLayers("../x").isEmpty());
}

TEST(CaptureHistoryStore, AnUnreadableIndexStartsEmpty)
{
    QTemporaryDir dir;
    CaptureHistory history(dir.path() + "/h");
    ASSERT_TRUE(QDir().mkpath(history.root()));
    ASSERT_TRUE(atomicWrite(history.root() + "/index.json", "{not json", 0600));
    EXPECT_TRUE(history.entries().isEmpty());
    HistoryEntry e;
    EXPECT_TRUE(history.add("/p.png", "x", QSize(1, 1), &e)) << "and a new entry still goes in";
    EXPECT_EQ(history.entries().size(), 1);
}
