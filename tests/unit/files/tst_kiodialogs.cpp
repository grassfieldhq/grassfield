// ADR-0035 D-12 a, docs/specs/system-dialogs.md section 9 (A-KD1, KD3): KIO's real jobs in Files ask Grassfield's prompts,
// never KIO's widget dialogs: a name that exists (Replace, Keep Both, Stop, Skip with Apply to All, a folder merged), a
// question withdrawn when its job ends, the answer a sheet gives (KioPrompts::reply), the default delegate KIO gives its
// own jobs, Undo of a copy changed since, and the sources of Files (no KIO or Qt widget dialog, no "open or execute").
// Its own process (scripts/dev/test.sh), offscreen, with HOME and the XDG directories in a scratch directory and no
// session bus or display: KIO's local file worker does the copies there.
#include "kioprompts.h"

#include <QApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFile>
#include <QMimeData>
#include <QPointer>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>

#include <KFileUtils>
#include <KIO/CopyJob>
#include <KIO/FileUndoManager>
#include <KIO/JobUiDelegateFactory>
#include <KIO/OpenUrlJob>
#include <KIO/OpenWithHandlerInterface>
#include <KIO/StatJob>
#include <KIO/UntrustedProgramHandlerInterface>
#include <KJobTrackerInterface>
#include <KSycoca>
#include <kio/jobtracker.h>
#include <kio/workerbase.h>

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <ostream>
#include <typeinfo>

// Readable QString values in gtest's messages.
void PrintTo(const QString &value, std::ostream *os)
{
    *os << '"' << value.toStdString() << '"';
}

namespace
{
QTemporaryDir *s_scratch = nullptr;
KioPrompts *s_prompts = nullptr;
QStringList s_reported; // what Files' error line got (KioDialogs::install's reportError)

constexpr int kTimeoutMs = 15000;

// Runs the event loop until `done` holds or the time is up.
bool waitFor(const std::function<bool()> &done)
{
    QEventLoop loop;
    QTimer poll;
    QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
        if (done())
            loop.quit();
    });
    QTimer::singleShot(kTimeoutMs, &loop, &QEventLoop::quit);
    poll.start(10);
    if (!done())
        loop.exec();
    return done();
}

// Runs a job to its end (killed if it hangs, so a test fails instead of the run); true when it succeeded.
bool run(KJob *job)
{
    const QPointer<KJob> guard(job);
    bool finished = false;
    int error = 0;
    QObject::connect(job, &KJob::result, job, [&](KJob *j) {
        finished = true;
        error = j->error();
    });
    if (!waitFor([&] {
            return finished;
        })) {
        if (guard)
            guard->kill();
        ADD_FAILURE() << "the job did not finish within " << kTimeoutMs << " ms";
        return false;
    }
    return error == 0;
}

int lastError = 0;

KIO::CopyJob *withGrassfieldsDelegate(KIO::CopyJob *job)
{
    job->setUiDelegate(KioDialogs::createDelegate(KJobUiDelegate::AutoHandlingDisabled));
    QObject::connect(job, &KJob::result, [](KJob *j) {
        lastError = j->error();
    });
    return job;
}

class KioDialogsTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        QDir().mkpath(path(QStringLiteral("from")));
        QDir().mkpath(path(QStringLiteral("to")));
        m_asked.clear();
        s_reported.clear();
        lastError = 0;
    }

    void TearDown() override
    {
        s_prompts->setResponder({});
        // KIO's widget dialogs are top-level widgets; Grassfield's sheets are QML in the browser window.
        EXPECT_TRUE(QApplication::topLevelWidgets().isEmpty()) << "a widget was created";
        EXPECT_TRUE(s_prompts->current().isEmpty()) << "a question was left on screen";
    }

    QString path(const QString &relative) const
    {
        return m_dir.filePath(relative);
    }
    QUrl url(const QString &relative) const
    {
        return QUrl::fromLocalFile(path(relative));
    }
    void write(const QString &relative, const QByteArray &content) const
    {
        QFile f(path(relative));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(content);
    }
    QByteArray read(const QString &relative) const
    {
        QFile f(path(relative));
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray("<missing>");
    }
    QStringList names(const QString &relative) const
    {
        QStringList out = QDir(path(relative)).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden);
        out.sort();
        return out;
    }
    // Every question is answered with `reply` (the sheet's {button, applyToAll}) and recorded.
    void answer(const QVariantMap &reply)
    {
        s_prompts->setResponder([this, reply](const QVariantMap &request) {
            m_asked << request;
            return reply;
        });
    }

    QTemporaryDir m_dir{s_scratch->filePath(QStringLiteral("case-XXXXXX"))};
    QList<QVariantMap> m_asked;
};

} // namespace

