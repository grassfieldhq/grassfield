#include "KioServer.h"

#include "Log.h"
#include "Text.h"

#include <gio/gunixfdlist.h>
#include <libsecret/secret.h>

#include <cstring>
#include <unistd.h>

namespace gf::prompter {

    namespace {
        constexpr int kBusTimeoutMs   = 5000;
        constexpr int kStepTimeoutMs  = 5000; // a keychain step that does not answer: the sheet goes without it
        constexpr int kPerCaller      = 8;    // open requests of one caller connection
        constexpr int kOpenRequests   = 32;   // open requests in all
        constexpr int kStoresInFlight = 8;    // stores holding a place
        constexpr int kStoresAlive    = 32;   // stores alive, holding a place or not
        constexpr int kReleaseDelayMs = 1000; // between the last answers and the name's release (decision 9-37)
        constexpr int kKiod6SettleMs  = 2000; // after kiod6 appears, before the bridge looks whether it took the name
        constexpr char kKiod6Name[]   = "org.kde.kiod6";
        constexpr char kSecretsName[] = "org.freedesktop.secrets";

        // KIO v6.31.0's org.kde.KPasswdServer (src/core/org.kde.KPasswdServer.xml) without its LEGACY "ay" methods, which KF6's
        // client never calls: GDBus checks every call's arguments against it (anything else: UnknownMethod or InvalidArgs).
        constexpr char kIntrospection[] = R"XML(<node>
  <interface name="org.kde.KPasswdServer">
    <signal name="checkAuthInfoAsyncResult">
      <arg type="x" name="requestId"/>
      <arg type="x" name="seqNr"/>
      <arg type="(ysssssssssbbbba{s(siv)})" name="info"/>
    </signal>
    <signal name="queryAuthInfoAsyncResult">
      <arg type="x" name="requestId"/>
      <arg type="x" name="seqNr"/>
      <arg type="(ysssssssssbbbba{s(siv)})" name="info"/>
    </signal>
    <method name="checkAuthInfoAsync">
      <arg direction="out" type="x"/>
      <arg direction="in" type="(ysssssssssbbbba{s(siv)})" name="info"/>
      <arg direction="in" type="x" name="windowId"/>
      <arg direction="in" type="x" name="usertime"/>
    </method>
    <method name="queryAuthInfoAsync">
      <arg direction="out" type="x"/>
      <arg direction="in" type="(ysssssssssbbbba{s(siv)})" name="info"/>
      <arg direction="in" type="s" name="errorMsg"/>
      <arg direction="in" type="x" name="windowId"/>
      <arg direction="in" type="x" name="seqNr"/>
      <arg direction="in" type="x" name="usertime"/>
    </method>
    <method name="addAuthInfo">
      <arg direction="in" type="(ysssssssssbbbba{s(siv)})" name="info"/>
      <arg direction="in" type="x" name="windowId"/>
    </method>
    <method name="removeAuthInfo">
      <arg direction="in" type="s" name="host"/>
      <arg direction="in" type="s" name="protocol"/>
      <arg direction="in" type="s" name="user"/>
    </method>
  </interface>
</node>)XML";

        const SecretSchema* schema() {
            static SecretSchema* s = secret_schema_new(kio::kSchemaName, SECRET_SCHEMA_NONE, "key", SECRET_SCHEMA_ATTRIBUTE_STRING, "realm",
                                                       SECRET_SCHEMA_ATTRIBUTE_STRING, "user", SECRET_SCHEMA_ATTRIBUTE_STRING, "protocol",
                                                       SECRET_SCHEMA_ATTRIBUTE_STRING, "server", SECRET_SCHEMA_ATTRIBUTE_STRING, "port",
                                                       SECRET_SCHEMA_ATTRIBUTE_STRING, nullptr);
            return s;
        }

        GHashTable* attributeTable(const QList<QPair<QString, QString>>& attributes) {
            GHashTable* table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
            for (const auto& [key, value] : attributes)
                g_hash_table_insert(table, g_strdup(key.toUtf8().constData()), g_strdup(value.toUtf8().constData()));
            return table;
        }

        bool cancelled(const GError* error) {
            return error && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        }

        // The caller's facts from a GetConnectionCredentials reply (its pidfd, never a bare PID: Identity.h).
        ExeFacts factsOf(GVariant* reply, GUnixFDList* fds, uid_t uid) {
            ExeFacts facts;
            if (!reply)
                return facts;
            GVariant* dict   = g_variant_get_child_value(reply, 0);
            guint32   who    = 0;
            gint32    handle = -1;
            const bool hasUid = g_variant_lookup(dict, "UnixUserID", "u", &who);
            if (g_variant_lookup(dict, "ProcessFD", "h", &handle) && fds && handle >= 0 && handle < g_unix_fd_list_get_length(fds)) {
                const int pidfd = g_unix_fd_list_get(fds, handle, nullptr);
                if (pidfd >= 0) {
                    facts = exeFactsOfPidfd(pidfd);
                    ::close(pidfd);
                }
            }
            facts.sameUser = hasUid && who == uid;
            g_variant_unref(dict);
            return facts;
        }

