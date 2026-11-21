// grassfield-stack-helper (ADR-0025): ONE process per folder kept in the Dock as a stack. It lists the folder, keeps the window of
// its first K entries in the stack's order, watches the folder with inotify, and writes the window to stdout when it changed.
//
//   grassfield-stack-helper <absolute folder | file: URI> <sort> <K> [<low>]
//   (a file: URI's escapes are bytes: a folder whose name is not UTF-8, as a window's \xHH names it)
//   sort: name | dateAdded | dateModified | dateCreated | kind
//
// stdout, one line each (fields separated by US, 0x1f; names escaped byte for byte, see StackLogic::escapeName):
//   A                                    the watch is armed (at the start, and again when the folder came back)
//   G                                    the folder is gone, moved, unmounted or cannot be watched (retried: 2 s up to 15 s)
//   W US seq US total US n { US name US isDir US modified US added US created }
//                                        the window: the first n entries in the order, `total` the entries of the folder (exact
//                                        after a scan, an estimate between scans, never decided on); only when it changed, at most
//                                        ten a second, and never while it may be wrong or short (the previous one stays on show)
// stdin, lines: "K <n> [<low>]" (the window size: 30 for the pile, 300 for an open popup; `low`: with entries outside the window, a
// scan is asked for only when fewer than this many are left, the entries between being the margin that removals use up), "SORT
// <sort>", "RELIST", "QUIT". End of stdin ends the helper.
//
// The watching is helper.h/.cpp (Helper), tested against a real folder; this file wires stdin and stdout. Runs at a lower priority
// than the shell and dies with it (PR_SET_PDEATHSIG).
#include "helper.h"

#include <QCoreApplication>
#include <QSocketNotifier>

#include <csignal>
#include <cstdio>

#include <fcntl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

using namespace StackLogic;

namespace
{
// stdin: lines of commands, read as they come
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
        char chunk[4096];
        for (;;) {
            const ssize_t n = ::read(0, chunk, sizeof chunk);
            if (n == 0) {
                QCoreApplication::quit(); // the shell closed our stdin
                return;
            }
            if (n < 0)
                return;
            m_buffer.append(chunk, int(n));
            int at;
            while ((at = m_buffer.indexOf('\n')) >= 0) {
                const QByteArray line = m_buffer.left(at);
                m_buffer.remove(0, at + 1);
                if (line.trimmed() == "QUIT")
                    QCoreApplication::quit();
                else
                    m_helper->command(line);
            }
            if (m_buffer.size() > 4096)
                m_buffer.clear();
        }
    }

    Helper *m_helper;
    QSocketNotifier *m_notifier;
    QByteArray m_buffer;
};
} // namespace

int main(int argc, char **argv)
{
    const QByteArray folder = argc == 4 || argc == 5 ? StackLogic::folderArgument(QByteArray(argv[1])) : QByteArray();
    if (folder.isEmpty()) {
        std::fprintf(stderr, "usage: grassfield-stack-helper <absolute folder | file: URI> <name|dateAdded|dateModified|dateCreated|kind> <K> [<low>]\n");
        return 2;
    }
    // dies with the shell, and runs behind it
    ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (::getppid() == 1)
        return 0;
    ::setpriority(PRIO_PROCESS, 0, 10);
    ::signal(SIGPIPE, SIG_IGN);
    QCoreApplication app(argc, argv);
    Sort sort;
    if (!parseSort(QString::fromUtf8(argv[2]), &sort)) {
        std::fprintf(stderr, "grassfield-stack-helper: unknown order %s\n", argv[2]);
        return 2;
    }
    const int limit = qBound(1, QByteArray(argv[3]).toInt(), Helper::kMaxLimit);
    const int low = argc == 5 ? qMax(0, QByteArray(argv[4]).toInt()) : 0;
    Helper helper{folder, sort, limit, low, [](const QByteArray &bytes) {
                      if (std::fwrite(bytes.constData(), 1, size_t(bytes.size()), stdout) != size_t(bytes.size()) || std::fflush(stdout) != 0)
                          _exit(0); // the reader is gone
                  }};
    Commands commands(&helper);
    return app.exec();
}
