// The sampler on a thread of its own (ADR-0038 AD35): a sample costs up to 17 ms on the reference machine's CPU tab and
// more on Energy and Network (AM-P2), too long for the window's thread. One sample at a time; the window asks for the next
// one when the interval passes, and the snapshot comes back as a copy the window keeps.
#pragma once

#include "desktopapps.h"
#include "sampler.h"

#include <QHash>
#include <QList>
#include <QStringList>
#include <QObject>

#include <memory>
#include <unordered_set>

namespace activity {

using SnapshotPtr = std::shared_ptr<const Snapshot>;
// The desktop entries of the app ids a sample names (its own rows' units, the windows' apps), resolved on the worker
// (A6 of the 2026-11 audit: the first sample read and parsed up to 4096 .desktop files on the window's thread).
using AppNames = QHash<QString, DesktopApp>;
using AppNamesPtr = std::shared_ptr<const AppNames>;

class SamplerWorker : public QObject
{
    Q_OBJECT

public:
    explicit SamplerWorker(Options options, QObject *parent = nullptr);
    ~SamplerWorker() override;

public slots:
    // `interval`: AM9's, for AD32's pauses. `forget`: AM8, the window comes back after a time hidden.
    void sample(unsigned reads, double interval, bool forget);
    // AM60, AM65: the pids that own a window (the shell's projection), from the next sample on.
    void setWindowOwners(const QList<int> &pids);
    // The app ids of the windows (the projection): resolved with the next sample's.
    void setWindowApps(const QStringList &ids);

public:
    // An app id's entry (AM65: the entry of that id, else the one whose Exec runs it). On the worker's thread only.
    DesktopApp resolveApp(const QString &id);

signals:
    void sampled(activity::SnapshotPtr snapshot, unsigned reads, activity::AppNamesPtr names);

private:
    Options m_options;
    std::unordered_set<int> m_windowOwners;
    std::unique_ptr<Sampler> m_sampler; // made on the worker's thread at its first sample
    QStringList m_windowApps;
    DesktopApps m_apps; // only ever touched on the worker's thread
};

} // namespace activity

Q_DECLARE_METATYPE(activity::SnapshotPtr)
Q_DECLARE_METATYPE(activity::AppNamesPtr)
