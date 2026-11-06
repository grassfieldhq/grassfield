// Where the memo windows are (ADR-0051 D-6): the tag a memo window sends and reads back, Hyprland's `j/clients` answer
// filtered on this process and its memo tags, the socket path, and a request to a fake socket.
#include "hyprframes.h"
#include "memostore.h"

#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

using namespace memos;

TEST(HyprFrames, TagCarriesIdAndPosition)
{
    const QString id = newId();
    EXPECT_EQ(memoTag(id, false, 0, 0), QStringLiteral("memo:") + id);
    EXPECT_EQ(memoTag(id, true, -12, 340), QStringLiteral("memo:") + id + QStringLiteral("@-12,340"));
    EXPECT_EQ(memoTag(id, true, 5, 6), QStringLiteral("memo:") + id + QStringLiteral("@5,6"));
    for (const QString &tag : {memoTag(id, false, 0, 0), memoTag(id, true, -1, -2), memoTag(id, true, 1, 2)})
        EXPECT_EQ(memoIdOfTag(tag), id) << qPrintable(tag);
    // Float on Top's suffix is not a tag of ours any more (ADR-0051 D-6): nothing reads ":top".
    EXPECT_EQ(memoIdOfTag(QStringLiteral("memo:") + id + QStringLiteral(":top")), QString());
    EXPECT_EQ(memoIdOfTag(QStringLiteral("browser")), QString());
    EXPECT_EQ(memoIdOfTag(QStringLiteral("memo:") + id.left(31)), QString());
    EXPECT_EQ(memoIdOfTag(QStringLiteral("memo:") + id + QStringLiteral(":bottom")), QString());
    EXPECT_EQ(memoIdOfTag(QStringLiteral("memo:") + id + QStringLiteral("@1,2x")), QString());
}

TEST(HyprFrames, OnlyThisProcessesMemoWindowsAreKept)
{
    const QString a = newId();
    const QString b = newId();
    const QByteArray json = QStringLiteral(
                                "[{\"pid\": 42, \"xdgTag\": \"memo:%1@1,2\", \"at\": [100, 200], \"size\": [240, 180]},"
                                " {\"pid\": 42, \"xdgTag\": \"memo:%2\", \"at\": [-50, 30], \"size\": [300, 16]},"
                                " {\"pid\": 43, \"xdgTag\": \"memo:%1\", \"at\": [9, 9], \"size\": [9, 9]},"
                                " {\"pid\": 42, \"xdgTag\": \"browser\", \"at\": [0, 0], \"size\": [800, 600]},"
                                " {\"pid\": 42, \"xdgTag\": \"memo:%1\", \"at\": [1], \"size\": [1, 1]},"
                                " 7]")
                                .arg(a, b)
                                .toUtf8();
    const QHash<QString, Frame> frames = parseClientFrames(json, 42);
    ASSERT_EQ(frames.size(), 2);
    EXPECT_EQ(frames.value(a).x, 100);
    EXPECT_EQ(frames.value(a).y, 200);
    EXPECT_EQ(frames.value(a).width, 240);
    EXPECT_EQ(frames.value(b).x, -50);
    EXPECT_EQ(frames.value(b).height, 16);
    EXPECT_TRUE(parseClientFrames(QByteArrayLiteral("{}"), 42).isEmpty());
    EXPECT_TRUE(parseClientFrames(QByteArrayLiteral("not json"), 42).isEmpty());
    EXPECT_TRUE(parseClientFrames(QByteArray(), 42).isEmpty());
}

TEST(HyprFrames, SocketPathNeedsAPlainSignature)
{
    QTemporaryDir run;
    QDir(run.path()).mkpath(QStringLiteral("hypr/abc_123"));
    EXPECT_EQ(hyprlandSocketPath(run.path(), QStringLiteral("abc_123")), run.path() + QStringLiteral("/hypr/abc_123/.socket.sock"));
    EXPECT_EQ(hyprlandSocketPath(run.path(), QStringLiteral("other")), QStringLiteral("/tmp/hypr/other/.socket.sock"));
    EXPECT_EQ(hyprlandSocketPath(run.path(), QString()), QString());
    EXPECT_EQ(hyprlandSocketPath(run.path(), QStringLiteral("../x")), QString());
    EXPECT_EQ(hyprlandSocketPath(run.path(), QStringLiteral("a/b")), QString());
}

TEST(HyprFrames, RequestReadsTheWholeAnswerAndGivesUpOnSilence)
{
    QTemporaryDir tmp;
    const QByteArray path = (tmp.path() + QStringLiteral("/.socket.sock")).toUtf8();
    const int server = ::socket(AF_UNIX, SOCK_STREAM, 0);
    ASSERT_GE(server, 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.constData(), size_t(path.size()));
    ASSERT_EQ(::bind(server, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)), 0);
    ASSERT_EQ(::listen(server, 2), 0);
    QByteArray received;
    const QByteArray answer(40000, 'x'); // more than one read
    std::thread peer([&] {
        int c = ::accept(server, nullptr, nullptr);
        char buf[64];
        const ssize_t n = ::recv(c, buf, sizeof(buf), 0);
        received = QByteArray(buf, int(n));
        ::send(c, answer.constData(), size_t(answer.size()), 0);
        ::close(c);
        // The second client: never answered, held open past the timeout.
        c = ::accept(server, nullptr, nullptr);
        ::usleep(400 * 1000);
        ::close(c);
    });
    EXPECT_EQ(hyprlandRequest(QString::fromUtf8(path), QByteArrayLiteral("j/clients")), answer);
    EXPECT_EQ(received, QByteArrayLiteral("j/clients"));
    EXPECT_EQ(hyprlandRequest(QString::fromUtf8(path), QByteArrayLiteral("j/clients"), 100), QByteArray());
    peer.join();
    ::close(server);
    // No socket at all.
    EXPECT_EQ(hyprlandRequest(tmp.path() + QStringLiteral("/missing.sock"), QByteArrayLiteral("j/clients")), QByteArray());
}

TEST(HyprFrames, AStalledCompositorGivesNoHalfAnswer)
{
    // Part of the list, then silence past the timeout: nothing is kept (half a JSON list could still parse into a few frames
    // read as the whole answer).
    QTemporaryDir tmp;
    const QByteArray path = (tmp.path() + QStringLiteral("/.socket.sock")).toUtf8();
    const int server = ::socket(AF_UNIX, SOCK_STREAM, 0);
    ASSERT_GE(server, 0);
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.constData(), size_t(path.size()));
    ASSERT_EQ(::bind(server, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)), 0);
    ASSERT_EQ(::listen(server, 1), 0);
    std::thread peer([&] {
        const int c = ::accept(server, nullptr, nullptr);
        char buf[64];
        ::recv(c, buf, sizeof(buf), 0);
        const QByteArray half("[{\"pid\": 1, \"xdgTag\": \"memo:");
        ::send(c, half.constData(), size_t(half.size()), 0);
        ::usleep(400 * 1000);
        ::close(c);
    });
    EXPECT_EQ(hyprlandRequest(QString::fromUtf8(path), QByteArrayLiteral("j/clients"), 100), QByteArray());
    peer.join();
    ::close(server);
}

TEST(HyprFrames, NoSocketGivesNothing)
{
    QTemporaryDir tmp;
    EXPECT_EQ(hyprlandRequest(tmp.path() + QStringLiteral("/missing.sock"), QByteArrayLiteral("j/clients")), QByteArray());
}
