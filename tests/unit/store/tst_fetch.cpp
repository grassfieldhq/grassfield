// The Store's requests (ADR-0037 c): https only, file:// only through dev plumbing, a size cap that drops (never
// truncates). The https path itself needs a server: its rules are requestAllowed's (tst_channel.cpp); here file:// in
// dev runs the same code with the caps.
#include "fetch.h"
#include "storetest.h"

#include <QFile>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkProxy>
#include <QProcess>
#include <QScopeGuard>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <QSslKey>
#include <QSslServer>
#include <QStandardPaths>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTimer>

#include <gtest/gtest.h>

#include <atomic>
#include <memory>

using namespace grassfield::store;

TEST(Fetch, RefusesWhatIsNotHttps)
{
    storetest::ensureApp();
    EXPECT_EQ(fetch(QUrl(QStringLiteral("http://example.org/x")), {}).status, FetchResult::Status::Refused);
    EXPECT_EQ(fetch(QUrl(QStringLiteral("file:///etc/hostname")), {}).status, FetchResult::Status::Refused);
    EXPECT_EQ(fetch(QUrl(QStringLiteral("ftp://example.org/x")), {}, {}, true).status, FetchResult::Status::Refused);
}

TEST(Fetch, TheRequest)
{
    const QNetworkRequest r = storeRequest(QUrl(QStringLiteral("https://example.org/x")), FetchLimits{1024, 7000}, "\"etag-1\"");
    EXPECT_EQ(r.rawHeader("User-Agent"), QByteArray("Grassfield-Store/1"));
    EXPECT_FALSE(r.hasRawHeader("Referer"));
    EXPECT_FALSE(r.hasRawHeader("Cookie"));
    EXPECT_EQ(r.rawHeader("If-None-Match"), QByteArray("\"etag-1\""));
    EXPECT_EQ(r.attribute(QNetworkRequest::CookieLoadControlAttribute).toInt(), int(QNetworkRequest::Manual));
    EXPECT_EQ(r.attribute(QNetworkRequest::CookieSaveControlAttribute).toInt(), int(QNetworkRequest::Manual));
    EXPECT_EQ(r.attribute(QNetworkRequest::CacheLoadControlAttribute).toInt(), int(QNetworkRequest::AlwaysNetwork));
    EXPECT_FALSE(r.attribute(QNetworkRequest::CacheSaveControlAttribute).toBool());
    EXPECT_EQ(r.attribute(QNetworkRequest::RedirectPolicyAttribute).toInt(), int(QNetworkRequest::UserVerifiedRedirectPolicy));
    EXPECT_EQ(r.maximumRedirectsAllowed(), 5);
    EXPECT_EQ(r.transferTimeout(), 7000);
    EXPECT_FALSE(storeRequest(QUrl(QStringLiteral("https://example.org/x")), {}).hasRawHeader("If-None-Match"));
}