TEST_F(KioDialogsTest, ReplaceWritesTheNewItem)
{
    write(QStringLiteral("from/a.txt"), "new");
    write(QStringLiteral("to/a.txt"), "old");
    answer({{QStringLiteral("button"), QStringLiteral("replace")}});
    EXPECT_TRUE(run(withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    ASSERT_EQ(m_asked.size(), 1);
    const QVariantMap &q = m_asked.first();
    EXPECT_EQ(q.value(QStringLiteral("kind")).toString(), QStringLiteral("conflict"));
    EXPECT_EQ(q.value(QStringLiteral("name")).toString(), QStringLiteral("a.txt"));
    EXPECT_EQ(q.value(QStringLiteral("folder")).toString(), QStringLiteral("to"));
    EXPECT_EQ(q.value(QStringLiteral("mode")).toString(), QStringLiteral("copy"));
    EXPECT_TRUE(q.value(QStringLiteral("replace")).toBool());
    EXPECT_TRUE(q.value(QStringLiteral("keepBoth")).toBool());
    EXPECT_FALSE(q.value(QStringLiteral("merge")).toBool());
    EXPECT_FALSE(q.value(QStringLiteral("applyToAll")).toBool());
    EXPECT_EQ(q.value(QStringLiteral("srcSize")).toLongLong(), 3);
    EXPECT_EQ(q.value(QStringLiteral("destSize")).toLongLong(), 3);
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("new"));
    EXPECT_EQ(names(QStringLiteral("to")), QStringList{QStringLiteral("a.txt")});
}

TEST_F(KioDialogsTest, KeepBothNamesTheNewItemAsKioWould)
{
    write(QStringLiteral("from/a.txt"), "new");
    write(QStringLiteral("to/a.txt"), "old");
    answer({{QStringLiteral("button"), QStringLiteral("keepBoth")}});
    const QString kept = KFileUtils::suggestName(url(QStringLiteral("to")), QStringLiteral("a.txt"));
    EXPECT_NE(kept, QStringLiteral("a.txt"));
    EXPECT_TRUE(run(withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    EXPECT_EQ(names(QStringLiteral("to")).size(), 2);
    EXPECT_TRUE(names(QStringLiteral("to")).contains(kept));
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("old"));
    EXPECT_EQ(read(QStringLiteral("to/") + kept), QByteArray("new"));
}

TEST_F(KioDialogsTest, StopCancelsAndLeavesTheDestination)
{
    write(QStringLiteral("from/a.txt"), "new");
    write(QStringLiteral("to/a.txt"), "old");
    answer({{QStringLiteral("button"), QStringLiteral("stop")}});
    EXPECT_FALSE(run(withGrassfieldsDelegate(KIO::move(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    EXPECT_EQ(lastError, KIO::ERR_USER_CANCELED);
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_EQ(m_asked.first().value(QStringLiteral("mode")).toString(), QStringLiteral("move"));
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("old"));
    EXPECT_EQ(read(QStringLiteral("from/a.txt")), QByteArray("new"));
}

TEST_F(KioDialogsTest, SkipWithApplyToAllAsksOnce)
{
    for (const QString &name : {QStringLiteral("a.txt"), QStringLiteral("b.txt"), QStringLiteral("c.txt")}) {
        write(QStringLiteral("from/") + name, "new");
        write(QStringLiteral("to/") + name, "old");
    }
    write(QStringLiteral("from/d.txt"), "new");
    answer({{QStringLiteral("button"), QStringLiteral("skip")}, {QStringLiteral("applyToAll"), true}});
    const QList<QUrl> sources{url(QStringLiteral("from/a.txt")), url(QStringLiteral("from/b.txt")), url(QStringLiteral("from/c.txt")),
                              url(QStringLiteral("from/d.txt"))};
    EXPECT_TRUE(run(withGrassfieldsDelegate(KIO::move(sources, url(QStringLiteral("to")), KIO::HideProgressInfo))));
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("skip")).toBool());
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("applyToAll")).toBool());
    for (const QString &name : {QStringLiteral("a.txt"), QStringLiteral("b.txt"), QStringLiteral("c.txt")}) {
        EXPECT_EQ(read(QStringLiteral("to/") + name), QByteArray("old")) << name.toStdString();
        EXPECT_EQ(read(QStringLiteral("from/") + name), QByteArray("new")) << name.toStdString();
    }
    EXPECT_EQ(read(QStringLiteral("to/d.txt")), QByteArray("new"));
}

TEST_F(KioDialogsTest, AFolderOntoAFolderIsAMerge)
{
    QDir().mkpath(path(QStringLiteral("from/Photos")));
    QDir().mkpath(path(QStringLiteral("to/Photos")));
    write(QStringLiteral("from/Photos/new.jpg"), "n");
    write(QStringLiteral("to/Photos/old.jpg"), "o");
    answer({{QStringLiteral("button"), QStringLiteral("replace")}});
    EXPECT_TRUE(run(withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/Photos")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("merge")).toBool());
    EXPECT_EQ(names(QStringLiteral("to/Photos")), (QStringList{QStringLiteral("new.jpg"), QStringLiteral("old.jpg")}));
}

TEST_F(KioDialogsTest, AFolderMovedOntoAFolderIsAMerge)
{
    // Within one file system KIO first renames, and asks without SourceIsDirectory (copyjob.cpp:2521-2533).
    QDir().mkpath(path(QStringLiteral("from/Photos")));
    QDir().mkpath(path(QStringLiteral("to/Photos")));
    write(QStringLiteral("from/Photos/new.jpg"), "n");
    write(QStringLiteral("to/Photos/old.jpg"), "o");
    answer({{QStringLiteral("button"), QStringLiteral("replace")}});
    EXPECT_TRUE(run(withGrassfieldsDelegate(KIO::move(url(QStringLiteral("from/Photos")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("merge")).toBool());
    EXPECT_EQ(m_asked.first().value(QStringLiteral("mode")).toString(), QStringLiteral("move"));
    EXPECT_EQ(names(QStringLiteral("to/Photos")), (QStringList{QStringLiteral("new.jpg"), QStringLiteral("old.jpg")}));
    EXPECT_FALSE(QFileInfo::exists(path(QStringLiteral("from/Photos"))));
}

TEST_F(KioDialogsTest, AFileOntoAFolderIsNeverAMerge)
{
    write(QStringLiteral("from/Photos"), "a file");
    QDir().mkpath(path(QStringLiteral("to/Photos")));
    answer({{QStringLiteral("button"), QStringLiteral("stop")}});
    EXPECT_FALSE(run(withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/Photos")), url(QStringLiteral("to")), KIO::HideProgressInfo))));
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_FALSE(m_asked.first().value(QStringLiteral("merge")).toBool());
    EXPECT_FALSE(m_asked.first().value(QStringLiteral("replace")).toBool());
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("destIsFolder")).toBool());
}

TEST_F(KioDialogsTest, TheSheetsAnswerReachesTheJob)
{
    write(QStringLiteral("from/a.txt"), "new");
    write(QStringLiteral("to/a.txt"), "old");
    KIO::CopyJob *job = withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo));
    bool finished = false;
    QObject::connect(job, &KJob::result, [&finished] {
        finished = true;
    });
    ASSERT_TRUE(waitFor([] {
        return !s_prompts->current().isEmpty();
    }));
    const QVariantMap shown = s_prompts->current();
    EXPECT_EQ(shown.value(QStringLiteral("kind")).toString(), QStringLiteral("conflict"));
    // An answer to a question no longer shown changes nothing.
    s_prompts->reply(shown.value(QStringLiteral("id")).toInt() + 1000, {{QStringLiteral("button"), QStringLiteral("stop")}});
    EXPECT_EQ(s_prompts->current(), shown);
    s_prompts->reply(shown.value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("replace")}});
    EXPECT_TRUE(s_prompts->current().isEmpty());
    ASSERT_TRUE(waitFor([&finished] {
        return finished;
    }));
    EXPECT_EQ(lastError, 0);
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("new"));
}

TEST_F(KioDialogsTest, AQuestionGoesWhenItsJobEnds)
{
    write(QStringLiteral("from/a.txt"), "new");
    write(QStringLiteral("to/a.txt"), "old");
    KIO::CopyJob *job = withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo));
    ASSERT_TRUE(waitFor([] {
        return !s_prompts->current().isEmpty();
    }));
    job->kill();
    EXPECT_TRUE(s_prompts->current().isEmpty());
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("old"));
}

