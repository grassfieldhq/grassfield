#pragma once

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>
#include <QSet>
#include <QString>
#include <QStringList>

#include <cstdlib>
#include <mutex>

// The file of a freedesktop icon name in the icon themes (the Icon Theme Specification's lookup, kept to what Login Items and the
// application picker need), found on ANY thread: Settings' image://icon provider runs on Qt Quick's image threads (SP-09: a
// Pixmap provider ran QIcon's theme lookup and the SVG rendering of every row on the GUI thread, which made the lists hitch while
// they scrolled). QIcon's loader is not made to be used from another thread, so the themes are read here: the theme's
// index.theme (Inherits, Directories with their Size, Type, MinSize, MaxSize, Scale 1 only), its parents, then the fallback theme
// and hicolor, then the legacy pixmaps folders. The values that only the GUI thread may read (the theme's name, the search
// paths) are taken by the constructor. Every answer is kept per name and size. Qt Core only.
namespace grassfield::settings {

class IconLookup
{
public:
    IconLookup(const QStringList &searchPaths, const QString &theme, const QString &fallbackTheme, const QStringList &pixmapDirs = {QStringLiteral("/usr/share/pixmaps")})
        : m_searchPaths(searchPaths)
        , m_pixmapDirs(pixmapDirs)
    {
        for (const QString &t : {theme, fallbackTheme, QStringLiteral("hicolor")}) {
            if (!t.isEmpty() && !m_roots.contains(t))
                m_roots << t;
        }
    }

    // A plain icon name (letters, digits, '.', '_', '+', '-'; at most 128), with an image extension dropped as desktop entries
    // sometimes write it ("firefox.png"); "" for anything else (a path, "..").
    static QString plainName(const QString &name)
    {
        static const QRegularExpression plain(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9][A-Za-z0-9._+-]{0,127}")));
        if (!plain.match(name).hasMatch())
            return QString();
        for (const char *ext : {".png", ".svg", ".xpm"}) {
            if (name.endsWith(QLatin1String(ext), Qt::CaseInsensitive))
                return name.left(name.size() - 4);
        }
        return name;
    }

    // The file that draws `name` best at `size` pixels: in the first theme of the chain that has it, the scalable or sized
    // directory nearest that size (the specification's DirectorySizeDistance); else a pixmaps folder's file. "" when none.
    QString find(const QString &name, int size)
    {
        const QString plain = plainName(name);
        if (plain.isEmpty())
            return QString();
        const QString key = plain + QLatin1Char('@') + QString::number(size);
        std::lock_guard<std::mutex> hold(m_lock);
        const auto cached = m_found.constFind(key);
        if (cached != m_found.cend())
            return *cached;
        QString found;
        QSet<QString> visited;
        for (const QString &root : std::as_const(m_roots)) {
            found = inTheme(root, plain, size, visited, 0);
            if (!found.isEmpty())
                break;
        }
        if (found.isEmpty()) {
            for (const QString &dir : std::as_const(m_pixmapDirs)) {
                for (const char *ext : {".png", ".svg", ".xpm"}) {
                    const QString path = dir + QLatin1Char('/') + plain + QLatin1String(ext);
                    if (QFileInfo(path).isFile()) {
                        found = path;
                        break;
                    }
                }
                if (!found.isEmpty())
                    break;
            }
        }
        m_found.insert(key, found);
        return found;
    }

private:
    struct Dir {
        QString name;
        int size = 0;
        int minSize = 0;
        int maxSize = 0;
        int threshold = 2;
        QString type;
    };
    struct Theme {
        QStringList bases; // <search path>/<theme> that exist
        QStringList inherits;
        QList<Dir> dirs;
    };

    static int distance(const Dir &d, int size)
    {
        if (d.type == QLatin1String("Fixed"))
            return std::abs(d.size - size);
        if (d.type == QLatin1String("Scalable")) {
            if (size < d.minSize)
                return d.minSize - size;
            if (size > d.maxSize)
                return size - d.maxSize;
            return 0;
        }
        if (size < d.size - d.threshold)
            return d.minSize > 0 ? d.minSize - size : d.size - d.threshold - size;
        if (size > d.size + d.threshold)
            return size - d.size - d.threshold;
        return 0;
    }

