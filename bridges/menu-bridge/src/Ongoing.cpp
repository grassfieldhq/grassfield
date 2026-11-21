#include "Ongoing.h"

#include <QDBusArgument>
#include <QDBusVariant>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaType>
#include <QRandomGenerator>
#include <QRegularExpression>

#include <algorithm>
#include <cmath>
#include <limits>

namespace gf::menubridge::ongoing {

    namespace {
        const QString kInvalidArgs = QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs");
        const QString kLimits      = QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded");
        const QString kDenied      = QStringLiteral("org.freedesktop.DBus.Error.AccessDenied");

        bool isBidiControl(char32_t c) {
            return c == 0x061C || c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069);
        }

        bool isControl(char32_t c) {
            return c < 0x20 || (c >= 0x7F && c <= 0x9F);
        }

        bool asciiMatch(const QString& s, int min, int max, bool (*first)(QChar), bool (*rest)(QChar)) {
            if (s.size() < min || s.size() > max)
                return false;
            for (qsizetype i = 0; i < s.size(); ++i) {
                if (!(i == 0 ? first(s.at(i)) : rest(s.at(i))))
                    return false;
            }
            return true;
        }

        bool isAlnum(QChar c) {
            return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') || (c >= u'0' && c <= u'9');
        }

        bool isIdChar(QChar c) {
            return isAlnum(c) || c == u'_' || c == u'-';
        }

        bool isLowerAlpha(QChar c) {
            return c >= u'a' && c <= u'z';
        }

        bool isActionChar(QChar c) {
            return isLowerAlpha(c) || (c >= u'0' && c <= u'9') || c == u'-';
        }

        bool isAppIdChar(QChar c) {
            return isAlnum(c) || c == u'.' || c == u'_' || c == u'-';
        }

        bool isAppIdFirst(QChar c) {
            return isAlnum(c) || c == u'_';
        }

        bool isLowerHex(QChar c) {
            return (c >= u'0' && c <= u'9') || (c >= u'a' && c <= u'f');
        }

        std::optional<qint64> integerOf(const QVariant& v) {
            switch (v.typeId()) {
                case QMetaType::Int:
                case QMetaType::Short:
                case QMetaType::UChar:
                case QMetaType::LongLong: return v.toLongLong();
                case QMetaType::UInt:
                case QMetaType::UShort: return static_cast<qint64>(v.toUInt());
                case QMetaType::ULongLong: {
                    const qulonglong u = v.toULongLong();
                    if (u > static_cast<qulonglong>(std::numeric_limits<qint64>::max()))
                        return std::nullopt;
                    return static_cast<qint64>(u);
                }
                default: return std::nullopt;
            }
        }

        std::optional<double> numberOf(const QVariant& v) {
            if (v.typeId() == QMetaType::Double)
                return v.toDouble();
            if (const auto i = integerOf(v))
                return static_cast<double>(*i);
            return std::nullopt;
        }

        // A text field: a string of at most kMaxRawText characters, cleaned to at most `max`; nullopt (error set) otherwise.
        std::optional<QString> textField(const QVariant& v, const char* name, int max, bool allowEmpty, QString* error) {
            if (v.typeId() != QMetaType::QString) {
                *error = QStringLiteral("%1 must be a string (s)").arg(QLatin1String(name));
                return std::nullopt;
            }
            const QString raw = v.toString();
            if (raw.size() > kMaxRawText) {
                *error = QStringLiteral("%1 is too long").arg(QLatin1String(name));
                return std::nullopt;
            }
            const QString clean = cleanText(raw, kMaxRawText);
            if (clean.size() > max) {
                *error = QStringLiteral("%1 is longer than %2 characters").arg(QLatin1String(name)).arg(max);
                return std::nullopt;
            }
            if (clean.isEmpty() && !allowEmpty) {
                *error = QStringLiteral("%1 is empty").arg(QLatin1String(name));
                return std::nullopt;
            }
            return clean;
        }

