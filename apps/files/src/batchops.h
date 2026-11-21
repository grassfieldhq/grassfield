#pragma once

#include <QList>
#include <QString>

#include <functional>

// Several local file operations that are ONE command for the user (Rename N Items, Make Alias of several items, New Folder
// with Selection): applied all together or not at all, and reverted or applied again as one undo or redo step (the Finder
// records one step per command; KIO's FileUndoManager records one per job, so Files keeps these commands itself and orders
// them against KIO's by serial number, FilesApp::undo). Qt Core and system calls only; unit tested.
//
// Nothing is ever replaced: a rename uses RENAME_NOREPLACE, a link and a folder fail when the name exists, a folder is only
// removed empty and a link only when it still points where it did. A case-only rename on a file system that ignores case is a
// rename in place, through a hidden name, only when the new name is the very item and no other entry (audit F19).
namespace BatchOps
{

struct Step {
    enum class Kind {
        Rename, // `from` becomes `to`
        Link,   // a symbolic link named `to` that points to `from`
        Unlink, // removes the link `to` when it still points to `from`
        Mkdir,  // a folder named `to`
        Rmdir,  // removes the folder `to` when it is empty
    };
    Kind kind = Kind::Rename;
    QString from;
    QString to;
};
using Steps = QList<Step>;

struct Failure {
    // The step that could not be done (index in the list given to apply()), its item's path and errno.
    int step = -1;
    QString path;
    int error = 0;
    // The steps still in effect after the failure, in the order they were done: empty when everything done was put back (the
    // usual case), the steps whose own revert failed otherwise. The caller must tell the user about them and keep them
    // undoable.
    Steps applied;
};

// The steps that revert `steps`: each inverted, in reverse order.
Steps inverse(const Steps &steps);

// Applies the steps in order. When one fails, the ones done are reverted (in reverse order) and false is returned with
// `failure` naming the step; nothing is left half done unless a revert itself fails: `failure.applied` then holds the steps
// still in effect (the disk is as far along as the revert got). True: all done.
bool apply(const Steps &steps, Failure *failure = nullptr);

// For tests only. forceNoReplaceFallback(true): act as on a filesystem without RENAME_NOREPLACE (the look-then-rename
// path). setStepHook(f): f(i) is called after step i of apply() succeeded (a test breaks the disk there to make a revert
// fail); an empty function removes it.
void forceNoReplaceFallback(bool on);
// actCaseInsensitive(true): a rename's new name is "taken" by any entry spelt like it but for ASCII case, as on FAT or exFAT
// (the case-only rename in place, audit F19).
void actCaseInsensitive(bool on);
void setStepHook(const std::function<void(int)> &hook);

} // namespace BatchOps
