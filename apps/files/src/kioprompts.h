#pragma once

#include "applicationchooser.h"

#include <QList>
#include <QObject>
#include <QPointer>
#include <QVariantMap>

#include <functional>
#include <memory>

#include <KIO/AskUserActionInterface>
#include <KIO/FileUndoManager>
#include <KIO/JobUiDelegate>
#include <KIO/JobUiDelegateFactory>
#include <KIO/OpenWithHandlerInterface>
#include <KIO/UntrustedProgramHandlerInterface>

#include <optional>

// Grassfield's KIO dialogs in Files (ADR-0035 D-12 a; docs/specs/system-dialogs.md section 9). KIO's jobs ask through the
// delegate extensions of their UI delegate (KIO::delegateExtension, src/core/jobuidelegatefactory.h): Files gives every job
// KIO's own delegate class with Grassfield's extensions as its children, so KIO never creates its widget dialogs
// (RenameDialog, SkipDialog, KMessageDialog, KOpenWithDialog, KSslInfoDialog). The questions go to KioPrompts, which the
// browser window shows one at a time as Grassfield sheets (qml/KioSheets.qml). Every answer is the KIO answer the widget
// dialog gives for the same choice (KioPromptLogic).

// The questions KIO's jobs ask in Files, in the order they were asked; the first one is shown.
class KioPrompts : public QObject
{
    Q_OBJECT
    // The question on screen: {id, kind, ...} (kinds and fields: qml/KioSheets.qml), {} when there is none.
    Q_PROPERTY(QVariantMap current READ current NOTIFY currentChanged)

public:
    using Answer = std::function<void(const QVariantMap &reply)>;

    explicit KioPrompts(QObject *parent = nullptr);

    // Queues a question; `answer` runs once with the sheet's reply ({button, applyToAll, alwaysTrust}). The question stands
    // while `owner` exists, and, when the owner is a job, while it runs (KIO closes its own dialog when the job ends); then
    // it goes unanswered. KIO's questions without a job (a worker's message box, a certificate) are owned by the extension
    // that asked, which lives as long as its job's delegate. No owner: it waits for the user.
    int ask(const QVariantMap &request, QObject *owner, const Answer &answer);
    // A sheet with only OK: nothing waits for its answer.
    void tell(const QString &title, const QString &text);
    Q_INVOKABLE void reply(int id, const QVariantMap &reply);
    QVariantMap current() const;
    // The Choose Application panels (KIO's question when a type has no application, and Open With > Other…).
    ApplicationChooser *applications() const;

    // Tests: every question is answered by `responder` (no sheet), after the call that asked it returns.
    void setResponder(const std::function<QVariantMap(const QVariantMap &request)> &responder);

signals:
    void currentChanged();

private:
    struct Pending {
        int id = 0;
        QVariantMap request;
        Answer answer;
        // The owner, if there was one when it was asked (an answer never reaches one that is gone, or a job that ended).
        QPointer<QObject> owner;
        bool owned = false;
        std::shared_ptr<bool> ended;
        QList<QMetaObject::Connection> connections;
    };
    void forget(const Pending &pending);
    void withdraw(int id);
    QList<Pending> m_queue;
    int m_next = 1;
    ApplicationChooser *m_applications;
    std::function<QVariantMap(const QVariantMap &)> m_responder;
};

// KIO's questions about files: conflicts, skips, deletions, worker message boxes, certificates.
class GrassfieldAskUserAction : public KIO::AskUserActionInterface
{
    Q_OBJECT

public:
    GrassfieldAskUserAction(KioPrompts *prompts, QObject *parent = nullptr);

    void askUserRename(KJob *job,
                       const QString &title,
                       const QUrl &src,
                       const QUrl &dest,
                       KIO::RenameDialog_Options options,
                       KIO::filesize_t sizeSrc,
                       KIO::filesize_t sizeDest,
                       const QDateTime &ctimeSrc = {},
                       const QDateTime &ctimeDest = {},
                       const QDateTime &mtimeSrc = {},
                       const QDateTime &mtimeDest = {}) override;
    void askUserSkip(KJob *job, KIO::SkipDialog_Options options, const QString &errorText) override;
    void askUserDelete(const QList<QUrl> &urls, DeletionType deletionType, ConfirmationType confirmationType, QWidget *parent = nullptr) override;
    void requestUserMessageBox(MessageDialogType type,
                               const QString &text,
                               const QString &title,
                               const QString &primaryActionText,
                               const QString &secondaryActionText,
                               const QString &primaryActionIconName = {},
                               const QString &secondaryActionIconName = {},
                               const QString &dontAskAgainName = {},
                               const QString &details = {},
                               QWidget *parent = nullptr) override;
    void askIgnoreSslErrors(const QVariantMap &sslErrorData, QWidget *parent) override;

private:
    QPointer<KioPrompts> m_prompts; // gone when Files quits while a job still runs: the safe answer then
    // After "Continue" on the certificate sheet: KIO's http worker's next question on this job is whether to accept the
    // certificate forever or for 30 minutes (http.cpp:310-327, the only sslError caller in KIO 6.31); the sheet's "Always
    // trust" box answers it (KioPromptLogic::certificateFollowUpAnswer). Any other question first clears it.
    std::optional<bool> m_alwaysTrust;
};