// The certificate sheet through the extension KIO's worker asks (KIO's UserNotificationHandler): Continue answers 1, and
// KIO's http worker's next question on the same job, "Forever" or "Current Session only" (WarningTwoActionsCancel), is
// answered from "Always trust" without a sheet; any other question is a sheet.
TEST_F(KioDialogsTest, TheCertificateSheetAnswersKiosFollowUp)
{
    std::unique_ptr<KJobUiDelegate> delegate(KioDialogs::createDelegate());
    auto *ask = delegate->findChild<GrassfieldAskUserAction *>();
    ASSERT_NE(ask, nullptr);
    QList<int> sslAnswers;
    QList<int> boxAnswers;
    QObject::connect(ask, &KIO::AskUserActionInterface::askIgnoreSslErrorsResult, [&sslAnswers](int r) {
        sslAnswers << r;
    });
    QObject::connect(ask, &KIO::AskUserActionInterface::messageBoxResult, [&boxAnswers](int r) {
        boxAnswers << r;
    });
    const QVariantMap ssl{{QStringLiteral("hostname"), QStringLiteral("files.example.org")},
                          {QStringLiteral("sslError"), QStringLiteral("The certificate has expired")}};
    const auto followUp = [ask] {
        ask->requestUserMessageBox(KIO::AskUserActionInterface::WarningTwoActionsCancel, QStringLiteral("Accept it?"),
                                   QStringLiteral("Server Authentication"), QStringLiteral("&Forever"),
                                   QStringLiteral("&Current Session only"));
    };

    for (const bool trust : {true, false}) {
        sslAnswers.clear();
        boxAnswers.clear();
        ask->askIgnoreSslErrors(ssl, nullptr);
        ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("certificate"));
        EXPECT_EQ(s_prompts->current().value(QStringLiteral("host")).toString(), QStringLiteral("files.example.org"));
        s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(),
                         {{QStringLiteral("button"), QStringLiteral("continue")}, {QStringLiteral("alwaysTrust"), trust}});
        // The answer comes after the call that gave it (KIO connects to it only once it has asked).
        EXPECT_TRUE(sslAnswers.isEmpty());
        ASSERT_TRUE(waitFor([&sslAnswers] {
            return !sslAnswers.isEmpty();
        }));
        EXPECT_EQ(sslAnswers, QList<int>{1});
        followUp();
        EXPECT_TRUE(s_prompts->current().isEmpty()) << "the follow-up is not a sheet";
        ASSERT_TRUE(waitFor([&boxAnswers] {
            return !boxAnswers.isEmpty();
        }));
        EXPECT_EQ(boxAnswers, QList<int>{trust ? KIO::WorkerBase::PrimaryAction : KIO::WorkerBase::SecondaryAction}) << trust;
        // The box answers that one question only: the same question again is a sheet.
        followUp();
        ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message")) << trust;
        s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
        ASSERT_TRUE(waitFor([&boxAnswers] {
            return boxAnswers.size() == 2;
        }));
    }

    // Cancel: no follow-up answer is kept; the same question afterwards is a sheet of its own.
    sslAnswers.clear();
    boxAnswers.clear();
    ask->askIgnoreSslErrors(ssl, nullptr);
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
    ASSERT_TRUE(waitFor([&sslAnswers] {
        return !sslAnswers.isEmpty();
    }));
    EXPECT_EQ(sslAnswers, QList<int>{0});
    followUp();
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message"));
    EXPECT_EQ(s_prompts->current().value(QStringLiteral("primary")).toString(), QStringLiteral("Forever"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
    ASSERT_TRUE(waitFor([&boxAnswers] {
        return !boxAnswers.isEmpty();
    }));
    EXPECT_EQ(boxAnswers, QList<int>{KIO::WorkerBase::Cancel});

    // The follow-up may come late (KIO asks worker message boxes one at a time): still answered, with no time limit.
    sslAnswers.clear();
    boxAnswers.clear();
    ask->askIgnoreSslErrors(ssl, nullptr);
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(),
                     {{QStringLiteral("button"), QStringLiteral("continue")}, {QStringLiteral("alwaysTrust"), false}});
    ASSERT_TRUE(waitFor([&sslAnswers] {
        return !sslAnswers.isEmpty();
    }));
    QEventLoop late;
    QTimer::singleShot(1500, &late, &QEventLoop::quit);
    late.exec();
    followUp();
    EXPECT_TRUE(s_prompts->current().isEmpty());
    ASSERT_TRUE(waitFor([&boxAnswers] {
        return !boxAnswers.isEmpty();
    }));
    EXPECT_EQ(boxAnswers, QList<int>{KIO::WorkerBase::SecondaryAction});

    // Continue, then a deletion question first: it clears "Always trust" (every kind of question does).
    sslAnswers.clear();
    boxAnswers.clear();
    ask->askIgnoreSslErrors(ssl, nullptr);
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(),
                     {{QStringLiteral("button"), QStringLiteral("continue")}, {QStringLiteral("alwaysTrust"), true}});
    ASSERT_TRUE(waitFor([&sslAnswers] {
        return !sslAnswers.isEmpty();
    }));
    ask->askUserDelete({url(QStringLiteral("from/x"))}, KIO::AskUserActionInterface::Delete, KIO::AskUserActionInterface::DefaultConfirmation);
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("delete"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
    followUp();
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
    ASSERT_TRUE(waitFor([&boxAnswers] {
        return !boxAnswers.isEmpty();
    }));
    EXPECT_EQ(boxAnswers, QList<int>{KIO::WorkerBase::Cancel});

    // Continue, then another kind of question first: it is a sheet, and "Always trust" answers nothing after it.
    sslAnswers.clear();
    boxAnswers.clear();
    ask->askIgnoreSslErrors(ssl, nullptr);
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(),
                     {{QStringLiteral("button"), QStringLiteral("continue")}, {QStringLiteral("alwaysTrust"), true}});
    ASSERT_TRUE(waitFor([&sslAnswers] {
        return !sslAnswers.isEmpty();
    }));
    ask->requestUserMessageBox(KIO::AskUserActionInterface::Information, QStringLiteral("Note"), QString(), QString(), QString());
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("ok")}});
    followUp();
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("cancel")}});
}

