#pragma once

// KIO's network passwords (ADR-0035 D-12 b, owner decision Q11 = K1; step 9e; docs/specs/system-dialogs.md section 5,
// SC9-SC9c): the pure rules of grassfield-prompter's org.kde.kpasswdserver6, unit-tested in tests/unit/prompter/ without a
// bus. The bus side (the object, the name, the requests, the Secret Service) is KioServer.h.
//
// KIO v6.31.0, read as data:
// - the interface (src/core/org.kde.KPasswdServer.xml:3-59): checkAuthInfoAsync(AuthInfo, x windowId, x usertime) -> x
//   requestId, queryAuthInfoAsync(AuthInfo, s errorMsg, x windowId, x seqNr, x usertime) -> x requestId, addAuthInfo(AuthInfo,
//   x windowId), removeAuthInfo(s host, s protocol, s user), and the results as the signals checkAuthInfoAsyncResult and
//   queryAuthInfoAsyncResult (x requestId, x seqNr, AuthInfo); KF6's client (src/core/kpasswdserverclient.cpp:41-128) uses
//   nothing else (the "ay" methods are marked LEGACY);
// - an AuthInfo on the bus (src/core/authinfo.cpp:210-231): (ysssssssssbbbba{s(siv)}) = version 1, the URL as
//   QUrl::toString(), username, password, prompt, caption, comment, commentLabel, realmValue, digestInfo, verifyPath,
//   readOnly, keepPassword, modified, and the extra fields (name -> (customTitle, flags, value)); KIO reads the URL back with
//   QUrl(url) (:229);
// - the session cache (src/kpasswdserver/kpasswdserver.cpp): its key (createCacheKey, :568-589), the entries of a key and
//   how one is found (findAuthInfoItem, :597-627), added (addAuthInfoItem, :649-687), removed (:629-647, removeAuthInfo
//   :448-469) and how long it lives (updateAuthExpire, :689-714; src/kpasswdserver/DESIGN). Its quirks are kept, since
//   they decide which request a credential answers: QUrl::port() is -1 when the URL has none and `if (port)` is true for
//   it, so a key without a port ends in ":-1" (:583-586); an entry's "directory" is the path up to its FIRST slash, which
//   for an absolute path is always "/" (:678, :603), so verifyPath matches every path; the entries of a key are sorted
//   shortest directory first (:52-57, :686).
// What Grassfield adds to it (decisions 9-39, 9-46, 9-49): a bound on the entries; a clock that does not jump (CLOCK_MONOTONIC,
// where kpasswdserver uses time()); the password kept in gcr's secure memory, never in a QString.

#include "Protocol.h"

#include <gio/gio.h>

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <cstddef>
#include <sys/types.h>

namespace gf::prompter::kio {

    inline constexpr char kBusName[]      = "org.kde.kpasswdserver6"; // kpasswdserverclient.cpp:31
    inline constexpr char kObjectPath[]   = "/modules/kpasswdserver";
    inline constexpr char kInterface[]    = "org.kde.KPasswdServer";
    inline constexpr char kAuthInfoType[] = "(ysssssssssbbbba{s(siv)})";
    inline constexpr char kCheckResult[]  = "checkAuthInfoAsyncResult";
    inline constexpr char kQueryResult[]  = "queryAuthInfoAsyncResult";

    // queryAuthInfoAsync's errorMsg that asks for no prompt at all (kpasswdserver.cpp:398-401; SlaveBase sets it for the
    // "no-auth-prompt" metadata).
    inline constexpr char kNoAuthPrompt[] = "<NoAuthPrompt>";

    // The extra fields kpasswdserver reads (kpasswdserver.cpp:39-44).
    inline constexpr char kExtraDomain[]       = "domain";
    inline constexpr char kExtraAnonymous[]    = "anonymous";
    inline constexpr char kExtraBypassCache[]  = "bypass-cache-and-kwallet";
    inline constexpr char kExtraSkipCaching[]  = "skip-caching-on-query";
    inline constexpr char kExtraHideUsername[] = "hide-username-line";