        // a(ss) as a QDBusArgument (QtDBus's form inside a variant) or a list of two-string lists.
        bool actionsOf(const QVariant& v, QList<Action>* out) {
            out->clear();
            if (v.canConvert<QDBusArgument>() && v.userType() == qMetaTypeId<QDBusArgument>()) {
                const QDBusArgument arg = v.value<QDBusArgument>();
                if (arg.currentSignature() != QLatin1String("a(ss)"))
                    return false;
                arg.beginArray();
                while (!arg.atEnd()) {
                    if (out->size() > kMaxActions)
                        break; // too many: refused by the caller, no need to read the rest
                    QString id;
                    QString label;
                    arg.beginStructure();
                    arg >> id >> label;
                    arg.endStructure();
                    out->append({id, label});
                }
                arg.endArray();
                return true;
            }
            if (v.typeId() != QMetaType::QVariantList)
                return false;
            const QVariantList list = v.toList();
            for (const QVariant& item : list) {
                const QVariantList pair = item.toList();
                if (item.typeId() != QMetaType::QVariantList && item.typeId() != QMetaType::QStringList)
                    return false;
                const QStringList strings = item.toStringList();
                if (strings.size() != 2 || pair.size() != 2 || pair.at(0).typeId() != QMetaType::QString || pair.at(1).typeId() != QMetaType::QString)
                    return false;
                out->append({strings.at(0), strings.at(1)});
                if (out->size() > kMaxActions)
                    break;
            }
            return true;
        }

        QString unescapeUnit(const QString& s) {
            QString out;
            for (qsizetype i = 0; i < s.size(); ++i) {
                if (s.at(i) == u'\\' && i + 3 < s.size() && s.at(i + 1) == u'x') {
                    bool       ok = false;
                    const uint c  = s.mid(i + 2, 2).toUInt(&ok, 16);
                    if (ok && c > 0) {
                        out += QChar(c);
                        i += 3;
                        continue;
                    }
                }
                out += s.at(i);
            }
            return out;
        }