// A question without a job (a worker's message box) goes with the delegate that asked it: no answer reaches a deleted
// extension.
TEST_F(KioDialogsTest, AQuestionGoesWithTheDelegateThatAsked)
{
    auto *delegate = KioDialogs::createDelegate();
    auto *ask = delegate->findChild<GrassfieldAskUserAction *>();
    ASSERT_NE(ask, nullptr);
    ask->requestUserMessageBox(KIO::AskUserActionInterface::QuestionTwoActions, QStringLiteral("Overwrite?"), QString(),
                               QStringLiteral("Yes"), QStringLiteral("No"));
    ASSERT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("message"));
    const int id = s_prompts->current().value(QStringLiteral("id")).toInt();
    delete delegate;
    EXPECT_TRUE(s_prompts->current().isEmpty());
    s_prompts->reply(id, {{QStringLiteral("button"), QStringLiteral("primary")}}); // a late reply: nothing happens

    // Answered, then the delegate goes before the answer is delivered (the next turn of the event loop): it is not.
    auto *second = KioDialogs::createDelegate();
    auto *ask2 = second->findChild<GrassfieldAskUserAction *>();
    ASSERT_NE(ask2, nullptr);
    ask2->requestUserMessageBox(KIO::AskUserActionInterface::QuestionTwoActions, QStringLiteral("Overwrite?"), QString(),
                                QStringLiteral("Yes"), QStringLiteral("No"));
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("primary")}});
    delete second;
    QEventLoop settle;
    QTimer::singleShot(50, &settle, &QEventLoop::quit);
    settle.exec(); // a delivery to the deleted extension would crash here
}

namespace
{
// A job that ends when told to (KJob::emitResult is protected).
class EndingJob : public KJob
{
public:
    void start() override
    {
    }
    void end()
    {
        emitResult();
    }
};
} // namespace

// An answer is delivered on the next turn of the event loop (KioPrompts::reply): a job that ended meanwhile does not get it.
TEST_F(KioDialogsTest, AnAnswerNeverReachesAJobThatEnded)
{
    auto *job = new EndingJob;
    bool answered = false;
    s_prompts->ask({{QStringLiteral("kind"), QStringLiteral("notice")}, {QStringLiteral("title"), QStringLiteral("t")}}, job,
                   [&answered](const QVariantMap &) {
                       answered = true;
                   });
    ASSERT_FALSE(s_prompts->current().isEmpty());
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("ok")}});
    job->end(); // before the answer's turn comes
    QEventLoop settle;
    QTimer::singleShot(50, &settle, &QEventLoop::quit);
    settle.exec();
    EXPECT_FALSE(answered);

    // The control: a job still running gets it.
    auto *running = new EndingJob;
    s_prompts->ask({{QStringLiteral("kind"), QStringLiteral("notice")}, {QStringLiteral("title"), QStringLiteral("t")}}, running,
                   [&answered](const QVariantMap &) {
                       answered = true;
                   });
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("ok")}});
    EXPECT_TRUE(waitFor([&answered] {
        return answered;
    }));
    running->end();
}

