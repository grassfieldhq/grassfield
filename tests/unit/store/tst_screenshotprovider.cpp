// The product page's screenshots (apps/store/src/screenshotprovider.h; spec SR10; SU-06 note): a screenshot the page no longer
// wants is cancelled by the engine, and the provider then drops it: one still waiting for its thread leaves the queue at once
// (finished, "cancelled", never fetched), one being fetched aborts its transfer. A server of the test's own accepts and never
// answers, so without the cancel each request would hold its thread for its whole 15 s timeout.
#include "screenshotprovider.h"
#include "storetest.h"

#include <QElapsedTimer>
#include <QEventLoop>
#include <QNetworkProxy>
#include <QQuickImageResponse>
#include <QScopeGuard>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTimer>
#include <QUrl>

#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <memory>

using namespace grassfield::store;

TEST(ScreenshotProvider, CancelledWithItsPage)
{
    storetest::ensureApp();
    QTcpServer silent;
    QList<QTcpSocket *> held;
    QObject::connect(&silent, &QTcpServer::newConnection, &silent, [&] {
        while (QTcpSocket *s = silent.nextPendingConnection())
            held.append(s);
    });
    ASSERT_TRUE(silent.listen(QHostAddress::LocalHost));
    const bool systemProxy = QNetworkProxyFactory::usesSystemConfiguration();
    QNetworkProxy::setApplicationProxy(QNetworkProxy::NoProxy);
    const auto restore = qScopeGuard([systemProxy] {
        QNetworkProxy::setApplicationProxy(QNetworkProxy());
        QNetworkProxyFactory::setUseSystemConfiguration(systemProxy);
    });

    auto allowed = std::make_shared<std::atomic_bool>(true);
    ScreenshotProvider provider(allowed);
    QList<QQuickImageResponse *> responses;
    std::array<std::atomic_bool, 4> done{}; // set on the workers' threads
    // Four at once on its two threads: two are fetched (and hang), two wait in the queue.
    for (int i = 0; i < 4; ++i) {
        const QString url = QStringLiteral("https://127.0.0.1:%1/shot%2.png").arg(silent.serverPort()).arg(i);
        QQuickImageResponse *r = provider.requestImageResponse(QString::fromLatin1(QUrl::toPercentEncoding(url)), QSize(100, 100));
        responses.append(r);
        QObject::connect(r, &QQuickImageResponse::finished, r, [&done, i] { done[i] = true; }, Qt::DirectConnection);
    }
    QEventLoop loop;
    const auto spin = [&loop](int ms) {
        QTimer::singleShot(ms, &loop, &QEventLoop::quit);
        loop.exec();
    };
    spin(300);
    for (const std::atomic_bool &d : done)
        EXPECT_FALSE(d.load()) << "the server never answers: nothing is finished yet";

    // The page goes: the engine cancels all four.
    QElapsedTimer clock;
    clock.start();
    responses.at(3)->cancel();
    responses.at(2)->cancel();
    EXPECT_TRUE(done[3] && done[2]) << "the queued ones finish at once, never fetched";
    EXPECT_EQ(responses.at(3)->errorString(), QStringLiteral("cancelled"));
    responses.at(0)->cancel();
    responses.at(1)->cancel();
    for (int i = 0; i < 100 && !(done[0] && done[1]); ++i)
        spin(20);
    EXPECT_TRUE(done[0] && done[1]) << "the running ones abort their transfer";
    EXPECT_LT(clock.elapsed(), 3000) << "well before the 15 s timeout";
    EXPECT_EQ(responses.at(0)->errorString(), QStringLiteral("cancelled"));
    spin(100); // the workers return from run() after their `finished`
    for (QQuickImageResponse *r : std::as_const(responses))
        delete r;
    qDeleteAll(held);
}
