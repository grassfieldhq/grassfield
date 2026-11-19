#include "KioAuth.h"

#include <gcr/gcr.h>

#include <QFile>

#include <algorithm>
#include <cstring>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace gf::prompter::kio {

    namespace {
        char* secureCopy(const char* data, std::size_t size) {
            auto* out = static_cast<char*>(gcr_secure_memory_alloc(size + 1));
            if (size)
                std::memcpy(out, data, size);
            out[size] = '\0';
            return out;
        }

        // A string of the bus (GDBus validated its UTF-8) of at most `cap` bytes.
        bool boundedString(const char* text, std::size_t cap) {
            return std::strlen(text) <= cap;
        }

        bool asciiAlnum(QChar c) {
            return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') || (c >= u'0' && c <= u'9');
        }

        int hexValue(QChar c) {
            if (c >= u'0' && c <= u'9')
                return c.unicode() - u'0';
            if (c >= u'a' && c <= u'f')
                return c.unicode() - u'a' + 10;
            if (c >= u'A' && c <= u'F')
                return c.unicode() - u'A' + 10;
            return -1;
        }
    } // namespace

    // --- Secret ----------------------------------------------------------------------------------------------------------

    Secret::Secret(const char* data, std::size_t size) : m_data(secureCopy(data, size)), m_size(size) {}

    Secret::Secret(const Secret& other) : m_data(other.m_data ? secureCopy(other.m_data, other.m_size) : nullptr), m_size(other.m_size) {}

    Secret& Secret::operator=(const Secret& other) {
        if (this != &other) {
            reset();
            if (other.m_data) {
                m_data = secureCopy(other.m_data, other.m_size);
                m_size = other.m_size;
            }
        }
        return *this;
    }

    Secret::Secret(Secret&& other) noexcept : m_data(other.m_data), m_size(other.m_size) {
        other.m_data = nullptr;
        other.m_size = 0;
    }

    Secret& Secret::operator=(Secret&& other) noexcept {
        if (this != &other) {
            reset();
            m_data       = other.m_data;
            m_size       = other.m_size;
            other.m_data = nullptr;
            other.m_size = 0;
        }
        return *this;
    }

    Secret::~Secret() {
        reset();
    }

    Secret Secret::adopt(char* secure, std::size_t size) {
        Secret s;
        s.m_data = secure;
        s.m_size = size;
        return s;
    }

    char* Secret::copyOut() const {
        return secureCopy(data(), m_size);
    }

    bool Secret::operator==(const Secret& other) const {
        return m_size == other.m_size && std::memcmp(data(), other.data(), m_size) == 0;
    }

    void Secret::reset() {
        if (m_data) {
            explicit_bzero(m_data, m_size + 1);
            gcr_secure_memory_free(m_data);
        }
        m_data = nullptr;
        m_size = 0;
    }

    void wipeAndFree(gpointer secure) {
        if (!secure)
            return;
        auto* s = static_cast<char*>(secure);
        explicit_bzero(s, std::strlen(s));
        gcr_secure_memory_free(s);
    }

    // --- VariantRef ------------------------------------------------------------------------------------------------------

    VariantRef::VariantRef(GVariant* value) : m_value(value ? g_variant_ref_sink(value) : nullptr) {}

    VariantRef::VariantRef(const VariantRef& other) : m_value(other.m_value ? g_variant_ref(other.m_value) : nullptr) {}

    VariantRef& VariantRef::operator=(const VariantRef& other) {
        if (this != &other) {
            GVariant* old = m_value;
            m_value       = other.m_value ? g_variant_ref(other.m_value) : nullptr;
            if (old)
                g_variant_unref(old);
        }
        return *this;
    }

    VariantRef::~VariantRef() {
        if (m_value)
            g_variant_unref(m_value);
    }

    // --- AuthInfo on the bus ---------------------------------------------------------------------------------------------

    bool parseAuthInfo(GVariant* value, AuthInfo* out, QString* why) {
        if (!value || !g_variant_is_of_type(value, G_VARIANT_TYPE(kAuthInfoType))) {
            *why = QStringLiteral("not an AuthInfo %1").arg(QLatin1String(kAuthInfoType));
            return false;
        }
        guchar       version = 0;
        const gchar* url = nullptr;
        const gchar* username = nullptr;
        const gchar* password = nullptr;
        const gchar* prompt = nullptr;
        const gchar* caption = nullptr;
        const gchar* comment = nullptr;
        const gchar* commentLabel = nullptr;
        const gchar* realm = nullptr;
        const gchar* digest = nullptr;
        gboolean     verifyPath = FALSE, readOnly = FALSE, keepPassword = FALSE, modified = FALSE;
        GVariant*    extra = nullptr;
        g_variant_get(value, "(y&s&s&s&s&s&s&s&s&sbbbb@a{s(siv)})", &version, &url, &username, &password, &prompt, &caption, &comment, &commentLabel,
                      &realm, &digest, &verifyPath, &readOnly, &keepPassword, &modified, &extra);
        (void)version; // KIO writes 1 and reads it without checking it (authinfo.cpp:213, 225)
        QString problem;
        if (!boundedString(url, kUrlBytes))
            problem = QStringLiteral("the URL is over %1 bytes").arg(kUrlBytes);
        else if (!boundedString(username, limits::kIdentity))
            problem = QStringLiteral("the user name is over %1 bytes").arg(limits::kIdentity);
        else if (!boundedString(password, limits::kPassword))
            problem = QStringLiteral("the password is over %1 bytes").arg(limits::kPassword);
        else if (!boundedString(prompt, kTextBytes) || !boundedString(caption, kTextBytes) || !boundedString(comment, kTextBytes)
                 || !boundedString(commentLabel, kTextBytes) || !boundedString(realm, kTextBytes) || !boundedString(digest, kTextBytes))
            problem = QStringLiteral("a text is over %1 bytes").arg(kTextBytes);
        else if (g_variant_n_children(extra) > kExtraFields)
            problem = QStringLiteral("more than %1 extra fields").arg(kExtraFields);
        for (gsize i = 0; problem.isEmpty() && i < g_variant_n_children(extra); ++i) {
            GVariant*    entry = g_variant_get_child_value(extra, i);
            const gchar* name  = nullptr;
            const gchar* title = nullptr;
            gint32       flags = 0;
            GVariant*    v     = nullptr;
            g_variant_get(entry, "{&s(&siv)}", &name, &title, &flags, &v);
            if (!name[0] || std::strlen(name) > kExtraNameBytes || std::strlen(title) > kExtraNameBytes || g_variant_get_size(entry) > kExtraEntryBytes)
                problem = QStringLiteral("an extra field is empty or over its bounds");
            g_variant_unref(v);
            g_variant_unref(entry);
        }
        if (!problem.isEmpty()) {
            g_variant_unref(extra);
            *why = problem;
            return false;
        }
        AuthInfo info;
        info.url          = QString::fromUtf8(url);
        info.parsed       = QUrl(info.url);
        info.username     = QString::fromUtf8(username);
        info.password     = Secret(password, std::strlen(password));
        info.prompt       = QString::fromUtf8(prompt);
        info.caption      = QString::fromUtf8(caption);
        info.comment      = QString::fromUtf8(comment);
        info.commentLabel = QString::fromUtf8(commentLabel);
        info.realm        = QString::fromUtf8(realm);
        info.digestInfo   = QString::fromUtf8(digest);
        info.verifyPath   = verifyPath;
        info.readOnly     = readOnly;
        info.keepPassword = keepPassword;
        info.modified     = modified;
        info.extra        = VariantRef(extra); // takes its own reference
        g_variant_unref(extra);
        *out = std::move(info);
        return true;
    }

    GVariant* authInfoVariant(const AuthInfo& info) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE(kAuthInfoType));
        g_variant_builder_add(&b, "y", guchar(1));
        g_variant_builder_add(&b, "s", info.url.toUtf8().constData());
        g_variant_builder_add(&b, "s", info.username.toUtf8().constData());
        // The password: a copy in gcr's secure memory is the string's own data, zeroed and freed with the variant. Only
        // valid UTF-8 without a NUL goes on the bus (the bus daemon drops a connection that sends anything else).
        const bool valid = std::strlen(info.password.data()) == info.password.size()
            && g_utf8_validate(info.password.data(), static_cast<gssize>(info.password.size()), nullptr);
        char* secret = valid ? info.password.copyOut() : Secret().copyOut();
        g_variant_builder_add_value(&b, g_variant_new_from_data(G_VARIANT_TYPE_STRING, secret, std::strlen(secret) + 1, TRUE, wipeAndFree, secret));
        for (const QString* text : {&info.prompt, &info.caption, &info.comment, &info.commentLabel, &info.realm, &info.digestInfo})
            g_variant_builder_add(&b, "s", text->toUtf8().constData());
        g_variant_builder_add(&b, "b", gboolean(info.verifyPath));
        g_variant_builder_add(&b, "b", gboolean(info.readOnly));
        g_variant_builder_add(&b, "b", gboolean(info.keepPassword));
        g_variant_builder_add(&b, "b", gboolean(info.modified));
        if (info.extra.get())
            g_variant_builder_add_value(&b, info.extra.get());
        else
            g_variant_builder_add_value(&b, g_variant_new_array(G_VARIANT_TYPE("{s(siv)}"), nullptr, 0));
        return g_variant_builder_end(&b);
    }

    bool extraBool(const AuthInfo& info, const char* name, bool* present) {
        if (present)
            *present = false;
        GVariant* extra = info.extra.get();
        if (!extra)
            return false;
        GVariant* entry = g_variant_lookup_value(extra, name, G_VARIANT_TYPE("(siv)"));
        if (!entry)
            return false;
        if (present)
            *present = true;
        GVariant* v = g_variant_get_child_value(entry, 2);
        GVariant* inner = g_variant_get_variant(v);
        const bool value = g_variant_is_of_type(inner, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(inner);
        g_variant_unref(inner);
        g_variant_unref(v);
        g_variant_unref(entry);
        return value;
    }

    void setExtraBool(AuthInfo* info, const char* name, bool value) {
        GVariant* extra = info->extra.get();
        if (!extra)
            return;
        bool present = false;
        extraBool(*info, name, &present);
        if (!present)
            return;
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{s(siv)}"));
        for (gsize i = 0; i < g_variant_n_children(extra); ++i) {
            GVariant*    entry = g_variant_get_child_value(extra, i);
            const gchar* key   = nullptr;
            const gchar* title = nullptr;
            gint32       flags = 0;
            GVariant*    v     = nullptr;
            g_variant_get(entry, "{&s(&siv)}", &key, &title, &flags, &v);
            if (std::strcmp(key, name) == 0)
                g_variant_builder_add(&b, "{s(siv)}", key, title, flags, g_variant_new_boolean(value));
            else
                g_variant_builder_add_value(&b, entry);
            g_variant_unref(v);
            g_variant_unref(entry);
        }
        info->extra = VariantRef(g_variant_builder_end(&b));
    }

    // --- keys and names --------------------------------------------------------------------------------------------------

    QString cacheKey(const QUrl& url) {
        if (!url.isValid())
            return {};
        QString key = url.scheme();
        key += u'-';
        if (!url.userName().isEmpty())
            key += url.userName() + u'@';
        key += url.host();
        const int port = url.port();
        if (port) // -1 when the URL has none, which is true here, as in kpasswdserver.cpp:583-586
            key += u':' + QString::number(port);
        return key;
    }

    QString directoryOf(const QUrl& url) {
        const QString path = url.path();
        return path.left(path.indexOf(u'/') + 1);
    }

    QString serverLabel(const QUrl& url) {
        if (!url.isValid())
            return {};
        QString host = url.host(QUrl::EncodeUnicode);
        if (host.startsWith(u'[') && host.endsWith(u']'))
            host = host.mid(1, host.size() - 2);
        if (host.isEmpty() || host.size() > 253)
            return {};
        QString shown;
        if (host.contains(u':')) {
            // An IPv6 address (QUrl gives it without brackets); no zone index.
            if (host.size() > 45 || !std::all_of(host.cbegin(), host.cend(), [](QChar c) {
                    return (c >= u'0' && c <= u'9') || (c >= u'a' && c <= u'f') || (c >= u'A' && c <= u'F') || c == u':' || c == u'.';
                }))
                return {};
            shown = u'[' + host.toLower() + u']';
        } else {
            host = host.toLower();
            QStringList labels = host.split(u'.');
            if (labels.size() > 1 && labels.constLast().isEmpty())
                labels.removeLast(); // a fully qualified name's final dot
            for (const QString& label : std::as_const(labels)) {
                if (label.isEmpty() || label.size() > 63)
                    return {};
                if (!std::all_of(label.cbegin(), label.cend(), [](QChar c) { return (c >= u'a' && c <= u'z') || (c >= u'0' && c <= u'9') || c == u'-' || c == u'_'; }))
                    return {};
            }
            shown = host;
        }
        if (url.port() >= 0)
            shown += u':' + QString::number(url.port());
        return shown;
    }

    QList<QPair<QString, QString>> storeAttributes(const QString& key, const AuthInfo& info) {
        return {
            {QStringLiteral("key"), key},
            {QStringLiteral("realm"), info.realm},
            {QStringLiteral("user"), info.username},
            {QStringLiteral("protocol"), info.parsed.scheme()},
            {QStringLiteral("server"), info.parsed.host(QUrl::EncodeUnicode)},
            {QStringLiteral("port"), QString::number(info.parsed.port())},
        };
    }

    QList<QPair<QString, QString>> searchAttributes(const QString& key, const AuthInfo& info) {
        QList<QPair<QString, QString>> attributes{{QStringLiteral("key"), key}, {QStringLiteral("realm"), info.realm}};
        if (!info.username.isEmpty())
            attributes.append({QStringLiteral("user"), info.username});
        return attributes;
    }

    QString itemLabel(const AuthInfo& info) {
        const QString server = serverLabel(info.parsed);
        return info.parsed.scheme() + QStringLiteral("://") + (info.username.isEmpty() ? QString() : info.username + u'@')
            + (server.isEmpty() ? info.parsed.host(QUrl::EncodeUnicode) : server);
    }

    // --- the keyring's protection --------------------------------------------------------------------------------------

    QString protectionName(Protection protection) {
        switch (protection) {
            case Protection::Protected: return QStringLiteral("protected");
            case Protection::Unprotected: return QStringLiteral("unprotected");
            case Protection::Unknown: break;
        }
        return QStringLiteral("unknown");
    }

    Protection protectionOfHeader(const QByteArray& head) {
        static const QByteArray binary("GnomeKeyring\n\r\0\n", 16);
        if (head.startsWith(binary))
            return Protection::Protected;
        if (head.startsWith("[keyring]"))
            return Protection::Unprotected;
        return Protection::Unknown;
    }

    QString collectionFileName(const QString& objectPath) {
        static const QString prefix = QStringLiteral("/org/freedesktop/secrets/collection/");
        if (!objectPath.startsWith(prefix))
            return {};
        const QString escaped = objectPath.mid(prefix.size());
        if (escaped.isEmpty() || escaped.size() > 3 * 255)
            return {};
        QByteArray name;
        for (qsizetype i = 0; i < escaped.size(); ++i) {
            const QChar c = escaped.at(i);
            if (c == u'_') {
                if (i + 2 >= escaped.size())
                    return {};
                const int hi = hexValue(escaped.at(i + 1));
                const int lo = hexValue(escaped.at(i + 2));
                if (hi < 0 || lo < 0)
                    return {};
                name.append(static_cast<char>(hi * 16 + lo));
                i += 2;
            } else if (asciiAlnum(c)) {
                name.append(static_cast<char>(c.unicode()));
            } else {
                return {};
            }
        }
        if (name.isEmpty() || name.size() > 255 || name.contains('/') || name.contains('\0') || name == "." || name == "..")
            return {};
        return QFile::decodeName(name);
    }

    QString keyringDirectory(const QString& xdgDataHome, const QString& home) {
        if (!xdgDataHome.isEmpty())
            return xdgDataHome + QStringLiteral("/keyrings");
        if (!home.isEmpty())
            return home + QStringLiteral("/.local/share/keyrings");
        return {};
    }

    Protection fileProtection(const QString& path, uid_t uid) {
        if (path.isEmpty())
            return Protection::Unknown;
        const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY);
        if (fd < 0)
            return Protection::Unknown;
        struct stat st{};
        char        head[16] = {};
        ssize_t     n        = -1;
        if (::fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == uid)
            n = ::read(fd, head, sizeof head);
        ::close(fd);
        return n > 0 ? protectionOfHeader(QByteArray(head, static_cast<qsizetype>(n))) : Protection::Unknown;
    }

    // --- the session cache -----------------------------------------------------------------------------------------------

    qint64 Cache::monotonicSeconds() {
        timespec ts{};
        ::clock_gettime(CLOCK_MONOTONIC, &ts);
        return static_cast<qint64>(ts.tv_sec);
    }

    Cache::Cache(Clock clock, int capacity) : m_clock(clock), m_capacity(capacity) {}

    CacheEntry* Cache::find(const QString& key, const AuthInfo& info) {
        const auto found = m_dict.find(key);
        if (found == m_dict.end())
            return nullptr;
        QList<CacheEntry>& list  = found.value();
        const QString      path2 = directoryOf(info.parsed);
        const qint64       now   = m_clock();
        for (auto it = list.begin(); it != list.end();) {
            if (it->expired(now)) {
                it = list.erase(it);
                continue;
            }
            const bool userMatches = info.username.isEmpty() || info.username == it->info.username;
            if (info.verifyPath ? (path2.startsWith(it->directory) && userMatches) : (it->info.realm == info.realm && userMatches))
                return &*it;
            ++it;
        }
        if (list.isEmpty())
            m_dict.erase(found);
        return nullptr;
    }

    void Cache::add(const QString& key, const AuthInfo& info, qint64 windowId, qint64 seqNr, bool canceled, const QString& caller) {
        QList<CacheEntry>& list = m_dict[key];
        CacheEntry         entry;
        bool               found = false;
        for (auto it = list.begin(); it != list.end(); ++it) {
            if (it->info.realm == info.realm) {
                entry = *it;
                list.erase(it);
                found = true;
                break;
            }
        }
        if (!found) {
            entry          = CacheEntry();
            entry.expire   = CacheEntry::Expire::Time;
            if (size() >= m_capacity)
                evictOne();
        }
        entry.info      = info;
        entry.directory = directoryOf(info.parsed);
        entry.seqNr     = seqNr;
        entry.canceled  = canceled;
        entry.order     = ++m_order;
        touch(&entry, windowId, info.keepPassword && !canceled, caller);
        QList<CacheEntry>& again = m_dict[key]; // evictOne may have changed the table
        again.append(entry);
        std::stable_sort(again.begin(), again.end(), [](const CacheEntry& a, const CacheEntry& b) { return a.directory.size() < b.directory.size(); });
    }

    void Cache::touch(CacheEntry* entry, qint64 windowId, bool keep, const QString& caller) {
        if (keep && !windowId) {
            entry->expire = CacheEntry::Expire::Never;
        } else if (windowId && entry->expire != CacheEntry::Expire::Never) {
            entry->expire = CacheEntry::Expire::WindowClose;
            // kiod6 keeps it until the window closes, which it never hears of on Wayland: the bridge keeps it while a
            // connection that tied it to a window is on the bus (callerGone), and at most kWindowExpireSeconds after its
            // last use (B-04).
            entry->expireAt = m_clock() + kWindowExpireSeconds;
            // The ids come from the callers: bounded, so that one entry cannot grow with every id a caller invents.
            const CacheEntry::Window window{windowId, caller};
            if (entry->windows.size() < kMaxWindows && !entry->windows.contains(window))
                entry->windows.append(window);
        } else if (entry->expire == CacheEntry::Expire::Time) {
            entry->expireAt = m_clock() + kExpireSeconds;
        }
    }

    int Cache::callerGone(const QString& caller) {
        if (caller.isEmpty())
            return 0;
        int gone = 0;
        for (auto it = m_dict.begin(); it != m_dict.end();) {
            QList<CacheEntry>& list = it.value();
            for (qsizetype i = 0; i < list.size();) {
                CacheEntry& e = list[i];
                if (e.expire == CacheEntry::Expire::WindowClose && e.windows.removeIf([&](const CacheEntry::Window& w) { return w.caller == caller; }) > 0
                    && e.windows.isEmpty()) {
                    // Tied only to connections that left: no window of a living caller can ask for it again.
                    list.removeAt(i);
                    ++gone;
                    continue;
                }
                ++i;
            }
            it = list.isEmpty() ? m_dict.erase(it) : std::next(it);
        }
        return gone;
    }

    void Cache::remove(const QString& key, const QString& realm) {
        const auto found = m_dict.find(key);
        if (found == m_dict.end())
            return;
        found.value().removeIf([&](const CacheEntry& e) { return e.info.realm == realm; });
        if (found.value().isEmpty())
            m_dict.erase(found);
    }

    int Cache::removeMatching(const QString& host, const QString& protocol, const QString& user) {
        const int before = size();
        QList<QPair<QString, QString>> doomed; // (key, realm)
        for (auto it = m_dict.cbegin(); it != m_dict.cend(); ++it) {
            for (const CacheEntry& e : it.value()) {
                if (e.info.parsed.scheme() == protocol && e.info.parsed.host() == host && (user.isEmpty() || e.info.username == user))
                    doomed.append({it.key(), e.info.realm});
            }
        }
        for (const auto& [key, realm] : std::as_const(doomed))
            remove(key, realm);
        return before - size();
    }

    int Cache::size() const {
        int n = 0;
        for (const QList<CacheEntry>& list : m_dict)
            n += static_cast<int>(list.size());
        return n;
    }

    void Cache::clear() {
        m_dict.clear();
    }

    void Cache::evictOne() {
        const qint64 now = m_clock();
        // Expired entries first.
        for (auto it = m_dict.begin(); it != m_dict.end();) {
            it.value().removeIf([&](const CacheEntry& e) { return e.expired(now); });
            it = it.value().isEmpty() ? m_dict.erase(it) : std::next(it);
        }
        if (size() < m_capacity)
            return;
        // Then the oldest.
        QString oldestKey;
        quint64 oldest = 0;
        for (auto it = m_dict.cbegin(); it != m_dict.cend(); ++it) {
            for (const CacheEntry& e : it.value()) {
                if (oldestKey.isNull() || e.order < oldest) {
                    oldest    = e.order;
                    oldestKey = it.key();
                }
            }
        }
        if (oldestKey.isNull())
            return;
        auto found = m_dict.find(oldestKey);
        found.value().removeIf([&](const CacheEntry& e) { return e.order == oldest; });
        if (found.value().isEmpty())
            m_dict.erase(found);
    }

} // namespace gf::prompter::kio
