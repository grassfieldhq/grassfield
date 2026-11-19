// grassfield-clipboard-helper (ADR-0034): the clipboard history's capture and store, ONE process per shell, started by
// shell/services/Clipboard.qml while the history is on.
//
//   grassfield-clipboard-helper --display <absolute socket> --state <dir> --runtime <dir> [--retention <ms>] [--history-store 0|1]
//   grassfield-clipboard-helper --clear-pinned --state <dir>          deletes the pinned store (the history being off), then exits
//   grassfield-clipboard-helper --clear-history --state <dir>         deletes the history store (the history being off), then exits
//   grassfield-clipboard-helper --apply-clears --state <dir> [--cleared-at <ms>] [--pinned-cleared-at <ms>]
//                                      carries out the settings' clears not carried out yet (the history being off), then exits
//   grassfield-clipboard-helper --thumbnail <png|jpeg|webp> <max px>  the image worker: one image on stdin, a PNG on stdout
//
// The display is only ever the socket named by --display: WAYLAND_DISPLAY and WAYLAND_SOCKET are removed from the environment
// first and never read (libwayland's own lookup takes WAYLAND_SOCKET first, whatever name it is given).
//
// stdout, one line each, fields separated by US (0x1f), each escaped (backslash, line break, return, US: \\ \n \r \u):
//   S ok | S unsupported | S error <why>     the state (unsupported: exit 3; error: exit 1)
//   L 0|1                                   the compositor's lock state (hyprland_lock_notifier_v1)
//   O <seq> <kind>                          a copy to decide: the shell answers Y or N; nothing is read before Y
//   I <id> <kind> <mimes> <size> <copiedAt> <pinnedAt> <formatted> <files> <title> <excerpt> <thumbnail> <app>
//   X <id>                                  an item is gone (deleted, expired, pushed out, cleared)
//   A <id> | A                              the clipboard now holds that item | the request failed or another client took it
//   R <seq> <id>...                         the items matching a search, pinned first, newest first
//   N pin-full <id>                         the pinned items are full
//   N pin-failed <id>                       the pinned item could not be written: it stays in the history (B-09)
//   K <id>                                  the clipboard was cleared (or replaced by blank text) within a minute of that copy:
//                                           the shell removes it (X) when its application still runs (a password manager), B-10
//   V <id> <png path> <text>                a preview (an image's PNG, or the text, at most 64 KiB); both empty when none
// stdin, one line each, same fields: R | P (resume or pause capture), Y <seq> <app> | N <seq>, T <retention ms>, D 0|1 (the
// history store), E (expire now), CH (clear the history), CP (clear the pinned items), X <id>, PIN <id>, UNPIN <id>,
// C <id> 0|1 (copy; 1: plain text only), Q <seq> <query>, V <id>, VD <id>, QUIT. End of stdin ends the helper, as does the
// shell's end (PR_SET_PDEATHSIG) and a closed stdout, except while the helper serves the clipboard: it then keeps serving it
// until another client takes it (Helper::keepSelection), so the clipboard survives a shell restart.
// stdout is non-blocking: lines wait in a queue while the shell is busy (B-14), the helper never stops for it.
#include "helper.h"
#include "thumbnail.h"

#include <QCoreApplication>
#include <QFile>
#include <QSocketNotifier>

#include <functional>

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cerrno>
#include <cstring>

#include <fcntl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
int g_signalPipe[2] = {-1, -1};
pid_t g_parent = 0;

// The shell is gone: the helper ends, unless it keeps the clipboard it serves.
void shellGone(Helper *helper)
{
    if (!helper->keepSelection())
        QCoreApplication::exit(0);
}

// The lines for the shell: written without ever blocking the helper (a start replay of 150 items or a 64 KiB preview fill the
// pipe while the shell's thread is busy); what the pipe does not take waits, in order, for a write notifier.
class Output : public QObject
{
public:
    static constexpr qsizetype kMaxQueued = 64 * 1024 * 1024; // a shell that reads nothing for that long is gone

