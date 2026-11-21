#include "stacklogic.h"

#include <QFile>
#include <QLocale>

#include <algorithm>
#include <cstring>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace StackLogic
{

bool parseSort(const QString &text, Sort *out)
{
    static const struct {
        const char *name;
        Sort sort;
    } table[] = {{"name", Sort::Name}, {"dateAdded", Sort::DateAdded}, {"dateModified", Sort::DateModified}, {"dateCreated", Sort::DateCreated}, {"kind", Sort::Kind}};
    for (const auto &row : table) {
        if (text == QLatin1String(row.name)) {
            *out = row.sort;
            return true;
        }
    }
    return false;
}

QCollator makeCollator()
{
    // The C locale collator has no numeric ("file2" < "file10") mode (the same line as apps/files/src/foldermodel.cpp).
    QLocale locale;
    if (locale.language() == QLocale::C)
        locale = QLocale(QLocale::English, QLocale::UnitedStates);
    QCollator collator(locale);
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    return collator;
}

QString kindKey(const QString &name, bool isDir)
{
    if (isDir)
        return QString();
    // a folder is "" and sorts before every file; a name without an extension ("b.", ".bashrc", "README") is "~"
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    return dot > 0 && dot < name.size() - 1 ? name.mid(dot + 1).toLower() : QStringLiteral("~");
}

namespace
{
int three(double a, double b)
{
    return a < b ? -1 : (b < a ? 1 : 0);
}

// Ties by name as Files breaks them: the collator, then the raw names.
int byName(const Entry &a, const Entry &b, const QCollator &collator)
{
    const int c = collator.compare(a.se.name, b.se.name);
    return c != 0 ? c : QString::compare(a.se.name, b.se.name);
}
} // namespace

int compare(const Entry &a, const Entry &b, Sort sort, const QCollator &collator)
{
    switch (sort) {
    case Sort::Name:
        return FileLogic::compareEntries(a.se, b.se, FileLogic::SortKey::Name, false, false, collator);
    case Sort::DateAdded:
        if (a.added != b.added)
            return three(b.added, a.added);
        break;
    case Sort::DateModified:
        if (a.modified != b.modified)
            return three(b.modified, a.modified);
        break;
    case Sort::DateCreated:
        if (a.created != b.created)
            return three(b.created, a.created);
        break;
    case Sort::Kind: {
        const int c = QString::compare(a.kind, b.kind);
        if (c != 0)
            return c < 0 ? -1 : 1;
        break;
    }
    }
    return byName(a, b, collator);
}

Window::Window(Sort sort, int limit, const QCollator *collator)
    : m_sort(sort)
    , m_limit(std::max(1, limit))
    , m_collator(collator)
{
}

void Window::setLimit(int limit)
{
    m_limit = std::max(1, limit);
    if (int(m_entries.size()) > m_limit)
        m_entries.resize(size_t(m_limit));
}

void Window::setSort(Sort sort)
{
    m_sort = sort;
    m_entries.clear();
}

void Window::clear()
{
    m_entries.clear();
}

bool Window::offer(const Entry &entry)
{
    if (full() && compare(entry, m_entries.back(), m_sort, *m_collator) >= 0)
        return false;
    const auto at = std::upper_bound(m_entries.begin(), m_entries.end(), entry, [this](const Entry &x, const Entry &y) { return compare(x, y, m_sort, *m_collator) < 0; });
    m_entries.insert(at, entry);
    if (int(m_entries.size()) > m_limit)
        m_entries.pop_back();
    return true;
}

bool Window::remove(const QByteArray &raw)
{
    for (auto it = m_entries.begin(); it != m_entries.end(); ++it) {
        if (it->raw == raw) {
            m_entries.erase(it);
            return true;
        }
    }
    return false;
}

bool Window::contains(const QByteArray &raw) const
{
    return std::any_of(m_entries.begin(), m_entries.end(), [&raw](const Entry &e) { return e.raw == raw; });
}

namespace
{
double seconds(const struct statx_timestamp &t)
{
    return double(t.tv_sec) + double(t.tv_nsec) * 1e-9;
}

bool visible(const char *name)
{
    return name[0] != '.' && name[0] != '\0';
}
} // namespace

bool statEntry(const QByteArray &dir, const QByteArray &raw, Entry *entry)
{
    const QByteArray path = dir + '/' + raw;
    struct statx sx;
    if (statx(AT_FDCWD, path.constData(), AT_SYMLINK_NOFOLLOW | AT_STATX_SYNC_AS_STAT, STATX_TYPE | STATX_MTIME | STATX_CTIME | STATX_BTIME, &sx) != 0)
        return false;
    entry->se.isDir = S_ISDIR(sx.stx_mode);
    entry->modified = seconds(sx.stx_mtime);
    const double changed = seconds(sx.stx_ctime);
    const double born = (sx.stx_mask & STATX_BTIME) ? seconds(sx.stx_btime) : 0.0;
    entry->added = std::max(changed, born);
    entry->created = born > 0 ? born : entry->modified;
    return true;
}

ScanResult scanFolder(const QByteArray &dir, Window *window, const BeforeStat &beforeStat)
{
    ScanResult result;
    const Sort sort = window->sort();
    const bool dates = sort == Sort::DateAdded || sort == Sort::DateModified || sort == Sort::DateCreated;
    // an entry that vanishes between the listing and the statx is skipped and the scan goes on; one that vanishes between the scan
    // and the dates of the window makes the scan run again (a few times)
    const bool wantDirs = sort == Sort::DateAdded || sort == Sort::DateModified;
    for (int attempt = 0; attempt < 4; attempt++) {
        window->clear();
        result.total = 0;
        result.dirs.clear();
        result.dirsOverflow = false;
        DIR *d = opendir(dir.constData());
        if (!d)
            return result;
        result.ok = true;
        while (const struct dirent *de = readdir(d)) {
            if (!visible(de->d_name))
                continue;
            Entry e;
            e.raw = QByteArray(de->d_name);
            if (beforeStat)
                beforeStat(e.raw);
            e.se.name = QFile::decodeName(e.raw);
            if (dates || de->d_type == DT_UNKNOWN) {
                if (!statEntry(dir, e.raw, &e))
                    continue;
            } else {
                e.se.isDir = de->d_type == DT_DIR;
            }
            if (sort == Sort::Kind)
                e.kind = kindKey(e.se.name, e.se.isDir);
            result.total++;
            if (wantDirs && e.se.isDir) {
                if (result.dirs.size() < kMaxDirs)
                    result.dirs.push_back(e.raw);
                else
                    result.dirsOverflow = true;
            }
            window->offer(e);
        }
        closedir(d);
        // the entries of the window are stat'ed once more: Name and Kind get their dates here, and for every order one that vanished
        // after the scan stat'ed it makes the scan run again, so that a window is never a window of files that are gone
        bool vanished = false;
        std::vector<Entry> entries = window->entries();
        for (Entry &e : entries) {
            if (!statEntry(dir, e.raw, &e)) {
                vanished = true;
                break;
            }
        }
        if (!vanished) {
            window->clear();
            for (const Entry &e : entries)
                window->offer(e);
            result.complete = true;
            return result;
        }
    }
    return result; // ok, but not complete: a window that may hold a file that is gone
}

namespace
{
// The length of the valid UTF-8 sequence at `i` (1 to 4), 0 when the byte there starts none (overlong forms, surrogates and
// code points past U+10FFFF are not valid).
int utf8Length(const QByteArray &s, qsizetype i)
{
    const auto at = [&s](qsizetype k) { return uchar(s.at(k)); };
    const uchar c = at(i);
    if (c < 0x80)
        return 1;
    int n = 0;
    uint cp = 0;
    if (c >= 0xC2 && c <= 0xDF) {
        n = 2;
        cp = c & 0x1F;
    } else if (c >= 0xE0 && c <= 0xEF) {
        n = 3;
        cp = c & 0x0F;
    } else if (c >= 0xF0 && c <= 0xF4) {
        n = 4;
        cp = c & 0x07;
    } else {
        return 0;
    }
    if (i + n > s.size())
        return 0;
    for (int k = 1; k < n; ++k) {
        if ((at(i + k) & 0xC0) != 0x80)
            return 0;
        cp = (cp << 6) | (at(i + k) & 0x3F);
    }
    if ((n == 3 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)))
        return 0;
    return n;
}
} // namespace

