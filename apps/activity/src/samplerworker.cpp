#include "samplerworker.h"

namespace activity {

SamplerWorker::SamplerWorker(Options options, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
    , m_apps(DesktopApps::fromEnvironment())
{
}

SamplerWorker::~SamplerWorker() = default;

void SamplerWorker::sample(unsigned reads, double interval, bool forget)
{
    if (!m_sampler) {
        m_sampler = std::make_unique<Sampler>(m_options);
        m_sampler->setWindowOwners(m_windowOwners);
    }
    m_sampler->setInterval(interval);
    if (forget)
        m_sampler->forgetRates();
    auto snapshot = std::make_shared<const Snapshot>(m_sampler->sample(reads));
    auto names = std::make_shared<AppNames>();
    for (const ProcessRow &row : snapshot->rows) {
        if (!row.own || row.appId.empty())
            continue;
        const QString id = QString::fromStdString(row.appId);
        if (!names->contains(id))
            names->insert(id, resolveApp(id));
    }
    for (const QString &id : std::as_const(m_windowApps)) {
        if (!names->contains(id))
            names->insert(id, m_apps.app(id)); // a window's app id is its desktop entry's id (AM17)
    }
    emit sampled(snapshot, reads, names);
}

DesktopApp SamplerWorker::resolveApp(const QString &id)
{
    const DesktopApp *entry = &m_apps.app(id);
    if (entry->name.isEmpty())
        entry = &m_apps.byExec(id);
    return *entry;
}

void SamplerWorker::setWindowApps(const QStringList &ids)
{
    m_windowApps = ids;
}

void SamplerWorker::setWindowOwners(const QList<int> &pids)
{
    m_windowOwners = std::unordered_set<int>(pids.cbegin(), pids.cend());
    if (m_sampler)
        m_sampler->setWindowOwners(m_windowOwners);
}

} // namespace activity
