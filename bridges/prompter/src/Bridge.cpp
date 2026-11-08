#include "Bridge.h"

#include "Filter.h"
#include "Identity.h"
#include "Log.h"
#include "Text.h"

#include <gio/gunixfdlist.h>

#include <QFile>
#include <QSocketNotifier>
#include <QTimer>

#include <array>
#include <cerrno>
#include <cstring>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

namespace gf::prompter {

    namespace {
        constexpr std::size_t kInCapacity = limits::kShellLine + 1; // one full line and its newline
        constexpr int         kBusTimeoutMs = 5000;

        // The kinds this bridge can send: gcr's password and confirm, nm when its NetworkManager agent runs (step 9c), kio when
        // its KIO password server runs (step 9e), bluetooth when its BlueZ pairing agent runs (step 10).
        QStringList bridgeKinds(bool nm, bool kio, bool bluetooth) {
            QStringList kinds{QStringLiteral("password"), QStringLiteral("confirm")};
            if (nm)
                kinds.append(QStringLiteral("nm"));
            if (kio)
                kinds.append(QStringLiteral("kio"));
            if (bluetooth)
                kinds.append(QStringLiteral("bluetooth"));
            return kinds;
        }

        QString kindName(PromptKind kind) {
            return kind == PromptKind::Password ? QStringLiteral("password") : QStringLiteral("confirm");
        }

        qint64 monotonicMs() {
            timespec ts{};
            ::clock_gettime(CLOCK_MONOTONIC, &ts);
            return static_cast<qint64>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }

        // Best effort, for a peer that is refused before it is adopted.
        void sendNow(int fd, const QByteArray& line) {
            (void)::send(fd, line.constData(), static_cast<std::size_t>(line.size()), MSG_NOSIGNAL | MSG_DONTWAIT);
        }

        struct CredentialsCall {
            Bridge*   bridge;
            QString   id;
            GfPrompt* prompt; // a reference
        };

        struct NameCall {
            Bridge* bridge;
            quint64 generation;
        };

        GVariant* busCall(GDBusConnection* bus, const char* method, GVariant* args, const GVariantType* reply, int timeoutMs, GError** error) {
            return g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", method, args, reply,
                                               G_DBUS_CALL_FLAGS_NONE, timeoutMs, nullptr, error);
        }

