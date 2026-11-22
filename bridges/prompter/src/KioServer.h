#pragma once

// grassfield-prompter's KIO password server (ADR-0035 D-12 b, owner decision Q11 = K1; step 9e; docs/specs/system-dialogs.md
// section 5, SC9-SC9c): org.kde.kpasswdserver6 at /modules/kpasswdserver, interface org.kde.KPasswdServer, on the bridge's
// own session bus connection (GDBus), its prompts asked through the shell's secret sheet as prompter/1 requests of kind
// "kio". The pure rules (the AuthInfo on the bus, the cache, the server's name, the keyring's protection) are KioAuth.h.
//
// - The name follows the shell (decision 9-36): requested with flags 0 (queued behind an owner, never replaceable) while a
//   shell that draws "kio" is connected, released when it goes, after every request still open has had its answer: KIO's
//   client waits for its result with no time limit (kpasswdserverloop.cpp:25-31) and hears only of the name being freed
//   (:16-19), never of it passing to another owner. The release comes kReleaseDelayMs after the answers (decision 9-37): a
//   client that reads its result and the name's departure in one turn of its event loop takes the departure, the later of
//   the two exit() calls, for the server's death (KIO::ERR_PASSWD_SERVER); meanwhile every new request gets "nothing". With
//   no shell, D-Bus activation starts kiod6 (KDE's dialog), as before step 9e; kiod6 neither queues for nor replaces a name
//   (kiod_main.cpp:107-115, Qt's defaults), so whichever holds it keeps it. kiod6 takes its names once, when it starts, and
//   a second kiod6 leaves at once (KDBusService Unique): a kiod6 that started while the bridge held the name never takes it
//   later, and D-Bus activation for it would time out (25 s). So the name is released only while kiod6 is not running;
//   else the bridge keeps it, answering "nothing" at once, until kiod6 leaves the bus; and a bridge that finds kiod6
//   running without the name takes it, kKiod6SettleMs after kiod6 appeared (the security review of step 9e, MINOR-1).
// - The object stays exported for the bridge's life; a call that reaches it while no shell draws "kio" is answered as if
//   nothing were known: no cache read, no sheet, nothing stored.
// - Results go to the caller only: each result signal is addressed to the unique name that asked
//   (g_dbus_connection_emit_signal with a destination), where kpasswdserver broadcasts them, credentials included
//   (kpasswdserver.cpp:330, 852, 883). The method reply (the requestId) always goes before its result.
// - kpasswdserver's rules (KioAuth.h): requestIds and the sequence number; one prompt at a time per window and per key, the
//   first query waiting holding the others (processRequest, kpasswdserver.cpp:485-566); a check that waits for a query of its
//   key (:293-304, 860-891); a query whose sequence number is older than the cache's entry is answered from it without a
//   sheet (:518-525); the user's Cancel kept as a cancelled entry (:962-967); a user name changed in the sheet moves the
//   entry to its new key (:941-948), and the key that was being prompted is released (kpasswdserver releases the new one
//   only, which leaves the old one blocked: decision 9-39).
// - Remembered passwords live in the Secret Service through libsecret (schema org.grassfield.NetworkPassword), never
//   KWallet, through libsecret's asynchronous calls only, on the bridge's GLib main context: storing into a locked keyring
//   makes gnome-keyring ask through gcr's prompter, which is this bridge (SC9c). addAuthInfo is answered at once and stores
//   in the background, only when keepPassword says the user chose "Remember this password" (decision 9-41); a check looks a
//   remembered password up (unlocking the keyring when an item is there: its prompt takes its turn in the shell's queue); a
//   query looks one up without unlocking, to tick "Remember this password" and fill the name. A password sent to the
//   keychain stays in the session's cache only while its window lives, as kpasswdserver's after a wallet store
//   (kpasswdserver.cpp:427-434, 947-950); for the session when the store fails.
// - A call that may hold one of gnome-keyring's unlock prompts (a store, a check's unlocking search) is never cancelled
//   while the Secret Service that holds it runs: a cancelled libsecret call dismisses its prompt, and gnome-keyring 51.1
//   aborts on the dismissal of an unlock prompt queued behind another one being shown (gkd-secret-unlock.c:244, the
//   g_assert of perform_next_unlock) and loses the next one when the shown one is dismissed (decision 9-50). A store holds
//   one of kStoresInFlight places for at most kStoreTimeoutMs, then goes on without it (its outcome logged when it comes);
//   when the Secret Service leaves the bus, its stores and searches end at once, and libsecret's shared service (whose
//   session belonged to the one that left) is dropped.
// - Who asks is resolved from the caller's bus credentials (Identity.h): a KIO worker (/usr/lib/kf6/kioworker, which runs
//   whatever worker plugin it is given) is the role "kio", whose text is another program's; else an app or "Unidentified
//   program". The server's name is a field of Grassfield's sentence, a host name only (KioAuth.h serverLabel).
// - Bounds: at most 8 requests (checks and queries) open per caller connection and 32 in all, beyond which a request is
//   answered "nothing" at once; a query shares the shell's bound of 8 with gcr's and NetworkManager's requests, and
//   waits in the bridge's applications' queue for a place past its share (B-05 amended, owner decision 2026-11-22); at most 8
//   stores holding a place and 32 alive; the cache's entries (KioAuth.h). No time limit once a sheet is shown (KIO's client has
//   none either); a query still waiting for a place ends after 110 s.
// - Nothing secret is logged: request ids, kinds, servers, roles, refusals and why.