// A sheet closed without a button of the question ("stop": no window, a kind it does not know) gives the safe answer:
// Cancel where there is one, else the secondary action of a two-action question, never OK.
TEST_F(KioDialogsTest, AStoppedMessageGivesTheSafeAnswer)
{
    std::unique_ptr<KJobUiDelegate> delegate(KioDialogs::createDelegate());
    auto *ask = delegate->findChild<GrassfieldAskUserAction *>();
    ASSERT_NE(ask, nullptr);
    QList<int> answers;
    QObject::connect(ask, &KIO::AskUserActionInterface::messageBoxResult, [&answers](int r) {
        answers << r;
    });
    struct Case {
        KIO::AskUserActionInterface::MessageDialogType type;
        int expected;
    };
    const Case cases[] = {
        {KIO::AskUserActionInterface::QuestionTwoActions, KIO::WorkerBase::SecondaryAction},
        {KIO::AskUserActionInterface::WarningTwoActions, KIO::WorkerBase::SecondaryAction},
        {KIO::AskUserActionInterface::QuestionTwoActionsCancel, KIO::WorkerBase::Cancel},
        {KIO::AskUserActionInterface::WarningContinueCancel, KIO::WorkerBase::Cancel},
        {KIO::AskUserActionInterface::Information, KIO::WorkerBase::Ok},
    };
    for (const Case &c : cases) {
        answers.clear();
        ask->requestUserMessageBox(c.type, QStringLiteral("?"), QString(), QStringLiteral("Yes"), QStringLiteral("No"));
        ASSERT_FALSE(s_prompts->current().isEmpty());
        s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("stop")}});
        ASSERT_TRUE(waitFor([&answers] {
            return !answers.isEmpty();
        }));
        EXPECT_EQ(answers.first(), c.expected) << c.type;
    }
}

// Once Files' prompts are gone (Files quitting while a job runs), a question gets the safe answer, not a crash.
TEST_F(KioDialogsTest, WithoutFilesPromptsTheAnswerIsSafe)
{
    auto *gone = new KioPrompts;
    auto *delegate = new GrassfieldJobUiDelegate(gone);
    auto *ask = delegate->findChild<GrassfieldAskUserAction *>();
    ASSERT_NE(ask, nullptr);
    delete gone;
    auto *job = new EndingJob;
    QList<KIO::RenameDialog_Result> results;
    QObject::connect(ask, &KIO::AskUserActionInterface::askUserRenameResult, [&results](KIO::RenameDialog_Result r, const QUrl &, KJob *) {
        results << r;
    });
    ask->askUserRename(job, QString(), url(QStringLiteral("from/a")), url(QStringLiteral("to/a")), KIO::RenameDialog_Overwrite, 1, 1);
    ASSERT_TRUE(waitFor([&results] {
        return !results.isEmpty();
    }));
    EXPECT_EQ(results.first(), KIO::Result_Cancel) << "Stop, never Replace";
    EXPECT_TRUE(s_prompts->current().isEmpty()) << "nothing asked through another window's prompts";
    job->end();
    delete delegate;
}

