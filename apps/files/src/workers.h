#pragma once

#include <QObject>

#include <functional>

class QThread;

// Files' own worker threads (audit F17): every thread Files starts for a walk (FileSearch, TagSearch), a probe of a folder's
// file system (FsKind), a check of a destination folder (FilesApp) or the removal of a staging tree (ArchiveJob) is listed
// here until it has finished. The quit waits for them, bounded (waitAll, from QCoreApplication::aboutToQuit, which the first
// tracked thread hooks: Files and the portal's panels alike), after raising stopping(): a long walk checks it at every entry
// and ends. A thread still running past the bound (a system call stuck on a dead mount) is left to the process's exit; none
// of them touches an object of the app, only data it owns.
namespace Workers
{
constexpr int kQuitWaitMs = 3000;

// Tracks `thread` (created, started or not) until its finished signal.
void track(QThread *thread);
// Runs `work` on a thread of its own (tracked, deleted when done); `done` then runs on `context`'s thread, unless `context`
// was destroyed meanwhile (then nothing runs: the work's result is dropped).
void run(QObject *context, std::function<void()> work, std::function<void()> done = {});
// Raises stopping() (unless `stop` is false: a test's wait), then waits up to `ms` for every tracked thread. True when none
// is left running.
bool waitAll(int ms, bool stop = true);
// Threads tracked and not finished yet.
int running();
// The app is quitting: a walk stops at its next entry.
bool stopping();
} // namespace Workers