#include "Identity.h"
#include "KioAuth.h"
#include "Protocol.h"

#include <gio/gio.h>

#include <QHash>
#include <QList>
#include <QString>
#include <QStringList>

#include <memory>
#include <sys/types.h>

namespace gf::prompter {

    class KioServer;

    // One request of a KIO client: a check (checkAuthInfoAsync) or a query (queryAuthInfoAsync).
    struct KioRequest {
        enum class Kind { Check, Query };
        enum class Stage { Waiting, Preparing, Shown, Ended };
        Kind          kind      = Kind::Query;
        Stage         stage     = Stage::Waiting;
        qint64        requestId = 0;
        QString       sender; // the caller's unique name: its result goes there only
        QString       key;    // kpasswdserver's cache key
        kio::AuthInfo info;
        QString       errorMsg;
        qint64        windowId = 0;
        qint64        seqNr    = 0;
        bool          prompt   = true;
        QString       promptedKey; // the key this query holds while it is prompted ("" before)
        bool          prompted     = false;
        bool          callerGone   = false;
        // What the sheet shows (a query on its way to the shell); the bridge reads these.
        RequesterView   requester;
        QString         server;              // KioAuth.h serverLabel
        QString         name;                // the name field's first text
        QString         nameMode;            // "edit", "fixed" (readOnly) or "none" (hide-username-line)
        QString         realm;               // flattened
        bool            retry           = false; // the worker says the last name and password failed
        bool            rememberOffered = false;
        bool            rememberChosen  = false; // the keychain holds an item for it already
        kio::Protection keyring         = kio::Protection::Unknown;
        QString         rememberedUser;
        QString         id; // the shell's request id, once sent
        GCancellable*   cancellable = nullptr;
    };

    class KioServer {
      public:
        class Sink {
          public:
            virtual ~Sink() = default;
            // Show `request` in the shell: its id when it went or waits for a place among the shell's 8 (B-05 amended:
            // the bridge sends it on its turn, or ends it through abandon()), empty when it cannot (no shell, a shell that
            // does not draw "kio", the applications' queue full). The request may end inside this call (the shell lost
            // while sending).
            virtual QString submitKio(KioRequest* request) = 0;
            // The server ended a request the shell holds or that waits for its turn (its caller left the bus): the shell is
            // told "cancel" when it was sent.
            virtual void withdrawKio(const QString& id) = 0;
        };

        struct Options {
            uid_t   uid = 0;
            QString keyringDirectory; // gnome-keyring's (KioAuth.h keyringDirectory)
            int     storeTimeoutMs = 0; // how long a store holds its place; 0: kStoreTimeoutMs (tests set less)
        };

        static constexpr int kStoreTimeoutMs = 120000;

        KioServer(GDBusConnection* bus, Sink* sink, Options options);
        ~KioServer();

        KioServer(const KioServer&)            = delete;
        KioServer& operator=(const KioServer&) = delete;

        // Exports the object and follows callers and the name. False with *error set.
        bool start(QString* error);
        // The name is held, and calls served, only while true (a shell that draws "kio" is connected). False ends every
        // open request ("nothing") before the name is released.
        void setWanted(bool wanted);

        // The shell's answers to a query it holds no more. `name` replaces the user name when the sheet asked for one
        // (nameMode "edit"); `remember`: the check box, when it was offered.
        void answer(KioRequest* request, const QString& name, kio::Secret password, bool remember);
        // The user's Cancel.
        void userCancel(KioRequest* request);
        // Any other end (the shell gone, a wrong answer, the bound): "nothing", and nothing cached.
        void abandon(KioRequest* request, const QString& why);

        int open() const {
            return static_cast<int>(m_requests.size());
        }

      private:
        using Request = std::shared_ptr<KioRequest>;
        struct Call;
        // A password on its way to the keychain.
        struct Store {
            QString       scheme;
            QString       key;
            kio::AuthInfo entry; // finds its cache entry again (no password)
            qint64        seqNr       = 0;
            quint64       secretsGen  = 0; // the Secret Service's owner it was sent to (m_secretsGen)
            GCancellable* cancellable = nullptr;
            guint         timer       = 0;
            bool          holdsPlace  = true;
        };
        // A check's unlocking search in flight (it may hold an unlock prompt).
        struct Unlock {
            GCancellable*             cancellable = nullptr;
            std::weak_ptr<KioRequest> request;
        };