// A real https server in the container of tests/integration/store_catalog.sh (STORE_TEST_HTTPS, its throwaway
// certificate trusted there): redirects, cookies and the size cap as the network does them.
TEST(Fetch, RealHttpsServer)
{
    const QString base = qEnvironmentVariable("STORE_TEST_HTTPS");
    if (base.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    storetest::ensureApp();
    auto get = [&](const QString &path, qint64 maxBytes = 1024 * 1024) {
        return fetch(QUrl(base + path), FetchLimits{maxBytes, 10000});
    };
    // A cookie set on the way is never sent back, nor a Referer; the User-Agent is the Store's.
    FetchResult r = get(QStringLiteral("/cookie"));
    ASSERT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    const QJsonObject headers = QJsonDocument::fromJson(r.body).object();
    EXPECT_FALSE(headers.contains(QStringLiteral("cookie"))) << r.body.toStdString();
    EXPECT_FALSE(headers.contains(QStringLiteral("referer"))) << r.body.toStdString();
    EXPECT_EQ(headers.value(QStringLiteral("user-agent")).toString(), QStringLiteral("Grassfield-Store/1"));
    // A redirect to http is refused; five redirects are followed, a sixth is not.
    EXPECT_EQ(get(QStringLiteral("/to-http")).status, FetchResult::Status::Refused);
    r = get(QStringLiteral("/chain/5"));
    EXPECT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    EXPECT_EQ(r.body, QByteArray("end"));
    EXPECT_EQ(get(QStringLiteral("/chain/6")).status, FetchResult::Status::Failed);
    // Over the cap: dropped, never truncated and used, whether the length is announced or not.
    r = get(QStringLiteral("/big"), 1000);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());
    r = get(QStringLiteral("/big-chunked"), 1000);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());

    // A plan's HEADs (the integrator's review of ff2fd83): twelve files that each take a second to answer, asked at once, in
    // well under twelve seconds; one gone (404) drops the others still running; one that never answers is 0 at the set's
    // deadline.
    QList<QUrl> slow;
    for (int i = 0; i < 12; ++i)
        slow.append(QUrl(base + QStringLiteral("/slow/%1").arg(i)));
    QElapsedTimer clock;
    clock.start();
    EXPECT_EQ(headStatuses(slow, 10000, 20000), QList<int>(12, 200));
    EXPECT_LT(clock.elapsed(), 6000);
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/slow/a")), QUrl(base + QStringLiteral("/gone"))}, 10000, 20000), (QList<int>{0, 404}));
    clock.restart();
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/hang"))}, 10000, 1500), QList<int>{0});
    EXPECT_LT(clock.elapsed(), 4000);
    EXPECT_EQ(headStatuses({QUrl(base + QStringLiteral("/to-http"))}, 10000, 5000), QList<int>{-1}) << "a redirect to http";
}