// A document whose type has no application (ADR-0035 5c-3; A-OW2): Finder's alert, then on Choose Application… the
// Choose Application panel; the application chosen opens the document. Cancel on the alert opens nothing, and a job that
// ends takes its panel away.
TEST_F(KioDialogsTest, NoApplicationAsksThenChoosesOne)
{
    // A type nothing opens, and an application that copies what it is given next to it.
    write(QStringLiteral("from/a.gfnone"), QByteArray("\x00\x01\x02\x03", 4));
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(apps));
    {
        QFile entry(apps + QStringLiteral("/org.example.GfOpenWithCopy.desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=Copy\nExec=cp %f %1\n").arg(path(QStringLiteral("to/opened"))).toUtf8());
    }
    ASSERT_TRUE(waitFor([] {
        KSycoca::self()->ensureCacheValid();
        return KService::serviceByMenuId(QStringLiteral("org.example.GfOpenWithCopy.desktop"));
    }));
    ApplicationChooser *chooser = s_prompts->applications();
    QList<QVariantMap> panels;
    QString choice = QStringLiteral("org.example.GfOpenWithCopy");
    const QMetaObject::Connection c = QObject::connect(chooser, &ApplicationChooser::opened, chooser, [&](int id, const QVariantMap &request) {
        panels << request;
        if (!choice.isEmpty())
            chooser->answer(id, 0, {{QStringLiteral("choice"), choice}});
    });
    const auto open = [this] {
        auto *job = new KIO::OpenUrlJob(url(QStringLiteral("from/a.gfnone")));
        job->setUiDelegate(KioDialogs::createDelegate(KJobUiDelegate::AutoHandlingDisabled));
        job->setRunExecutables(false);
        job->start(); // its handler answers after this returns (KioPrompts' responder, ApplicationChooser)
        return job;
    };

    answer({{QStringLiteral("button"), QStringLiteral("choose")}});
    EXPECT_TRUE(run(open()));
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_EQ(m_asked.first().value(QStringLiteral("kind")).toString(), QStringLiteral("noApplication"));
    EXPECT_EQ(m_asked.first().value(QStringLiteral("name")).toString(), QStringLiteral("a.gfnone"));
    ASSERT_EQ(panels.size(), 1);
    EXPECT_EQ(panels.first().value(QStringLiteral("kind")).toString(), QStringLiteral("application"));
    EXPECT_EQ(panels.first().value(QStringLiteral("filename")).toString(), QStringLiteral("a.gfnone"));
    EXPECT_TRUE(waitFor([this] {
        return read(QStringLiteral("to/opened")) == QByteArray("\x00\x01\x02\x03", 4);
    })) << "the chosen application opened the document";

    // Cancel on the alert: no panel, nothing opened, and the job ends as cancelled. Hermetic: no grassfield-store on the PATH
    // (an empty folder: the machine's own /usr/bin/grassfield-store is not seen) and not a dev session (the dev build beside
    // this binary is not taken), whatever the machine running the test has installed.
    struct Restore {
        QByteArray path = qgetenv("PATH"), dev = qgetenv("GRASSFIELD_DEV");
        bool hadDev = qEnvironmentVariableIsSet("GRASSFIELD_DEV");
        ~Restore()
        {
            qputenv("PATH", path);
            if (hadDev)
                qputenv("GRASSFIELD_DEV", dev);
        }
    } restore; // put back however the case ends
    const QByteArray savedPath = restore.path;
    qunsetenv("GRASSFIELD_DEV");
    const QString noStore = path(QStringLiteral("no-store-bin"));
    ASSERT_TRUE(QDir().mkpath(noStore));
    qputenv("PATH", noStore.toUtf8());
    m_asked.clear();
    panels.clear();
    QFile::remove(path(QStringLiteral("to/opened")));
    answer({{QStringLiteral("button"), QStringLiteral("cancel")}});
    KJob *cancelled = open();
    int error = 0;
    QObject::connect(cancelled, &KJob::result, cancelled, [&error](KJob *j) {
        error = j->error();
    });
    EXPECT_FALSE(run(cancelled));
    EXPECT_EQ(error, int(KIO::ERR_USER_CANCELED));
    EXPECT_EQ(m_asked.size(), 1);
    EXPECT_TRUE(panels.isEmpty());
    EXPECT_FALSE(m_asked.first().value(QStringLiteral("store")).toBool()) << "no Grassfield Store here: no Search the Store";
    qputenv("PATH", savedPath);

    // Search the Store (Finder's App Store button; ADR-0035 5c-3, Store step 4): offered once Grassfield Store is on the PATH;
    // it starts the Store on the document's type (--page=type:<type>), and the job ends as cancelled (nothing opens it yet).
    const QString bin = path(QStringLiteral("bin"));
    ASSERT_TRUE(QDir().mkpath(bin));
    {
        QFile store(bin + QStringLiteral("/grassfield-store"));
        ASSERT_TRUE(store.open(QIODevice::WriteOnly));
        store.write("#!/bin/sh\necho \"$*\" >\"$(dirname \"$0\")/asked.tmp\" && mv \"$(dirname \"$0\")/asked.tmp\" \"$(dirname \"$0\")/asked\"\n");
        store.close();
        store.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    }
    qputenv("PATH", bin.toUtf8() + ':' + savedPath);
    m_asked.clear();
    answer({{QStringLiteral("button"), QStringLiteral("store")}});
    EXPECT_FALSE(run(open()));
    qputenv("PATH", savedPath);
    ASSERT_EQ(m_asked.size(), 1);
    EXPECT_TRUE(m_asked.first().value(QStringLiteral("store")).toBool());
    EXPECT_TRUE(panels.isEmpty()) << "no Choose Application panel";
    EXPECT_TRUE(waitFor([&bin] {
        return QFile::exists(bin + QStringLiteral("/asked"));
    })) << "the Store was started";
    QFile asked(bin + QStringLiteral("/asked"));
    ASSERT_TRUE(asked.open(QIODevice::ReadOnly));
    const QByteArray args = asked.readAll().trimmed();
    EXPECT_TRUE(args.startsWith("--page=type:") && args.contains('/')) << args.constData();
    EXPECT_FALSE(QFile::exists(path(QStringLiteral("to/opened"))));

    // Cancel in the panel: the job ends as cancelled.
    answer({{QStringLiteral("button"), QStringLiteral("choose")}});
    choice.clear();
    QList<int> closed;
    const QMetaObject::Connection d = QObject::connect(chooser, &ApplicationChooser::opened, chooser, [&](int id, const QVariantMap &) {
        chooser->answer(id, 1);
    });
    EXPECT_FALSE(run(open()));
    QObject::disconnect(d);

    // A job killed while its panel is open: the panel goes.
    const QMetaObject::Connection e = QObject::connect(chooser, &ApplicationChooser::closed, chooser, [&closed](int id) {
        closed << id;
    });
    panels.clear();
    KJob *killed = open();
    ASSERT_TRUE(waitFor([&panels] {
        return !panels.isEmpty();
    }));
    killed->kill();
    EXPECT_EQ(closed.size(), 1);
    QObject::disconnect(e);
    QObject::disconnect(c);
    EXPECT_FALSE(QFile::exists(path(QStringLiteral("to/opened"))));
}

TEST_F(KioDialogsTest, KiosOwnJobsGetGrassfieldsDelegate)
{
    // KIO gives the jobs it makes itself (sub-jobs such as DirectCopyJob, src/core/job.cpp:282; undo's jobs) a delegate
    // from the default factory: Grassfield's, with Grassfield's extensions.
    std::unique_ptr<KJobUiDelegate> made(KIO::createDefaultJobUiDelegate());
    EXPECT_NE(dynamic_cast<GrassfieldJobUiDelegate *>(made.get()), nullptr);
    std::unique_ptr<KJobUiDelegate> withFlags(KIO::createDefaultJobUiDelegate(KJobUiDelegate::AutoHandlingEnabled, nullptr));
    EXPECT_NE(dynamic_cast<GrassfieldJobUiDelegate *>(withFlags.get()), nullptr);

    KIO::StatJob *job = KIO::stat(url(QStringLiteral("from")), KIO::HideProgressInfo);
    EXPECT_NE(dynamic_cast<GrassfieldAskUserAction *>(KIO::delegateExtension<KIO::AskUserActionInterface *>(job)), nullptr);
    EXPECT_NE(dynamic_cast<GrassfieldOpenWithHandler *>(KIO::delegateExtension<KIO::OpenWithHandlerInterface *>(job)), nullptr);
    EXPECT_NE(dynamic_cast<GrassfieldUntrustedProgramHandler *>(KIO::delegateExtension<KIO::UntrustedProgramHandlerInterface *>(job)), nullptr);
    EXPECT_TRUE(run(job));
}