        static void onMethodCall(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* method,
                                 GVariant* parameters, GDBusMethodInvocation* invocation, gpointer self);
        static void onOwnerChanged(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* signal,
                                   GVariant* parameters, gpointer self);
        static void onNameSignal(GDBusConnection* bus, const gchar* sender, const gchar* path, const gchar* iface, const gchar* signal,
                                 GVariant* parameters, gpointer self);
        static void onNameReply(GObject* source, GAsyncResult* result, gpointer data);
        static void onCallerCredentials(GObject* source, GAsyncResult* result, gpointer data);
        static void onRememberedSearch(GObject* source, GAsyncResult* result, gpointer data);
        static void onSecretsOwner(GObject* source, GAsyncResult* result, gpointer data);
        static void onSecretsCredentials(GObject* source, GAsyncResult* result, gpointer data);
        static void onDefaultAlias(GObject* source, GAsyncResult* result, gpointer data);
        static void onLookup(GObject* source, GAsyncResult* result, gpointer data);
        static void onLookupSecret(GObject* source, GAsyncResult* result, gpointer data);
        static void onStored(GObject* source, GAsyncResult* result, gpointer data);
        static void onKiod6Running(GObject* source, GAsyncResult* result, gpointer data);
        static void onRepairNames(GObject* source, GAsyncResult* result, gpointer data);
        static gboolean onProcess(gpointer self);
        static gboolean onRelease(gpointer data);
        static gboolean onRepair(gpointer data);
        static gboolean onStoreTimeout(gpointer data);
        static gboolean onStepTimeout(gpointer data);

        void check(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender);
        void query(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender);
        void add(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender);
        void remove(GDBusMethodInvocation* invocation, GVariant* parameters);
        // Why a new request of `sender` is answered "nothing" at once ("" when it may go on).
        QString refusal(const QString& sender) const;

        void processLater();
        void process();
        void prepare(const Request& request);
        void identified(const Request& request);
        void keychainNext(const Request& request);
        void show(const Request& request);
        // Every query ends here: its result, the checks that waited for it, the window and key it held, the next query.
        void respond(const Request& request);
        void finishCheck(const Request& request, const kio::AuthInfo& info);
        void lookup(const Request& request);
        // True when the store went (false: dropped at the bound, or nothing to store).
        bool store(const QString& key, const kio::AuthInfo& info);
        // The Secret Service's owner left: the stores and searches sent to it end now (libsecret's calls would wait for its
        // answer for ever, cancelled or not).
        void secretsOwnerLeft();
        bool hasPendingQuery(const QString& key, const kio::AuthInfo& info) const;
        void emitResult(const char* signal, const QString& destination, qint64 requestId, const kio::AuthInfo& info);
        void endAll(const QString& why);
        void callerGone(const QString& name);
        void startStepTimer(const Request& request);
        void stopStepTimer(const Request& request);

        Request find(const KioRequest* request) const;
        void    forget(const Request& request);

        void wantName(bool want);
        // The shell went: the name goes, unless kiod6 runs without it (MINOR-1).
        void releaseUnlessKiod6();
        // org.kde.kiod6 appeared or left the bus.
        void kiod6Changed(bool running);
        void repairLater();

        GDBusConnection*       m_bus = nullptr;
        Sink*                  m_sink;
        Options                m_options;
        std::shared_ptr<bool>  m_alive; // async callbacks hold a weak reference: nothing runs on a server that went
        GCancellable*          m_cancel = nullptr; // the name's calls, cancelled when the server goes (never a keychain call)
        guint                  m_objectId = 0;
        guint                  m_ownersSub = 0;
        guint                  m_acquiredSub = 0;
        guint                  m_lostSub = 0;
        bool                   m_wanted = false;
        bool                   m_nameWanted = false;
        bool                   m_owned = false;    // the bus said NameAcquired (and no NameLost since)
        bool                   m_forKiod6 = false; // held with no shell: kiod6 runs without it
        guint                  m_repairSource = 0;
        quint64                m_nameGen = 0;
        guint                  m_processSource = 0;
        guint                  m_releaseSource = 0;
        qint64                 m_nextRequestId = 0; // kpasswdserver.cpp:46-50 counts from 0
        qint64                 m_seqNr = 0;
        int                    m_storesInFlight = 0; // stores holding a place
        quint64                m_nextStore = 0;
        quint64                m_secretsGen = 0;
        QHash<quint64, Store*> m_stores; // every store alive
        quint64                m_nextUnlock = 0;
        QHash<quint64, Unlock> m_unlocks; // checks' unlocking searches in flight (their request ended or not)
        kio::Cache             m_cache;
        QList<Request>         m_requests; // every open request
        QList<Request>         m_pending;  // queries not taken yet, in arrival order (m_authPending)
        QList<Request>         m_wait;     // checks waiting for a query of their key (m_authWait)
        QStringList            m_prompted; // window ids and keys being prompted (m_authPrompted)
        QHash<KioRequest*, guint> m_stepTimers;
    };

} // namespace gf::prompter
