#include "archivelogic.h"

#include "filelogic.h"

#include <QRegularExpression>

namespace ArchiveLogic
{
namespace
{
// Longest first: ".tar.gz" before ".gz" (a lone .gz is no archive of several items: left to the applications).
const QStringList kExtensions = {QStringLiteral(".tar.gz"), QStringLiteral(".tar.bz2"), QStringLiteral(".tar.xz"), QStringLiteral(".tar.zst"),
                                 QStringLiteral(".tgz"),    QStringLiteral(".tbz2"),    QStringLiteral(".txz"),    QStringLiteral(".tzst"),
                                 QStringLiteral(".tar"),    QStringLiteral(".zip"),     QStringLiteral(".7z")};

QString extensionOf(const QString &name)
{
    for (const QString &ext : kExtensions) {
        if (name.size() > ext.size() && name.endsWith(ext, Qt::CaseInsensitive))
            return name.right(ext.size());
    }
    return {};
}
} // namespace

bool isArchive(const QString &name)
{
    return !extensionOf(name).isEmpty();
}

QString stripArchiveExtension(const QString &name)
{
    const QString ext = extensionOf(name);
    return ext.isEmpty() ? name : name.chopped(ext.size());
}

QString compressName(const QStringList &names, const std::function<bool(const QString &)> &exists)
{
    // The Finder's names; uniqueName counts " 2", " 3"… on the stem, the ".zip" stays last.
    const QString stem = names.size() == 1 ? names.first() : QStringLiteral("Archive");
    return FileLogic::uniqueName(stem, [&exists](const QString &candidate) { return exists(candidate + QStringLiteral(".zip")); }) + QStringLiteral(".zip");
}

QString expandName(const QString &archiveName, const QStringList &topLevel, const std::function<bool(const QString &)> &exists)
{
    if (topLevel.size() == 1) {
        // One item keeps its name: " 2" goes before its extension for a file ("notes 2.txt"), at the end for a folder.
        const QString &name = topLevel.first();
        if (!exists(name))
            return name;
        const int stem = FileLogic::baseNameLength(name, false);
        const QString base = name.left(stem);
        const QString ext = name.mid(stem);
        return FileLogic::uniqueName(base, [&](const QString &candidate) { return exists(candidate + ext); }) + ext;
    }
    return FileLogic::uniqueName(stripArchiveExtension(archiveName), exists);
}

QStringList compressArgs(const QString &archivePath, const QString &folder, const QStringList &names)
{
    QStringList args = {QStringLiteral("--format"), QStringLiteral("zip"), QStringLiteral("-s"), QStringLiteral(",^\\./,,S"),
                        QStringLiteral("-cf"),      archivePath,          QStringLiteral("-C"), folder,
                        QStringLiteral("--")};
    for (const QString &name : names)
        args.append(QStringLiteral("./") + name);
    return args;
}

QStringList expandArgs(const QString &archivePath, const QString &intoFolder)
{
    return {QStringLiteral("-xf"),           archivePath,
            QStringLiteral("-C"),            intoFolder,
            QStringLiteral("--no-same-owner"), QStringLiteral("--no-same-permissions"),
            QStringLiteral("--no-acls"),     QStringLiteral("--no-fflags"),
            QStringLiteral("--no-xattrs")};
}

QStringList listArgs(const QString &archivePath)
{
    return {QStringLiteral("-tvf"), archivePath};
}

std::optional<qint64> listedSize(const QString &listing)
{
    ListingTally tally;
    tally.feed(listing.toLocal8Bit());
    tally.finish();
    return tally.total();
}

void ListingTally::feed(const QByteArray &chunk)
{
    qsizetype from = 0;
    while (from < chunk.size()) {
        const qsizetype newline = chunk.indexOf('\n', from);
        const qsizetype end = newline < 0 ? chunk.size() : newline;
        if (!m_skipping) {
            if (m_partial.size() + (end - from) > kMaxLine) {
                // Too long to be a listing line: the size is unknown, and the rest of the line is skipped.
                m_known = false;
                m_skipping = true;
                m_partial.clear();
            } else {
                m_partial.append(chunk.constData() + from, end - from);
            }
        }
        if (newline < 0)
            return;
        if (!m_skipping)
            line(m_partial);
        else
            ++m_entries;
        m_partial.clear();
        m_skipping = false;
        from = newline + 1;
    }
}

void ListingTally::finish()
{
    if (m_skipping)
        ++m_entries;
    else if (!m_partial.isEmpty())
        line(m_partial);
    m_partial.clear();
    m_skipping = false;
}

void ListingTally::line(const QByteArray &text)
{
    // "-rw-r--r--  0 user   group     1234 Oct 26 12:00 name": permissions, links, owner, group, size, date… An owner or
    // group with a space would shift the columns: any line whose fifth column is no number makes the size unknown.
    const QList<QByteArray> columns = text.simplified().split(' ');
    if (text.trimmed().isEmpty())
        return;
    ++m_entries;
    if (!m_known)
        return;
    if (columns.size() < 6) {
        m_known = false;
        return;
    }
    bool ok = false;
    const qint64 size = columns.at(4).toLongLong(&ok);
    if (!ok || size < 0 || m_total + size < m_total) {
        m_known = false;
        return;
    }
    m_total += size;
}

Failure failureOf(const QString &stderrText)
{
    const QString t = stderrText.toLower();
    if (t.contains(QLatin1String("passphrase")) || t.contains(QLatin1String("encrypted")) || t.contains(QLatin1String("password")))
        return Failure::Encrypted;
    return Failure::Other;
}

} // namespace ArchiveLogic