    // Bounds of what the bridge keeps of an AuthInfo (Grassfield's; kpasswdserver has none): a larger one is refused
    // (InvalidArgs) before anything is kept. KIO's own prompts and comments are a sentence or two; with these bounds an entry
    // of the session cache stays under 48 KiB, the full cache under 12 MiB (the unit's MemoryHigh is 48M).
    inline constexpr std::size_t kUrlBytes        = 4096;
    inline constexpr std::size_t kTextBytes       = 4096; // prompt, caption, comment, commentLabel, realmValue, digestInfo, errorMsg
    inline constexpr std::size_t kExtraFields     = 16;
    inline constexpr std::size_t kExtraNameBytes  = 256;
    inline constexpr std::size_t kExtraEntryBytes = 1024; // one serialised extra field
    // Entries of the session cache (all keys together); beyond, the expired ones go, then the oldest.
    inline constexpr int kCacheEntries = 256;
    // An entry that is neither kept for the session nor tied to a window lives this long after its last use (10 s,
    // kpasswdserver.cpp:704).
    inline constexpr qint64 kExpireSeconds = 10;
    // An entry tied to a window (B-04, decision 9-39 as amended): kiod6 keeps it until KDE tells it the window closed, which
    // never happens on Wayland, so the bridge ends it when every bus connection that tied it to a window has left the bus,
    // and at the latest this long after its last use.
    inline constexpr qint64 kWindowExpireSeconds = 15 * 60;
    // Windows (with their connection) one entry is tied to: the ids come from the callers.
    inline constexpr qsizetype kMaxWindows = 64;
    // UTF-16 code units of the texts the sheet shows: the server (a host name of at most 253 characters, its port), the
    // name's first text, the realm.
    inline constexpr int kServerCap = 262;
    inline constexpr int kNameCap   = 256;
    inline constexpr int kRealmCap  = 256;

    // A password in gcr's secure memory (NUL-terminated), zeroed when it goes. Copies are deep.
    class Secret {
      public:
        Secret() = default;
        Secret(const char* data, std::size_t size);
        Secret(const Secret& other);
        Secret& operator=(const Secret& other);
        Secret(Secret&& other) noexcept;
        Secret& operator=(Secret&& other) noexcept;
        ~Secret();

        // Takes over `secure` (gcr secure memory, at least size + 1 bytes, NUL-terminated at `size`).
        static Secret adopt(char* secure, std::size_t size);

        const char* data() const {
            return m_data ? m_data : "";
        }
        std::size_t size() const {
            return m_size;
        }
        bool empty() const {
            return m_size == 0;
        }
        // A new gcr secure buffer holding a copy (NUL-terminated); the caller frees it with wipeAndFree.
        char* copyOut() const;
        bool  operator==(const Secret& other) const;

      private:
        void   reset();
        char*  m_data = nullptr;
        std::size_t m_size = 0;
    };

    // Zeroes and frees a gcr secure buffer of `size` bytes and its NUL (a GDestroyNotify with the size unknown: strlen).
    void wipeAndFree(gpointer secure);

    // A reference to a GVariant (copies share it).
    class VariantRef {
      public:
        VariantRef() = default;
        explicit VariantRef(GVariant* value); // takes a reference (sinks a floating one)
        VariantRef(const VariantRef& other);
        VariantRef& operator=(const VariantRef& other);
        ~VariantRef();
        GVariant* get() const {
            return m_value;
        }

      private:
        GVariant* m_value = nullptr;
    };

    struct AuthInfo {
        QString    url;    // as KIO sent it (QUrl::toString())
        QUrl       parsed; // QUrl(url): KIO's own reading
        QString    username;
        Secret     password;
        QString    prompt, caption, comment, commentLabel, realm, digestInfo;
        bool       verifyPath   = false;
        bool       readOnly     = false;
        bool       keepPassword = false;
        bool       modified     = false;
        VariantRef extra; // a{s(siv)}, as the bus gave it (bounded), echoed back
    };

    // Reads an AuthInfo of type kAuthInfoType; false with *why set when it is of another type or over a bound.
    bool parseAuthInfo(GVariant* value, AuthInfo* out, QString* why);
    // The AuthInfo as KIO reads it back (a floating reference). The password's string is a copy in gcr's secure memory,
    // zeroed and freed with the variant.
    GVariant* authInfoVariant(const AuthInfo& info);

    // An extra field: `present` set when it exists; its value as a boolean (a "b" value only; anything else is false).
    bool extraBool(const AuthInfo& info, const char* name, bool* present = nullptr);
    // Sets an existing extra field's value to the boolean `value` (its title and flags kept); nothing when it is absent.
    void setExtraBool(AuthInfo* info, const char* name, bool value);

    // kpasswdserver's createCacheKey: "<scheme>-[<user>@]<host>:<port>", the port -1 when the URL has none; empty for an
    // invalid URL.
    QString cacheKey(const QUrl& url);
    // kpasswdserver's "directory" of a URL: its path up to the first slash (":678").
    QString directoryOf(const QUrl& url);

    // The server the sheet names: the URL's host in its ASCII form (punycode for an international name: never a look-alike
    // character), lower case, letters, digits, '-', '_' and dots only (a NetBIOS name has underscores), or an IPv6 address
    // in brackets, then ":<port>" when the URL has one. Empty when the URL has no such host: the sheet is not shown.
    QString serverLabel(const QUrl& url);

