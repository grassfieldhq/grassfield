#include "screenshotlogic.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QUrl>

namespace screenshot {

QStringList clipboardArguments()
{
    return {QStringLiteral("wl-copy"), QStringLiteral("--type"), QStringLiteral("image/png"), QStringLiteral("--sensitive")};
}

QStringList clipboardTypesArguments()
{
    return {QStringLiteral("wl-paste"), QStringLiteral("--list-types")};
}

QStringList clipboardPasteArguments()
{
    return {QStringLiteral("wl-paste"), QStringLiteral("--no-newline"), QStringLiteral("--type"), QStringLiteral("image/png")};
}

QStringList clipboardClearArguments()
{
    return {QStringLiteral("wl-copy"), QStringLiteral("--clear")};
}

QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error)
{
    const auto fail = [error](const QString &message) {
        if (error)
            *error = message;
        return QString();
    };
    if (arg.trimmed().isEmpty())
        return fail(QStringLiteral("empty argument"));
    // Something that looks like "scheme:" and is not an existing relative file name is a URL.
    static const QRegularExpression scheme(QStringLiteral("^[A-Za-z][A-Za-z0-9+.-]+:"));
    const bool urlLike = scheme.match(arg).hasMatch() && !QFileInfo::exists(QDir(cwd).absoluteFilePath(arg));
    if (urlLike) {
        const QUrl url(arg, QUrl::StrictMode);
        if (!url.isValid() || url.scheme().toLower() != QLatin1String("file"))
            return fail(QStringLiteral("only local files are supported: %1").arg(arg));
        if (!url.host().isEmpty() && url.host() != QLatin1String("localhost"))
            return fail(QStringLiteral("remote file hosts are not supported: %1").arg(arg));
        if (url.hasQuery() || url.hasFragment())
            return fail(QStringLiteral("not a plain file URL: %1").arg(arg));
        const QString local = url.host().isEmpty() ? url.toLocalFile() : url.path();
        return local.isEmpty() ? fail(QStringLiteral("not a local file: %1").arg(arg)) : QDir::cleanPath(local);
    }
    return QDir::cleanPath(QDir(cwd).absoluteFilePath(arg));
}

bool isSystemPath(const QString &canonical)
{
    for (const char *root : {"/proc", "/sys", "/dev"}) {
        const QString r = QString::fromLatin1(root);
        if (canonical == r || canonical.startsWith(r + QLatin1Char('/')))
            return true;
    }
    return false;
}

bool imageSizeAllowed(const QSize &size)
{
    if (!size.isValid() || size.width() <= 0 || size.height() <= 0)
        return false;
    if (size.width() > kMaxImageSide || size.height() > kMaxImageSide)
        return false;
    return qint64(size.width()) * size.height() * 4 <= kMaxImageBytes;
}

QSize pngSize(const QByteArray &head)
{
    static const QByteArray signature("\x89PNG\r\n\x1a\n", 8);
    // 8 bytes of signature, then the IHDR chunk: length (4), "IHDR" (4), width (4), height (4).
    if (head.size() < 24 || !head.startsWith(signature) || head.mid(12, 4) != "IHDR")
        return {};
    const auto be32 = [&head](int at) {
        return (quint32(quint8(head[at])) << 24) | (quint32(quint8(head[at + 1])) << 16) | (quint32(quint8(head[at + 2])) << 8)
            | quint32(quint8(head[at + 3]));
    };
    const quint32 w = be32(16);
    const quint32 h = be32(20);
    if (w == 0 || h == 0 || w > 0x7fffffffu || h > 0x7fffffffu)
        return {};
    return QSize(int(w), int(h));
}

Arguments resolveArguments(const QStringList &args, const QString &cwd)
{
    Arguments out;
    if (args.isEmpty()) {
        out.errors << QStringLiteral("no file to edit");
        return out;
    }
    if (args.size() > 1) {
        out.errors << QStringLiteral("one file at a time (got %1)").arg(args.size());
        return out;
    }
    QString why;
    const QString path = localPathFromArgument(args.constFirst(), cwd, &why);
    if (path.isEmpty()) {
        out.errors << why;
        return out;
    }
    const QFileInfo info(path);
    const QString canonical = info.canonicalFilePath(); // empty when the file does not exist (a dangling link included)
    if (canonical.isEmpty()) {
        out.errors << QStringLiteral("no such file: %1").arg(path);
        return out;
    }
    if (isSystemPath(canonical)) {
        out.errors << QStringLiteral("not a user file: %1").arg(path);
        return out;
    }
    const QFileInfo real(canonical);
    if (!real.isFile()) { // rejects directories, devices, FIFOs and sockets
        out.errors << QStringLiteral("not a regular file: %1").arg(path);
        return out;
    }
    if (real.size() > kMaxImageBytes) {
        out.errors << QStringLiteral("file too large: %1").arg(path);
        return out;
    }
    QFile file(canonical);
    if (!file.open(QIODevice::ReadOnly)) {
        out.errors << QStringLiteral("cannot read: %1").arg(path);
        return out;
    }
    const QSize size = pngSize(file.read(32));
    if (!size.isValid()) {
        out.errors << QStringLiteral("not a PNG picture: %1").arg(path);
        return out;
    }
    if (!imageSizeAllowed(size)) {
        out.errors << QStringLiteral("picture too large: %1").arg(path);
        return out;
    }
    out.path = canonical;
    return out;
}

QStringList openToolbarArguments(const QStringList &shellIpc)
{
    if (shellIpc.isEmpty())
        return {};
    return shellIpc + QStringList{QStringLiteral("capture"), QStringLiteral("toggle")};
}

int openToolbar(const QStringList &shellIpc, const std::function<bool(const QStringList &)> &run, QString *error)
{
    const QStringList args = openToolbarArguments(shellIpc);
    if (args.isEmpty()) {
        if (error)
            *error = QStringLiteral("no file to edit, and no running shell to open the capture toolbar");
        return 2;
    }
    if (!run(args)) {
        if (error)
            *error = QStringLiteral("no file to edit, and the shell did not open the capture toolbar");
        return 2;
    }
    return 0;
}

} // namespace screenshot