        QString scheme(const KioRequest& r) {
            return flatten(r.info.parsed.scheme(), 16);
        }
    } // namespace

    struct KioServer::Call {
        std::weak_ptr<bool>       alive;
        KioServer*                server = nullptr;
        std::weak_ptr<KioRequest> request;
        QString                   text; // a step's own datum (an owner's unique name, a user)
        quint64                   generation = 0;
        KioServer*                live() const {
            return alive.expired() ? nullptr : server;
        }
    };

    KioServer::KioServer(GDBusConnection* bus, Sink* sink, Options options)
        : m_bus(G_DBUS_CONNECTION(g_object_ref(bus))), m_sink(sink), m_options(std::move(options)), m_alive(std::make_shared<bool>(true)),
          m_cancel(g_cancellable_new()) {}

    KioServer::~KioServer() {
        // Every open request has its answer before the server goes ("nothing": nothing more can be asked).
        endAll(QStringLiteral("the bridge stops"));
        if (m_nameWanted) {
            m_nameWanted = false;
            GVariant* reply = g_dbus_connection_call_sync(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                                                          g_variant_new("(s)", kio::kBusName), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr,
                                                          nullptr);
            if (reply)
                g_variant_unref(reply);
        }
        m_alive.reset();
        g_cancellable_cancel(m_cancel);
        if (m_processSource)
            g_source_remove(m_processSource);
        if (m_releaseSource)
            g_source_remove(m_releaseSource);
        if (m_repairSource)
            g_source_remove(m_repairSource);
        // Keychain calls are left to the process's end, never cancelled: a cancelled call dismisses gnome-keyring's prompt
        // (decision 9-50).
        for (Store* store : std::as_const(m_stores)) {
            if (store->timer)
                g_source_remove(store->timer);
            g_object_unref(store->cancellable);
            delete store;
        }
        m_stores.clear();
        for (const Unlock& unlock : std::as_const(m_unlocks))
            g_object_unref(unlock.cancellable);
        m_unlocks.clear();
        for (const guint id : std::as_const(m_stepTimers))
            g_source_remove(id);
        m_stepTimers.clear();
        for (guint* sub : {&m_ownersSub, &m_acquiredSub, &m_lostSub}) {
            if (*sub)
                g_dbus_connection_signal_unsubscribe(m_bus, *sub);
        }
        if (m_objectId)
            g_dbus_connection_unregister_object(m_bus, m_objectId);
        g_dbus_connection_flush_sync(m_bus, nullptr, nullptr);
        g_object_unref(m_cancel);
        g_object_unref(m_bus);
    }

    bool KioServer::start(QString* error) {
        GError*        gerror = nullptr;
        GDBusNodeInfo* node   = g_dbus_node_info_new_for_xml(kIntrospection, &gerror);
        if (!node) {
            *error = QStringLiteral("the KPasswdServer introspection: %1").arg(QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        static const GDBusInterfaceVTable vtable = {onMethodCall, nullptr, nullptr, {nullptr}};
        m_objectId = g_dbus_connection_register_object(m_bus, kio::kObjectPath, node->interfaces[0], &vtable, this, nullptr, &gerror);
        g_dbus_node_info_unref(node);
        if (!m_objectId) {
            *error = QStringLiteral("cannot export %1: %2").arg(QLatin1String(kio::kObjectPath), QString::fromUtf8(gerror ? gerror->message : ""));
            g_clear_error(&gerror);
            return false;
        }
        // Callers that leave the bus: their requests go (withdrawn from the shell, nothing answered).
        m_ownersSub   = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                                                           nullptr, G_DBUS_SIGNAL_FLAGS_NONE, onOwnerChanged, this, nullptr);
        m_acquiredSub = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameAcquired", "/org/freedesktop/DBus",
                                                           kio::kBusName, G_DBUS_SIGNAL_FLAGS_NONE, onNameSignal, this, nullptr);
        m_lostSub     = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameLost", "/org/freedesktop/DBus",
                                                           kio::kBusName, G_DBUS_SIGNAL_FLAGS_NONE, onNameSignal, this, nullptr);
        (void)schema();
        log(QStringLiteral("KIO's password server ready at %1 (%2 is requested while a shell that draws kind kio is connected)")
                .arg(QLatin1String(kio::kObjectPath), QLatin1String(kio::kBusName)));
        // A kiod6 that runs without the name (it started while an earlier bridge held it) never takes it (releaseUnlessKiod6).
        repairLater();
        return true;
    }

    // --- the name -------------------------------------------------------------------------------------------------------

    void KioServer::setWanted(bool wanted) {
        if (wanted == m_wanted)
            return;
        m_wanted = wanted;
        if (m_releaseSource) {
            g_source_remove(m_releaseSource);
            m_releaseSource = 0;
        }
        if (wanted) {
            m_forKiod6 = false;
            wantName(true);
            return;
        }
        // Every request still open gets its answer first (KIO's client would wait for it for ever), then the name goes, a
        // moment later, so that each client has read its answer before it hears that the name left (decision 9-37).
        endAll(QStringLiteral("no shell to ask"));
        if (m_nameWanted)
            m_releaseSource = g_timeout_add(kReleaseDelayMs, onRelease, this);
    }

    gboolean KioServer::onRelease(gpointer data) {
        auto* self            = static_cast<KioServer*>(data);
        self->m_releaseSource = 0;
        if (!self->m_wanted)
            self->releaseUnlessKiod6();
        return G_SOURCE_REMOVE;
    }

    // kiod6 registers the names of its modules once, when it starts, without queueing (kiod_main.cpp:107-115), and a second
    // kiod6 leaves at once, as KDBusService Unique (kdbusservice.cpp:196-230): a kiod6 that started while the bridge held
    // the name (a KF6 app's SSL check or cookie jar starts it for its other names) never takes it. Released then, the name
    // would make D-Bus activation start a kiod6 that exits, and KIO's calls time out after 25 s with no dialog; kept, they
    // are answered "nothing" at once until kiod6 leaves the bus (the security review of step 9e, MINOR-1; decision 9-36).
    void KioServer::releaseUnlessKiod6() {
        if (!m_nameWanted)
            return;
        if (!m_owned) {
            wantName(false); // queued behind another owner: nothing to keep
            return;
        }
        auto* call = new Call{m_alive, this, {}, {}, m_nameGen};
        g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", kKiod6Name),
                               G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, m_cancel, onKiod6Running, call);
    }

    void KioServer::onKiod6Running(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call    = static_cast<Call*>(data);
        GError*   error   = nullptr;
        GVariant* reply   = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        gboolean  running = FALSE;
        if (reply) {
            g_variant_get(reply, "(b)", &running);
            g_variant_unref(reply);
        }
        KioServer* self = call->live();
        if (self && !cancelled(error) && call->generation == self->m_nameGen && self->m_nameWanted && !self->m_wanted) {
            if (running && self->m_owned) {
                self->m_forKiod6 = true;
                log(QStringLiteral("%1 kept: kiod6 runs without it (it takes its names only when it starts), so KIO's requests are answered "
                                   "with nothing until kiod6 leaves the bus or a shell that draws kind kio returns")
                        .arg(QLatin1String(kio::kBusName)));
            } else {
                self->wantName(false);
            }
        }
        g_clear_error(&error);
        delete call;
    }

    void KioServer::kiod6Changed(bool running) {
        if (running) {
            if (!m_nameWanted)
                repairLater();
            return;
        }
        if (m_forKiod6 && !m_wanted) {
            log(QStringLiteral("kiod6 left the bus"));
            wantName(false);
        }
    }

    void KioServer::repairLater() {
        if (m_repairSource || m_nameWanted)
            return;
        m_repairSource = g_timeout_add(kKiod6SettleMs, onRepair, this);
    }

    gboolean KioServer::onRepair(gpointer data) {
        auto* self           = static_cast<KioServer*>(data);
        self->m_repairSource = 0;
        if (!self->m_nameWanted) {
            auto* call = new Call{self->m_alive, self, {}, {}, self->m_nameGen};
            g_dbus_connection_call(self->m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", nullptr,
                                   G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, self->m_cancel, onRepairNames, call);
        }
        return G_SOURCE_REMOVE;
    }

    void KioServer::onRepairNames(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call     = static_cast<Call*>(data);
        GError*   error    = nullptr;
        GVariant* reply    = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        bool      kiod6    = false;
        bool      nameHeld = false;
        if (reply) {
            GVariantIter* names = nullptr;
            const gchar*  name  = nullptr;
            g_variant_get(reply, "(as)", &names);
            while (g_variant_iter_next(names, "&s", &name)) {
                kiod6    = kiod6 || g_strcmp0(name, kKiod6Name) == 0;
                nameHeld = nameHeld || g_strcmp0(name, kio::kBusName) == 0;
            }
            g_variant_iter_free(names);
            g_variant_unref(reply);
        }
        KioServer* self = call->live();
        if (self && !cancelled(error) && call->generation == self->m_nameGen && !self->m_nameWanted && kiod6 && !nameHeld) {
            // kiod6 had kKiod6SettleMs to take it at its start: it never will now.
            log(QStringLiteral("%1 taken: kiod6 runs without it, so KIO's requests are answered with nothing at once instead of waiting "
                               "for a kiod6 that cannot take it")
                    .arg(QLatin1String(kio::kBusName)));
            self->wantName(true);
            self->m_forKiod6 = true;
        }
        g_clear_error(&error);
        delete call;
    }

    void KioServer::wantName(bool want) {
        if (want == m_nameWanted)
            return;
        m_nameWanted = want;
        if (!want) {
            m_owned    = false;
            m_forKiod6 = false;
        }
        ++m_nameGen;
        auto* call = new Call{m_alive, this, {}, {}, m_nameGen};
        if (want) {
            // Flags 0: queued behind an owner (kiod6 started while no shell was there), never replaceable by anyone.
            g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                   g_variant_new("(su)", kio::kBusName, 0u), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, m_cancel, onNameReply,
                                   call);
        } else {
            g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                                   g_variant_new("(s)", kio::kBusName), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, m_cancel, onNameReply, call);
            log(QStringLiteral("%1 released (no shell that draws kind kio)").arg(QLatin1String(kio::kBusName)));
        }
    }

    void KioServer::onNameReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<Call*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        guint32   code  = 0;
        if (reply) {
            g_variant_get(reply, "(u)", &code);
            g_variant_unref(reply);
        }
        KioServer* self = call->live();
        if (self && !cancelled(error) && call->generation == self->m_nameGen && self->m_nameWanted) {
            if (!reply)
                log(QStringLiteral("%1 could not be requested: %2").arg(QLatin1String(kio::kBusName), flatten(QString::fromUtf8(error ? error->message : ""), 256)));
            else if (code == 1 || code == 4) // DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER, ALREADY_OWNER
                log(QStringLiteral("%1 owned: KIO's passwords are asked in the shell").arg(QLatin1String(kio::kBusName)));
            else if (code == 2) // IN_QUEUE
                log(QStringLiteral("%1 is held by another program (kiod6, started while no shell was connected?): queued behind it, KIO's passwords are "
                                   "asked in its own dialog until it leaves the bus")
                        .arg(QLatin1String(kio::kBusName)));
        }
        g_clear_error(&error);
        delete call;
    }

    void KioServer::onNameSignal(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/, const gchar* signal,
                                 GVariant* /*parameters*/, gpointer data) {
        auto* self = static_cast<KioServer*>(data);
        if (g_strcmp0(sender, "org.freedesktop.DBus") != 0)
            return;
        if (g_strcmp0(signal, "NameAcquired") == 0) {
            if (!self->m_nameWanted) {
                // A late answer to an earlier request: the bridge holds a name it no longer wants.
                g_dbus_connection_call(self->m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                                       g_variant_new("(s)", kio::kBusName), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, nullptr, nullptr);
                return;
            }
            self->m_owned = true;
            log(QStringLiteral("%1 acquired").arg(QLatin1String(kio::kBusName)));
        } else {
            self->m_owned = false;
            if (self->m_nameWanted)
                log(QStringLiteral("%1 lost").arg(QLatin1String(kio::kBusName)));
        }
    }

    void KioServer::onOwnerChanged(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/, const gchar* /*signal*/,
                                   GVariant* parameters, gpointer data) {
        if (g_strcmp0(sender, "org.freedesktop.DBus") != 0 || !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sss)")))
            return;
        const gchar* name     = nullptr;
        const gchar* oldOwner = nullptr;
        const gchar* newOwner = nullptr;
        g_variant_get(parameters, "(&s&s&s)", &name, &oldOwner, &newOwner);
        auto* self = static_cast<KioServer*>(data);
        if (name[0] == ':' && !newOwner[0])
            self->callerGone(QString::fromUtf8(name));
        else if (g_strcmp0(name, kKiod6Name) == 0)
            self->kiod6Changed(newOwner[0] != '\0');
        else if (g_strcmp0(name, kSecretsName) == 0 && oldOwner[0])
            self->secretsOwnerLeft();
    }

    // --- calls ------------------------------------------------------------------------------------------------------------

    void KioServer::onMethodCall(GDBusConnection* /*bus*/, const gchar* sender, const gchar* /*path*/, const gchar* /*iface*/, const gchar* method,
                                 GVariant* parameters, GDBusMethodInvocation* invocation, gpointer data) {
        auto*         self = static_cast<KioServer*>(data);
        const QString who  = QString::fromUtf8(sender ? sender : "");
        if (g_strcmp0(method, "checkAuthInfoAsync") == 0)
            self->check(invocation, parameters, who);
        else if (g_strcmp0(method, "queryAuthInfoAsync") == 0)
            self->query(invocation, parameters, who);
        else if (g_strcmp0(method, "addAuthInfo") == 0)
            self->add(invocation, parameters, who);
        else if (g_strcmp0(method, "removeAuthInfo") == 0)
            self->remove(invocation, parameters);
        else
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
    }

    QString KioServer::refusal(const QString& sender) const {
        if (!m_wanted)
            return QStringLiteral("no shell draws kind kio");
        if (sender.isEmpty())
            return QStringLiteral("no sender to answer");
        if (m_requests.size() >= kOpenRequests)
            return QStringLiteral("%1 requests are open").arg(kOpenRequests);
        int mine = 0;
        for (const Request& r : m_requests)
            mine += r->sender == sender ? 1 : 0;
        if (mine >= kPerCaller)
            return QStringLiteral("%1 requests of this caller are open").arg(kPerCaller);
        return {};
    }

    void KioServer::check(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender) {
        GVariant* raw      = nullptr;
        gint64    windowId = 0;
        gint64    usertime = 0;
        g_variant_get(parameters, "(@(ysssssssssbbbba{s(siv)})xx)", &raw, &windowId, &usertime);
        auto       r = std::make_shared<KioRequest>();
        QString    why;
        const bool parsed = kio::parseAuthInfo(raw, &r->info, &why);
        g_variant_unref(raw);
        if (!parsed) {
            log(QStringLiteral("checkAuthInfoAsync refused: %1").arg(why));
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", why.toUtf8().constData());
            return;
        }
        r->kind      = KioRequest::Kind::Check;
        r->requestId = m_nextRequestId++;
        r->sender    = sender;
        r->windowId  = windowId;
        r->key       = kio::cacheKey(r->info.parsed);
        // The requestId first, its result after it (kpasswdserver.cpp:285-291).
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(x)", static_cast<gint64>(r->requestId)));
        QString refused = refusal(sender);
        if (refused.isEmpty() && r->key.isEmpty())
            refused = QStringLiteral("not a valid URL");
        if (!refused.isEmpty()) {
            log(QStringLiteral("check %1 (%2) answered with nothing: %3").arg(r->requestId).arg(scheme(*r), refused));
            r->info.modified = false;
            emitResult(kio::kCheckResult, sender, r->requestId, r->info);
            return;
        }
        m_requests.append(r);
        if (hasPendingQuery(r->key, r->info)) {
            log(QStringLiteral("check %1 (%2) waits for a query of the same server").arg(r->requestId).arg(scheme(*r)));
            m_wait.append(r);
            return;
        }
        kio::CacheEntry* entry = m_cache.find(r->key, r->info);
        if (entry && !entry->canceled) {
            m_cache.touch(entry, r->windowId, false, r->sender);
            kio::AuthInfo info = entry->info;
            info.modified      = true;
            log(QStringLiteral("check %1 (%2) answered from the session's cache").arg(r->requestId).arg(scheme(*r)));
            finishCheck(r, info);
            return;
        }
        // A remembered password (kpasswdserver.cpp:306-317: only when nothing is cached, and the caller lacks the name or the
        // password); a read-only empty name can match no remembered one (:182).
        if (!entry && (r->info.username.isEmpty() || r->info.password.empty()) && !(r->info.readOnly && r->info.username.isEmpty())) {
            lookup(r);
            return;
        }
        kio::AuthInfo info = r->info;
        info.modified      = false;
        finishCheck(r, info);
    }

    void KioServer::query(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender) {
        GVariant*    raw      = nullptr;
        const gchar* errorMsg = nullptr;
        gint64       windowId = 0;
        gint64       seqNr    = 0;
        gint64       usertime = 0;
        g_variant_get(parameters, "(@(ysssssssssbbbba{s(siv)})&sxxx)", &raw, &errorMsg, &windowId, &seqNr, &usertime);
        auto       r = std::make_shared<KioRequest>();
        QString    why;
        const bool parsed = kio::parseAuthInfo(raw, &r->info, &why);
        g_variant_unref(raw);
        if (parsed && std::strlen(errorMsg) > kio::kTextBytes)
            why = QStringLiteral("errorMsg over %1 bytes").arg(kio::kTextBytes);
        if (!parsed || !why.isEmpty()) {
            log(QStringLiteral("queryAuthInfoAsync refused: %1").arg(why));
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", why.toUtf8().constData());
            return;
        }
        r->kind      = KioRequest::Kind::Query;
        r->requestId = m_nextRequestId++;
        r->sender    = sender;
        r->windowId  = windowId;
        r->seqNr     = seqNr;
        r->key       = kio::cacheKey(r->info.parsed);
        if (std::strcmp(errorMsg, kio::kNoAuthPrompt) == 0) {
            r->prompt = false;
        } else {
            r->errorMsg = QString::fromUtf8(errorMsg);
            r->prompt   = true;
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(x)", static_cast<gint64>(r->requestId)));
        QString refused = refusal(sender);
        if (refused.isEmpty() && r->key.isEmpty())
            refused = QStringLiteral("not a valid URL");
        if (!refused.isEmpty()) {
            log(QStringLiteral("query %1 (%2) answered with nothing: %3").arg(r->requestId).arg(scheme(*r), refused));
            r->info.modified = false;
            emitResult(kio::kQueryResult, sender, r->requestId, r->info);
            return;
        }
        m_requests.append(r);
        m_pending.append(r);
        log(QStringLiteral("query %1 (%2)%3").arg(r->requestId).arg(scheme(*r), r->prompt ? QString() : QStringLiteral(", no prompt asked")));
        if (m_pending.size() == 1)
            processLater(); // kpasswdserver.cpp:407-409: only when the queue was empty, the next after each answer
    }

    void KioServer::add(GDBusMethodInvocation* invocation, GVariant* parameters, const QString& sender) {
        GVariant*     raw      = nullptr;
        gint64        windowId = 0;
        g_variant_get(parameters, "(@(ysssssssssbbbba{s(siv)})x)", &raw, &windowId);
        kio::AuthInfo info;
        QString       why;
        const bool    parsed = kio::parseAuthInfo(raw, &info, &why);
        g_variant_unref(raw);
        if (!parsed) {
            log(QStringLiteral("addAuthInfo refused: %1").arg(why));
            g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.InvalidArgs", why.toUtf8().constData());
            return;
        }
        // Answered at once (SC9c): the store, when there is one, goes on in the background.
        g_dbus_method_invocation_return_value(invocation, nullptr);
        const QString key = kio::cacheKey(info.parsed);
        if (!m_wanted || key.isEmpty()) {
            log(QStringLiteral("addAuthInfo ignored: %1").arg(!m_wanted ? QStringLiteral("no shell draws kind kio") : QStringLiteral("not a valid URL")));
            return;
        }
        ++m_seqNr;
        // Remembered only when the user chose it (keepPassword): kpasswdserver stores in KWallet whatever the flag says, and
        // warns (kpasswdserver.cpp:417-425; decision 9-41).
        // Once sent to the keychain, in memory only while its window lives, as kpasswdserver's after a wallet store
        // (kpasswdserver.cpp:427-434; the security review of step 9e, NIT-2).
        kio::AuthInfo cached = info;
        const bool    stored = info.keepPassword && store(key, info);
        if (stored)
            cached.keepPassword = false;
        m_cache.add(key, cached, windowId, m_seqNr, false, sender);
        log(QStringLiteral("addAuthInfo (%1): kept in the session's cache%2")
                .arg(flatten(info.parsed.scheme(), 16), stored ? QStringLiteral(" while its window lives, and sent to the keychain") : QString()));
    }

    void KioServer::remove(GDBusMethodInvocation* invocation, GVariant* parameters) {
        const gchar* host     = nullptr;
        const gchar* protocol = nullptr;
        const gchar* user     = nullptr;
        g_variant_get(parameters, "(&s&s&s)", &host, &protocol, &user);
        g_dbus_method_invocation_return_value(invocation, nullptr);
        if (!m_wanted)
            return;
        const int n = m_cache.removeMatching(QString::fromUtf8(host), QString::fromUtf8(protocol), QString::fromUtf8(user));
        log(QStringLiteral("removeAuthInfo (%1): %2 entr%3 of the session's cache removed").arg(flatten(QString::fromUtf8(protocol), 16)).arg(n).arg(n == 1 ? "y" : "ies"));
    }

    bool KioServer::hasPendingQuery(const QString& key, const kio::AuthInfo& info) const {
        // kpasswdserver.cpp:197-216, which reads the request's path with the index of `info`'s first slash.
        const QString path  = info.parsed.path();
        const QString path2 = path.left(path.indexOf(u'/') + 1);
        for (const Request& r : m_pending) {
            if (r->key != key)
                continue;
            if (info.verifyPath) {
                const QString path1 = r->info.parsed.path().left(path.indexOf(u'/') + 1);
                if (!path2.startsWith(path1))
                    continue;
            }
            return true;
        }
        return false;
    }

    // --- queries ----------------------------------------------------------------------------------------------------------

    void KioServer::processLater() {
        if (!m_processSource)
            m_processSource = g_idle_add(onProcess, this);
    }

    gboolean KioServer::onProcess(gpointer data) {
        auto* self            = static_cast<KioServer*>(data);
        self->m_processSource = 0;
        self->process();
        return G_SOURCE_REMOVE;
    }

    void KioServer::process() {
        if (m_pending.isEmpty())
            return;
        const Request r = m_pending.constFirst();
        if (!m_wanted) {
            r->info.modified = false;
            respond(r);
            return;
        }
        // One prompt at a time per window and per server; the first query waiting holds the others (kpasswdserver.cpp:493-499).
        const QString window = QString::number(r->windowId);
        if (m_prompted.contains(window) || m_prompted.contains(r->key))
            return;
        m_pending.removeFirst();
        m_prompted << window << r->key;
        r->prompted    = true;
        r->promptedKey = r->key;
        kio::AuthInfo& info = r->info;
        if (info.username.isEmpty() && !info.parsed.userName().isEmpty())
            info.username = info.parsed.userName();
        const bool       bypass = kio::extraBool(info, kio::kExtraBypassCache);
        kio::CacheEntry* entry  = m_cache.find(r->key, info);
        if (!bypass && entry && r->seqNr < entry->seqNr) {
            // The user answered for this server since the worker last asked: that answer, without a sheet (DESIGN, "Sequence
            // numbers").
            if (entry->canceled) {
                info.modified = false;
            } else {
                m_cache.touch(entry, r->windowId, false, r->sender);
                r->info          = entry->info;
                r->info.modified = true;
            }
            log(QStringLiteral("query %1 answered from the session's cache (an answer newer than the worker's)").arg(r->requestId));
            respond(r);
            return;
        }
        ++m_seqNr;
        if (!r->prompt) {
            info.modified = false;
            respond(r);
            return;
        }
        // A failed login (the worker's message, never shown: decision 9-40) makes the sheet say so.
        r->retry = !r->errorMsg.isEmpty();
        prepare(r);
    }

    void KioServer::prepare(const Request& r) {
        r->stage  = KioRequest::Stage::Preparing;
        r->server = kio::serverLabel(r->info.parsed);
        if (r->server.isEmpty()) {
            abandon(r.get(), QStringLiteral("no host name to show"));
            return;
        }
        if (!r->cancellable)
            r->cancellable = g_cancellable_new();
        // Who asks: the caller's credentials and pidfd (Identity.h), never its text.
        auto* call = new Call{m_alive, this, r, {}, 0};
        g_dbus_connection_call_with_unix_fd_list(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionCredentials",
                                                 g_variant_new("(s)", r->sender.toUtf8().constData()), G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE,
                                                 kBusTimeoutMs, nullptr, r->cancellable, onCallerCredentials, call);
    }

    void KioServer::onCallerCredentials(GObject* source, GAsyncResult* result, gpointer data) {
        auto*        call  = static_cast<Call*>(data);
        GUnixFDList* fds   = nullptr;
        GError*      error = nullptr;
        GVariant*    reply = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), &fds, result, &error);
        KioServer*   self  = call->live();
        const Request r    = call->request.lock();
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            r->requester = requesterFor(factsOf(reply, fds, self->m_options.uid));
            self->identified(r);
        }
        if (reply)
            g_variant_unref(reply);
        g_clear_object(&fds);
        g_clear_error(&error);
        delete call;
    }

    void KioServer::identified(const Request& r) {
        const kio::AuthInfo& info = r->info;
        const bool           hide = kio::extraBool(info, kio::kExtraHideUsername);
        r->nameMode               = hide ? QStringLiteral("none") : info.readOnly ? QStringLiteral("fixed") : QStringLiteral("edit");
        r->name                   = hide ? QString() : flatten(info.username, kio::kNameCap);
        r->realm                  = flatten(info.realm, kio::kRealmCap);
        // kpasswdserver offers "keep password" when the caller asks for it and a wallet is there (:779-781): here the Secret
        // Service always is.
        r->rememberOffered = info.keepPassword && !kio::extraBool(info, kio::kExtraBypassCache);
        if (!r->rememberOffered) {
            show(r);
            return;
        }
        // Is a password remembered for this server already (a search that never unlocks), and is the keyring protected?
        GHashTable* attributes = attributeTable(kio::searchAttributes(r->key, r->info));
        auto*       call       = new Call{m_alive, this, r, {}, 0};
        startStepTimer(r);
        secret_password_searchv(schema(), attributes, SECRET_SEARCH_NONE, r->cancellable, onRememberedSearch, call);
        g_hash_table_unref(attributes);
    }

    void KioServer::onRememberedSearch(GObject* /*source*/, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GError*       error = nullptr;
        GList*        items = secret_password_search_finish(result, &error);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            self->stopStepTimer(r);
            if (items) {
                r->rememberChosen      = true;
                GHashTable*  attrs     = secret_retrievable_get_attributes(SECRET_RETRIEVABLE(items->data));
                const gchar* user      = attrs ? static_cast<const gchar*>(g_hash_table_lookup(attrs, "user")) : nullptr;
                r->rememberedUser      = QString::fromUtf8(user ? user : "");
                if (attrs)
                    g_hash_table_unref(attrs);
            }
            if (r->nameMode == QLatin1String("edit") && r->info.username.isEmpty() && !r->rememberedUser.isEmpty())
                r->name = flatten(r->rememberedUser, kio::kNameCap);
            self->keychainNext(r);
        }
        g_list_free_full(items, g_object_unref);
        g_clear_error(&error);
        delete call;
    }

    // The keyring's protection (decision 9-45): who holds org.freedesktop.secrets; only gnome-keyring's own executable is
    // read further: its default collection, then that keyring's file.
    void KioServer::keychainNext(const Request& r) {
        auto* call = new Call{m_alive, this, r, {}, 0};
        startStepTimer(r);
        g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", "org.freedesktop.secrets"), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, r->cancellable,
                               onSecretsOwner, call);
    }

    void KioServer::onSecretsOwner(GObject* source, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GVariant*     reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        QString       owner;
        if (reply) {
            const gchar* name = nullptr;
            g_variant_get(reply, "(&s)", &name);
            owner = QString::fromUtf8(name);
            g_variant_unref(reply);
        }
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            if (owner.isEmpty()) {
                self->stopStepTimer(r);
                self->show(r);
            } else {
                auto* next = new Call{call->alive, self, r, owner, 0};
                g_dbus_connection_call_with_unix_fd_list(self->m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                                         "GetConnectionCredentials", g_variant_new("(s)", owner.toUtf8().constData()), G_VARIANT_TYPE("(a{sv})"),
                                                         G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, r->cancellable, onSecretsCredentials, next);
            }
        }
        delete call;
    }

    void KioServer::onSecretsCredentials(GObject* source, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GUnixFDList*  fds   = nullptr;
        GVariant*     reply = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), &fds, result, nullptr);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            const RequesterView holder = requesterFor(factsOf(reply, fds, self->m_options.uid));
            if (holder.role != QLatin1String("keyring")) {
                // Another Secret Service (or one that cannot be identified): its protection is its own; the sheet says nothing.
                self->stopStepTimer(r);
                self->show(r);
            } else {
                auto* next = new Call{call->alive, self, r, call->text, 0};
                g_dbus_connection_call(self->m_bus, call->text.toUtf8().constData(), "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "ReadAlias",
                                       g_variant_new("(s)", "default"), G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, kBusTimeoutMs, r->cancellable,
                                       onDefaultAlias, next);
            }
        }
        if (reply)
            g_variant_unref(reply);
        g_clear_object(&fds);
        delete call;
    }

    void KioServer::onDefaultAlias(GObject* source, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GVariant*     reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            self->stopStepTimer(r);
            if (reply) {
                const gchar* path = nullptr;
                g_variant_get(reply, "(&o)", &path);
                const QString name = kio::collectionFileName(QString::fromUtf8(path));
                if (!name.isEmpty() && !self->m_options.keyringDirectory.isEmpty())
                    r->keyring = kio::fileProtection(self->m_options.keyringDirectory + u'/' + name + QStringLiteral(".keyring"), self->m_options.uid);
            }
            self->show(r);
        }
        if (reply)
            g_variant_unref(reply);
        delete call;
    }

    void KioServer::startStepTimer(const Request& r) {
        stopStepTimer(r);
        auto* call = new Call{m_alive, this, r, {}, 0};
        m_stepTimers.insert(r.get(), g_timeout_add_full(G_PRIORITY_DEFAULT, kStepTimeoutMs, onStepTimeout, call, [](gpointer p) { delete static_cast<Call*>(p); }));
    }

    void KioServer::stopStepTimer(const Request& r) {
        if (const guint id = m_stepTimers.take(r.get()))
            g_source_remove(id);
    }

    gboolean KioServer::onStepTimeout(gpointer data) {
        auto*         call = static_cast<Call*>(data);
        KioServer*    self = call->live();
        const Request r    = call->request.lock();
        if (self && r) {
            self->m_stepTimers.remove(r.get());
            if (r->stage == KioRequest::Stage::Preparing && r->cancellable) {
                // The step in flight ends (cancelled) and its callback goes on without its answer.
                log(QStringLiteral("query %1: the keychain did not answer within %2 s; the sheet goes without what it would say").arg(r->requestId).arg(kStepTimeoutMs / 1000));
                GCancellable* old = r->cancellable;
                r->cancellable    = g_cancellable_new();
                g_cancellable_cancel(old);
                g_object_unref(old);
            }
        }
        return G_SOURCE_REMOVE;
    }

    void KioServer::show(const Request& r) {
        if (r->stage != KioRequest::Stage::Preparing)
            return;
        r->stage         = KioRequest::Stage::Shown;
        const QString id = m_sink->submitKio(r.get());
        if (r->stage == KioRequest::Stage::Ended)
            return; // ended while it was sent (the shell went)
        if (id.isEmpty()) {
            abandon(r.get(), QStringLiteral("the sheet cannot ask now (no shell, or no place and the applications' queue full)"));
            return;
        }
        r->id = id;
        log(QStringLiteral("query %1 is request %2: kio (%3) for %4%5")
                .arg(r->requestId)
                .arg(id, scheme(*r), r->requester.role, r->requester.path.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(r->requester.path)));
    }

    void KioServer::answer(KioRequest* raw, const QString& name, kio::Secret password, bool remember) {
        const Request r = find(raw);
        if (!r || r->stage != KioRequest::Stage::Shown)
            return; // `password` is wiped as it goes
        kio::AuthInfo& info = r->info;
        if (r->nameMode == QLatin1String("edit"))
            info.username = name;
        info.password     = std::move(password);
        info.keepPassword = r->rememberOffered && remember;
        // The sheet offers no anonymous login: a name and a password are not one (kpasswdserver.cpp:920-922).
        kio::setExtraBool(&info, kio::kExtraAnonymous, false);
        if (!kio::extraBool(info, kio::kExtraBypassCache)) {
            if (!info.parsed.userName().isEmpty() && info.username != info.parsed.userName()) {
                // The user typed another name than the URL's: its entry moves to the key of the new name (:941-948).
                const QString oldKey = r->key;
                m_cache.remove(oldKey, info.realm);
                info.parsed.setUserName(info.username);
                info.url = info.parsed.toString();
                r->key   = kio::cacheKey(info.parsed);
                for (const QList<Request>* list : {&m_pending, &m_wait}) {
                    for (const Request& other : *list) {
                        if (other->key == oldKey)
                            other->key = r->key;
                    }
                }
            }
            // Once sent to the keychain, in memory only while its window lives (kpasswdserver.cpp:947-950; NIT-2). The result
            // keeps the user's choice: the worker's own addAuthInfo stores only on it (decision 9-41).
            kio::AuthInfo cached = info;
            if (!kio::extraBool(info, kio::kExtraSkipCaching) && info.keepPassword && store(r->key, info))
                cached.keepPassword = false;
            m_cache.add(r->key, cached, r->windowId, m_seqNr, false, r->sender);
        }
        info.modified = true;
        log(QStringLiteral("request %1 answered: a name and a password%2").arg(r->id, info.keepPassword ? QStringLiteral(", to be remembered") : QString()));
        respond(r);
    }

    void KioServer::userCancel(KioRequest* raw) {
        const Request r = find(raw);
        if (!r || r->stage != KioRequest::Stage::Shown)
            return;
        // Kept as a cancelled entry, so that the worker's other connections do not ask again at once (:962-965).
        if (!kio::extraBool(r->info, kio::kExtraBypassCache) && r->prompt)
            m_cache.add(r->key, r->info, 0, m_seqNr, true);
        r->info.modified = false;
        log(QStringLiteral("request %1 answered: cancel").arg(r->id));
        respond(r);
    }

    void KioServer::abandon(KioRequest* raw, const QString& why) {
        const Request r = find(raw);
        if (!r || r->stage == KioRequest::Stage::Ended)
            return;
        log(QStringLiteral("%1 %2 answered with nothing: %3").arg(r->kind == KioRequest::Kind::Query ? QStringLiteral("query") : QStringLiteral("check")).arg(r->requestId).arg(why));
        if (r->kind == KioRequest::Kind::Check) {
            kio::AuthInfo info = r->info;
            info.modified      = false;
            finishCheck(r, info);
            return;
        }
        r->info.modified = false;
        respond(r);
    }

    void KioServer::respond(const Request& r) {
        if (r->stage == KioRequest::Stage::Ended)
            return;
        r->stage = KioRequest::Stage::Ended;
        forget(r);
        if (!r->callerGone)
            emitResult(kio::kQueryResult, r->sender, r->requestId, r->info);
        // The checks that waited for a query of their key (kpasswdserver.cpp:860-891).
        const QList<Request> waiting = m_wait;
        for (const Request& w : waiting) {
            if (w->stage == KioRequest::Stage::Ended || hasPendingQuery(w->key, w->info))
                continue;
            kio::AuthInfo    info  = w->info;
            kio::CacheEntry* entry = m_wanted ? m_cache.find(w->key, w->info) : nullptr;
            if (!entry || entry->canceled) {
                info.modified = false;
            } else {
                m_cache.touch(entry, w->windowId, false, w->sender);
                info          = entry->info;
                info.modified = true;
            }
            finishCheck(w, info);
        }
        if (r->prompted) {
            m_prompted.removeOne(QString::number(r->windowId));
            m_prompted.removeOne(r->promptedKey);
        }
        if (!m_pending.isEmpty())
            processLater();
    }

    // --- checks -----------------------------------------------------------------------------------------------------------

    void KioServer::finishCheck(const Request& r, const kio::AuthInfo& info) {
        if (r->stage == KioRequest::Stage::Ended)
            return;
        r->stage = KioRequest::Stage::Ended;
        const kio::AuthInfo result = info; // `info` may be r's own
        forget(r);
        if (!r->callerGone)
            emitResult(kio::kCheckResult, r->sender, r->requestId, result);
    }

    void KioServer::lookup(const Request& r) {
        r->stage       = KioRequest::Stage::Preparing;
        r->cancellable = g_cancellable_new();
        // Unlocking the keyring when an item is there: gnome-keyring asks through gcr's prompter, this bridge, and its sheet
        // takes its turn in the shell's queue; nothing here waits for it. This search may hold an unlock prompt: it has a
        // cancellable of its own, which the request's end leaves alone (its result is dropped) and only the Secret Service's
        // departure cancels (decision 9-50).
        GHashTable*   attributes = attributeTable(kio::searchAttributes(r->key, r->info));
        const quint64 id         = ++m_nextUnlock;
        GCancellable* unlock     = g_cancellable_new();
        m_unlocks.insert(id, Unlock{unlock, r});
        auto* call = new Call{m_alive, this, r, {}, id};
        secret_password_searchv(schema(), attributes, static_cast<SecretSearchFlags>(SECRET_SEARCH_UNLOCK | SECRET_SEARCH_LOAD_SECRETS), unlock, onLookup, call);
        g_hash_table_unref(attributes);
    }

    void KioServer::onLookup(GObject* /*source*/, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GError*       error = nullptr;
        GList*        items = secret_password_search_finish(result, &error);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        if (self) {
            if (const Unlock unlock = self->m_unlocks.take(call->generation); unlock.cancellable)
                g_object_unref(unlock.cancellable);
        }
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            if (!items) {
                kio::AuthInfo info = r->info;
                info.modified      = false;
                self->finishCheck(r, info);
            } else {
                auto*        item  = SECRET_RETRIEVABLE(items->data);
                GHashTable*  attrs = secret_retrievable_get_attributes(item);
                const gchar* user  = attrs ? static_cast<const gchar*>(g_hash_table_lookup(attrs, "user")) : nullptr;
                auto*        next  = new Call{call->alive, self, r, QString::fromUtf8(user ? user : ""), 0};
                if (attrs)
                    g_hash_table_unref(attrs);
                secret_retrievable_retrieve_secret(item, r->cancellable, onLookupSecret, next);
            }
        }
        g_list_free_full(items, g_object_unref);
        g_clear_error(&error);
        delete call;
    }

    void KioServer::onLookupSecret(GObject* source, GAsyncResult* result, gpointer data) {
        auto*         call  = static_cast<Call*>(data);
        GError*       error = nullptr;
        SecretValue*  value = secret_retrievable_retrieve_secret_finish(SECRET_RETRIEVABLE(source), result, &error);
        KioServer*    self  = call->live();
        const Request r     = call->request.lock();
        if (self && r && r->stage == KioRequest::Stage::Preparing) {
            kio::AuthInfo info = r->info;
            info.modified      = false;
            gsize        length = 0;
            const gchar* secret = value ? secret_value_get(value, &length) : nullptr;
            // Only what can go back on the bus as KIO reads it: valid UTF-8, no NUL, within the password's bound.
            if (secret && length > 0 && length <= limits::kPassword && !std::memchr(secret, '\0', length)
                && g_utf8_validate(secret, static_cast<gssize>(length), nullptr)) {
                if (info.username.isEmpty())
                    info.username = call->text;
                info.password = kio::Secret(secret, length);
                info.modified = true;
                log(QStringLiteral("check %1 (%2) answered with a remembered password").arg(r->requestId).arg(scheme(*r)));
            }
            self->finishCheck(r, info);
        }
        if (value)
            secret_value_unref(value);
        g_clear_error(&error);
        delete call;
    }

    // --- the keychain -----------------------------------------------------------------------------------------------------

    bool KioServer::store(const QString& key, const kio::AuthInfo& info) {
        if (key.isEmpty() || info.password.empty())
            return false;
        const QString scheme = flatten(info.parsed.scheme(), 16);
        if (m_storesInFlight >= kStoresInFlight || m_stores.size() >= kStoresAlive) {
            log(QStringLiteral("a password (%1) to remember was dropped: %2 stores hold a place, %3 are alive (at most %4 and %5)")
                    .arg(scheme)
                    .arg(m_storesInFlight)
                    .arg(m_stores.size())
                    .arg(kStoresInFlight)
                    .arg(kStoresAlive));
            return false;
        }
        GHashTable*   attributes = attributeTable(kio::storeAttributes(key, info));
        const QString label      = kio::itemLabel(info);
        char*         secret     = info.password.copyOut();
        // The value's bytes are that gcr secure copy, zeroed and freed with the value.
        SecretValue*  value = secret_value_new_full(secret, static_cast<gssize>(info.password.size()), "text/plain", kio::wipeAndFree);
        auto*         store = new Store;
        store->scheme       = scheme;
        store->key          = key;
        store->entry.url        = info.url;
        store->entry.parsed     = info.parsed;
        store->entry.username   = info.username;
        store->entry.realm      = info.realm;
        store->entry.verifyPath = info.verifyPath;
        store->seqNr            = m_seqNr;
        store->secretsGen       = m_secretsGen;
        store->cancellable      = g_cancellable_new();
        const quint64 id        = ++m_nextStore;
        m_stores.insert(id, store);
        ++m_storesInFlight;
        const int limit = m_options.storeTimeoutMs > 0 ? m_options.storeTimeoutMs : kStoreTimeoutMs;
        store->timer    = g_timeout_add_full(G_PRIORITY_DEFAULT, static_cast<guint>(limit), onStoreTimeout, new Call{m_alive, this, {}, {}, id},
                                             [](gpointer p) { delete static_cast<Call*>(p); });
        // Asynchronous, on this main context: a locked keyring's prompt comes back through this bridge (SC9c). Its cancellable
        // is cancelled only when the Secret Service leaves the bus (decision 9-50).
        secret_password_storev_binary(schema(), attributes, SECRET_COLLECTION_DEFAULT, label.toUtf8().constData(), value, store->cancellable, onStored,
                                      new Call{m_alive, this, {}, {}, id});
        secret_value_unref(value);
        g_hash_table_unref(attributes);
        log(QStringLiteral("remembering a password (%1) in the Secret Service, in the background").arg(scheme));
        return true;
    }

    void KioServer::onStored(GObject* /*source*/, GAsyncResult* result, gpointer data) {
        auto*      call  = static_cast<Call*>(data);
        GError*    error = nullptr;
        const bool ok    = secret_password_store_finish(result, &error);
        KioServer* self  = call->live();
        if (Store* store = self ? self->m_stores.take(call->generation) : nullptr) {
            if (store->holdsPlace)
                --self->m_storesInFlight;
            const QString late = store->holdsPlace ? QString() : QStringLiteral(" (after its place was freed)");
            if (ok) {
                log(QStringLiteral("a password (%1) is remembered in the Secret Service%2").arg(store->scheme, late));
            } else {
                // As kpasswdserver when its wallet cannot take one: kept in memory for the session (kpasswdserver.cpp:427-436).
                kio::CacheEntry* entry = self->m_cache.find(store->key, store->entry);
                const bool       kept  = entry && entry->seqNr == store->seqNr && !entry->canceled;
                if (kept)
                    self->m_cache.touch(entry, 0, true);
                log(QStringLiteral("a password (%1) could not be remembered%2: %3%4")
                        .arg(store->scheme, late, flatten(QString::fromUtf8(error ? error->message : ""), 256),
                             kept ? QStringLiteral("; kept in the session's cache for the session") : QString()));
            }
            if (store->timer)
                g_source_remove(store->timer);
            g_object_unref(store->cancellable);
            delete store;
        }
        g_clear_error(&error);
        delete call;
    }

    gboolean KioServer::onStoreTimeout(gpointer data) {
        auto* call = static_cast<Call*>(data);
        if (KioServer* self = call->live()) {
            if (Store* store = self->m_stores.value(call->generation)) {
                store->timer = 0;
                if (store->holdsPlace) {
                    // Not cancelled: it may hold gnome-keyring's unlock prompt (decision 9-50). Its place goes to the next store.
                    store->holdsPlace = false;
                    --self->m_storesInFlight;
                    const int limit = self->m_options.storeTimeoutMs > 0 ? self->m_options.storeTimeoutMs : kStoreTimeoutMs;
                    log(QStringLiteral("a password (%1) is not remembered yet: no answer from the Secret Service within %2 s (an unlock prompt "
                                       "waiting?); its place is freed, and the Secret Service's answer will be logged")
                            .arg(store->scheme, QString::number(limit / 1000.0)));
                }
            }
        }
        return G_SOURCE_REMOVE;
    }

    void KioServer::secretsOwnerLeft() {
        const quint64 gen = m_secretsGen++;
        // Nothing runs the prompts of the stores and unlocking searches sent to it any more, and libsecret's calls wait for
        // its answer for ever, cancelled or not (kio_passwd.sh 21): they end here, their places and requests freed; a late
        // callback finds nothing. Cancelling them dismisses nothing that runs.
        QList<GCancellable*> doomed;
        QList<Request>       checks;
        int                  stores = 0;
        for (auto it = m_stores.begin(); it != m_stores.end();) {
            Store* store = it.value();
            if (store->secretsGen != gen) {
                ++it;
                continue;
            }
            if (store->holdsPlace)
                --m_storesInFlight;
            if (store->timer)
                g_source_remove(store->timer);
            log(QStringLiteral("a password (%1) could not be remembered: the Secret Service left the bus").arg(store->scheme));
            doomed.append(store->cancellable); // its reference
            delete store;
            it = m_stores.erase(it);
            ++stores;
        }
        for (const Unlock& unlock : std::as_const(m_unlocks)) {
            doomed.append(unlock.cancellable);
            if (const Request r = unlock.request.lock(); r && r->stage == KioRequest::Stage::Preparing)
                checks.append(r);
        }
        m_unlocks.clear();
        if (stores || !checks.isEmpty())
            log(QStringLiteral("the Secret Service left the bus: %1 store(s) and %2 check(s) waiting on it ended").arg(stores).arg(checks.size()));
        for (const Request& r : std::as_const(checks)) {
            kio::AuthInfo info = r->info;
            info.modified      = false;
            finishCheck(r, info);
        }
        for (GCancellable* cancellable : std::as_const(doomed)) {
            g_cancellable_cancel(cancellable);
            g_object_unref(cancellable);
        }
        // libsecret's shared service keeps the session it opened with the Secret Service that left: every later call would
        // fail ("The session wrapping the secret does not exist"). Dropped, the next call opens one with the new owner.
        secret_service_disconnect();
    }

    // --- results and ends -------------------------------------------------------------------------------------------------

    void KioServer::emitResult(const char* signal, const QString& destination, qint64 requestId, const kio::AuthInfo& info) {
        // Addressed to the caller's unique name, never broadcast (SC9b).
        if (destination.isEmpty())
            return;
        GVariant* parameters = g_variant_new("(xx@(ysssssssssbbbba{s(siv)}))", static_cast<gint64>(requestId), static_cast<gint64>(m_seqNr), kio::authInfoVariant(info));
        GError*   error      = nullptr;
        if (!g_dbus_connection_emit_signal(m_bus, destination.toUtf8().constData(), kio::kObjectPath, kio::kInterface, signal, parameters, &error))
            log(QStringLiteral("a result could not be sent: %1").arg(flatten(QString::fromUtf8(error ? error->message : ""), 256)));
        g_clear_error(&error);
    }

    void KioServer::endAll(const QString& why) {
        const QList<Request> all = m_requests;
        for (const Request& r : all)
            abandon(r.get(), why);
    }

    void KioServer::callerGone(const QString& name) {
        // The session cache's entries tied to this connection's windows go with it (B-04: kiod6 would keep them until the
        // window closes, which nothing reports on Wayland).
        if (const int n = m_cache.callerGone(name); n > 0)
            log(QStringLiteral("%1 cached password(s) forgotten: the connection that used them left the bus").arg(n));
        const QList<Request> all = m_requests;
        for (const Request& r : all) {
            if (r->sender != name || r->stage == KioRequest::Stage::Ended)
                continue;
            r->callerGone = true;
            if (r->kind == KioRequest::Kind::Query && r->stage == KioRequest::Stage::Shown && !r->id.isEmpty())
                m_sink->withdrawKio(r->id);
            log(QStringLiteral("%1 %2 withdrawn: its caller left the bus").arg(r->kind == KioRequest::Kind::Query ? QStringLiteral("query") : QStringLiteral("check")).arg(r->requestId));
            if (r->kind == KioRequest::Kind::Query)
                respond(r);
            else
                finishCheck(r, r->info);
        }
    }

    KioServer::Request KioServer::find(const KioRequest* request) const {
        for (const Request& r : m_requests) {
            if (r.get() == request)
                return r;
        }
        return nullptr;
    }

    void KioServer::forget(const Request& r) {
        m_requests.removeAll(r);
        m_pending.removeAll(r);
        m_wait.removeAll(r);
        stopStepTimer(r);
        if (r->cancellable) {
            g_cancellable_cancel(r->cancellable);
            g_object_unref(r->cancellable);
            r->cancellable = nullptr;
        }
    }

} // namespace gf::prompter