TEST_F(KioDialogsTest, AnErrorKioReportsItselfIsASheet)
{
    // Where KIO turns automatic error handling on for a job (KDirModel's renames, src/widgets/kdirmodel.cpp:1038), the
    // error is Grassfield's notice, not KIO's message box.
    KIO::StatJob *job = KIO::stat(url(QStringLiteral("nowhere")), KIO::HideProgressInfo);
    job->uiDelegate()->setAutoErrorHandlingEnabled(true);
    EXPECT_FALSE(run(job));
    ASSERT_FALSE(s_prompts->current().isEmpty());
    EXPECT_EQ(s_prompts->current().value(QStringLiteral("kind")).toString(), QStringLiteral("notice"));
    EXPECT_FALSE(s_prompts->current().value(QStringLiteral("text")).toString().isEmpty());
    s_prompts->reply(s_prompts->current().value(QStringLiteral("id")).toInt(), {{QStringLiteral("button"), QStringLiteral("ok")}});
}

TEST_F(KioDialogsTest, UndoKeepsACopyChangedSince)
{
    write(QStringLiteral("from/a.txt"), "new");
    KIO::CopyJob *job = withGrassfieldsDelegate(KIO::copy(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo));
    KIO::FileUndoManager::self()->recordCopyJob(job);
    ASSERT_TRUE(run(job));
    ASSERT_TRUE(KIO::FileUndoManager::self()->isUndoAvailable());
    {
        QFile copy(path(QStringLiteral("to/a.txt")));
        ASSERT_TRUE(copy.open(QIODevice::ReadWrite));
        ASSERT_TRUE(copy.setFileTime(QDateTime::currentDateTime().addSecs(3600), QFileDevice::FileModificationTime));
    }
    KIO::FileUndoManager::self()->undo();
    ASSERT_TRUE(waitFor([] {
        return !s_reported.isEmpty();
    }));
    EXPECT_TRUE(s_reported.first().contains(QStringLiteral("a.txt"))) << s_reported.first().toStdString();
    EXPECT_EQ(read(QStringLiteral("to/a.txt")), QByteArray("new"));
    EXPECT_NE(dynamic_cast<GrassfieldUndoUi *>(KIO::FileUndoManager::self()->uiInterface()), nullptr);
}

TEST_F(KioDialogsTest, UndoOfALinkOpensNoProgressWindow)
{
    // Undo removes a link with a job KIO tracks (KIO::file_delete without HideProgressInfo, fileundomanager.cpp:699): with
    // no KDE job server, KIO's tracker would make its progress window (TearDown fails on any widget).
    write(QStringLiteral("from/a.txt"), "a");
    KIO::CopyJob *job = withGrassfieldsDelegate(KIO::link(url(QStringLiteral("from/a.txt")), url(QStringLiteral("to")), KIO::HideProgressInfo));
    KIO::FileUndoManager::self()->recordCopyJob(job);
    ASSERT_TRUE(run(job));
    ASSERT_TRUE(QFileInfo(path(QStringLiteral("to/a.txt"))).isSymLink());
    bool undone = false;
    const auto done = QObject::connect(KIO::FileUndoManager::self(), &KIO::FileUndoManager::undoJobFinished, [&undone] {
        undone = true;
    });
    KIO::FileUndoManager::self()->undo();
    EXPECT_TRUE(waitFor([&undone] {
        return undone;
    }));
    QObject::disconnect(done);
    EXPECT_FALSE(QFileInfo(path(QStringLiteral("to/a.txt"))).isSymLink()) << "the link is removed";
    EXPECT_TRUE(s_reported.isEmpty()) << (s_reported.isEmpty() ? std::string() : s_reported.first().toStdString());
}

TEST_F(KioDialogsTest, AJobKioTracksMakesNoProgressWindow)
{
    // A KIO job started without HideProgressInfo registers with KIO's job tracker as it is made (statjob.cpp:51-53); KIO's
    // own tracker, with no KDE job server on the bus, makes its progress widget right there (KWidgetJobTracker), and
    // deletes it when the job ends: checked at once, not only after the case.
    KIO::StatJob *job = KIO::stat(url(QStringLiteral("from")));
    EXPECT_TRUE(QApplication::topLevelWidgets().isEmpty()) << "KIO's progress window";
    EXPECT_TRUE(run(job));
}

// What Files pastes: items only (ADR-0035 4a-14). Text, an image, or URLs KIO::paste would not take as items would go to
// KIO's own dialogs (KIO::PasteDialog).
TEST(KioDialogsPaste, OnlyItemsArePasted)
{
    QMimeData text;
    text.setText(QStringLiteral("some words"));
    EXPECT_TRUE(KioDialogs::pastableItems(&text).isEmpty());
    QMimeData image;
    image.setData(QStringLiteral("image/png"), QByteArray("\x89PNG", 4));
    EXPECT_TRUE(KioDialogs::pastableItems(&image).isEmpty());
    QMimeData kdeOnly; // KIO::paste reads items from text/uri-list only (pastejob.cpp:68-70)
    kdeOnly.setData(QStringLiteral("application/x-kde4-urilist"), QByteArray("file:///tmp/a\r\n"));
    EXPECT_TRUE(KioDialogs::pastableItems(&kdeOnly).isEmpty());
    EXPECT_TRUE(KioDialogs::pastableItems(nullptr).isEmpty());
    QMimeData items;
    items.setUrls({QUrl::fromLocalFile(QStringLiteral("/tmp/a")), QUrl(QStringLiteral("sftp://host/b"))});
    items.setText(QStringLiteral("/tmp/a"));
    EXPECT_EQ(KioDialogs::pastableItems(&items).size(), 2);
}