QByteArray escapeName(const QByteArray &raw)
{
    static const char hex[] = "0123456789abcdef";
    QByteArray out;
    out.reserve(raw.size());
    for (qsizetype i = 0; i < raw.size();) {
        const int n = utf8Length(raw, i);
        if (n == 0) {
            const uchar c = uchar(raw.at(i));
            out += "\\x";
            out += hex[c >> 4];
            out += hex[c & 0xF];
            ++i;
            continue;
        }
        if (n > 1) {
            out.append(raw.constData() + i, n);
            i += n;
            continue;
        }
        switch (const char c = raw.at(i)) {
        case '\\':
            out += "\\\\";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\x1f':
            out += "\\u";
            break;
        default:
            out += c;
        }
        ++i;
    }
    return out;
}

QByteArray folderArgument(const QByteArray &argument)
{
    if (argument.startsWith('/'))
        return argument;
    if (!argument.startsWith("file://"))
        return {};
    const QByteArray path = QByteArray::fromPercentEncoding(argument.mid(7));
    return path.startsWith('/') && !path.contains('\0') ? path : QByteArray();
}

QByteArray encodeWindow(qint64 sequence, qint64 total, const std::vector<Entry> &entries)
{
    QByteArray out("W");
    const char us = '\x1f';
    out += us + QByteArray::number(sequence) + us + QByteArray::number(total) + us + QByteArray::number(qint64(entries.size()));
    for (const Entry &e : entries) {
        out += us + escapeName(e.raw);
        out += us + QByteArray(e.se.isDir ? "1" : "0");
        out += us + QByteArray::number(e.modified, 'f', 9);
        out += us + QByteArray::number(e.added, 'f', 9);
        out += us + QByteArray::number(e.created, 'f', 9);
    }
    out += '\n';
    return out;
}

} // namespace StackLogic