    explicit Output(std::function<void()> gone)
        : m_gone(std::move(gone))
    {
        ::fcntl(1, F_SETFL, ::fcntl(1, F_GETFL) | O_NONBLOCK);
        m_notifier = new QSocketNotifier(1, QSocketNotifier::Write, this);
        m_notifier->setEnabled(false);
        connect(m_notifier, &QSocketNotifier::activated, this, [this] { drain(); });
    }

    void write(const QByteArray &line)
    {
        if (m_closed)
            return;
        m_queue += line;
        if (m_queue.size() > kMaxQueued) {
            close();
            return;
        }
        drain();
    }

private:
    void drain()
    {
        while (m_written < m_queue.size()) {
            const ssize_t n = ::write(1, m_queue.constData() + m_written, size_t(m_queue.size() - m_written));
            if (n > 0) {
                m_written += n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN) {
                m_notifier->setEnabled(true);
                if (m_written > 1024 * 1024) { // compacted now and then, not on every partial write
                    m_queue.remove(0, m_written);
                    m_written = 0;
                }
                return;
            }
            close(); // the reader is gone (EPIPE)
            return;
        }
        m_queue.clear();
        m_written = 0;
        m_notifier->setEnabled(false);
    }

    void close()
    {
        m_closed = true;
        m_queue.clear();
        m_written = 0;
        m_notifier->setEnabled(false);
        QMetaObject::invokeMethod(this, [this] { m_gone(); }, Qt::QueuedConnection);
    }

    std::function<void()> m_gone;
    QSocketNotifier *m_notifier = nullptr;
    QByteArray m_queue;
    qsizetype m_written = 0;
    bool m_closed = false;
};

void onSignal(int)
{
    const char c = 1;
    [[maybe_unused]] const ssize_t n = ::write(g_signalPipe[1], &c, 1);
}

class Commands : public QObject
{
public:
    explicit Commands(Helper *helper)
        : m_helper(helper)
    {
        ::fcntl(0, F_SETFL, ::fcntl(0, F_GETFL) | O_NONBLOCK);
        m_notifier = new QSocketNotifier(0, QSocketNotifier::Read, this);
        connect(m_notifier, &QSocketNotifier::activated, this, [this] { readable(); });
    }

private:
    void readable()
    {
        char chunk[65536];
        for (;;) {
            const ssize_t n = ::read(0, chunk, sizeof chunk);
            if (n == 0) {
                m_notifier->setEnabled(false);
                shellGone(m_helper); // the shell closed our stdin
                return;
            }
            if (n < 0)
                return;
            m_buffer.append(chunk, int(n));
            qsizetype at;
            while ((at = m_buffer.indexOf('\n')) >= 0) {
                const QByteArray line = m_buffer.left(at);
                m_buffer.remove(0, at + 1);
                m_helper->command(line);
            }
            if (m_buffer.size() > 1024 * 1024)
                m_buffer.clear(); // no command is that long
        }
    }

    Helper *m_helper;
    QSocketNotifier *m_notifier;
    QByteArray m_buffer;
};

int usage()
{
    std::fprintf(stderr, "usage: grassfield-clipboard-helper --display <absolute socket> --state <dir> --runtime <dir> "
                         "[--retention <ms>] [--history-store 0|1]\n"
                         "       grassfield-clipboard-helper --clear-pinned --state <dir>\n"
                         "       grassfield-clipboard-helper --clear-history --state <dir>\n"
                         "       grassfield-clipboard-helper --apply-clears --state <dir> [--cleared-at <ms>] [--pinned-cleared-at <ms>]\n"
                         "       grassfield-clipboard-helper --thumbnail <png|jpeg|webp> <max px>\n");
    return 2;
}
} // namespace