namespace {

// An https server of the test's own on 127.0.0.1, answering HEADs: /slow/* 200 after a second, /gone 404 at once, /hang
// never.
class HeadServer : public QObject
{
public:
    bool listen(const QSslCertificate &certificate, const QSslKey &key)
    {
        QSslConfiguration config = QSslConfiguration::defaultConfiguration();
        config.setLocalCertificate(certificate);
        config.setPrivateKey(key);
        m_server.setSslConfiguration(config);
        connect(&m_server, &QTcpServer::pendingConnectionAvailable, this, [this] {
            while (QTcpSocket *socket = m_server.nextPendingConnection())
                serve(socket);
        });
        return m_server.listen(QHostAddress::LocalHost);
    }
    QUrl url(const QByteArray &path) const
    {
        return QUrl(QStringLiteral("https://127.0.0.1:%1%2").arg(m_server.serverPort()).arg(QString::fromLatin1(path)));
    }

private:
    static void serve(QTcpSocket *socket)
    {
        auto buffer = std::make_shared<QByteArray>();
        connect(socket, &QTcpSocket::readyRead, socket, [socket, buffer] {
            *buffer += socket->readAll();
            for (qsizetype end = buffer->indexOf("\r\n\r\n"); end >= 0; end = buffer->indexOf("\r\n\r\n")) {
                const QByteArray path = buffer->left(buffer->indexOf("\r\n")).split(' ').value(1);
                buffer->remove(0, end + 4);
                if (path == "/gone") {
                    socket->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                } else if (path.startsWith("/slow/")) {
                    auto *later = new QTimer(socket); // gone with the socket
                    later->setSingleShot(true);
                    connect(later, &QTimer::timeout, socket, [socket] { socket->write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"); });
                    later->start(1000);
                }
            }
        });
    }
    QSslServer m_server;
};

} // namespace

// A plan's HEADs against that server (the integrator's merge note on PR #54: the set's deadline and its early stop were
// held only by the container of store_catalog.sh). Its certificate is a throwaway one openssl makes here, trusted for this
// test only.
TEST(Fetch, HeadStatusesAgainstALocalServer)
{
    storetest::ensureApp();
    const QString openssl = QStandardPaths::findExecutable(QStringLiteral("openssl"));
    if (openssl.isEmpty())
        GTEST_SKIP() << "no openssl to make the throwaway certificate";
    QTemporaryDir dir;
    QProcess make;
    make.start(openssl, {QStringLiteral("req"), QStringLiteral("-x509"), QStringLiteral("-newkey"), QStringLiteral("ec"),
                         QStringLiteral("-pkeyopt"), QStringLiteral("ec_paramgen_curve:prime256v1"), QStringLiteral("-nodes"),
                         QStringLiteral("-days"), QStringLiteral("1"), QStringLiteral("-subj"), QStringLiteral("/CN=127.0.0.1"),
                         QStringLiteral("-addext"), QStringLiteral("subjectAltName=IP:127.0.0.1"), QStringLiteral("-keyout"),
                         dir.filePath(QStringLiteral("key.pem")), QStringLiteral("-out"), dir.filePath(QStringLiteral("cert.pem"))});
    ASSERT_TRUE(make.waitForFinished(30000) && make.exitStatus() == QProcess::NormalExit && make.exitCode() == 0)
        << make.readAllStandardError().toStdString();
    const QList<QSslCertificate> certificate = QSslCertificate::fromPath(dir.filePath(QStringLiteral("cert.pem")));
    ASSERT_EQ(certificate.size(), 1);
    QFile keyFile(dir.filePath(QStringLiteral("key.pem")));
    ASSERT_TRUE(keyFile.open(QIODevice::ReadOnly));
    const QSslKey key(&keyFile, QSsl::Ec);
    ASSERT_FALSE(key.isNull());
    // The Store's requests take the default configuration: the certificate is trusted there, no proxy, until the test ends.
    const QSslConfiguration saved = QSslConfiguration::defaultConfiguration();
    QSslConfiguration trusting = saved;
    trusting.addCaCertificate(certificate.first());
    QSslConfiguration::setDefaultConfiguration(trusting);
    // Never QNetworkProxy::applicationProxy(): it asks the system's proxy (libproxy 0.5.12 leaks under LSan when one is set).
    const bool systemProxy = QNetworkProxyFactory::usesSystemConfiguration();
    QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
    const auto restore = qScopeGuard([&saved, systemProxy] {
        QSslConfiguration::setDefaultConfiguration(saved);
        QNetworkProxy::setApplicationProxy(QNetworkProxy());
        QNetworkProxyFactory::setUseSystemConfiguration(systemProxy);
    });
    HeadServer server;
    ASSERT_TRUE(server.listen(certificate.first(), key));

    // Twelve files that each take a second, asked at once: well under twelve seconds.
    QList<QUrl> slow;
    for (int i = 0; i < 12; ++i)
        slow.append(server.url("/slow/" + QByteArray::number(i)));
    QElapsedTimer clock;
    clock.start();
    EXPECT_EQ(headStatuses(slow, 10000, 20000), QList<int>(12, 200));
    EXPECT_LT(clock.elapsed(), 6000);
    // One gone: the set stops there, and the file still on its way is dropped (0) before its answer.
    EXPECT_EQ(headStatuses({server.url("/slow/a"), server.url("/gone")}, 10000, 20000), (QList<int>{0, 404}));
    EXPECT_EQ(headStatuses({server.url("/gone"), server.url("/slow/b")}, 10000, 20000), (QList<int>{404, 0}));
    // Never answered: 0 at the set's deadline, long before each request's own timeout.
    clock.restart();
    EXPECT_EQ(headStatuses({server.url("/hang"), server.url("/hang")}, 10000, 1500), (QList<int>{0, 0}));
    EXPECT_GE(clock.elapsed(), 1400);
    EXPECT_LT(clock.elapsed(), 4000);
}

// A plan's HEADs through dev plumbing (file://): a file there answers 200, a missing one 404 and drops the rest; file://
// without dev plumbing, or http, is not requested (-1).
TEST(Fetch, HeadStatusesThroughDevPlumbing)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("a.pkg")), "a");
    storetest::writeFile(dir.filePath(QStringLiteral("c.pkg")), "c");
    const auto file = [&dir](const char *name) { return QUrl::fromLocalFile(dir.filePath(QLatin1String(name))); };
    EXPECT_EQ(headStatuses({file("a.pkg"), file("c.pkg")}, 1000, 1000, true), (QList<int>{200, 200}));
    EXPECT_EQ(headStatuses({file("a.pkg"), file("b.pkg"), file("c.pkg")}, 1000, 1000, true), (QList<int>{200, 404, 0}));
    EXPECT_EQ(headStatuses({QUrl(QStringLiteral("http://example.org/a.pkg")), file("a.pkg")}, 1000, 1000), (QList<int>{-1, -1}));
    EXPECT_TRUE(headStatuses({}, 1000, 1000).isEmpty());
}

