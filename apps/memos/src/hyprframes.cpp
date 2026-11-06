#include "hyprframes.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace memos {

QString memoTag(const QString &id, bool hasPosition, int x, int y)
{
    QString tag = QStringLiteral("memo:") + id;
    if (hasPosition)
        tag += QStringLiteral("@%1,%2").arg(x).arg(y);
    return tag;
}

QString memoIdOfTag(const QString &tag)
{
    static const QRegularExpression re(QStringLiteral("^memo:([0-9a-f]{32})(?:@-?\\d+,-?\\d+)?(?:!\\d+x\\d+)?$"));
    const QRegularExpressionMatch m = re.match(tag);
    return m.hasMatch() ? m.captured(1) : QString();
}

QHash<QString, Frame> parseClientFrames(const QByteArray &json, qint64 pid)
{
    QHash<QString, Frame> frames;
    const QJsonDocument doc = QJsonDocument::fromJson(json);
    if (!doc.isArray())
        return frames;
    for (const QJsonValue &v : doc.array()) {
        const QJsonObject o = v.toObject();
        if (o.value(QStringLiteral("pid")).toInteger(-1) != pid)
            continue;
        const QString id = memoIdOfTag(o.value(QStringLiteral("xdgTag")).toString());
        const QJsonArray at = o.value(QStringLiteral("at")).toArray();
        const QJsonArray size = o.value(QStringLiteral("size")).toArray();
        if (id.isEmpty() || at.size() != 2 || size.size() != 2 || !at[0].isDouble() || !at[1].isDouble() || !size[0].isDouble()
            || !size[1].isDouble())
            continue;
        // A hidden window (minimized by the plugin, or a special workspace) still has its last frame.
        frames.insert(id, Frame{at[0].toInt(), at[1].toInt(), size[0].toInt(), size[1].toInt()});
    }
    return frames;
}

QString hyprlandSocketPath(const QString &runtimeDir, const QString &signature)
{
    static const QRegularExpression plain(QStringLiteral("^[A-Za-z0-9_]+$"));
    if (!plain.match(signature).hasMatch())
        return {};
    QString dir = runtimeDir.isEmpty() ? QString() : runtimeDir + QStringLiteral("/hypr/") + signature;
    if (dir.isEmpty() || !QFileInfo(dir).isDir())
        dir = QStringLiteral("/tmp/hypr/") + signature; // Hyprland's own fallback (as Quickshell's)
    return dir + QStringLiteral("/.socket.sock");
}

QString hyprlandSocketPath()
{
    return hyprlandSocketPath(qEnvironmentVariable("XDG_RUNTIME_DIR"), qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE"));
}

QByteArray hyprlandRequest(const QString &socketPath, const QByteArray &request, int timeoutMs)
{
    const QByteArray path = QFile::encodeName(socketPath);
    sockaddr_un addr{};
    if (path.isEmpty() || size_t(path.size()) >= sizeof(addr.sun_path))
        return {};
    const int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return {};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.constData(), size_t(path.size()));
    timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    QByteArray answer;
    if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0
        && ::send(fd, request.constData(), size_t(request.size()), MSG_NOSIGNAL) == request.size()) {
        constexpr qsizetype kMax = 4 * 1024 * 1024;
        char buf[16384];
        for (;;) {
            pollfd p{fd, POLLIN, 0};
            if (::poll(&p, 1, timeoutMs) <= 0) {
                answer.clear(); // a stalled compositor: no half answer
                break;
            }
            const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            answer.append(buf, n);
            if (answer.size() > kMax) {
                answer.clear();
                break;
            }
        }
    }
    ::close(fd);
    return answer;
}

QHash<QString, Frame> currentFrames()
{
    const QString socket = hyprlandSocketPath();
    if (socket.isEmpty())
        return {};
    return parseClientFrames(hyprlandRequest(socket, QByteArrayLiteral("j/clients")), QCoreApplication::applicationPid());
}

} // namespace memos