int main(int argc, char **argv)
{
    // Before anything that could look at them: the display is only the one named on the command line.
    ::unsetenv("WAYLAND_SOCKET");
    ::unsetenv("WAYLAND_DISPLAY");
    ::umask(077);
    ::signal(SIGPIPE, SIG_IGN);

    if (argc == 4 && std::strcmp(argv[1], "--thumbnail") == 0) {
        QCoreApplication app(argc, argv);
        return Thumbnail::runWorker(QByteArray(argv[2]), QByteArray(argv[3]).toInt());
    }

    Helper::Options options;
    bool clearPinned = false;
    bool clearHistory = false;
    bool applyClears = false;
    // A clear time: digits only, 0 or more (the settings' milliseconds).
    const auto clearTime = [](const char *text, qint64 *out) {
        const QByteArray value(text);
        bool ok = !value.isEmpty() && std::all_of(value.cbegin(), value.cend(), [](char c) { return c >= '0' && c <= '9'; });
        *out = ok ? value.toLongLong(&ok) : -1;
        return ok;
    };
    for (int i = 1; i < argc; ++i) {
        const QByteArray arg(argv[i]);
        const bool hasValue = i + 1 < argc;
        if (arg == "--clear-pinned")
            clearPinned = true;
        else if (arg == "--clear-history")
            clearHistory = true;
        else if (arg == "--apply-clears")
            applyClears = true;
        else if (arg == "--cleared-at" && hasValue) {
            if (!clearTime(argv[++i], &options.clearedAtMs))
                return usage();
        } else if (arg == "--pinned-cleared-at" && hasValue) {
            if (!clearTime(argv[++i], &options.pinnedClearedAtMs))
                return usage();
        }
        else if (arg == "--display" && hasValue)
            options.display = QByteArray(argv[++i]);
        else if (arg == "--state" && hasValue)
            options.stateDir = QFile::decodeName(argv[++i]);
        else if (arg == "--runtime" && hasValue)
            options.runtimeDir = QFile::decodeName(argv[++i]);
        else if (arg == "--retention" && hasValue)
            options.retentionMs = QByteArray(argv[++i]).toLongLong();
        else if (arg == "--history-store" && hasValue)
            options.historyStore = QByteArray(argv[++i]) == "1";
        else
            return usage();
    }
    if (!options.stateDir.startsWith(QLatin1Char('/')))
        return usage();
    if (clearPinned)
        return Helper::clearPinned(options.stateDir);
    if (clearHistory)
        return Helper::clearHistoryStore(options.stateDir);
    if (applyClears) {
        Helper::applyClears(options.stateDir, options.clearedAtMs, options.pinnedClearedAtMs);
        return 0;
    }
    if (!options.runtimeDir.startsWith(QLatin1Char('/')))
        return usage();
    if (options.display.isEmpty() || options.display.at(0) != '/') {
        std::fprintf(stderr, "grassfield-clipboard-helper: --display needs an absolute socket path (there is no default)\n");
        return 2;
    }

    // told when the shell dies, and runs behind it
    g_parent = ::getppid();
    ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (::getppid() != g_parent || g_parent == 1)
        return 0;
    ::setpriority(PRIO_PROCESS, 0, 10);

    QCoreApplication app(argc, argv);
    options.program = QCoreApplication::applicationFilePath();

    if (::pipe2(g_signalPipe, O_CLOEXEC | O_NONBLOCK) != 0)
        return 1;
    ::signal(SIGTERM, onSignal);
    ::signal(SIGINT, onSignal);
    Helper *current = nullptr;
    QSocketNotifier signalNotifier(g_signalPipe[0], QSocketNotifier::Read);
    QObject::connect(&signalNotifier, &QSocketNotifier::activated, &app, [&current] {
        char drained[16];
        while (::read(g_signalPipe[0], drained, sizeof drained) > 0) {
        }
        // PR_SET_PDEATHSIG's SIGTERM: the shell died (the helper was reparented). Any other SIGTERM or SIGINT (a logout, a
        // stop) ends the helper.
        if (current && ::getppid() != g_parent && !current->keeping()) {
            shellGone(current);
            return;
        }
        QCoreApplication::exit(0);
    });

    Output output([&current] {
        if (current)
            shellGone(current);
    });
    Helper helper{options, [&output](const QByteArray &line) { output.write(line); }, [](int code) { QCoreApplication::exit(code); }};
    current = &helper;
    if (const int failed = helper.start()) {
        helper.cleanup();
        return failed;
    }
    helper.leaveShellUnit();
    Commands commands(&helper);
    const int code = app.exec();
    helper.cleanup();
    return code;
}
