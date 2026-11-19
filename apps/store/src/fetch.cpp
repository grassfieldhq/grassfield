#include "fetch.h"

#include "channel.h"

#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QList>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>
#include <QTimer>

namespace grassfield::store {

namespace {
thread_local std::shared_ptr<const std::atomic_bool> t_cancel;
constexpr int kCancelPollMs = 100;
}

FetchCancelScope::FetchCancelScope(std::shared_ptr<const std::atomic_bool> cancel)
    : m_previous(std::move(t_cancel))
{
    t_cancel = std::move(cancel);
}

FetchCancelScope::~FetchCancelScope()
{
    t_cancel = std::move(m_previous);
}

bool fetchCancelled()
{
    return t_cancel && t_cancel->load();
}

QNetworkRequest storeRequest(const QUrl &url, const FetchLimits &limits, const QByteArray &etag)
{
    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", "Grassfield-Store/1");
    request.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setAttribute(QNetworkRequest::CacheSaveControlAttribute, false);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::UserVerifiedRedirectPolicy);
    request.setMaximumRedirectsAllowed(5);
    request.setTransferTimeout(limits.timeoutMs);
    if (!etag.isEmpty())
        request.setRawHeader("If-None-Match", etag);
    return request;
}

FetchResult fetch(const QUrl &url, const FetchLimits &limits, const QByteArray &etag, bool devPlumbing)
{
    FetchResult result;
    if (!requestAllowed(url, devPlumbing)) {
        result.status = FetchResult::Status::Refused;
        result.error = QStringLiteral("not an https URL");
        return result;
    }
    if (fetchCancelled()) {
        result.error = QStringLiteral("cancelled");
        return result;
    }
    QNetworkAccessManager manager;
    manager.setCookieJar(nullptr); // QNetworkAccessManager then keeps no cookie at all
    manager.setRedirectPolicy(QNetworkRequest::UserVerifiedRedirectPolicy);
    QNetworkReply *reply = manager.get(storeRequest(url, limits, etag));
    QEventLoop loop;
    QByteArray body;
    bool tooLarge = false, refused = false;
    QObject::connect(reply, &QNetworkReply::redirected, reply, [&](const QUrl &to) {
        if (requestAllowed(to, false)) {
            emit reply->redirectAllowed();
        } else {
            refused = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::metaDataChanged, reply, [&] {
        const QVariant length = reply->header(QNetworkRequest::ContentLengthHeader);
        if (length.isValid() && length.toLongLong() > limits.maxBytes) {
            tooLarge = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [&] {
        body += reply->read(limits.maxBytes + 1 - body.size());
        if (body.size() > limits.maxBytes) {
            tooLarge = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    // A guard beside the transfer timeout: the whole exchange never outlives twice its limit. A timer of this call's own,
    // gone with it: a pending QTimer::singleShot outlived the call in a thread whose loop never ran again (LSan).
    QTimer guard;
    guard.setSingleShot(true);
    QObject::connect(&guard, &QTimer::timeout, reply, [reply] { reply->abort(); });
    guard.start(2 * limits.timeoutMs);
    // The worker's cancel flag (FetchCancelScope), looked at ten times a second.
    QTimer cancelPoll;
    bool cancelled = false;
    QObject::connect(&cancelPoll, &QTimer::timeout, reply, [reply, &cancelled] {
        if (fetchCancelled()) {
            cancelled = true;
            reply->abort();
        }
    });
    if (t_cancel)
        cancelPoll.start(kCancelPollMs);
    if (!reply->isFinished())
        loop.exec();
    cancelPoll.stop();
    if (!tooLarge && !refused)
        body += reply->read(limits.maxBytes + 1 - body.size());
    if (body.size() > limits.maxBytes)
        tooLarge = true;

    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (cancelled) {
        result.status = FetchResult::Status::Failed;
        result.error = QStringLiteral("cancelled");
    } else if (refused) {
        result.status = FetchResult::Status::Refused;
        result.error = QStringLiteral("redirected to a URL that is not https");
    } else if (tooLarge) {
        result.status = FetchResult::Status::TooLarge;
        result.error = QStringLiteral("larger than %1 bytes").arg(limits.maxBytes);
    } else if (code == 304) {
        result.status = FetchResult::Status::NotModified;
    } else if (reply->error() != QNetworkReply::NoError || (url.scheme() == QLatin1String("https") && code != 200)) {
        result.status = FetchResult::Status::Failed;
        result.error = code ? QStringLiteral("HTTP %1").arg(code) : reply->errorString();
    } else {
        result.status = FetchResult::Status::Ok;
        result.body = body;
        result.etag = reply->rawHeader("ETag").left(512);
    }
    reply->deleteLater();
    return result;
}

QList<int> headStatuses(const QList<QUrl> &urls, int timeoutMs, int deadlineMs, bool devPlumbing)
{
    QList<int> out(urls.size(), 0);
    bool gone = false;
    const auto isGone = [](int status) { return status == 404 || status == 410; };
    // One manager for all: it keeps its connections open between requests and runs several to a host at once.
    QNetworkAccessManager manager;
    manager.setCookieJar(nullptr);
    manager.setRedirectPolicy(QNetworkRequest::UserVerifiedRedirectPolicy);
    QEventLoop loop;
    QList<QNetworkReply *> replies;
    qsizetype pending = 0;
    for (qsizetype i = 0; i < urls.size() && !gone; ++i) {
        const QUrl &url = urls.at(i);
        if (!requestAllowed(url, devPlumbing)) {
            out[i] = -1;
            continue;
        }
        if (url.isLocalFile()) {
            out[i] = QFileInfo(url.toLocalFile()).isFile() ? 200 : 404;
            gone = isGone(out.at(i));
            continue;
        }
        QNetworkReply *reply = manager.head(storeRequest(url, FetchLimits{0, timeoutMs}));
        replies.append(reply);
        ++pending;
        QObject::connect(reply, &QNetworkReply::redirected, reply, [reply, &out, i](const QUrl &to) {
            if (requestAllowed(to, false)) {
                emit reply->redirectAllowed();
            } else {
                out[i] = -1;
                reply->abort();
            }
        });
        QObject::connect(reply, &QNetworkReply::finished, &loop, [reply, &out, &gone, &pending, &loop, &isGone, i] {
            if (out.at(i) != -1)
                out[i] = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            gone = gone || isGone(out.at(i));
            if (--pending == 0 || gone)
                loop.quit();
        });
    }
    if (pending > 0 && !gone) {
        QTimer deadline; // the whole set's
        deadline.setSingleShot(true);
        QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
        deadline.start(deadlineMs);
        QTimer cancelPoll;
        QObject::connect(&cancelPoll, &QTimer::timeout, &loop, [&loop] {
            if (fetchCancelled())
                loop.quit();
        });
        if (t_cancel)
            cancelPoll.start(kCancelPollMs);
        loop.exec();
    }
    // What has not answered by now (the deadline, or one file already gone) is dropped: 0.
    for (QNetworkReply *reply : std::as_const(replies)) {
        QObject::disconnect(reply, nullptr, nullptr, nullptr);
        if (!reply->isFinished())
            reply->abort();
    }
    return out;
}

bool downloadTo(const QUrl &url, const QString &file, const FetchLimits &limits, bool devPlumbing)
{
    QFile::remove(file);
    const FetchResult r = fetch(url, limits, {}, devPlumbing);
    if (r.status != FetchResult::Status::Ok)
        return false;
    QSaveFile out(file);
    return out.open(QIODevice::WriteOnly) && out.write(r.body) == r.body.size() && out.commit();
}

} // namespace grassfield::store