        QByteArray readSmall(const QString& path, qsizetype max) {
            QFile f(path);
            if (!f.open(QIODevice::ReadOnly))
                return {};
            return f.read(max);
        }
    } // namespace

    QString kindName(Kind kind) {
        switch (kind) {
            case Kind::Timer: return QStringLiteral("timer");
            case Kind::Transfer: return QStringLiteral("transfer");
            case Kind::Recording: return QStringLiteral("recording");
            case Kind::Install: return QStringLiteral("install");
            case Kind::Call: return QStringLiteral("call");
            case Kind::Progress: return QStringLiteral("progress");
        }
        return QStringLiteral("progress");
    }

    std::optional<Kind> kindFromName(const QString& name) {
        for (Kind k : {Kind::Timer, Kind::Transfer, Kind::Recording, Kind::Install, Kind::Call, Kind::Progress}) {
            if (kindName(k) == name)
                return k;
        }
        return std::nullopt;
    }

    QString cleanText(const QString& raw, int max) {
        QString out;
        out.reserve(std::min<qsizetype>(raw.size(), kMaxRawText));
        const QList<uint> codes = raw.left(kMaxRawText).toUcs4();
        for (const uint c : codes) {
            if (isBidiControl(c))
                continue;
            if (isControl(c)) {
                out += u' ';
                continue;
            }
            const char32_t c32 = c;
            out += QString::fromUcs4(&c32, 1);
        }
        out = out.simplified();
        if (out.size() > max) {
            qsizetype cut = max;
            if (cut > 0 && out.at(cut - 1).isHighSurrogate())
                --cut;
            out.truncate(cut);
            out = out.trimmed();
        }
        return out;
    }

    bool isValidActivityId(const QString& id) {
        return asciiMatch(id, 1, kMaxId, isIdChar, isIdChar);
    }

    bool isValidActionId(const QString& id) {
        return asciiMatch(id, 1, kMaxActionId, isLowerAlpha, isActionChar);
    }

    bool isValidAppId(const QString& id) {
        return asciiMatch(id, 1, kMaxAppId, isAppIdFirst, isAppIdChar);
    }

    bool isValidKey(const QString& key) {
        return asciiMatch(key, 16, 16, isLowerHex, isLowerHex);
    }

    std::optional<Input> inputFromDBus(const QVariant& argument) {
        Input in;
        auto  take = [&in](const QString& key, const QVariant& value) {
            ++in.entries;
            if (key == QLatin1String("actions")) {
                in.hasActions    = true;
                in.actionsTypeOk = actionsOf(value, &in.actions);
            } else if (in.fields.size() <= kMaxFields) {
                in.fields.insert(key, value);
            }
        };
        if (argument.userType() == qMetaTypeId<QDBusArgument>()) {
            const QDBusArgument arg = argument.value<QDBusArgument>();
            if (arg.currentSignature() != QLatin1String("a{sv}"))
                return std::nullopt;
            arg.beginMap();
            while (!arg.atEnd() && in.entries <= kMaxFields) {
                QString      key;
                QDBusVariant value;
                arg.beginMapEntry();
                arg >> key >> value;
                arg.endMapEntry();
                take(key, value.variant());
            }
            if (!arg.atEnd())
                ++in.entries; // more than kMaxFields + 1: refused, the rest is not read
            arg.endMap(); // always closed, as readLayout does after its break: the container is not left open
            return in;
        }
        if (argument.typeId() != QMetaType::QVariantMap)
            return std::nullopt;
        const QVariantMap map = argument.toMap();
        for (auto it = map.cbegin(); it != map.cend(); ++it)
            take(it.key(), it.value());
        return in;
    }

    Checked checkState(const Input& input, qint64 nowMs) {
        Checked out;
        auto    fail = [&out](const QString& why) {
            out.error = why;
            return out;
        };
        if (input.entries > kMaxFields)
            return fail(QStringLiteral("more than %1 fields").arg(kMaxFields));
        static const QStringList known = {QStringLiteral("kind"),     QStringLiteral("title"), QStringLiteral("subtitle"),
                                          QStringLiteral("progress"), QStringLiteral("started"), QStringLiteral("ends")};
        for (auto it = input.fields.cbegin(); it != input.fields.cend(); ++it) {
            if (!known.contains(it.key()))
                return fail(QStringLiteral("unknown field \"%1\"").arg(cleanText(it.key(), 32)));
        }
        State       s;
        const auto& f = input.fields;
        if (!f.contains(QStringLiteral("kind")) || f.value(QStringLiteral("kind")).typeId() != QMetaType::QString)
            return fail(QStringLiteral("kind (s) is required"));
        const auto kind = kindFromName(f.value(QStringLiteral("kind")).toString());
        if (!kind)
            return fail(QStringLiteral("kind must be timer, transfer, recording, install, call or progress"));
        s.kind = *kind;

        QString error;
        if (!f.contains(QStringLiteral("title")))
            return fail(QStringLiteral("title (s) is required"));
        const auto title = textField(f.value(QStringLiteral("title")), "title", kMaxTitle, false, &error);
        if (!title)
            return fail(error);
        s.title = *title;
        if (f.contains(QStringLiteral("subtitle"))) {
            const auto subtitle = textField(f.value(QStringLiteral("subtitle")), "subtitle", kMaxSubtitle, true, &error);
            if (!subtitle)
                return fail(error);
            s.subtitle = *subtitle;
        }
        if (f.contains(QStringLiteral("progress"))) {
            const auto p = numberOf(f.value(QStringLiteral("progress")));
            if (!p || !std::isfinite(*p) || *p > 1.0)
                return fail(QStringLiteral("progress must be a number (d) of 0..1, or negative for indeterminate"));
            if (*p >= 0.0)
                s.progress = *p;
        }
        if (f.contains(QStringLiteral("started"))) {
            const auto t = integerOf(f.value(QStringLiteral("started")));
            if (!t || *t > nowMs + kFutureSlackMs || *t < nowMs - kStartedPastMs)
                return fail(QStringLiteral("started must be Unix milliseconds (x), not in the future nor more than 7 days ago"));
            s.started = *t;
        }
        if (f.contains(QStringLiteral("ends"))) {
            const auto t = integerOf(f.value(QStringLiteral("ends")));
            if (!t || *t < nowMs - kFutureSlackMs || *t > nowMs + kEndsAheadMs)
                return fail(QStringLiteral("ends must be Unix milliseconds (x), from now to 24 hours ahead"));
            s.ends = *t;
        }
        if (s.started && s.ends)
            return fail(QStringLiteral("started and ends exclude each other"));
        if (s.kind == Kind::Timer && !s.started && !s.ends)
            return fail(QStringLiteral("a timer needs started or ends"));
        if (input.hasActions) {
            if (!input.actionsTypeOk)
                return fail(QStringLiteral("actions must be a(ss)"));
            if (input.actions.size() > kMaxActions)
                return fail(QStringLiteral("at most %1 actions").arg(kMaxActions));
            for (const Action& a : input.actions) {
                if (!isValidActionId(a.id))
                    return fail(QStringLiteral("an action id must match [a-z][a-z0-9-]{0,31}"));
                if (std::any_of(s.actions.cbegin(), s.actions.cend(), [&a](const Action& b) { return b.id == a.id; }))
                    return fail(QStringLiteral("action ids must be unique"));
                const auto label = textField(QVariant(a.label), "an action label", kMaxLabel, false, &error);
                if (!label)
                    return fail(error);
                s.actions.append({a.id, *label});
            }
        }
        out.state = s;
        return out;
    }

    // ---- identity ------------------------------------------------------------------------------------------------------

    void DesktopIndex::clear() {
        m_exec.clear();
        m_hidden.clear();
    }

    void DesktopIndex::add(const QString& id, const QString& execBinary) {
        if (!m_exec.contains(id) && !m_hidden.contains(id))
            m_exec.insert(id, execBinary);
    }

    bool DesktopIndex::has(const QString& id) const {
        return m_exec.contains(id);
    }

    QStringList DesktopIndex::withExec(const QString& binary) const {
        QStringList out;
        if (binary.isEmpty())
            return out;
        for (auto it = m_exec.cbegin(); it != m_exec.cend(); ++it) {
            if (it.value() == binary)
                out << it.key();
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    QString DesktopIndex::execBinaryOf(const QByteArray& desktopText, bool* hidden) {
        if (hidden)
            *hidden = false;
        bool       inEntry = false;
        QString    exec;
        const auto lines = desktopText.split('\n');
        for (const QByteArray& rawLine : lines) {
            const QByteArray line = rawLine.trimmed();
            if (line.startsWith('[')) {
                inEntry = line == "[Desktop Entry]";
                continue;
            }
            if (!inEntry)
                continue;
            if (line.startsWith("Exec=") && exec.isEmpty())
                exec = QString::fromUtf8(line.mid(5)).trimmed();
            else if (line.startsWith("Hidden=") && hidden)
                *hidden = line.mid(7).trimmed() == "true";
        }
        // Tokens with the desktop entry spec's double quotes.
        QStringList tokens;
        QString     current;
        bool        quoted = false;
        bool        any    = false;
        for (qsizetype i = 0; i < exec.size(); ++i) {
            const QChar c = exec.at(i);
            if (quoted) {
                if (c == u'\\' && i + 1 < exec.size()) {
                    current += exec.at(++i);
                } else if (c == u'"') {
                    quoted = false;
                } else {
                    current += c;
                }
                continue;
            }
            if (c == u'"') {
                quoted = true;
                any    = true;
            } else if (c.isSpace()) {
                if (any || !current.isEmpty())
                    tokens << current;
                current.clear();
                any = false;
            } else {
                current += c;
            }
        }
        if (any || !current.isEmpty())
            tokens << current;
        qsizetype i = 0;
        if (i < tokens.size() && QFileInfo(tokens.at(i)).fileName() == QLatin1String("env")) {
            ++i;
            while (i < tokens.size() && tokens.at(i).contains(u'=') && !tokens.at(i).startsWith(u'-'))
                ++i;
            if (i < tokens.size() && tokens.at(i).startsWith(u'-'))
                return {}; // env's options may take a value: the program is not known for certain
        }
        if (i >= tokens.size())
            return {};
        return QFileInfo(tokens.at(i)).fileName();
    }

    QStringList DesktopIndex::applicationDirs() {
        QStringList out;
        QString     home = qEnvironmentVariable("XDG_DATA_HOME");
        if (home.isEmpty() || !home.startsWith(u'/')) {
            const QString h = qEnvironmentVariable("HOME");
            home            = h.startsWith(u'/') ? h + QStringLiteral("/.local/share") : QString();
        }
        if (!home.isEmpty())
            out << home + QStringLiteral("/applications");
        QString dirs = qEnvironmentVariable("XDG_DATA_DIRS");
        if (dirs.isEmpty())
            dirs = QStringLiteral("/usr/local/share:/usr/share");
        for (const QString& d : dirs.split(u':', Qt::SkipEmptyParts)) {
            if (d.startsWith(u'/') && !out.contains(d + QStringLiteral("/applications")))
                out << d + QStringLiteral("/applications");
        }
        return out;
    }

    void DesktopIndex::scan(const QStringList& dirs, int maxFiles) {
        clear();
        int read = 0;
        for (const QString& dir : dirs) {
            QList<std::pair<QString, QString>> files; // (id, path)
            const QDir                         top(dir);
            for (const QFileInfo& fi : top.entryInfoList({QStringLiteral("*.desktop")}, QDir::Files | QDir::Readable, QDir::Name))
                files.append({fi.completeBaseName(), fi.filePath()});
            for (const QFileInfo& sub : top.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name)) {
                if (sub.isSymLink())
                    continue;
                for (const QFileInfo& fi : QDir(sub.filePath()).entryInfoList({QStringLiteral("*.desktop")}, QDir::Files | QDir::Readable, QDir::Name))
                    files.append({sub.fileName() + u'-' + fi.completeBaseName(), fi.filePath()});
            }
            for (const auto& [id, path] : files) {
                if (read >= maxFiles)
                    return;
                if (!isValidAppId(id) || m_exec.contains(id) || m_hidden.contains(id))
                    continue;
                ++read;
                bool          hidden = false;
                const QString binary = execBinaryOf(readSmall(path, 64 * 1024), &hidden);
                if (hidden)
                    m_hidden.insert(id);
                else
                    m_exec.insert(id, binary);
            }
        }
    }

    QString unitAppId(const QString& cgroupText) {
        QString           path;
        const QStringList lines = cgroupText.split(u'\n', Qt::SkipEmptyParts);
        for (const QString& line : lines) {
            const QStringList f = line.split(u':');
            if (f.size() < 3)
                continue;
            path = f.mid(2).join(u':');
            if (f.at(0) == QLatin1String("0"))
                break;
        }
        static const QRegularExpression instance(QStringLiteral("-(?:[0-9]+|[0-9a-f]{8}|[0-9a-f]{32})$"));
        const QStringList               parts = path.split(u'/', Qt::SkipEmptyParts);
        for (qsizetype i = parts.size() - 1; i >= 0; --i) {
            QString unit = parts.at(i);
            if (!unit.startsWith(QLatin1String("app-")))
                continue;
            if (unit.endsWith(QLatin1String(".scope"))) {
                unit.chop(6);
                const auto m = instance.match(unit);
                if (!m.hasMatch())
                    return {}; // not the scope contract (ADR-0011): no instance suffix
                unit.truncate(m.capturedStart());
            } else if (unit.endsWith(QLatin1String(".service"))) {
                unit.chop(8);
                const qsizetype at = unit.indexOf(u'@');
                if (at < 0)
                    return {};
                unit.truncate(at);
            } else {
                continue; // a slice (app-graphical.slice): look further up
            }
            const QStringList fields = unit.mid(4).split(u'-');
            if (fields.isEmpty() || fields.size() > 2 || fields.last().isEmpty())
                return {}; // app-<a>-<b>-<c>: which part is the id cannot be told
            const QString id = unescapeUnit(fields.last());
            return isValidAppId(id) ? id : QString();
        }
        return {};
    }

    QString flatpakAppId(const QByteArray& info) {
        bool       inApplication = false;
        const auto lines         = info.left(64 * 1024).split('\n');
        for (const QByteArray& raw : lines) {
            const QByteArray line = raw.trimmed();
            if (line.startsWith('[')) {
                inApplication = line == "[Application]";
                continue;
            }
            if (inApplication && line.startsWith("name=")) {
                const QString id = QString::fromUtf8(line.mid(5)).trimmed();
                return isValidAppId(id) && id.count(u'.') >= 2 ? id : QString();
            }
        }
        return {};
    }

    Verdict resolveApp(const ProcFacts& facts, uint ownUid, const DesktopIndex& index) {
        if (facts.uid != ownUid)
            return {{}, QStringLiteral("the caller runs as another user")};
        if (facts.flatpak) {
            const QString id = flatpakAppId(facts.flatpakInfo);
            if (id.isEmpty())
                return {{}, QStringLiteral("the caller's /.flatpak-info names no application")};
            if (!index.has(id))
                return {{}, QStringLiteral("no desktop entry for the Flatpak %1").arg(id)};
            return {id, {}};
        }
        const QString unit = unitAppId(facts.cgroup);
        if (unit.isEmpty())
            return {{}, QStringLiteral("the caller is not in a verified application scope")};
        if (index.has(unit))
            return {unit, {}};
        const QStringList byExec = index.withExec(unit);
        if (byExec.size() == 1)
            return {byExec.first(), {}};
        if (byExec.isEmpty())
            return {{}, QStringLiteral("no desktop entry for the application scope's %1").arg(unit)};
        return {{}, QStringLiteral("several desktop entries start %1: the application cannot be told").arg(unit)};
    }

    // ---- book ----------------------------------------------------------------------------------------------------------

    QString randomKey() {
        return QStringLiteral("%1").arg(QRandomGenerator::global()->generate64(), 16, 16, QLatin1Char('0'));
    }

    Book::Book(std::function<QString()> newKey) : m_newKey(newKey ? std::move(newKey) : std::function<QString()>(randomKey)) {}

    Book::Result Book::publish(const QString& sender, const QString& appId, const QString& localId, const State& state) {
        Result r;
        for (auto it = m_items.begin(); it != m_items.end(); ++it) {
            if (it->appId != appId || it->localId != localId)
                continue;
            if (it->owner != sender) {
                r.error   = kDenied;
                r.message = QStringLiteral("activity \"%1\" belongs to another connection of the application").arg(localId);
                return r;
            }
            r.ok      = true;
            r.key     = it->key;
            r.changed = !(it->state == state);
            it->state = state;
            return r;
        }
        if (countFor(appId) >= kMaxPerApp) {
            r.error   = kLimits;
            r.message = QStringLiteral("an application shows at most %1 activities").arg(kMaxPerApp);
            return r;
        }
        if (count() >= kMaxTotal) {
            r.error   = kLimits;
            r.message = QStringLiteral("at most %1 activities are shown").arg(kMaxTotal);
            return r;
        }
        QString key = m_newKey();
        for (int tries = 0; (!isValidKey(key) || m_items.contains(key)) && tries < 8; ++tries)
            key = randomKey();
        if (m_items.contains(key)) {
            r.error   = kLimits;
            r.message = QStringLiteral("no free key");
            return r;
        }
        m_items.insert(key, Activity{key, appId, localId, sender, state, ++m_seq});
        r.ok      = true;
        r.key     = key;
        r.changed = true;
        return r;
    }

    std::optional<QString> Book::end(const QString& sender, const QString& appId, const QString& localId) {
        for (auto it = m_items.begin(); it != m_items.end(); ++it) {
            if (it->appId == appId && it->localId == localId && it->owner == sender) {
                const QString key = it.key();
                m_items.erase(it);
                return key;
            }
        }
        return std::nullopt;
    }

    QStringList Book::senderGone(const QString& sender) {
        QStringList out;
        for (auto it = m_items.begin(); it != m_items.end();) {
            if (it->owner == sender) {
                out << it.key();
                it = m_items.erase(it);
            } else {
                ++it;
            }
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    QStringList Book::expire(qint64 nowMs) {
        QStringList out;
        for (auto it = m_items.begin(); it != m_items.end();) {
            if (it->state.ends && nowMs > *it->state.ends + kExpireAfterEndsMs) {
                out << it.key();
                it = m_items.erase(it);
            } else {
                ++it;
            }
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    const Activity* Book::byKey(const QString& key) const {
        const auto it = m_items.constFind(key);
        return it == m_items.constEnd() ? nullptr : &it.value();
    }

    QList<Activity> Book::all() const {
        QList<Activity> out = m_items.values();
        std::sort(out.begin(), out.end(), [](const Activity& a, const Activity& b) { return a.seq < b.seq; });
        return out;
    }

    bool Book::hasEnds() const {
        return std::any_of(m_items.cbegin(), m_items.cend(), [](const Activity& a) { return a.state.ends.has_value(); });
    }

    int Book::countFor(const QString& appId) const {
        return static_cast<int>(std::count_if(m_items.cbegin(), m_items.cend(), [&appId](const Activity& a) { return a.appId == appId; }));
    }

    bool RateLimiter::allow(const QString& sender, qint64 nowMs) {
        std::deque<qint64>& calls = m_calls[sender];
        while (!calls.empty() && calls.front() <= nowMs - kRateWindowMs)
            calls.pop_front();
        if (static_cast<int>(calls.size()) >= kRateCalls)
            return false;
        calls.push_back(nowMs);
        return true;
    }

    void RateLimiter::forget(const QString& sender) {
        m_calls.remove(sender);
    }

    // ---- menu/1 --------------------------------------------------------------------------------------------------------

    QByteArray ongoingMessage(const Activity& a, bool redacted) {
        QJsonArray actions;
        if (!redacted) {
            for (const Action& x : a.state.actions)
                actions.append(QJsonObject{{QStringLiteral("id"), x.id}, {QStringLiteral("label"), x.label}});
        }
        const QJsonObject o{
            {QStringLiteral("type"), QStringLiteral("ongoing")},
            {QStringLiteral("id"), a.key},
            {QStringLiteral("app"), redacted ? QString() : a.appId},
            {QStringLiteral("kind"), kindName(a.state.kind)},
            {QStringLiteral("title"), redacted ? QString() : a.state.title},
            {QStringLiteral("subtitle"), redacted ? QString() : a.state.subtitle},
            {QStringLiteral("progress"), a.state.progress ? QJsonValue(*a.state.progress) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("started"), a.state.started ? QJsonValue(static_cast<double>(*a.state.started)) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("ends"), a.state.ends ? QJsonValue(static_cast<double>(*a.state.ends)) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("actions"), actions},
            {QStringLiteral("redacted"), redacted},
        };
        QByteArray out = QJsonDocument(o).toJson(QJsonDocument::Compact);
        out += '\n';
        return out;
    }

    QByteArray ongoingEndMessage(const QString& key) {
        QByteArray out = QJsonDocument(QJsonObject{{QStringLiteral("type"), QStringLiteral("ongoing-end")}, {QStringLiteral("id"), key}}).toJson(QJsonDocument::Compact);
        out += '\n';
        return out;
    }

    QString interfaceXml() {
        return QStringLiteral(R"XML(  <interface name="org.grassfield.Ongoing1">
    <method name="Publish">
      <arg name="id" type="s" direction="in"/>
      <arg name="state" type="a{sv}" direction="in"/>
    </method>
    <method name="End">
      <arg name="id" type="s" direction="in"/>
    </method>
    <method name="Version">
      <arg name="version" type="s" direction="out"/>
    </method>
    <signal name="ActionInvoked">
      <arg name="id" type="s"/>
      <arg name="action" type="s"/>
    </signal>
  </interface>
)XML");
    }

} // namespace gf::menubridge::ongoing

namespace gf::menubridge::ongoing {

    // ---- the host without the bus --------------------------------------------------------------------------------------

    QString readProblem(const ProcReads& reads) {
        if (reads.rootUnreadable)
            return QStringLiteral("the caller's root cannot be read (a Flatpak cannot be told from a native app)");
        if (reads.cgroup.trimmed().isEmpty())
            return QStringLiteral("the caller's cgroup cannot be read");
        if (reads.pidfdPid && *reads.pidfdPid != reads.pid)
            return QStringLiteral("the caller's process changed while it was read");
        return {};
    }

    Verdict judgeCaller(const ProcReads& reads, uint ownUid, const DesktopIndex& index) {
        if (const QString problem = readProblem(reads); !problem.isEmpty())
            return {{}, problem};
        return resolveApp(ProcFacts{reads.uid, reads.cgroup, reads.flatpak, reads.flatpakInfo}, ownUid, index);
    }

    Admission::Result Admission::admit(const QString& sender, const QString& member, qint64 nowMs, const QHash<QString, bool>& tracked, const std::function<bool(const QString&)>& holds) {
        Result     r;
        const bool isEnd = member == QLatin1String("End");
        if (const auto it = m_refusals.constFind(sender); it != m_refusals.constEnd()) {
            if (nowMs < it->untilMs) {
                r.outcome = Outcome::Refused;
                r.message = it->why;
                return r;
            }
            m_refusals.remove(sender);
        }
        if (!tracked.contains(sender) && static_cast<int>(tracked.size()) >= kMaxSenders) {
            for (auto it = tracked.cbegin(); it != tracked.cend(); ++it) {
                const bool verified = it.value();
                if (verified && !(holds && holds(it.key())))
                    r.evicted << it.key();
            }
            std::sort(r.evicted.begin(), r.evicted.end());
            if (static_cast<int>(tracked.size() - r.evicted.size()) >= kMaxSenders) {
                r.evicted.clear();
                r.outcome = Outcome::TooManyConnections;
                r.message = QStringLiteral("too many connections publish activities");
                return r; // nothing is kept for it
            }
            for (const QString& e : r.evicted)
                m_rate.forget(e);
        }
        if (!isEnd && !m_rate.allow(sender, nowMs)) {
            r.outcome = Outcome::RateLimited;
            r.message = QStringLiteral("more than %1 calls a second").arg(kRateCalls);
        }
        return r;
    }

    void Admission::refused(const QString& sender, const QString& why, qint64 nowMs) {
        m_rate.forget(sender);
        if (static_cast<int>(m_refusals.size()) >= kMaxRefusals) {
            for (auto it = m_refusals.begin(); it != m_refusals.end();) {
                if (nowMs >= it->untilMs)
                    it = m_refusals.erase(it);
                else
                    ++it;
            }
        }
        if (static_cast<int>(m_refusals.size()) < kMaxRefusals)
            m_refusals.insert(sender, {nowMs + kRefusalCacheMs, why});
    }

    void Admission::forget(const QString& sender) {
        m_rate.forget(sender);
        m_refusals.remove(sender);
    }

    Host::Host(Send send, std::function<QString()> newKey) : m_send(std::move(send)), m_book(std::move(newKey)) {}

    Host::Call Host::publish(const QString& sender, const QString& appId, const QString& localId, const Input& input, qint64 nowMs) {
        Call c;
        if (!isValidActivityId(localId)) {
            c.error   = kInvalidArgs;
            c.message = QStringLiteral("id must match [A-Za-z0-9_-]{1,64}");
            return c;
        }
        const Checked checked = checkState(input, nowMs);
        if (!checked.state) {
            c.error   = kInvalidArgs;
            c.message = checked.error;
            return c;
        }
        const Book::Result r = m_book.publish(sender, appId, localId, *checked.state);
        if (!r.ok) {
            c.error   = r.error;
            c.message = r.message;
            return c;
        }
        c.ok = true;
        if (r.changed) {
            if (const Activity* a = m_book.byKey(r.key))
                m_send(ongoingMessage(*a, m_locked));
        }
        return c;
    }

    void Host::end(const QString& sender, const QString& appId, const QString& localId) {
        if (const auto key = m_book.end(sender, appId, localId))
            m_send(ongoingEndMessage(*key));
    }

    void Host::senderGone(const QString& sender) {
        for (const QString& key : m_book.senderGone(sender))
            m_send(ongoingEndMessage(key));
    }

    void Host::expire(qint64 nowMs) {
        for (const QString& key : m_book.expire(nowMs))
            m_send(ongoingEndMessage(key));
    }

    bool Host::holds(const QString& sender) const {
        const QList<Activity> all = m_book.all();
        return std::any_of(all.cbegin(), all.cend(), [&sender](const Activity& a) { return a.owner == sender; });
    }

    void Host::resetLock() {
        m_locked = true;
    }

    void Host::setLocked(bool locked) {
        if (locked == m_locked)
            return;
        m_locked = locked;
        for (const QByteArray& line : snapshot())
            m_send(line);
    }

    QList<QByteArray> Host::snapshot() const {
        QList<QByteArray> out;
        for (const Activity& a : m_book.all())
            out.append(ongoingMessage(a, m_locked));
        return out;
    }

    Host::Invocation Host::invoke(const QString& key, const QString& action) const {
        Invocation inv;
        if (m_locked) {
            inv.error = QStringLiteral("locked");
            return inv;
        }
        const Activity* a = m_book.byKey(key);
        if (!a) {
            inv.error = QStringLiteral("unknown-activity");
            return inv;
        }
        const bool declared = std::any_of(a->state.actions.cbegin(), a->state.actions.cend(), [&action](const Action& x) { return x.id == action; });
        if (!declared) {
            inv.error = QStringLiteral("unknown-action");
            return inv;
        }
        inv.owner   = a->owner;
        inv.localId = a->localId;
        inv.appId   = a->appId;
        return inv;
    }

} // namespace gf::menubridge::ongoing