// KIO asks for an application when none is set for a document's type: Finder's alert (Choose Application…, Cancel), then
// the Choose Application panel (ApplicationChooser; ADR-0035 5c-3).
class GrassfieldOpenWithHandler : public KIO::OpenWithHandlerInterface
{
    Q_OBJECT

public:
    GrassfieldOpenWithHandler(KioPrompts *prompts, QObject *parent = nullptr);
    void promptUserForApplication(KJob *job, const QList<QUrl> &urls, const QString &mimeType) override;

private:
    QPointer<KioPrompts> m_prompts; // gone when Files quits while a job still runs: the safe answer then
};

// KIO asks before running a program it does not trust: KIO never runs one for Files (its LaunchGuard decides first and runs
// programs itself, after its own checks and sheet; this is the second guard, docs/specs/security.md "Files opens apps the
// Gatekeeper way").
class GrassfieldUntrustedProgramHandler : public KIO::UntrustedProgramHandlerInterface
{
    Q_OBJECT

public:
    GrassfieldUntrustedProgramHandler(KioPrompts *prompts, QObject *parent = nullptr);
    void showUntrustedProgramWarning(KJob *job, const QString &programName) override;

private:
    QPointer<KioPrompts> m_prompts; // gone when Files quits while a job still runs: the safe answer then
};

// KIO's own delegate class (clipboard updates and the rest stay KIO's), with Grassfield's extensions. KIO's fourth,
// OpenOrExecuteFileInterface, has no installed header in KIO 6.31; it is only asked when a job enables
// setShowOpenOrExecuteDialog, which Files never does (tests/unit/files/tst_kiodialogs.cpp checks the sources).
// Files' jobs report their errors themselves (automatic handling off); where KIO turns it on for a job of its own, the
// error or warning is a sheet too, not KIO's message box.
class GrassfieldJobUiDelegate : public KIO::JobUiDelegate
{
    Q_OBJECT

public:
    GrassfieldJobUiDelegate(KioPrompts *prompts, KJobUiDelegate::Flags flags = AutoHandlingDisabled, QWidget *window = nullptr);
    void showErrorMessage() override;

protected Q_SLOTS:
    void slotWarning(KJob *job, const QString &message) override;

private:
    QPointer<KioPrompts> m_prompts; // gone when Files quits while a job still runs: the safe answer then
};

// Undo and redo (KIO's FileUndoManager) report through their own interface (KIO's shows KMessageBox): an error goes to the
// window's error line, and a copy changed since it was made is not deleted by an undo (KIO asks, synchronously; Grassfield
// keeps the file and says so). No progress window either. The jobs an undo starts get Grassfield's delegate from the
// default factory.
class GrassfieldUndoUi : public KIO::FileUndoManager::UiInterface
{
public:
    explicit GrassfieldUndoUi(const std::function<void(const QString &)> &reportError);
    void jobError(KIO::Job *job) override;
    bool copiedFileWasModified(const QUrl &src, const QUrl &dest, const QDateTime &srcTime, const QDateTime &destTime) override;

private:
    std::function<void(const QString &)> m_reportError;
};

class QMimeData;

namespace KioDialogs
{
// Called once at start, before Files starts any job: every KIO delegate Files gets from now on is Grassfield's, also for
// the sub-jobs KIO gives a default delegate of their own (DirectCopyJob, src/core/job.cpp:282), which the delegate of the
// job Files starts would not reach; undo and redo ask through Grassfield's interface; KIO's job tracker opens no progress
// window (KWidgetJobTracker). All of it is KIO's again once `prompts` is destroyed. Returns `prompts`.
KioPrompts *install(KioPrompts *prompts, const std::function<void(const QString &)> &reportError);
// The delegate for a job Files starts (explicit, so it does not depend on the default factory).
KJobUiDelegate *createDelegate(KJobUiDelegate::Flags flags = KJobUiDelegate::AutoHandlingDisabled);
// The items a paste of `data` would copy or move. Data without items (text, an image) is not pasted: KIO would ask for a
// file name and a format in its own widget dialogs (KIO::PasteDialog, src/widgets/paste.cpp), and the Finder pastes items
// only (ADR-0035 4a-14).
QList<QUrl> pastableItems(const QMimeData *data);
} // namespace KioDialogs