// The sources of Files: no widget dialog of KIO or Qt (every question is a sheet), every delegate Grassfield's, and no job
// that asks KIO's "open or execute" question (OpenOrExecuteFileInterface, which Grassfield does not provide).
TEST(KioDialogsSources, FilesCreatesNoWidgetDialog)
{
    const QStringList forbidden{
        QStringLiteral("KMessageBox"),       QStringLiteral("KMessageDialog"),   QStringLiteral("QMessageBox"),
        QStringLiteral("QFileDialog"),       QStringLiteral("QInputDialog"),     QStringLiteral("QProgressDialog"),
        QStringLiteral("QColorDialog"),      QStringLiteral("QFontDialog"),      QStringLiteral("KOpenWithDialog"),
        QStringLiteral("KPropertiesDialog"), QStringLiteral("KSslInfoDialog"),   QStringLiteral("RenameDialog("),
        QStringLiteral("SkipDialog("),       QStringLiteral("KDialogJobUiDelegate"), QStringLiteral("KFileWidget"),
        QStringLiteral("KDirOperator"),      QStringLiteral("setShowOpenOrExecuteDialog"),
        QStringLiteral("WidgetsAskUserActionHandler"), QStringLiteral("PasteDialog"),
        // Files decides what it pastes itself (KioDialogs::pastableItems): KIO's rule accepts text, which goes to its dialogs.
        QStringLiteral("canPasteMimeData"),
    };
    // A comment starts at "//" after a space or at the start of a line ("file://" in a literal is code).
    static const QRegularExpression comment(QStringLiteral("(^|\\s)//.*$"));
    int files = 0;
    QDirIterator it(QStringLiteral(FILES_SOURCE_DIR), {QStringLiteral("*.cpp"), QStringLiteral("*.h")}, QDir::Files);
    while (it.hasNext()) {
        const QString file = it.next();
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::ReadOnly | QIODevice::Text)) << file.toStdString();
        ++files;
        int line = 0;
        while (!f.atEnd()) {
            ++line;
            QString code = QString::fromUtf8(f.readLine());
            code.remove(comment);
            for (const QString &word : forbidden)
                EXPECT_FALSE(code.contains(word)) << file.toStdString() << ":" << line << ": " << word.toStdString();
            // Every delegate Files sets is Grassfield's.
            if (code.contains(QLatin1String("setUiDelegate("))) {
                EXPECT_TRUE(code.contains(QLatin1String("KioDialogs::createDelegate("))) << file.toStdString() << ":" << line;
            }
        }
    }
    EXPECT_GT(files, 10);
}

int main(int argc, char **argv)
{
    ::testing::InitGoogleTest(&argc, argv);
    // A scratch home: KIO's worker, FileUndoManager and Qt write nothing of the session that runs the tests. Grassfield's own
    // GRASSFIELD_STATE_HOME and GRASSFIELD_CONFIG_HOME win over the XDG folders (runmode.h; the dev shells set them to .dev
    // paths): redirected too, so Files' state (files-staging, files-views.json) and config land in the scratch home only.
    QTemporaryDir scratch(QDir(qEnvironmentVariableIsEmpty("GRASSFIELD_TEST_TMP") ? QDir::tempPath() : qEnvironmentVariable("GRASSFIELD_TEST_TMP"))
                              .filePath(QStringLiteral("kiodialogs-XXXXXX")));
    if (!scratch.isValid())
        return 2;
    for (const char *name : {"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
                             "GRASSFIELD_STATE_HOME", "GRASSFIELD_CONFIG_HOME"}) {
        const QString dir = scratch.filePath(QString::fromLatin1(name));
        QDir().mkpath(dir);
        QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
        qputenv(name, dir.toLocal8Bit());
    }
    // GRASSFIELD_SESSION too: a terminal of the session sets it, and apps then start through uwsm-app, which cannot reach its
    // daemon from this scratch runtime folder (integrator review of #97: "Search the Store" failed from a session terminal).
    for (const char *name : {"DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "QT_QPA_PLATFORMTHEME", "QT_IM_MODULE", "QT_IM_MODULES",
                             "GRASSFIELD_SESSION"})
        qunsetenv(name);
    qputenv("QT_QPA_PLATFORM", "offscreen");
    s_scratch = &scratch;

    QApplication app(argc, argv); // Files is a QApplication (KIO's widget dialogs could exist here: none must)
    auto *prompts = new KioPrompts(&app);
    KioDialogs::install(prompts, [](const QString &message) {
        s_reported << message;
    });
    s_prompts = prompts;
    const int result = RUN_ALL_TESTS();
    delete prompts;
    // Once Files' prompts are gone, KIO's default factory and undo interface are KIO's again.
    if (dynamic_cast<GrassfieldJobUiDelegate *>(std::unique_ptr<KJobUiDelegate>(KIO::createDefaultJobUiDelegate()).get())
        || dynamic_cast<GrassfieldUndoUi *>(KIO::FileUndoManager::self()->uiInterface())
        || typeid(*KIO::getJobTracker()) == typeid(KJobTrackerInterface)) {
        std::fprintf(stderr, "Grassfield's delegate factory, undo interface or job tracker outlived Files' prompts\n");
        return 1;
    }
    return result;
}