        // The main process of `unit` as the user's systemd manager says it now (a session run: the bus is the session bus, on
        // which the manager holds org.freedesktop.systemd1 from login): > 0, 0 when it names none, -1 when it cannot be asked
        // (Peer.h MainPidQuery; rc7 security review of R7-SEC-02). Two calls of at most 1 s, only for a peer already in the
        // unit's cgroup.
        qint64 unitMainPid(GDBusConnection* bus, const QString& unit) {
            GError*   error = nullptr;
            GVariant* found = g_dbus_connection_call_sync(bus, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
                                                          "org.freedesktop.systemd1.Manager", "GetUnit",
                                                          g_variant_new("(s)", unit.toUtf8().constData()), G_VARIANT_TYPE("(o)"),
                                                          G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, nullptr, &error);
            if (!found) {
                g_clear_error(&error);
                return -1;
            }
            const gchar* path = nullptr;
            g_variant_get(found, "(&o)", &path);
            const QByteArray object(path ? path : "");
            g_variant_unref(found);
            if (object.isEmpty())
                return -1;
            GVariant* reply = g_dbus_connection_call_sync(bus, "org.freedesktop.systemd1", object.constData(), "org.freedesktop.DBus.Properties",
                                                          "Get", g_variant_new("(ss)", "org.freedesktop.systemd1.Service", "MainPID"),
                                                          G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, nullptr, &error);
            if (!reply) {
                g_clear_error(&error);
                return -1;
            }
            GVariant* value = nullptr;
            g_variant_get(reply, "(v)", &value);
            qint64 pid = -1;
            if (value && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32))
                pid = static_cast<qint64>(g_variant_get_uint32(value));
            if (value)
                g_variant_unref(value);
            g_variant_unref(reply);
            return pid;
        }
    } // namespace

    Bridge::Bridge(GDBusConnection* bus, Options options) : m_bus(G_DBUS_CONNECTION(g_object_ref(bus))), m_options(std::move(options)) {
        m_in = static_cast<char*>(gcr_secure_memory_alloc(kInCapacity));
    }

    Bridge::~Bridge() {
        stop();
        for (GfPrompt* prompt : std::as_const(m_prompts))
            detachSink(prompt);
        m_prompts.clear();
        // What was left for a later turn never runs after the bridge (it would find the bridge gone): removed, its
        // references released; the sinks are detached first, so a prompt that goes now reports nowhere (opus re-check of
        // step 9a, NIT).
        m_later.clear();
        if (m_acquiredSub)
            g_dbus_connection_signal_unsubscribe(m_bus, m_acquiredSub);
        if (m_lostSub)
            g_dbus_connection_signal_unsubscribe(m_bus, m_lostSub);
        if (m_ownersSub)
            g_dbus_connection_signal_unsubscribe(m_bus, m_ownersSub);
        // The filter and its state stay with the connection until the process ends: GDBus's worker thread may still be
        // running the filter while it is removed.
        // The prompter stays registered until the process ends (decision 9-3): unregistering with prompts in flight would
        // race libgcr's own clean-up, and the bus forgets the object with the connection.
        explicit_bzero(m_in, kInCapacity);
        gcr_secure_memory_free(m_in);
        g_object_unref(m_bus);
    }

    bool Bridge::start(QString* error) {
        // The filter comes first: no PerformPrompt is ever dispatched without it (Filter.h). It counts each caller's open
        // prompts and forgets a caller that leaves the bus, so the bridge listens to every NameOwnerChanged.
        m_filterState = new FilterState;
        m_filterId    = g_dbus_connection_add_filter(m_bus, promptFilter, m_filterState, nullptr);
        m_ownersSub   = g_dbus_connection_signal_subscribe(
            m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
            [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant*, gpointer) {}, nullptr, nullptr);
        m_prompter = gcr_system_prompter_new(GCR_SYSTEM_PROMPTER_MULTIPLE, 0);
        g_signal_connect(m_prompter, "new-prompt", G_CALLBACK(onNewPrompt), this);
        gcr_system_prompter_register(m_prompter, m_bus);
        m_acquiredSub = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameAcquired", "/org/freedesktop/DBus",
                                                           kPrompterName, G_DBUS_SIGNAL_FLAGS_NONE, onNameSignal, this, nullptr);
        m_lostSub     = g_dbus_connection_signal_subscribe(m_bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameLost", "/org/freedesktop/DBus",
                                                           kPrompterName, G_DBUS_SIGNAL_FLAGS_NONE, onNameSignal, this, nullptr);
        // NetworkManager's secrets (step 9c): without a system bus, or when the agent cannot start, NetworkManager has no
        // agent, as before; gcr's prompts are not affected.
        if (m_options.systemBus) {
            m_nm = std::make_unique<NmAgent>(m_options.systemBus, this, m_options.nmTimeoutMs);
            QString nmError;
            if (!m_nm->start(&nmError)) {
                log(QStringLiteral("no NetworkManager secret agent: %1").arg(nmError));
                m_nm.reset();
            }
            // Bluetooth pairing (step 10): without it bluetoothd has no agent in this session (ADR-0035 decision 10-1).
            m_bt = std::make_unique<BtAgent>(m_options.systemBus, this, m_options.btTimeoutMs);
            if (QString btError; !m_bt->start(&btError)) {
                log(QStringLiteral("no Bluetooth pairing agent: %1").arg(btError));
                m_bt.reset();
            }
        }
        // KIO's network passwords (step 9e): without it, KIO's clients reach kiod6 by D-Bus activation, as before.
        m_kio = std::make_unique<KioServer>(m_bus, this, KioServer::Options{m_options.uid, m_options.keyringDirectory, m_options.kioStoreTimeoutMs});
        if (QString kioError; !m_kio->start(&kioError)) {
            log(QStringLiteral("no KIO password server: %1").arg(kioError));
            m_kio.reset();
        }
        return listen(error);
    }

    bool Bridge::listen(QString* error) {
        const QString& path = m_options.socketPath;
        if (!fitsSocketPath(path)) {
            *error = QStringLiteral("socket path too long or empty: %1").arg(path);
            return false;
        }
        if (const QString dirError = prepareSocketDirectory(path); !dirError.isEmpty()) {
            *error = dirError;
            return false;
        }
        const QByteArray local = QFile::encodeName(path);
        sockaddr_un      address{};
        address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, local.constData(), static_cast<std::size_t>(local.size()));
        struct stat st{};
        if (::lstat(local.constData(), &st) == 0) {
            if (!S_ISSOCK(st.st_mode) || st.st_uid != m_options.uid) {
                *error = QStringLiteral("%1 exists and is not a socket of this user").arg(path);
                return false;
            }
            const int probe = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
            const bool live = probe >= 0 && ::connect(probe, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0;
            if (probe >= 0)
                ::close(probe);
            if (live) {
                *error = QStringLiteral("another grassfield-prompter listens on %1").arg(path);
                return false;
            }
            ::unlink(local.constData()); // a stale socket of an earlier run
        }
        m_listenFd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (m_listenFd < 0) {
            *error = QStringLiteral("socket: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
            return false;
        }
        const mode_t previous = ::umask(0077);
        const int    bound    = ::bind(m_listenFd, reinterpret_cast<const sockaddr*>(&address), sizeof(address));
        ::umask(previous);
        if (bound != 0 || ::chmod(local.constData(), 0600) != 0 || ::lstat(local.constData(), &st) != 0 || !S_ISSOCK(st.st_mode)
            || st.st_uid != m_options.uid || (st.st_mode & 077) != 0 || ::listen(m_listenFd, 4) != 0) {
            *error = QStringLiteral("cannot listen on %1: %2").arg(path, QString::fromLocal8Bit(std::strerror(errno)));
            ::close(m_listenFd);
            m_listenFd = -1;
            return false;
        }
        m_socketDev      = st.st_dev;
        m_socketIno      = st.st_ino;
        m_refusalReport.setSingleShot(true);
        QObject::connect(&m_refusalReport, &QTimer::timeout, [this] {
            if (const qint64 n = m_refusals.takeSuppressed(); n > 0)
                log(QStringLiteral("%1 more connection(s) refused in the last %2 s, not logged one by one").arg(n).arg(m_refusals.windowMs() / 1000));
        });
        m_acceptNotifier = new QSocketNotifier(m_listenFd, QSocketNotifier::Read);
        QObject::connect(m_acceptNotifier, &QSocketNotifier::activated, [this] { onAcceptReady(); });
        log(QStringLiteral("listening on %1 for %2 (the name is requested once the shell says hello)").arg(flatten(path, caps::kPath), m_options.peerUnit));
        return true;
    }

    void Bridge::stop() {
        if (m_nameWanted) {
            m_nameWanted = false;
            ++m_nameGen;
            GError*   error = nullptr;
            GVariant* reply = busCall(m_bus, "ReleaseName", g_variant_new("(s)", kPrompterName), G_VARIANT_TYPE("(u)"), 1000, &error);
            if (reply)
                g_variant_unref(reply);
            g_clear_error(&error);
        }
        if (m_client >= 0)
            dropClient(QStringLiteral("stopping"));
        m_nm.reset();  // answers whatever is still pending
        m_kio.reset(); // likewise, then releases its name
        m_bt.reset();  // likewise
        if (m_listenFd >= 0) {
            delete m_acceptNotifier;
            m_acceptNotifier = nullptr;
            ::close(m_listenFd);
            m_listenFd = -1;
            // Removed only when it is still the socket this run made.
            const QByteArray local = QFile::encodeName(m_options.socketPath);
            struct stat      st{};
            if (::lstat(local.constData(), &st) == 0 && S_ISSOCK(st.st_mode) && st.st_dev == m_socketDev && st.st_ino == m_socketIno)
                ::unlink(local.constData());
            log(QStringLiteral("stopped"));
        }
        g_dbus_connection_flush_sync(m_bus, nullptr, nullptr);
    }

    // --- gcr's side ------------------------------------------------------------------------------------------------------

    GcrPrompt* Bridge::onNewPrompt(GcrSystemPrompter* /*prompter*/, gpointer data) {
        auto*      self = static_cast<Bridge*>(data);
        const bool full = self->m_prompts.size() >= limits::kPrompts;
        GfPrompt*  prompt = newPrompt(full ? nullptr : self);
        if (full)
            log(QStringLiteral("%1 gcr prompts already open: the new one answers \"cancelled\"").arg(limits::kPrompts));
        else
            self->m_prompts.insert(prompt);
        return GCR_PROMPT(prompt);
    }

    void Bridge::submit(GfPrompt* prompt) {
        const PromptKind kind = pendingKind(prompt);
        if (kind == PromptKind::None)
            return;
        if (m_client < 0 || !m_ready) {
            log(QStringLiteral("a %1 request answered \"cancelled\": no shell").arg(kindName(kind)));
            answerCancel(prompt);
            return;
        }
        if (!m_kinds.contains(kindName(kind))) {
            log(QStringLiteral("a %1 request answered \"cancelled\": the shell does not draw that kind").arg(kindName(kind)));
            answerCancel(prompt);
            return;
        }
        const QString id = m_book.reserve(prompt);
        if (id.isEmpty()) {
            log(QStringLiteral("a %1 request answered \"cancelled\": %2 requests are outstanding").arg(kindName(kind)).arg(m_book.count()));
            answerCancel(prompt);
            return;
        }
        Pending pending;
        pending.prompt = GF_PROMPT(g_object_ref(prompt));
        pending.kind   = kind;
        m_pending.insert(id, pending);

        const QString caller = promptCaller(prompt);
        if (caller.isEmpty()) {
            identified(id, prompt, RequesterView());
            return;
        }
        // GetConnectionCredentials: the caller's user and its pidfd (ProcessFD), never a bare PID.
        auto* call = new CredentialsCall{this, id, GF_PROMPT(g_object_ref(prompt))};
        g_dbus_connection_call_with_unix_fd_list(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                                 "GetConnectionCredentials", g_variant_new("(s)", caller.toUtf8().constData()),
                                                 G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, nullptr, onCredentials, call);
    }

    void Bridge::onCredentials(GObject* source, GAsyncResult* result, gpointer data) {
        auto*        call   = static_cast<CredentialsCall*>(data);
        GUnixFDList* fds    = nullptr;
        GError*      error  = nullptr;
        GVariant*    reply  = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), &fds, result, &error);
        ExeFacts     facts;
        if (reply) {
            GVariant* dict = g_variant_get_child_value(reply, 0);
            guint32   uid  = 0;
            gint32    handle = -1;
            const bool hasUid = g_variant_lookup(dict, "UnixUserID", "u", &uid);
            if (g_variant_lookup(dict, "ProcessFD", "h", &handle) && fds && handle >= 0 && handle < g_unix_fd_list_get_length(fds)) {
                const int pidfd = g_unix_fd_list_get(fds, handle, nullptr);
                if (pidfd >= 0) {
                    facts = exeFactsOfPidfd(pidfd);
                    ::close(pidfd);
                }
            }
            facts.sameUser = hasUid && uid == call->bridge->m_options.uid;
            g_variant_unref(dict);
            g_variant_unref(reply);
        }
        g_clear_error(&error);
        g_clear_object(&fds);
        const RequesterView requester = requesterFor(facts);
        call->bridge->identified(call->id, call->prompt, requester);
        g_object_unref(call->prompt);
        delete call;
    }

    void Bridge::identified(const QString& id, GfPrompt* prompt, const RequesterView& requester) {
        auto it = m_pending.find(id);
        if (it == m_pending.end() || it->prompt != prompt || m_client < 0)
            return; // withdrawn, or the shell went away, meanwhile
        const PromptFields f = promptFields(prompt);
        PromptView         view;
        view.id            = id;
        view.kind          = kindName(it->kind);
        view.requester     = requester;
        view.title         = flatten(f.title, caps::kTitle);
        view.message       = flatten(f.message, caps::kMessage);
        view.description   = flatten(f.description, caps::kDescription);
        view.warning       = flatten(f.warning, caps::kWarning);
        view.continueLabel = flatten(f.continueLabel, caps::kButton);
        view.cancelLabel   = flatten(f.cancelLabel, caps::kButton);
        view.choiceLabel   = flatten(f.choiceLabel, caps::kChoice);
        view.hasChoice     = !view.choiceLabel.isEmpty();
        view.choiceChosen  = f.choiceChosen;
        view.passwordNew   = f.passwordNew;
        it->sent           = true;
        it->choice         = view.hasChoice;
        log(QStringLiteral("request %1: %2 for %3%4").arg(id, view.kind, requester.role, requester.path.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(requester.path)));
        send(promptMessage(view));
    }

    // A request's reference to its prompt is dropped in a later main loop turn: these paths can run inside gcr's own
    // callbacks (withdraw and forget always do, cancelRequest through dropClient), where a last reference going would
    // dispose a prompt gcr is still working on (opus final check of step 9a: the audit of the paths into gcr).
    void Bridge::unrefLater(GfPrompt* prompt) {
        m_later.schedule({prompt}, {});
    }

    void Bridge::withdraw(GfPrompt* prompt) {
        const QString id = m_book.idOf(prompt);
        if (id.isEmpty())
            return;
        log(QStringLiteral("request %1 withdrawn by its caller").arg(id));
        const Pending pending = m_pending.take(id);
        m_book.release(id);
        if (pending.sent && m_client >= 0)
            send(cancelMessage(id));
        if (pending.prompt)
            unrefLater(pending.prompt);
    }

    void Bridge::forget(GfPrompt* prompt) {
        m_prompts.remove(prompt);
        // A prompt with an outstanding request is referenced by it, so it cannot be going away; this is only defensive.
        if (const QString id = m_book.idOf(prompt); !id.isEmpty()) {
            const Pending pending = m_pending.take(id);
            m_book.release(id);
            if (pending.sent && m_client >= 0)
                send(cancelMessage(id));
            if (pending.prompt)
                unrefLater(pending.prompt);
        }
    }

    void Bridge::cancelRequest(const QString& id, bool tellShell) {
        if (!m_pending.contains(id))
            return;
        const Pending pending = m_pending.take(id);
        m_book.release(id);
        if (tellShell && pending.sent && m_client >= 0)
            send(cancelMessage(id));
        if (pending.nm) {
            // Fail closed: NetworkManager is told there are no secrets (it may ask another agent).
            if (m_nm)
                m_nm->refuse(pending.nm, nm::kErrorNoSecrets, QStringLiteral("cancelled by the bridge"));
            return;
        }
        if (pending.kio) {
            // Fail closed: the KIO client gets "nothing" (its worker reports a cancelled login), nothing is cached.
            if (m_kio)
                m_kio->abandon(pending.kio, QStringLiteral("cancelled by the bridge"));
            return;
        }
        if (pending.bt) {
            // Fail closed: bluetoothd is told Rejected (the pairing fails; a code shown just ends).
            if (m_bt)
                m_bt->refuse(pending.bt, bt::kErrorRejected, QStringLiteral("cancelled by the bridge"));
            return;
        }
        answerCancel(pending.prompt);
        unrefLater(pending.prompt);
    }

    // --- NetworkManager's side (step 9c) ---------------------------------------------------------------------------------

    QString Bridge::submitNm(NmRequest* request) {
        if (m_client < 0 || !m_ready) {
            log(QStringLiteral("an nm request answered NoSecrets: no shell"));
            return {};
        }
        if (!m_kinds.contains(QStringLiteral("nm"))) {
            log(QStringLiteral("an nm request answered NoSecrets: the shell does not draw that kind"));
            return {};
        }
        const QString id = m_book.reserve(request);
        if (id.isEmpty()) {
            log(QStringLiteral("an nm request answered NoSecrets: %1 requests are outstanding").arg(m_book.count()));
            return {};
        }
        Pending pending;
        pending.nm   = request;
        pending.sent = true;
        m_pending.insert(id, pending);
        request->id = id;
        NmPromptView view;
        view.id       = id;
        view.ssid     = request->ask.ssid;
        view.security = nm::securityName(request->ask.security);
        view.identity = request->ask.identity;
        send(nmPromptMessage(view)); // may drop the shell, which then refuses this request too (NmAgent checks)
        return id;
    }

    void Bridge::withdrawNm(const QString& id) {
        const auto it = m_pending.find(id);
        if (it == m_pending.end() || !it->nm)
            return;
        m_pending.erase(it);
        m_book.release(id);
        if (m_client >= 0)
            send(cancelMessage(id));
    }

    void Bridge::onNmAnswer(const ShellLine& answer, std::string_view line, NmRequest* request) {
        // Only the password goes back: NetworkManager keeps nothing but secrets from an agent's reply, so a name (identity)
        // is never asked or accepted (opus review of step 9c, MAJOR; decision 9-33 amended).
        QString wrong;
        if (answer.hasChoice)
            wrong = QStringLiteral("a choice where none was shown");
        else if (answer.hasIdentity)
            wrong = QStringLiteral("a name where none is asked");
        else if (!answer.ok && answer.hasPassword)
            wrong = QStringLiteral("a secret in a cancellation");
        else if (answer.ok && !answer.hasPassword)
            wrong = QStringLiteral("ok without a password");
        if (!wrong.isEmpty()) {
            log(QStringLiteral("invalid answer to %1: %2; the request is cancelled").arg(answer.id, wrong));
            cancelRequest(answer.id, true);
            protocolError(QStringLiteral("bad-answer"), wrong, false);
            return;
        }
        m_pending.remove(answer.id);
        m_book.release(answer.id);
        if (answer.refused) {
            // The shell could not take it (its bound): no secrets, NetworkManager may ask another agent (decision 9-31).
            log(QStringLiteral("request %1 refused by the shell").arg(answer.id));
            if (m_nm)
                m_nm->refuse(request, nm::kErrorNoSecrets, QStringLiteral("the shell could not take it"));
            return;
        }
        if (!answer.ok) {
            log(QStringLiteral("request %1 answered: cancel").arg(answer.id));
            if (m_nm)
                m_nm->refuse(request, nm::kErrorUserCanceled, QStringLiteral("the user cancelled"));
            return;
        }
        // Decoded straight into gcr's secure memory; the line it came from is wiped by the caller.
        auto*      secure = static_cast<char*>(gcr_secure_memory_alloc(limits::kPassword + 1));
        const long n      = decodeJsonString(line.data() + answer.password.begin, answer.password.end - answer.password.begin, secure, limits::kPassword);
        if (n <= 0 || !m_nm) {
            explicit_bzero(secure, limits::kPassword + 1);
            gcr_secure_memory_free(secure);
            log(QStringLiteral("answer to %1: an empty or undecodable password; the request is cancelled").arg(answer.id));
            send(cancelMessage(answer.id));
            if (m_nm)
                m_nm->refuse(request, nm::kErrorNoSecrets, QStringLiteral("an empty answer"));
            return;
        }
        secure[n] = '\0';
        m_nm->answer(request, secure, static_cast<std::size_t>(n));
    }

    // --- KIO's side (step 9e) ----------------------------------------------------------------------------------------------

    QString Bridge::submitKio(KioRequest* request) {
        if (m_client < 0 || !m_ready || !m_kinds.contains(QStringLiteral("kio")))
            return {};
        const QString id = m_book.reserve(request);
        if (id.isEmpty()) {
            log(QStringLiteral("a kio request answered with nothing: %1 requests are outstanding").arg(m_book.count()));
            return {};
        }
        Pending pending;
        pending.kio    = request;
        pending.sent   = true;
        pending.choice = request->rememberOffered;
        m_pending.insert(id, pending);
        request->id = id;
        KioPromptView view;
        view.id        = id;
        view.requester = request->requester;
        view.server    = request->server;
        view.name      = request->name;
        view.nameMode  = request->nameMode;
        view.realm     = request->realm;
        view.retry     = request->retry;
        view.remember  = !request->rememberOffered ? QStringLiteral("none") : request->rememberChosen ? QStringLiteral("on") : QStringLiteral("off");
        view.keyring   = request->rememberOffered ? kio::protectionName(request->keyring) : QStringLiteral("unknown");
        send(kioPromptMessage(view)); // may drop the shell, which then ends this request too (KioServer checks)
        return id;
    }

    void Bridge::withdrawKio(const QString& id) {
        const auto it = m_pending.find(id);
        if (it == m_pending.end() || !it->kio)
            return;
        m_pending.erase(it);
        m_book.release(id);
        if (m_client >= 0)
            send(cancelMessage(id));
    }

    void Bridge::onKioAnswer(const ShellLine& answer, std::string_view line, KioRequest* request) {
        const bool asksName = request->nameMode == QLatin1String("edit");
        QString    wrong;
        if (!answer.ok && (answer.hasPassword || answer.hasIdentity || answer.hasChoice))
            wrong = QStringLiteral("a secret, a name or a choice in a cancellation or a refusal");
        else if (answer.ok && !answer.hasPassword)
            wrong = QStringLiteral("ok without a password");
        else if (answer.ok && asksName && !answer.hasIdentity)
            wrong = QStringLiteral("ok without a name");
        else if (answer.hasIdentity && !asksName)
            wrong = QStringLiteral("a name where none is asked");
        else if (answer.hasChoice && !request->rememberOffered)
            wrong = QStringLiteral("a choice where none was shown");
        if (!wrong.isEmpty()) {
            log(QStringLiteral("invalid answer to %1: %2; the request is cancelled").arg(answer.id, wrong));
            cancelRequest(answer.id, true);
            protocolError(QStringLiteral("bad-answer"), wrong, false);
            return;
        }
        m_pending.remove(answer.id);
        m_book.release(answer.id);
        if (!m_kio)
            return;
        if (answer.refused) {
            // The shell could not take it (its bound): "nothing" to KIO's client, as when the bridge cannot ask, and no
            // cancelled entry in the cache (that is the user's Cancel only): the worker may ask again (decision 9-31, 9-37).
            log(QStringLiteral("request %1 refused by the shell").arg(answer.id));
            m_kio->abandon(request, QStringLiteral("the shell could not take it"));
            return;
        }
        if (!answer.ok) {
            m_kio->userCancel(request);
            return;
        }
        // Decoded straight into gcr's secure memory; the line it came from is wiped by the caller.
        auto*      secure = static_cast<char*>(gcr_secure_memory_alloc(limits::kPassword + 1));
        const long n      = decodeJsonString(line.data() + answer.password.begin, answer.password.end - answer.password.begin, secure, limits::kPassword);
        QString    name;
        long       named = 0;
        if (asksName) {
            std::array<char, limits::kIdentity> buffer{};
            named = decodeJsonString(line.data() + answer.identity.begin, answer.identity.end - answer.identity.begin, buffer.data(), buffer.size());
            if (named > 0)
                name = QString::fromUtf8(buffer.data(), static_cast<qsizetype>(named));
        }
        if (n <= 0 || (asksName && named <= 0)) {
            explicit_bzero(secure, limits::kPassword + 1);
            gcr_secure_memory_free(secure);
            log(QStringLiteral("answer to %1: an empty or undecodable password or name; the request is cancelled").arg(answer.id));
            send(cancelMessage(answer.id));
            m_kio->abandon(request, QStringLiteral("an empty answer"));
            return;
        }
        secure[n] = '\0';
        m_kio->answer(request, name, kio::Secret::adopt(secure, static_cast<std::size_t>(n)), answer.hasChoice && answer.choice);
    }

    // --- Bluetooth's side (step 10) ------------------------------------------------------------------------------------------

    QString Bridge::submitBt(BtRequest* request) {
        if (m_client < 0 || !m_ready) {
            log(QStringLiteral("a bluetooth request answered Rejected: no shell"));
            return {};
        }
        if (!m_kinds.contains(QStringLiteral("bluetooth"))) {
            log(QStringLiteral("a bluetooth request answered Rejected: the shell does not draw that kind"));
            return {};
        }
        const QString id = m_book.reserve(request);
        if (id.isEmpty()) {
            log(QStringLiteral("a bluetooth request answered Rejected: %1 requests are outstanding").arg(m_book.count()));
            return {};
        }
        Pending pending;
        pending.bt   = request;
        pending.sent = true;
        m_pending.insert(id, pending);
        request->id = id;
        BtPromptView view;
        view.id      = id;
        view.mode    = bt::modeName(request->mode);
        view.name    = request->device.name;
        view.address = request->device.address;
        view.icon    = request->device.icon;
        view.code    = request->code;
        view.entered = request->entered;
        view.service = request->service;
        view.uuid    = request->uuid;
        send(btPromptMessage(view)); // may drop the shell, which then ends this request too (BtAgent checks)
        return id;
    }

    void Bridge::withdrawBt(const QString& id) {
        const auto it = m_pending.find(id);
        if (it == m_pending.end() || !it->bt)
            return;
        m_pending.erase(it);
        m_book.release(id);
        if (m_client >= 0)
            send(cancelMessage(id));
    }

    void Bridge::progressBt(const QString& id, int entered) {
        const auto it = m_pending.constFind(id);
        if (it == m_pending.constEnd() || !it->bt || m_client < 0)
            return;
        send(progressMessage(id, entered));
    }

    void Bridge::onBtAnswer(const ShellLine& answer, std::string_view line, BtRequest* request) {
        // ADR-0035 decision 10-6: a code only for a PIN or a passkey answered ok; a code shown is only ever cancelled.
        const bool code    = bt::asksCode(request->mode);
        const bool display = bt::isDisplay(request->mode);
        QString    wrong;
        if (answer.hasChoice)
            wrong = QStringLiteral("a choice where none was shown");
        else if (answer.hasIdentity)
            wrong = QStringLiteral("a name where none is asked");
        else if (display && answer.ok)
            wrong = QStringLiteral("ok for a code shown");
        else if (answer.hasPassword && !(code && answer.ok))
            wrong = QStringLiteral("a code where none is asked");
        else if (code && answer.ok && !answer.hasPassword)
            wrong = QStringLiteral("ok without a code");
        if (!wrong.isEmpty()) {
            log(QStringLiteral("invalid answer to %1: %2; the request is cancelled").arg(answer.id, wrong));
            cancelRequest(answer.id, true);
            protocolError(QStringLiteral("bad-answer"), wrong, false);
            return;
        }
        m_pending.remove(answer.id);
        m_book.release(answer.id);
        if (!m_bt)
            return;
        if (answer.refused) {
            // The shell could not take it (its bound): Rejected, never the user's Canceled (as 9-31).
            log(QStringLiteral("request %1 refused by the shell").arg(answer.id));
            m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("the shell could not take it"));
            return;
        }
        if (!answer.ok) {
            log(QStringLiteral("request %1 answered: %2").arg(answer.id, display ? QStringLiteral("cancel (the code shown)")
                                                                     : request->mode == bt::Mode::Authorize || request->mode == bt::Mode::AuthorizeService
                                                                         ? QStringLiteral("decline")
                                                                         : QStringLiteral("cancel")));
            if (display)
                m_bt->cancelDisplay(request);
            else if (request->mode == bt::Mode::Authorize || request->mode == bt::Mode::AuthorizeService)
                m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("the user declined"));
            else
                m_bt->refuse(request, bt::kErrorCanceled, QStringLiteral("the user cancelled"));
            return;
        }
        if (!code) {
            m_bt->answerYes(request);
            return;
        }
        // Decoded straight into gcr's secure memory; the line it came from is wiped by the caller.
        auto*      secure = static_cast<char*>(gcr_secure_memory_alloc(limits::kPassword + 1));
        const long n      = decodeJsonString(line.data() + answer.password.begin, answer.password.end - answer.password.begin, secure, limits::kPassword);
        guint32    passkey = 0;
        const bool valid   = n > 0
                           && (request->mode == bt::Mode::Pin ? bt::validPin(secure, static_cast<std::size_t>(n))
                                                              : bt::parsePasskey(secure, static_cast<std::size_t>(n), &passkey));
        if (!valid || request->mode == bt::Mode::Passkey) {
            explicit_bzero(secure, limits::kPassword + 1);
            gcr_secure_memory_free(secure);
        }
        if (!valid) {
            log(QStringLiteral("answer to %1: not a %2; the request is cancelled")
                    .arg(answer.id, request->mode == bt::Mode::Pin ? QStringLiteral("PIN of 1 to 16 letters or digits") : QStringLiteral("passkey of 6 digits")));
            send(cancelMessage(answer.id));
            m_bt->refuse(request, bt::kErrorRejected, QStringLiteral("a wrong code from the shell"));
            return;
        }
        if (request->mode == bt::Mode::Pin) {
            secure[n] = '\0';
            m_bt->answerPin(request, secure, static_cast<std::size_t>(n));
        } else {
            m_bt->answerPasskey(request, passkey);
        }
    }

    void Bridge::cancelAll(bool tellShell) {
        for (const QString& id : m_book.ids())
            cancelRequest(id, tellShell);
    }

    // --- the shell's side ------------------------------------------------------------------------------------------------

    void Bridge::onAcceptReady() {
        while (true) {
            const int fd = ::accept4(m_listenFd, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
            if (fd < 0) {
                if (errno == EINTR)
                    continue;
                return;
            }
            // A session run also asks systemd whether the peer is the unit's main process (Peer.h); a development run, on its
            // private test bus, has no manager to ask and checks the cgroup alone.
            const PeerCheck check = checkSocketPeer(fd, m_options.uid, m_options.peerUnit, m_options.requireUserManager, nullptr,
                                                    [this](const QString& unit) { return unitMainPid(m_bus, unit); });
            // A refused peer can try again at once: the journal gets one line per 10 s, with the count of the others,
            // written when the window ends even if no refusal follows.
            qint64 suppressed = 0;
            if (!check.accepted) {
                if (m_refusals.allow(monotonicMs(), &suppressed))
                    log(QStringLiteral("refused a connection from pid %1 (cgroup %2): %3%4")
                            .arg(check.pid)
                            .arg(flatten(check.cgroup, caps::kPath), check.reason,
                                 suppressed ? QStringLiteral(" (and %1 refused connection(s) not logged)").arg(suppressed) : QString()));
                sendNow(fd, errorMessage(QStringLiteral("refused"), QStringLiteral("not the shell")));
                ::close(fd);
                reportRefusalsLater();
                continue;
            }
            if (m_client >= 0) {
                if (m_refusals.allow(monotonicMs(), &suppressed))
                    log(QStringLiteral("refused a second shell connection (pid %1)%2")
                            .arg(check.pid)
                            .arg(suppressed ? QStringLiteral(" (and %1 refused connection(s) not logged)").arg(suppressed) : QString()));
                sendNow(fd, errorMessage(QStringLiteral("busy"), QStringLiteral("another shell is connected")));
                ::close(fd);
                reportRefusalsLater();
                continue;
            }
            m_client   = fd;
            m_inLen    = 0;
            m_badLines = 0;
            m_ready    = false;
            m_kinds.clear();
            m_out.clear();
            m_readNotifier  = new QSocketNotifier(fd, QSocketNotifier::Read);
            m_writeNotifier = new QSocketNotifier(fd, QSocketNotifier::Write);
            m_writeNotifier->setEnabled(false);
            QObject::connect(m_readNotifier, &QSocketNotifier::activated, [this] { onClientReadable(); });
            QObject::connect(m_writeNotifier, &QSocketNotifier::activated, [this] { flush(); });
            log(QStringLiteral("shell connected (pid %1, %2)")
                    .arg(check.pid)
                    .arg(check.raceFree ? QStringLiteral("cgroup read through its pidfd") : QStringLiteral("cgroup read through SO_PEERCRED's pid")));
            send(helloMessage(bridgeKinds(m_nm != nullptr, m_kio != nullptr, m_bt != nullptr)));
        }
    }

    void Bridge::reportRefusalsLater() {
        if (m_refusalReport.isActive())
            return;
        m_refusalReport.start(static_cast<int>(m_refusals.windowMs()));
    }

    void Bridge::onClientReadable() {
        while (m_client >= 0) {
            const ssize_t n = ::recv(m_client, m_in + m_inLen, kInCapacity - m_inLen, 0);
            if (n == 0) {
                dropClient(QStringLiteral("shell disconnected"));
                return;
            }
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                if (errno != EAGAIN && errno != EWOULDBLOCK)
                    dropClient(QStringLiteral("read error: %1").arg(QString::fromLocal8Bit(std::strerror(errno))));
                return;
            }
            m_inLen += static_cast<std::size_t>(n);
            // Each complete line is handled, then wiped (takeLines, Protocol.h).
            const std::size_t rest = takeLines(m_in, m_inLen, [this](std::string_view line) {
                handleLine(line);
                return m_client >= 0;
            });
            if (m_client < 0)
                return; // dropped: dropClient wiped the buffer
            m_inLen = rest;
            if (m_inLen > limits::kShellLine) {
                protocolError(QStringLiteral("too-long"), QStringLiteral("a line over %1 bytes").arg(limits::kShellLine), true);
                return;
            }
        }
    }

    void Bridge::handleLine(std::string_view line) {
        ShellLine         message;
        QString           error;
        const ParseStatus status = parseShellLine(line, &message, &error);
        switch (status) {
            case ParseStatus::Malformed: protocolError(QStringLiteral("bad-line"), error, true); return;
            case ParseStatus::Version: protocolError(QStringLiteral("version"), error, true); return;
            case ParseStatus::Unknown: protocolError(QStringLiteral("unknown-type"), error, false); return;
            case ParseStatus::Invalid:
                log(QStringLiteral("invalid answer to %1: %2; the request is cancelled").arg(message.id, error));
                cancelRequest(message.id, true);
                protocolError(QStringLiteral("bad-answer"), error, false);
                return;
            case ParseStatus::Ok: break;
        }
        if (message.type == ShellLine::Type::Hello) {
            if (m_ready) {
                protocolError(QStringLiteral("bad-line"), QStringLiteral("hello repeated"), false);
                return;
            }
            m_ready = true;
            m_kinds = message.kinds;
            log(QStringLiteral("shell %1 says hello (draws: %2)").arg(flatten(message.shell, 64), flatten(m_kinds.join(u','), 256)));
            send(nameMessage(m_nameState));
            wantName(true);
            if (m_nm)
                m_nm->setWanted(m_kinds.contains(QStringLiteral("nm")));
            if (m_kio)
                m_kio->setWanted(m_kinds.contains(QStringLiteral("kio")));
            if (m_bt)
                m_bt->setWanted(m_kinds.contains(QStringLiteral("bluetooth")));
            return;
        }
        if (!m_ready) {
            protocolError(QStringLiteral("bad-line"), QStringLiteral("an answer before hello"), true);
            return;
        }
        onAnswer(message, line);
    }

    void Bridge::onAnswer(const ShellLine& answer, std::string_view line) {
        const auto it = m_pending.constFind(answer.id);
        if (it == m_pending.constEnd() || !it->sent) {
            // Withdrawn meanwhile, already answered, or never sent: nothing is answered on its behalf.
            log(QStringLiteral("answer to %1 ignored: not outstanding").arg(answer.id));
            return;
        }
        const Pending pending = *it;
        if (pending.nm) {
            onNmAnswer(answer, line, pending.nm);
            return;
        }
        if (pending.kio) {
            onKioAnswer(answer, line, pending.kio);
            return;
        }
        if (pending.bt) {
            onBtAnswer(answer, line, pending.bt);
            return;
        }
        QString wrong;
        if (answer.hasIdentity)
            wrong = QStringLiteral("a name where none is asked");
        else if (pending.kind == PromptKind::Password && answer.ok && !answer.hasPassword)
            wrong = QStringLiteral("ok without a password");
        else if ((pending.kind == PromptKind::Confirm || !answer.ok) && answer.hasPassword)
            wrong = QStringLiteral("a password where none is asked");
        else if (answer.hasChoice && !pending.choice)
            wrong = QStringLiteral("a choice where none was shown");
        if (!wrong.isEmpty()) {
            log(QStringLiteral("invalid answer to %1: %2; the request is cancelled").arg(answer.id, wrong));
            cancelRequest(answer.id, true);
            protocolError(QStringLiteral("bad-answer"), wrong, false);
            return;
        }
        m_pending.erase(it);
        m_book.release(answer.id);
        const int choice = answer.hasChoice ? (answer.choice ? 1 : 0) : -1;
        if (pending.kind == PromptKind::Password) {
            char* secure = nullptr;
            if (answer.ok) {
                // Decoded straight into gcr's secure memory; the line it came from is wiped by the caller.
                secure     = static_cast<char*>(gcr_secure_memory_alloc(limits::kPassword + 1));
                const long n = decodeJsonString(line.data() + answer.password.begin, answer.password.end - answer.password.begin, secure, limits::kPassword);
                if (n < 0) {
                    explicit_bzero(secure, limits::kPassword + 1);
                    gcr_secure_memory_free(secure);
                    log(QStringLiteral("answer to %1: the password cannot be decoded; the request is cancelled").arg(answer.id));
                    send(cancelMessage(answer.id));
                    answerCancel(pending.prompt);
                    g_object_unref(pending.prompt);
                    return;
                }
                secure[n] = '\0';
            }
            answerPassword(pending.prompt, secure, choice);
        } else {
            answerConfirm(pending.prompt, answer.ok, choice);
        }
        log(QStringLiteral("request %1 answered: %2").arg(answer.id, answer.ok ? QStringLiteral("ok") : QStringLiteral("cancel")));
        g_object_unref(pending.prompt);
    }

    void Bridge::protocolError(const QString& code, const QString& why, bool fatal) {
        log(QStringLiteral("protocol error from the shell (%1): %2%3").arg(code, why, fatal ? QStringLiteral("; closing the connection") : QString()));
        send(errorMessage(code, why));
        if (fatal || ++m_badLines > limits::kBadLines) {
            flush();
            dropClient(fatal ? QStringLiteral("protocol error") : QStringLiteral("too many invalid lines"));
        }
    }

    void Bridge::send(const QByteArray& line) {
        if (m_client < 0)
            return;
        m_out.append(line);
        if (m_out.size() > limits::kPendingOut) {
            dropClient(QStringLiteral("the shell does not read"));
            return;
        }
        flush();
    }

    void Bridge::flush() {
        while (m_client >= 0 && !m_out.isEmpty()) {
            const ssize_t n = ::send(m_client, m_out.constData(), static_cast<std::size_t>(m_out.size()), MSG_NOSIGNAL | MSG_DONTWAIT);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    m_writeNotifier->setEnabled(true);
                    return;
                }
                dropClient(QStringLiteral("write error: %1").arg(QString::fromLocal8Bit(std::strerror(errno))));
                return;
            }
            m_out.remove(0, n);
        }
        if (m_writeNotifier)
            m_writeNotifier->setEnabled(false);
    }

    void Bridge::dropClient(const QString& why) {
        if (m_client < 0)
            return;
        log(QStringLiteral("shell gone: %1; %2 request(s) cancelled, the name released").arg(why).arg(m_book.count()));
        // QSocketNotifier must not outlive its descriptor: disabled and deleted later, as the signal may be on the stack.
        for (QSocketNotifier* n : {m_readNotifier, m_writeNotifier}) {
            if (n) {
                n->setEnabled(false);
                n->deleteLater();
            }
        }
        m_readNotifier  = nullptr;
        m_writeNotifier = nullptr;
        ::close(m_client);
        m_client = -1;
        explicit_bzero(m_in, kInCapacity);
        m_inLen = 0;
        m_out.clear();
        m_ready = false;
        m_kinds.clear();
        cancelAll(false);
        wantName(false);
        // NetworkManager loses its agent with the shell (step 9c): it fails with NoSecrets meanwhile, as before.
        if (m_nm)
            m_nm->setWanted(false);
        // KIO's clients get "nothing" for every request still open, then the name goes: kiod6 is activated for the next
        // one (step 9e).
        if (m_kio)
            m_kio->setWanted(false);
        // bluetoothd loses its agent with the shell (step 10): it then refuses every pairing step that needs one.
        if (m_bt)
            m_bt->setWanted(false);
        // gcr's clients forget a prompt without stopping it when the prompter's name goes (gcr-system-prompt.c
        // on_prompter_vanished): gcr would keep it, and the filter would count it, until the client leaves the bus. Each
        // open prompt is closed instead, so gcr ends it and tells its caller PromptDone (counter-review of step 9a,
        // MINOR-A) -- in a later main loop turn, never from here: dropClient can run inside gcr's own callbacks (a write
        // error while a withdrawal goes out from gcr's prompt_stop_prompting, itself called by on_caller_vanished), and
        // closing a prompt re-enters gcr, which would free callbacks the outer frame still holds (opus final check of step
        // 9a, MAJOR: a use-after-free).
        closeOpenPromptsLater();
    }

    void Bridge::closeOpenPromptsLater() {
        if (m_prompts.isEmpty())
            return;
        const QList<GfPrompt*> open = m_prompts.values();
        for (GfPrompt* prompt : open)
            g_object_ref(prompt); // the address cannot be reused by another prompt meanwhile
        m_later.schedule(open, [this](const QList<GfPrompt*>& prompts) {
            int closed = 0;
            for (GfPrompt* prompt : prompts) {
                // A prompt gcr ended meanwhile was disposed, which took it out of m_prompts: nothing to close.
                if (m_prompts.contains(prompt)) {
                    gcr_prompt_close(GCR_PROMPT(prompt));
                    ++closed;
                }
            }
            // gcr disposes each prompt it ends, which takes it out of m_prompts: what is left was not ended.
            log(QStringLiteral("%1 open gcr prompt(s) closed: their callers saw the name go (%2 still open)").arg(closed).arg(m_prompts.size()));
        });
    }

    // --- the well-known name ------------------------------------------------------------------------------------------------

    void Bridge::wantName(bool want) {
        if (want == m_nameWanted)
            return;
        m_nameWanted = want;
        ++m_nameGen;
        auto* call = new NameCall{this, m_nameGen};
        if (want) {
            // Flags 0: queued behind a current owner, and without ALLOW_REPLACEMENT nobody can take it from the bridge.
            g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                   g_variant_new("(su)", kPrompterName, 0u), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr,
                                   onNameReply, call);
        } else {
            g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                                   g_variant_new("(s)", kPrompterName), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr,
                                   onNameReply, call);
            setNameState(QStringLiteral("released"));
        }
    }

    void Bridge::onNameReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<NameCall*>(data);
        GError*   error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (!reply)
            log(QStringLiteral("name request failed: %1").arg(QString::fromUtf8(error ? error->message : "")));
        if (reply)
            g_variant_unref(reply);
        g_clear_error(&error);
        if (call->generation == call->bridge->m_nameGen)
            call->bridge->refreshName();
        delete call;
    }

    void Bridge::onNameSignal(GDBusConnection* /*bus*/, const gchar* /*sender*/, const gchar* /*path*/, const gchar* /*iface*/, const gchar* /*signal*/,
                              GVariant* /*parameters*/, gpointer self) {
        static_cast<Bridge*>(self)->refreshName();
    }

    // Asks the bus who owns the name now: the state follows the answer, whatever order the events came in.
    void Bridge::refreshName() {
        auto* call = new NameCall{this, m_nameGen};
        g_dbus_connection_call(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                               g_variant_new("(s)", kPrompterName), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, onOwnerReply, call);
    }

    void Bridge::onOwnerReply(GObject* source, GAsyncResult* result, gpointer data) {
        auto*     call  = static_cast<NameCall*>(data);
        Bridge*   self  = call->bridge;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, nullptr);
        QString   owner;
        if (reply) {
            const gchar* name = nullptr;
            g_variant_get(reply, "(&s)", &name);
            owner = QString::fromUtf8(name);
            g_variant_unref(reply);
        }
        const bool current = call->generation == self->m_nameGen;
        delete call;
        if (!current)
            return;
        const bool mine = !owner.isEmpty() && owner == QString::fromUtf8(g_dbus_connection_get_unique_name(self->m_bus));
        if (!self->m_nameWanted) {
            if (mine) // the bridge holds a name it no longer wants (a late answer to an earlier request): let it go
                g_dbus_connection_call(self->m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ReleaseName",
                                       g_variant_new("(s)", kPrompterName), G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, nullptr,
                                       nullptr);
            self->setNameState(QStringLiteral("released"));
            return;
        }
        self->setNameState(mine ? QStringLiteral("owned") : QStringLiteral("queued"), owner);
    }

    void Bridge::setNameState(const QString& state, const QString& owner) {
        if (state == m_nameState)
            return;
        m_nameState = state;
        if (state == QLatin1String("queued") && !owner.isEmpty()) {
            // Who holds it, for the journal: the stock gcr-prompter for 10 s after its last prompt, or anything else.
            auto* call = new CredentialsCall{this, owner, nullptr};
            g_dbus_connection_call_with_unix_fd_list(m_bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                                     "GetConnectionCredentials", g_variant_new("(s)", owner.toUtf8().constData()),
                                                     G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, kBusTimeoutMs, nullptr, nullptr, onOwnerCredentials,
                                                     call);
        } else {
            log(QStringLiteral("%1 %2").arg(QLatin1String(kPrompterName), state));
        }
        if (m_ready)
            send(nameMessage(state));
    }

    void Bridge::onOwnerCredentials(GObject* source, GAsyncResult* result, gpointer data) {
        auto*        call  = static_cast<CredentialsCall*>(data);
        GUnixFDList* fds   = nullptr;
        GVariant*    reply = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), &fds, result, nullptr);
        QString      exe;
        if (reply) {
            GVariant* dict   = g_variant_get_child_value(reply, 0);
            gint32    handle = -1;
            if (g_variant_lookup(dict, "ProcessFD", "h", &handle) && fds && handle >= 0 && handle < g_unix_fd_list_get_length(fds)) {
                const int pidfd = g_unix_fd_list_get(fds, handle, nullptr);
                if (pidfd >= 0) {
                    exe = exeFactsOfPidfd(pidfd, false).path; // the executable only: a journal line needs no more
                    ::close(pidfd);
                }
            }
            g_variant_unref(dict);
            g_variant_unref(reply);
        }
        g_clear_object(&fds);
        log(QStringLiteral("%1 is held by %2 (%3): queued behind it")
                .arg(QLatin1String(kPrompterName), call->id, exe.isEmpty() ? QStringLiteral("executable unknown") : flatten(exe, caps::kPath)));
        delete call;
    }

} // namespace gf::prompter
