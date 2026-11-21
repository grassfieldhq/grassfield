// Every request of the Store (ADR-0037 c "What is fetched"): https only, redirects included (at most 5, each checked);
// file:// only through dev plumbing; no cookie, no Referer, the User-Agent Grassfield-Store/1, no HTTP cache; a transfer
// timeout and a size cap (a body over the cap is dropped, never truncated and used). Blocking: the app runs it on a worker
// thread (each call has its own QNetworkAccessManager and event loop).
#pragma once

#include <QByteArray>
#include <QList>
#include <QNetworkRequest>
#include <QString>
#include <QUrl>

#include <atomic>
#include <memory>

namespace grassfield::store {

// A worker's cancel flag for every fetch it runs (SU-07): while a FetchCancelScope lives on a thread, fetch, headStatuses and
// downloadTo on that thread abort their transfer within a tenth of a second once the flag is set (Failed, "cancelled"), so a
// Store that quits never waits for a 120 s download to end.
class FetchCancelScope
{
public:
    explicit FetchCancelScope(std::shared_ptr<const std::atomic_bool> cancel);
    ~FetchCancelScope();
    FetchCancelScope(const FetchCancelScope &) = delete;
    FetchCancelScope &operator=(const FetchCancelScope &) = delete;

private:
    std::shared_ptr<const std::atomic_bool> m_previous;
};
// The flag of the scope this thread is in, set: its fetches stop.
bool fetchCancelled();

struct FetchLimits {
    qint64 maxBytes = 1024 * 1024;
    int timeoutMs = 15000;
};

struct FetchResult {
    enum class Status { Ok, NotModified, Refused, TooLarge, Failed };
    Status status = Status::Failed;
    QByteArray body;
    QByteArray etag;
    QString error;
};

// The request every fetch sends: no cookie loaded or saved, no Referer, the User-Agent Grassfield-Store/1, no HTTP cache,
// redirects only as fetch verifies them (requestAllowed, at most 5), the transfer timeout, If-None-Match when given.
QNetworkRequest storeRequest(const QUrl &url, const FetchLimits &limits, const QByteArray &etag = {});

// devPlumbing: the URL came from GRASSFIELD_STORE_CATALOG_URL in a dev session (file:// allowed then).
FetchResult fetch(const QUrl &url, const FetchLimits &limits, const QByteArray &etag = {}, bool devPlumbing = false);

// HEAD requests for a plan's files (ADR-0037 e.4 and S5), all at once on one QNetworkAccessManager (it keeps its
// connections and runs several to a host), within `deadlineMs` for the whole set: each URL's HTTP status after the
// redirects fetch allows, in order; 0 for one with no answer by the deadline, -1 for one the Store does not request (not
// https). Once one answers 404 or 410 the others still running are dropped (0): that answer is enough. Through dev
// plumbing a file:// URL answers 200 when the file exists, else 404.
QList<int> headStatuses(const QList<QUrl> &urls, int timeoutMs, int deadlineMs, bool devPlumbing = false);

// The same request saved to `file`, written whole and then renamed into place; on any failure nothing is left there (the
// AppStream package file and its signature, appstreamsource.h).
bool downloadTo(const QUrl &url, const QString &file, const FetchLimits &limits, bool devPlumbing = false);

} // namespace grassfield::store