    // The Secret Service item of a remembered password (schema kSchemaName, every attribute a string): the cache key and the
    // realm (KWallet's "<key>-<realm>" entry, kpasswdserver.cpp:97-101), the user (its "login"), and the URL's parts for
    // the keyring's own browsers. Searches use the key, the realm and, when known, the user.
    inline constexpr char kSchemaName[] = "org.grassfield.NetworkPassword";
    QList<QPair<QString, QString>> storeAttributes(const QString& key, const AuthInfo& info);
    QList<QPair<QString, QString>> searchAttributes(const QString& key, const AuthInfo& info);
    // The item's label: "<scheme>://[<user>@]<server>".
    QString itemLabel(const AuthInfo& info);

    // Whether the keyring that receives a remembered password is protected by a password (step 9e, decision 9-45). The
    // Secret Service API does not say (a collection has Items, Label, Locked, Created and Modified only); gnome-keyring,
    // the session's Secret Service (ADR-0035 Q17-b), writes a keyring whose password is empty as plain text ("[keyring]",
    // gkm-secret-textual.c) and any other in its encrypted format ("GnomeKeyring\n\r\0\n", gkm-secret-binary.c).
    enum class Protection { Unknown, Protected, Unprotected };
    QString    protectionName(Protection protection); // "unknown", "protected", "unprotected"
    Protection protectionOfHeader(const QByteArray& head);
    // gnome-keyring's collection object path -> the keyring's file name without ".keyring": it escapes every byte that is not
    // a letter or a digit as "_xx" (gkd-secret-util.c; "Default_keyring" -> "Default_5fkeyring"). Empty when the path is not
    // /org/freedesktop/secrets/collection/<escaped> or the name would not be a plain file name.
    QString collectionFileName(const QString& objectPath);
    // gnome-keyring's keyrings directory: $XDG_DATA_HOME/keyrings, else $HOME/.local/share/keyrings (g_get_user_data_dir).
    QString keyringDirectory(const QString& xdgDataHome, const QString& home);
    // The protection of the keyring file `path`: read without following a symlink, a regular file of `uid`, its first 16
    // bytes.
    Protection fileProtection(const QString& path, uid_t uid);

    // The session cache (kpasswdserver's m_authDict).
    struct CacheEntry {
        enum class Expire { Never, WindowClose, Time };
        struct Window {
            qint64  id = 0;
            QString caller; // the unique bus name that tied it (empty: not known, kept until the time limit)
            bool    operator==(const Window&) const = default;
        };
        AuthInfo      info;
        QString       directory;
        Expire        expire   = Expire::Time;
        QList<Window> windows;
        qint64        expireAt = 0; // on the cache's clock: Expire::Time (10 s) and Expire::WindowClose (kWindowExpireSeconds)
        bool          expired(qint64 now) const {
            return expire != Expire::Never && now > expireAt;
        }
        qint64        seqNr    = 0;
        bool          canceled = false;
        quint64       order    = 0; // when it was added, for the bound
    };

    class Cache {
      public:
        using Clock = qint64 (*)();
        static qint64 monotonicSeconds();

        explicit Cache(Clock clock = monotonicSeconds, int capacity = kCacheEntries);

        // findAuthInfoItem: expired entries of the key go; then the first entry (shortest directory first) that matches
        // `info`'s path (verifyPath) or realm, and its user when `info` names one. Valid until the next change.
        CacheEntry* find(const QString& key, const AuthInfo& info);
        // addAuthInfoItem: replaces the key's entry of the same realm (keeping how long it lives) or adds one, then
        // touch(..., keepPassword && !canceled).
        void add(const QString& key, const AuthInfo& info, qint64 windowId, qint64 seqNr, bool canceled, const QString& caller = QString());
        // updateAuthExpire, with `caller` (the unique bus name asking for `windowId`) and the time limit of a window's entry.
        void touch(CacheEntry* entry, qint64 windowId, bool keep, const QString& caller = QString());
        // The bus connection `caller` left: its windows are untied; an entry tied to no window any more goes. Returns how
        // many entries went.
        int  callerGone(const QString& caller);
        // removeAuthInfoItem: the key's entries of that realm.
        void remove(const QString& key, const QString& realm);
        // removeAuthInfo: every entry of that scheme and host (and user, when not empty), with the other entries of their
        // key and realm. Returns how many entries went.
        int  removeMatching(const QString& host, const QString& protocol, const QString& user);
        int  size() const;
        void clear();

      private:
        void evictOne();

        QHash<QString, QList<CacheEntry>> m_dict;
        Clock                             m_clock;
        int                               m_capacity;
        quint64                           m_order = 0;
    };

} // namespace gf::prompter::kio
