#include "workers.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QList>
#include <QMutex>
#include <QMutexLocker>
#include <QThread>
#include <QVariant>

#include <atomic>

namespace
{
QMutex g_mutex;
QList<QThread *> g_threads; // under g_mutex
std::atomic_bool g_stopping{false};

// Once per application object (a test may make several in turn): the bounded join at quit.
void hookQuit()
{
    QCoreApplication *app = QCoreApplication::instance();
    if (!app || app->property("_gf_workers_hooked").toBool())
        return;
    app->setProperty("_gf_workers_hooked", true);
    QObject::connect(app, &QCoreApplication::aboutToQuit, app, [] { Workers::waitAll(Workers::kQuitWaitMs); });
}
} // namespace

namespace Workers
{
void track(QThread *thread)
{
    if (!thread)
        return;
    {
        QMutexLocker lock(&g_mutex);
        g_threads.append(thread);
    }
    // Emitted by the thread itself as it ends: forgotten there and then (the object is deleted later, on its own thread).
    QObject::connect(
        thread, &QThread::finished, thread,
        [thread] {
            QMutexLocker lock(&g_mutex);
            g_threads.removeAll(thread);
        },
        Qt::DirectConnection);
    if (QThread::currentThread() == (QCoreApplication::instance() ? QCoreApplication::instance()->thread() : nullptr))
        hookQuit();
}

void run(QObject *context, std::function<void()> work, std::function<void()> done)
{
    QThread *thread = QThread::create(std::move(work));
    if (context && done)
        QObject::connect(thread, &QThread::finished, context, [done = std::move(done)] { done(); }, Qt::QueuedConnection);
    QObject::connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    track(thread);
    thread->start();
}

bool waitAll(int ms, bool stop)
{
    if (stop)
        g_stopping.store(true);
    QList<QThread *> threads;
    {
        QMutexLocker lock(&g_mutex);
        threads = g_threads;
    }
    // No event is processed while this waits: a thread listed above is not deleted under it (deleteLater needs the loop).
    const QDeadlineTimer deadline(ms);
    bool all = true;
    for (QThread *thread : std::as_const(threads)) {
        if (!thread->wait(deadline))
            all = false;
    }
    return all;
}

int running()
{
    QMutexLocker lock(&g_mutex);
    return int(g_threads.size());
}

bool stopping()
{
    return g_stopping.load();
}
} // namespace Workers