    const Theme &theme(const QString &name)
    {
        const auto it = m_themes.constFind(name);
        if (it != m_themes.cend())
            return *it;
        Theme t;
        QString index;
        for (const QString &path : std::as_const(m_searchPaths)) {
            const QString base = path + QLatin1Char('/') + name;
            if (!QFileInfo(base).isDir())
                continue;
            t.bases << base;
            if (index.isEmpty()) {
                QFile f(base + QStringLiteral("/index.theme"));
                if (f.open(QIODevice::ReadOnly))
                    index = QString::fromUtf8(f.read(1024 * 1024));
            }
        }
        // index.theme: [Icon Theme] Inherits and Directories, then one group per directory.
        QString group;
        QHash<QString, Dir> byName;
        QStringList order;
        for (const QString &raw : index.split(QLatin1Char('\n'))) {
            const QString line = raw.trimmed();
            if (line.startsWith(QLatin1Char('['))) {
                group = line.mid(1, line.size() - 2);
                continue;
            }
            const int eq = line.indexOf(QLatin1Char('='));
            if (eq <= 0)
                continue;
            const QString key = line.left(eq).trimmed();
            const QString value = line.mid(eq + 1).trimmed();
            if (group == QLatin1String("Icon Theme")) { // i18n-ignore: index.theme group
                if (key == QLatin1String("Inherits"))
                    t.inherits = value.split(QLatin1Char(','), Qt::SkipEmptyParts);
                else if (key == QLatin1String("Directories"))
                    order = value.split(QLatin1Char(','), Qt::SkipEmptyParts);
                continue;
            }
            Dir &d = byName[group];
            d.name = group;
            if (key == QLatin1String("Size"))
                d.size = value.toInt();
            else if (key == QLatin1String("MinSize"))
                d.minSize = value.toInt();
            else if (key == QLatin1String("MaxSize"))
                d.maxSize = value.toInt();
            else if (key == QLatin1String("Threshold"))
                d.threshold = value.toInt();
            else if (key == QLatin1String("Type"))
                d.type = value;
            else if (key == QLatin1String("Scale") && value.toInt() != 1)
                d.size = -1; // a @2x directory: its Size is not its pixels
        }
        for (const QString &n : std::as_const(order)) {
            Dir d = byName.value(n.trimmed());
            d.name = n.trimmed();
            if (d.size <= 0)
                continue;
            if (d.minSize <= 0)
                d.minSize = d.size;
            if (d.maxSize <= 0)
                d.maxSize = d.size;
            if (d.type.isEmpty())
                d.type = QStringLiteral("Threshold"); // i18n-ignore: index.theme directory type
            t.dirs << d;
        }
        return *m_themes.insert(name, t);
    }

    QString inTheme(const QString &name, const QString &icon, int size, QSet<QString> &visited, int depth)
    {
        if (visited.contains(name) || depth > 8)
            return QString();
        visited.insert(name);
        const Theme t = theme(name);
        QString best;
        int bestDistance = 0;
        for (const Dir &d : t.dirs) {
            const int dist = distance(d, size);
            if (!best.isEmpty() && dist >= bestDistance)
                continue;
            for (const QString &base : t.bases) {
                QString hit;
                for (const char *ext : {".png", ".svg", ".xpm"}) {
                    const QString path = base + QLatin1Char('/') + d.name + QLatin1Char('/') + icon + QLatin1String(ext);
                    if (QFileInfo(path).isFile()) {
                        hit = path;
                        break;
                    }
                }
                if (!hit.isEmpty()) {
                    best = hit;
                    bestDistance = dist;
                    break;
                }
            }
        }
        if (!best.isEmpty())
            return best;
        for (const QString &parent : t.inherits) {
            const QString found = inTheme(parent.trimmed(), icon, size, visited, depth + 1);
            if (!found.isEmpty())
                return found;
        }
        return QString();
    }

    const QStringList m_searchPaths;
    const QStringList m_pixmapDirs;
    QStringList m_roots;
    std::mutex m_lock;
    QHash<QString, Theme> m_themes;
    QHash<QString, QString> m_found;
};

} // namespace grassfield::settings