TEST(Fetch, DevPlumbingReadsAFileWithinItsCap)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("catalog.json")), QByteArray(1000, 'x'));
    const QUrl url = QUrl::fromLocalFile(dir.filePath(QStringLiteral("catalog.json")));
    FetchResult r = fetch(url, {}, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::Ok) << r.error.toStdString();
    EXPECT_EQ(r.body.size(), 1000);

    FetchLimits small;
    small.maxBytes = 999;
    r = fetch(url, small, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::TooLarge);
    EXPECT_TRUE(r.body.isEmpty());

    r = fetch(QUrl::fromLocalFile(dir.filePath(QStringLiteral("missing.json"))), {}, {}, true);
    EXPECT_EQ(r.status, FetchResult::Status::Failed);
}

TEST(Fetch, DownloadToAFile)
{
    storetest::ensureApp();
    QTemporaryDir dir;
    storetest::writeFile(dir.filePath(QStringLiteral("package")), QByteArray(5000, 'p'));
    const QUrl url = QUrl::fromLocalFile(dir.filePath(QStringLiteral("package")));
    const QString out = dir.filePath(QStringLiteral("out"));
    ASSERT_TRUE(downloadTo(url, out, {}, true));
    QFile f(out);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(f.readAll(), QByteArray(5000, 'p'));
    f.close();
    FetchLimits small;
    small.maxBytes = 4999;
    EXPECT_FALSE(downloadTo(url, out, small, true));
    EXPECT_FALSE(QFile::exists(out)); // the earlier copy is gone too: a failed download leaves nothing
    EXPECT_FALSE(downloadTo(QUrl(QStringLiteral("http://example.org/p")), out, {}));
}


// SU-07: a worker's fetches stop once its cancel flag is set (FetchCancelScope): a transfer that hangs (a server that accepts
// and never answers) ends within a fraction of a second, not at its 15 s timeout; a fetch asked after the flag is set does
// not start; HEADs stop the same way. Outside a scope nothing changes.
TEST(Fetch, CancelledByItsWorkersFlag)
{
    storetest::ensureApp();
    QTcpServer silent;
    QList<QTcpSocket *> held;
    QObject::connect(&silent, &QTcpServer::newConnection, &silent, [&] {
        while (QTcpSocket *s = silent.nextPendingConnection())
            held.append(s); // kept open, never answered
    });
    ASSERT_TRUE(silent.listen(QHostAddress::LocalHost));
    const QUrl url(QStringLiteral("https://127.0.0.1:%1/catalog.json").arg(silent.serverPort()));
    const bool systemProxy = QNetworkProxyFactory::usesSystemConfiguration();
    QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
    const auto restore = qScopeGuard([systemProxy] {
        QNetworkProxy::setApplicationProxy(QNetworkProxy());
        QNetworkProxyFactory::setUseSystemConfiguration(systemProxy);
    });

    auto cancel = std::make_shared<std::atomic_bool>(false);
    {
        const FetchCancelScope scope(cancel);
        EXPECT_FALSE(fetchCancelled());
        QTimer::singleShot(300, [cancel] { *cancel = true; });
        QElapsedTimer clock;
        clock.start();
        const FetchResult r = fetch(url, FetchLimits{1024, 15000});
        EXPECT_LT(clock.elapsed(), 2000) << "aborted by the flag, not by the 15 s timeout";
        EXPECT_EQ(r.status, FetchResult::Status::Failed);
        EXPECT_EQ(r.error, QStringLiteral("cancelled"));
        EXPECT_TRUE(fetchCancelled());
        clock.restart();
        EXPECT_EQ(fetch(url, FetchLimits{1024, 15000}).error, QStringLiteral("cancelled")) << "not started once set";
        EXPECT_LT(clock.elapsed(), 500);
        clock.restart();
        EXPECT_EQ(headStatuses({url}, 15000, 15000), QList<int>{0});
        EXPECT_LT(clock.elapsed(), 2000);
    }
    EXPECT_FALSE(fetchCancelled()) << "the scope is gone with its block";
    qDeleteAll(held);
}
