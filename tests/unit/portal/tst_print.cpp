// grassfield-portal's print sheet (ADR-0035 D-7, steps 6a and 6b; docs/specs/system-dialogs.md section 7, PR1-PR5, A-PR1): what
// the sheet is given (Print::toQml), and org.freedesktop.impl.portal.Print on the run's private bus (tst_filechooser.cpp's main)
// with a fake frontend, a fake x-d-p-gtk and a fake print system: PreparePrint's answer with GTK's keys and a token, the job
// Print sends with that token (the CUPS options, the document), the token good once for its application, Save as PDF, Cancel,
// a printer that refuses, no printer, another printer chosen, and the forward to x-d-p-gtk. Step 6b: a document sent first (the
// sheet with its preview, drawn by a confined child: this binary, as grassfield-portal runs itself), Open in Preview, Last Used
// Settings and a printer's own options.
#include <gtest/gtest.h>

#include "print.h"
#include "printpreview.h"
#include "printsystem.h"

#include <QDBusAbstractAdaptor>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusUnixFileDescriptor>
#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QUrl>

#include <cups/cups.h>

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <cerrno>

#include <algorithm>
#include <functional>
#include <limits>
#include <memory>
#include <utility>

using namespace grassfield::portal;

extern QString g_address;

namespace {

constexpr auto kService = "org.freedesktop.impl.portal.desktop.grassfield";
constexpr auto kFakeGtk = "org.test.fakegtk.print";
constexpr int kDeadlineMs = 1500;

print::Media media(const QString &name, double w, double h)
{
    print::Media m;
    m.name = name;
    m.displayName = print::mediaDisplayName(name);
    m.widthMm = w;
    m.heightMm = h;
    m.topMm = m.bottomMm = m.leftMm = m.rightMm = 3;
    return m;
}

// CUPS as the backend sees it: two printers (Office the default: colour, two sides; Mono: neither), answered on the next
// turn of the event loop; the jobs it gets, their documents read to the end.
class FakePrintSystem : public PrintSystem
{
    Q_OBJECT
public:
    struct Job {
        QString printer;
        QString title;
        Options options;
        QByteArray document;
    };
    QList<print::Destination> printers{{QStringLiteral("Office"), QStringLiteral("Office Printer"), QStringLiteral("Hall"), true},
                                       {QStringLiteral("Mono"), QStringLiteral("Mono Laser"), QString(), false}};
    bool listed = true;
    QString refuse;
    QList<Job> jobs;
    QStringList asked;
    // Office's own options (none unless a test gives some) and its default paper ("": A4).
    QList<print::PrinterOption> officeOptions;
    QString officeDefault;

    static print::Capabilities caps(const QString &printer)
    {
        print::Capabilities c;
        c.known = true;
        c.media = {media(QStringLiteral("iso_a4_210x297mm"), 210, 297), media(QStringLiteral("iso_a5_148x210mm"), 148, 210)};
        c.defaultMedia = QStringLiteral("iso_a4_210x297mm");
        c.twoSided = printer == QLatin1String("Office");
        c.color = printer == QLatin1String("Office");
        c.maxCopies = 50;
        return c;
    }

    void destinations(QObject *context, DestinationsDone done) override
    {
        QTimer::singleShot(0, context, [this, done] { done(listed ? printers : QList<print::Destination>{}, listed); });
    }
    void capabilities(const QString &printer, QObject *context, CapabilitiesDone done) override
    {
        asked << printer;
        print::Capabilities c = caps(printer);
        if (printer == QLatin1String("Office")) {
            c.options = officeOptions;
            if (!officeDefault.isEmpty())
                c.defaultMedia = officeDefault;
        }
        QTimer::singleShot(0, context, [c, done] { done(c); });
    }
    // A job held (holdJobs): its document is not read and its answer waits until the test lets it go; `stops` counts the stops
    // the backend asked for (a request closed while its job was being sent).
    bool holdJobs = false;
    int stops = 0;
    Stop submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done) override
    {
        if (holdJobs) {
            ::close(fd);
            return [this] { ++stops; };
        }
        Job job{printer, title, options, {}};
        char buffer[4096];
        ssize_t n;
        while ((n = ::read(fd, buffer, sizeof buffer)) > 0)
            job.document.append(buffer, n);
        ::close(fd);
        jobs << job;
        QTimer::singleShot(0, context, [this, done] { done(refuse); });
        return [this] { ++stops; };
    }
};

// x-d-p-gtk's Print as the forward sees it: holds each call until the test answers it.
class FakeGtkPrint : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Print")
public:
    QStringList calls;
    QDBusMessage held;
    // Where the document's descriptor stood when it came (a document sent on as it came stands at its start).
    QList<qint64> offsets;

public Q_SLOTS:
    uint PreparePrint(const QDBusObjectPath &handle, const QString &, const QString &, const QString &, const QVariantMap &,
                      const QVariantMap &, const QVariantMap &, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("PreparePrint %1").arg(handle.path());
        message.setDelayedReply(true);
        held = message;
        return 0;
    }
    uint Print(const QDBusObjectPath &handle, const QString &, const QString &, const QString &, const QDBusUnixFileDescriptor &fd,
               const QVariantMap &options, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("Print %1 token %2 fd %3")
                     .arg(handle.path())
                     .arg(options.value(QStringLiteral("token")).toUInt())
                     .arg(fd.isValid() ? QStringLiteral("valid") : QStringLiteral("none"));
        offsets << (fd.isValid() ? qint64(::lseek(fd.fileDescriptor(), 0, SEEK_CUR)) : -1);
        message.setDelayedReply(true);
        held = message;
        return 0;
    }
};

// The process's own FileChooser as Save as PDF calls it (SaveFile on the backend's own connection): holds the call until the
// test answers it, and records Close.
// A request's Request object, as the real FileChooser exports one at the handle: records Close.
class FakeRequest : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Request")
public:
    QStringList *closes = nullptr;
    QString handle;

public Q_SLOTS:
    Q_SCRIPTABLE void Close() { closes->append(handle); }
};

class FakeSaveFile : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.FileChooser")
public:
    FakeSaveFile(QObject *parent, QDBusConnection *bus)
        : QDBusAbstractAdaptor(parent)
        , m_bus(bus)
    {
    }
    QStringList calls;
    QStringList closes;
    QDBusMessage held;
    QList<std::shared_ptr<FakeRequest>> requests;

public Q_SLOTS:
    uint SaveFile(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("SaveFile %1 %2 %3 %4 %5")
                     .arg(handle.path().section(QLatin1Char('/'), 0, -2), appId, parentWindow, title,
                          options.value(QStringLiteral("current_name")).toString());
        auto request = std::make_shared<FakeRequest>();
        request->closes = &closes;
        request->handle = handle.path();
        m_bus->registerObject(handle.path(), request.get(), QDBusConnection::ExportScriptableSlots);
        requests << request;
        message.setDelayedReply(true);
        held = message;
        return 0;
    }

private:
    QDBusConnection *m_bus;
};

struct Reply {
    bool done = false;
    bool error = false;
    uint response = 99;
    QVariantMap results;
    // The sheet's answer was refused (savedAs).
    bool refused = false;
};

QVariantMap mapOf(const QVariant &v)
{
    return v.metaType() == QMetaType::fromType<QDBusArgument>() ? qdbus_cast<QVariantMap>(v.value<QDBusArgument>()) : v.toMap();
}

class PrintTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        static int n = 0;
        const QString suffix = QString::number(++n);
        backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-backend") + suffix));
        frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-frontend") + suffix));
        gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-gtk") + suffix));
        panelBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-panels") + suffix));
        ASSERT_TRUE(backendBus->isConnected() && frontendBus->isConnected() && gtkBus->isConnected() && panelBus->isConnected());
        ASSERT_TRUE(dir.isValid());
        make({});
        ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &gtk, QDBusConnection::ExportAllSlots));
        ASSERT_TRUE(gtkBus->registerService(QString::fromLatin1(kFakeGtk)));
    }

    void make(const std::function<void(Print::Options &)> &adjust)
    {
        if (printer) {
            backendBus->unregisterService(QString::fromLatin1(kService));
            backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
            exported.reset();
            printer.reset();
        }
        Print::Options options;
        options.gtkService = QString::fromLatin1(kFakeGtk);
        options.uiDeadlineMs = kDeadlineMs;
        options.idleQuitMs = 200;
        options.fileIdleMs = 2000;
        if (adjust)
            adjust(options);
        printer = std::make_unique<Print>(*backendBus, &system, options);
        printer->setUiLoader([] { return true; });
        printer->setPanelBus(*panelBus);
        exported = std::make_unique<QObject>();
        new PrintAdaptor(exported.get(), printer.get());
        saveFile = new FakeSaveFile(exported.get(), backendBus.get());
        ASSERT_TRUE(backendBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), exported.get(), QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(backendBus->registerService(QString::fromLatin1(kService)));
        // No window is presented: each test ends its sheet well within the deadline (kDeadlineMs) that would send it to x-d-p-gtk.
        QObject::connect(printer.get(), &Print::opened, printer.get(), [this](int id, const QVariantMap &sheet) { opened.append({id, sheet}); });
        QObject::connect(printer.get(), &Print::printersListed, printer.get(),
                         [this](int id, const QVariantList &list, const QString &current, bool ok) { listed.append({id, list, current, ok}); });
        QObject::connect(printer.get(), &Print::printerChosen, printer.get(),
                         [this](int id, const QString &name, const QVariantMap &caps, const QVariantMap &choices) {
                             chosen.append({id, name, caps, choices});
                         });
        QObject::connect(printer.get(), &Print::closed, printer.get(), [this](int id) { closed.append(id); });
    }

    void TearDown() override
    {
        backendBus->unregisterService(QString::fromLatin1(kService));
        backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
        gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
        printer.reset();
        exported.reset();
        QDBusConnection::disconnectFromBus(backendBus->name());
        QDBusConnection::disconnectFromBus(frontendBus->name());
        QDBusConnection::disconnectFromBus(gtkBus->name());
        QDBusConnection::disconnectFromBus(panelBus->name());
    }

    std::shared_ptr<Reply> send(QDBusMessage m)
    {
        auto reply = std::make_shared<Reply>();
        auto *w = new QDBusPendingCallWatcher(frontendBus->asyncCall(m, std::numeric_limits<int>::max()));
        QObject::connect(w, &QDBusPendingCallWatcher::finished, w, [reply](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusMessage r = watcher->reply();
            reply->done = true;
            reply->error = r.type() != QDBusMessage::ReplyMessage;
            if (!reply->error && r.arguments().size() == 2) {
                reply->response = r.arguments().at(0).toUInt();
                reply->results = qdbus_cast<QVariantMap>(r.arguments().at(1));
            }
        });
        return reply;
    }

    // The frontend's calls (src/print.c): PreparePrint and Print on the backend's name, no timeout.
    std::shared_ptr<Reply> prepare(const QString &handle, const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options,
                                   const QString &appId = QStringLiteral("org.example.Writer"))
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("PreparePrint"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << appId << QStringLiteral("wayland:abc") << QStringLiteral("Print") << settings
          << pageSetup << options;
        return send(m);
    }

    std::shared_ptr<Reply> printDocument(const QString &handle, const QByteArray &document, const QVariantMap &options,
                                         const QString &appId = QStringLiteral("org.example.Writer"))
    {
        QFile file(dir.filePath(QStringLiteral("doc-%1").arg(++docs)));
        EXPECT_TRUE(file.open(QIODevice::WriteOnly));
        file.write(document);
        file.close();
        const int fd = ::open(QFile::encodeName(file.fileName()).constData(), O_RDONLY | O_CLOEXEC);
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("Print"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << appId << QString() << QStringLiteral("Print")
          << QVariant::fromValue(QDBusUnixFileDescriptor(fd)) << options;
        ::close(fd);
        return send(m);
    }

    // The same with the document on a pipe (it can be read once, as it flows).
    std::shared_ptr<Reply> printPipe(const QString &handle, const QByteArray &document, const QVariantMap &options)
    {
        int ends[2];
        EXPECT_EQ(::pipe2(ends, O_CLOEXEC), 0);
        EXPECT_EQ(::write(ends[1], document.constData(), size_t(document.size())), document.size());
        ::close(ends[1]);
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("Print"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << QStringLiteral("org.example.Writer") << QString() << QStringLiteral("Print")
          << QVariant::fromValue(QDBusUnixFileDescriptor(ends[0])) << options;
        ::close(ends[0]);
        return send(m);
    }

    // A pipe whose first bytes are written and whose write end stays open (the document still coming): the write end.
    int printHeldPipe(const QString &handle, const QByteArray &first, std::shared_ptr<Reply> *reply)
    {
        int ends[2];
        EXPECT_EQ(::pipe2(ends, O_CLOEXEC), 0);
        EXPECT_EQ(::write(ends[1], first.constData(), size_t(first.size())), first.size());
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("Print"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << QStringLiteral("org.example.Writer") << QString() << QStringLiteral("Print")
          << QVariant::fromValue(QDBusUnixFileDescriptor(ends[0])) << QVariantMap{};
        ::close(ends[0]);
        *reply = send(m);
        return ends[1];
    }

    bool waitFor(const std::function<bool()> &condition, int ms = 3000)
    {
        QDeadlineTimer deadline(ms);
        while (!condition() && !deadline.hasExpired())
            QTest::qWait(10);
        return condition();
    }

    // PreparePrint to the sheet with Office's options read, then the sheet's answer; the reply.
    std::shared_ptr<Reply> preparedAnswer(const QString &handle, const QVariantMap &edit, const QVariantMap &settings = {},
                                          const QVariantMap &options = {})
    {
        const qsizetype before = chosen.size();
        auto reply = prepare(handle, settings, {}, options);
        EXPECT_TRUE(waitFor([&] { return chosen.size() > before; })) << "the default printer's options read";
        if (chosen.size() <= before)
            return reply;
        const auto &last = chosen.last();
        QVariantMap choices = last.choices;
        for (auto it = edit.cbegin(); it != edit.cend(); ++it)
            choices.insert(it.key(), it.value());
        EXPECT_TRUE(printer->answer(last.id, 0, choices));
        EXPECT_TRUE(waitFor([&] { return reply->done; }));
        return reply;
    }

    // Save as PDF… on sheet `id`, the Save panel (the fake) answering `path`: true once the sheet has its file.
    bool choosePdf(int id, const QString &path)
    {
        bool picked = false;
        const auto connection = QObject::connect(printer.get(), &Print::pdfChosen, printer.get(), [&picked, id](int which, const QString &) {
            picked = picked || which == id;
        });
        const qsizetype calls = saveFile->calls.size();
        printer->savePdf(id, QStringLiteral("Report"), QStringLiteral("Save as PDF"));
        const bool asked = waitFor([&] { return saveFile->calls.size() > calls; });
        if (asked)
            backendBus->send(saveFile->held.createReply(QVariantList{
                QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{QUrl::fromLocalFile(path).toString()}}}}));
        const bool ok = asked && waitFor([&] { return picked; });
        QObject::disconnect(connection);
        return ok;
    }

    // PreparePrint answered with Save as PDF to `path` as the Save panel chose it, the sheet answering `answered` (the same file
    // unless given).
    std::shared_ptr<Reply> savedAs(const QString &handle, const QString &path, const QString &answered = {})
    {
        const qsizetype before = chosen.size();
        auto reply = prepare(handle, {}, {}, {});
        EXPECT_TRUE(waitFor([&] { return chosen.size() > before; }));
        if (chosen.size() <= before)
            return reply;
        const int id = chosen.last().id;
        EXPECT_TRUE(choosePdf(id, path));
        QVariantMap choices = chosen.last().choices;
        choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(answered.isEmpty() ? path : answered).toString());
        if (!printer->answer(id, 0, choices)) {
            reply->refused = true;
            printer->answer(id, 1);
        }
        EXPECT_TRUE(waitFor([&] { return reply->done; }));
        return reply;
    }

    std::shared_ptr<Reply> printWith(const QString &handle, const std::shared_ptr<Reply> &prepared, const QByteArray &document)
    {
        return printDocument(handle, document, {{QStringLiteral("token"), QVariant::fromValue(prepared->results.value("token").toUInt())}});
    }

    struct Listed {
        int id;
        QVariantList printers;
        QString current;
        bool ok;
    };
    struct Chosen {
        int id;
        QString printer;
        QVariantMap capabilities;
        QVariantMap choices;
    };

    std::unique_ptr<QDBusConnection> backendBus, frontendBus, gtkBus, panelBus;
    FakePrintSystem system;
    std::unique_ptr<Print> printer;
    std::unique_ptr<QObject> exported;
    FakeSaveFile *saveFile = nullptr;
    FakeGtkPrint gtk;
    QTemporaryDir dir;
    int docs = 0;
    QList<QPair<int, QVariantMap>> opened;
    QList<Listed> listed;
    QList<Chosen> chosen;
    QList<int> closed;
};

const QString kHandle = QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/print");

// tests/fixtures/print/two-pages.pdf: page 1 A4 portrait with a black band across its upper half, page 2 A4 landscape.
QByteArray twoPages()
{
    QFile file(QDir::cleanPath(QFileInfo(QStringLiteral(__FILE__)).absoluteDir().filePath(QStringLiteral("../../fixtures/print/two-pages.pdf"))));
    EXPECT_TRUE(file.open(QIODevice::ReadOnly)) << file.fileName().toStdString();
    return file.readAll();
}

// The child that draws a page, as grassfield-portal runs itself: this binary (tst_filechooser.cpp's main answers it).
QStringList renderer()
{
    return {QCoreApplication::applicationFilePath(), QStringLiteral("--print-preview")};
}

// Office's own options in the fake: two in Media & Quality.
QList<print::PrinterOption> officeOptions()
{
    return {{QStringLiteral("media-source"), {{QStringLiteral("auto"), QStringLiteral("Automatic"), QStringLiteral("auto")}, {QStringLiteral("tray-1"), QStringLiteral("Tray 1"), QStringLiteral("tray-1")}},
             QStringLiteral("auto"), QStringLiteral("auto")},
            {QStringLiteral("print-quality"),
             {{QStringLiteral("3"), QStringLiteral("Draft"), QStringLiteral("3")}, {QStringLiteral("4"), QStringLiteral("Normal"), QStringLiteral("4")}, {QStringLiteral("5"), QStringLiteral("High"), QStringLiteral("5")}},
             QStringLiteral("4"), QStringLiteral("4")}};
}

} // namespace

// What the sheet is given first: one-line title, the accept label without its mnemonic, the pages the application has, Save as
// PDF only when it can make a PDF, and the application's own settings as the first choices (the printer not known yet).
TEST(PrintToQml, WhatTheSheetIsGiven)
{
    const QVariantMap sheet = Print::toQml(QStringLiteral("org.example.Writer"), QStringLiteral("wayland:abc"), QStringLiteral("Print\nnow"),
                                           {{QStringLiteral("n-copies"), QStringLiteral("2")}},
                                           {{QStringLiteral("Name"), QStringLiteral("iso_a5_148x210mm")}, {QStringLiteral("Width"), 148.0},
                                            {QStringLiteral("Height"), 210.0}},
                                           {{QStringLiteral("accept_label"), QStringLiteral("_Print")}, {QStringLiteral("has_current_page"), true},
                                            {QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("ps")}}});
    EXPECT_EQ(sheet.value("title").toString(), QStringLiteral("Print now"));
    EXPECT_EQ(sheet.value("acceptLabel").toString(), QStringLiteral("Print"));
    EXPECT_TRUE(sheet.value("parented").toBool());
    EXPECT_TRUE(sheet.value("modal").toBool());
    EXPECT_TRUE(sheet.value("hasCurrentPage").toBool());
    EXPECT_FALSE(sheet.value("hasSelection").toBool());
    EXPECT_FALSE(sheet.value("canSavePdf").toBool()) << "this application makes PostScript only";
    const QVariantMap choices = sheet.value("choices").toMap();
    EXPECT_EQ(choices.value("copies").toInt(), 2);
    EXPECT_EQ(choices.value("media").toMap().value("name").toString(), QStringLiteral("iso_a5_148x210mm"));
    EXPECT_EQ(choices.value("printer").toString(), QString());
    EXPECT_TRUE(Print::toQml({}, {}, {}, {}, {}, {}).value("canSavePdf").toBool()) << "no formats given: all three";
    EXPECT_FALSE(Print::toQml({}, {}, {}, {}, {}, {}).value("parented").toBool());
}

// PR1, PR2: the sheet over PreparePrint, the default printer first and its options read; the answer is GTK's settings and page
// setup with a token; Print with that token sends the document to that printer with the copies, paper, sides and colour, never
// the pages (GTK rendered only those).
TEST_F(PrintTest, PreparePrintThenPrintWithItsToken)
{
    auto reply = prepare(kHandle, {{QStringLiteral("n-copies"), QStringLiteral("2")}, {QStringLiteral("print-pages"), QStringLiteral("ranges")},
                                   {QStringLiteral("page-ranges"), QStringLiteral("0-1")}},
                         {{QStringLiteral("Name"), QStringLiteral("iso_a5_148x210mm")}, {QStringLiteral("Width"), 148.0}, {QStringLiteral("Height"), 210.0}},
                         {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    ASSERT_EQ(opened.size(), 1);
    ASSERT_EQ(listed.size(), 1);
    EXPECT_TRUE(listed.first().ok);
    EXPECT_EQ(listed.first().current, QStringLiteral("Office")) << "the default";
    ASSERT_EQ(listed.first().printers.size(), 2);
    EXPECT_EQ(listed.first().printers.first().toMap().value("displayName").toString(), QStringLiteral("Office Printer"));
    EXPECT_EQ(chosen.first().printer, QStringLiteral("Office"));
    EXPECT_TRUE(chosen.first().capabilities.value("twoSided").toBool());
    QVariantMap choices = chosen.first().choices;
    EXPECT_EQ(choices.value("copies").toInt(), 2);
    EXPECT_EQ(choices.value("ranges").toString(), QStringLiteral("1-2"));
    EXPECT_EQ(choices.value("media").toMap().value("name").toString(), QStringLiteral("iso_a5_148x210mm"));
    choices.insert(QStringLiteral("duplex"), QStringLiteral("horizontal"));
    choices.insert(QStringLiteral("color"), false);
    EXPECT_FALSE(reply->done);
    ASSERT_TRUE(printer->answer(opened.first().first, 0, choices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    const QVariantMap settings = mapOf(reply->results.value("settings"));
    const QVariantMap pageSetup = mapOf(reply->results.value("page-setup"));
    EXPECT_EQ(settings.value("printer").toString(), QStringLiteral("Office"));
    EXPECT_EQ(settings.value("n-copies").toString(), QStringLiteral("1")) << "GTK makes one copy; the job asks for two";
    EXPECT_FALSE(pageSetup.contains("PPDName"));
    EXPECT_EQ(settings.value("page-ranges").toString(), QStringLiteral("0-1"));
    EXPECT_EQ(settings.value("duplex").toString(), QStringLiteral("horizontal"));
    EXPECT_EQ(pageSetup.value("Name").toString(), QStringLiteral("iso_a5_148x210mm"));
    EXPECT_DOUBLE_EQ(pageSetup.value("Width").toDouble(), 148.0);
    ASSERT_EQ(reply->results.value("token").metaType(), QMetaType::fromType<uint>());
    const uint token = reply->results.value("token").toUInt();
    EXPECT_NE(token, 0u);

    auto job = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), "%PDF-1.4 two pages",
                             {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u);
    ASSERT_EQ(system.jobs.size(), 1);
    EXPECT_EQ(system.jobs.first().printer, QStringLiteral("Office"));
    EXPECT_EQ(system.jobs.first().document, QByteArray("%PDF-1.4 two pages"));
    using Options = PrintSystem::Options;
    EXPECT_EQ(system.jobs.first().options, (Options{{QStringLiteral("copies"), QStringLiteral("2")},
                                                    {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-collated-copies")},
                                                    {QStringLiteral("media"), QStringLiteral("iso_a5_148x210mm")},
                                                    {QStringLiteral("sides"), QStringLiteral("two-sided-long-edge")},
                                                    {QStringLiteral("print-color-mode"), QStringLiteral("monochrome")}}));
    EXPECT_TRUE(gtk.calls.isEmpty()) << "nothing went to x-d-p-gtk";

    // While a token waits for its Print the process is not idle (GTK may render for longer than the idle time).
    QTest::qWait(20);
    EXPECT_GE(printer->quietFor(), 15) << "the job's request is over, no token left";

    // The token is good once: a second Print with it is x-d-p-gtk's.
    auto again = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/again"), "%PDF-1.4",
                               {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("Print /org/freedesktop/portal/desktop/request/1_1/again token %1 fd valid").arg(token));
    EXPECT_EQ(system.jobs.size(), 1);
    QDBusMessage held = gtk.held;
    gtkBus->send(held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return again->done; }));
    EXPECT_EQ(again->response, 1u) << "x-d-p-gtk's answer, relayed";
}

// A token is its application's, and lives five minutes (x-d-p-gtk's rule): another application's Print, or a late one, goes to
// x-d-p-gtk (a Print with no token gets Grassfield's sheet since step 6b: ADocumentSentFirst...).
TEST_F(PrintTest, ATokenIsItsApplicationsAndExpires)
{
    auto reply = preparedAnswer(kHandle, {});
    const uint token = reply->results.value("token").toUInt();
    QTest::qWait(20);
    EXPECT_EQ(printer->quietFor(), 0) << "a token waits for its Print: the process must not quit (review of step 6a, MINOR 2)";
    auto other = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/other"), "%PDF-1.4",
                               {{QStringLiteral("token"), QVariant::fromValue(token)}}, QStringLiteral("org.example.Other"));
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_TRUE(system.jobs.isEmpty());
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(2u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return other->done; }));
    // Still good for its own application after another's try.
    auto own = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/own"), "%PDF-1.4",
                             {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return own->done; }));
    EXPECT_EQ(own->response, 0u);
    EXPECT_EQ(system.jobs.size(), 1);

    // A token of x-d-p-gtk's (one this backend never gave): x-d-p-gtk's.
    const uint foreignToken = token == 0xffffffffu ? 1u : 0xffffffffu;
    auto foreign = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/foreign"), "%PDF-1.4",
                                 {{QStringLiteral("token"), QVariant::fromValue(foreignToken)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 2; }));
    EXPECT_EQ(gtk.calls.last(), QStringLiteral("Print /org/freedesktop/portal/desktop/request/1_1/foreign token %1 fd valid").arg(foreignToken));
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return foreign->done; }));

    // A live token keeps the process (its idle time passes, but it is not quiet); its expiry starts the idle time again.
    make([](Print::Options &o) {
        o.tokenLifetimeMs = 300;
        o.idleQuitMs = 50;
    });
    bool idled = false;
    QObject::connect(printer.get(), &Print::idle, printer.get(), [&idled] { idled = true; });
    auto late = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/late"), {});
    const uint lateToken = late->results.value("token").toUInt();
    ASSERT_TRUE(waitFor([&] { return idled; })) << "the idle time after the sheet";
    EXPECT_EQ(printer->quietFor(), 0) << "the token lives";
    EXPECT_FALSE(RequestHost::quiet({printer.get()}, 50));
    idled = false;
    ASSERT_TRUE(waitFor([&] { return idled; })) << "the idle time starts again once the token has expired";
    EXPECT_GE(printer->quietFor(), 50) << "quiet for the idle time since it started again";
    EXPECT_TRUE(RequestHost::quiet({printer.get()}, 50));
    printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/late2"), "%PDF-1.4",
                  {{QStringLiteral("token"), QVariant::fromValue(lateToken)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 3; })) << "an expired token is not ours any more";
    EXPECT_EQ(system.jobs.size(), 1);
}

// PR3: Save as PDF writes the document GTK made to the file chosen in the Save panel, and only there (integrator security review
// of step 6a): only a PDF, never half of one; never through a link (a link put at the name since the choice is replaced, its target
// untouched; a folder replaced by a link since the choice fails the write; a folder that was a link when chosen, as a user's
// Documents on another disk, is written through); the application gets no path back; an answer for any other file, or with no
// Save panel answer, is refused; an application that cannot make a PDF gets no Save as PDF.
TEST_F(PrintTest, SaveAsPdfWritesTheFileChosen)
{
    // No window is presented here: the deadline that would send the sheet to x-d-p-gtk is moved out of the way.
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    const QString target = dir.filePath(QStringLiteral("Report.pdf"));
    auto reply = savedAs(kHandle, target);
    ASSERT_EQ(reply->response, 0u);
    const QVariantMap settings = mapOf(reply->results.value("settings"));
    EXPECT_EQ(settings.value("output-uri").toString(), QStringLiteral("file:///dev/null")) << "never the user's path";
    EXPECT_EQ(settings.value("output-file-format").toString(), QStringLiteral("pdf"));
    EXPECT_FALSE(settings.contains("printer"));
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/pdf"), reply, "%PDF-1.7 the report");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u);
    QFile written(target);
    ASSERT_TRUE(written.open(QIODevice::ReadOnly));
    EXPECT_EQ(written.readAll(), QByteArray("%PDF-1.7 the report"));
    written.close();
    EXPECT_TRUE(system.jobs.isEmpty()) << "nothing printed";

    // Not a PDF: nothing written, the file there stays.
    auto second = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), target);
    auto bad = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/bad"), second, "%!PS-Adobe-3.0");
    ASSERT_TRUE(waitFor([&] { return bad->done; }));
    EXPECT_EQ(bad->response, 2u);
    ASSERT_TRUE(written.open(QIODevice::ReadOnly));
    EXPECT_EQ(written.readAll(), QByteArray("%PDF-1.7 the report"));
    written.close();

    // Only the file the Save panel answered.
    auto other = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/other"), target, dir.filePath(QStringLiteral("Other.pdf")));
    EXPECT_TRUE(other->refused) << "another file than the Save panel's";
    EXPECT_EQ(other->response, 1u);
    const qsizetype before = chosen.size();
    auto unasked = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/unasked"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }));
    QVariantMap choices = chosen.last().choices;
    choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(target).toString());
    EXPECT_FALSE(printer->answer(chosen.last().id, 0, choices)) << "no Save panel answer";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));

    // A link put at the name after the choice (an application that can write in the folder): the file takes the link's place,
    // what it pointed to is untouched.
    QTemporaryDir elsewhere;
    ASSERT_TRUE(elsewhere.isValid());
    const QString secret = elsewhere.filePath(QStringLiteral("bashrc"));
    QFile secretFile(secret);
    ASSERT_TRUE(secretFile.open(QIODevice::WriteOnly));
    secretFile.write("keep");
    secretFile.close();
    const QString linked = dir.filePath(QStringLiteral("Linked.pdf"));
    auto planted = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/planted"), linked);
    ASSERT_EQ(planted->response, 0u);
    ASSERT_TRUE(QFile::link(secret, linked));
    auto through = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/through"), planted, "%PDF-1.7\necho owned");
    ASSERT_TRUE(waitFor([&] { return through->done; }));
    EXPECT_EQ(through->response, 0u);
    ASSERT_TRUE(secretFile.open(QIODevice::ReadOnly));
    EXPECT_EQ(secretFile.readAll(), QByteArray("keep")) << "the link's target is untouched";
    secretFile.close();
    EXPECT_FALSE(QFileInfo(linked).isSymLink()) << "the link replaced by the file";
    QFile replaced(linked);
    ASSERT_TRUE(replaced.open(QIODevice::ReadOnly));
    EXPECT_EQ(replaced.readAll(), QByteArray("%PDF-1.7\necho owned"));

    // The folder replaced by a link after the choice: nothing written anywhere.
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Sub")));
    auto moved = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/moved"), dir.filePath(QStringLiteral("Sub/Out.pdf")));
    ASSERT_EQ(moved->response, 0u);
    ASSERT_TRUE(QDir(dir.path()).rename(QStringLiteral("Sub"), QStringLiteral("Sub.old")));
    ASSERT_TRUE(QFile::link(elsewhere.path(), dir.filePath(QStringLiteral("Sub"))));
    auto refused = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/refused"), moved, "%PDF-1.7 elsewhere");
    ASSERT_TRUE(waitFor([&] { return refused->done; }));
    EXPECT_EQ(refused->response, 2u);
    EXPECT_EQ(QDir(elsewhere.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("bashrc")}) << "nothing through the link";
    EXPECT_TRUE(QDir(dir.filePath(QStringLiteral("Sub.old"))).isEmpty());

    // A folder that is a link when the user chooses it (Documents on another disk): written in the folder it leads to.
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Disk")));
    ASSERT_TRUE(QFile::link(dir.filePath(QStringLiteral("Disk")), dir.filePath(QStringLiteral("Documents"))));
    auto documents = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/documents"), dir.filePath(QStringLiteral("Documents/Mine.pdf")));
    ASSERT_EQ(documents->response, 0u);
    auto mine = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/mine"), documents, "%PDF-1.7 mine");
    ASSERT_TRUE(waitFor([&] { return mine->done; }));
    EXPECT_EQ(mine->response, 0u);
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("Disk/Mine.pdf"))).isFile());

    // An application that makes PostScript only: no Save as PDF answer.
    const qsizetype count = chosen.size();
    auto ps = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/ps"), {}, {},
                      {{QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("ps")}}});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > count; }));
    choices = chosen.last().choices;
    choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(target).toString());
    EXPECT_FALSE(printer->answer(chosen.last().id, 0, choices));
    EXPECT_FALSE(ps->done) << "the sheet stays";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));
    ASSERT_TRUE(waitFor([&] { return ps->done; }));
    EXPECT_EQ(ps->response, 1u);
}

// Save as PDF… asks the process's own Save panel (the D-4 panel, with the application's memory) over the application's window,
// the name suggested with ".pdf"; the file chosen comes back to the sheet; Cancel there brings the sheet back; a request closed
// meanwhile closes its Save panel.
TEST_F(PrintTest, SaveAsPdfAsksTheSavePanel)
{
    // The sheet is on screen meanwhile (shown: no deadline sends it to x-d-p-gtk); here no window is presented, so the deadline
    // is moved out of the way.
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    QList<QPair<int, QString>> pdf;
    QList<int> back;
    QObject::connect(printer.get(), &Print::pdfChosen, printer.get(), [&pdf](int id, const QString &uri) { pdf.append({id, uri}); });
    QObject::connect(printer.get(), &Print::pdfCancelled, printer.get(), [&back](int id) { back.append(id); });
    auto reply = prepare(kHandle, {{QStringLiteral("output-basename"), QStringLiteral("Quarterly Report")}}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    EXPECT_EQ(opened.first().second.value("outputBasename").toString(), QStringLiteral("Quarterly Report"));
    const int id = chosen.first().id;
    printer->savePdf(id, QStringLiteral("Quarterly Report"), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 1; }));
    EXPECT_EQ(saveFile->calls.first(),
              QStringLiteral("SaveFile /org/freedesktop/portal/desktop/request/grassfield org.example.Writer wayland:abc Save as PDF Quarterly Report.pdf"));
    backendBus->send(saveFile->held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return back.size() == 1; })) << "Cancel in the Save panel: the sheet comes back";
    EXPECT_TRUE(pdf.isEmpty());

    printer->savePdf(id, QStringLiteral("a/b"), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 2; }));
    EXPECT_TRUE(saveFile->calls.last().endsWith(QStringLiteral(" Document.pdf"))) << "never a folder in the name";
    const QString target = QUrl::fromLocalFile(dir.filePath(QStringLiteral("Quarterly Report.pdf"))).toString();
    backendBus->send(saveFile->held.createReply(
        QVariantList{QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{target}}}}));
    ASSERT_TRUE(waitFor([&] { return pdf.size() == 1; }));
    EXPECT_EQ(pdf.first(), qMakePair(id, target));
    QVariantMap choices = chosen.first().choices;
    choices.insert(QStringLiteral("outputUri"), target);
    ASSERT_TRUE(printer->answer(id, 0, choices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("output-uri").toString(), QStringLiteral("file:///dev/null"));

    // A Save panel open when the application closes the request goes with it.
    auto second = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() == 2; }));
    printer->savePdf(chosen.last().id, QString(), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 3; }));
    const QString saveHandle = saveFile->held.arguments().at(0).value<QDBusObjectPath>().path();
    QDBusMessage close = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Request"), QStringLiteral("Close"));
    frontendBus->asyncCall(close);
    ASSERT_TRUE(waitFor([&] { return second->done; }));
    ASSERT_TRUE(waitFor([&] { return saveFile->closes.contains(saveHandle); })) << "its Save panel was closed";
    // The Save panel's late answer is no answer of the sheet's.
    backendBus->send(saveFile->held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{target}}}}));
    QTest::qWait(50);
    EXPECT_EQ(pdf.size(), 1);
}

// Cancel is response 1; a job the printer refuses is response 2 (GTK tells the application); answers for a request that is gone
// are ignored.
TEST_F(PrintTest, CancelAndARefusedJob)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    EXPECT_TRUE(printer->answer(chosen.first().id, 1));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 1u);
    EXPECT_TRUE(reply->results.isEmpty());
    EXPECT_TRUE(printer->answer(chosen.first().id, 0, chosen.first().choices)) << "gone: ignored";

    system.refuse = QStringLiteral("the printer is out of paper");
    auto prepared = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/refused"), {});
    auto job = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), "%PDF-1.4",
                             {{QStringLiteral("token"), QVariant::fromValue(prepared->results.value("token").toUInt())}});
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 2u);
}

// PR4: no printer: the sheet is told (an empty list, none current) and cannot print, only Save as PDF or Cancel; a printer
// the sheet did not choose is no answer.
TEST_F(PrintTest, NoPrinter)
{
    system.printers.clear();
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !listed.isEmpty(); }));
    EXPECT_TRUE(listed.first().printers.isEmpty());
    EXPECT_EQ(listed.first().current, QString());
    EXPECT_TRUE(listed.first().ok);
    QTest::qWait(50);
    EXPECT_TRUE(chosen.isEmpty());
    const QVariantMap choices = opened.first().second.value("choices").toMap();
    EXPECT_FALSE(printer->answer(opened.first().first, 0, choices)) << "nothing to print on";
    QVariantMap other = choices;
    other.insert(QStringLiteral("printer"), QStringLiteral("Office"));
    EXPECT_FALSE(printer->answer(opened.first().first, 0, other)) << "a printer the sheet never chose";
    other.insert(QStringLiteral("printer"), QString());
    other.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(dir.filePath(QStringLiteral("a.pdf"))).toString());
    EXPECT_FALSE(printer->answer(opened.first().first, 0, other)) << "no file chosen in the Save panel";
    ASSERT_TRUE(choosePdf(opened.first().first, dir.filePath(QStringLiteral("a.pdf"))));
    EXPECT_TRUE(printer->answer(opened.first().first, 0, other));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);

    // CUPS does not answer: the sheet is told so.
    system.listed = false;
    prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/nocups"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return listed.size() == 2; }));
    EXPECT_FALSE(listed.last().ok);
}

// Another printer: its options read, the choices made so far carried over where it takes them (Mono: one side, black and white;
// the copies and pages stay); the answer then prints there.
TEST_F(PrintTest, AnotherPrinterKeepsTheChoicesItTakes)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    QVariantMap choices = chosen.first().choices;
    choices.insert(QStringLiteral("copies"), 3);
    choices.insert(QStringLiteral("duplex"), QStringLiteral("vertical"));
    choices.insert(QStringLiteral("pages"), QStringLiteral("ranges"));
    choices.insert(QStringLiteral("ranges"), QStringLiteral("2-"));
    choices.insert(QStringLiteral("orientation"), QStringLiteral("landscape"));
    choices.insert(QStringLiteral("scale"), 80);
    const int id = chosen.first().id;
    printer->choosePrinter(id, QStringLiteral("Mono"), choices);
    // Its options are being read: no answer prints on it yet.
    QVariantMap early = choices;
    early.insert(QStringLiteral("printer"), QStringLiteral("Mono"));
    early.insert(QStringLiteral("ranges"), QStringLiteral("2"));
    EXPECT_FALSE(printer->answer(id, 0, early)) << "the options are not read yet";
    ASSERT_TRUE(waitFor([&] { return chosen.size() == 2; }));
    const QVariantMap mono = chosen.last().choices;
    EXPECT_EQ(chosen.last().printer, QStringLiteral("Mono"));
    EXPECT_EQ(mono.value("copies").toInt(), 3);
    EXPECT_EQ(mono.value("duplex").toString(), QStringLiteral("simplex"));
    EXPECT_FALSE(mono.value("color").toBool());
    EXPECT_EQ(mono.value("ranges").toString(), QStringLiteral("2-")) << "pages being typed stay as typed";
    EXPECT_EQ(mono.value("orientation").toString(), QStringLiteral("landscape")) << "the rest carried though the pages do not read yet";
    EXPECT_EQ(mono.value("scale").toInt(), 80);
    EXPECT_EQ(printer->tidyRanges(QStringLiteral("2-")), QString());
    EXPECT_EQ(printer->tidyRanges(QStringLiteral("5, 1-2")), QStringLiteral("1-2, 5"));
    QVariantMap answerChoices = mono;
    EXPECT_FALSE(printer->answer(id, 0, answerChoices)) << "bad pages: the sheet stays";
    answerChoices.insert(QStringLiteral("ranges"), QStringLiteral("2-4"));
    ASSERT_TRUE(printer->answer(id, 0, answerChoices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("printer").toString(), QStringLiteral("Mono"));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("page-ranges").toString(), QStringLiteral("1-3"));
}

// FC7 for print: a sheet that cannot be made sends PreparePrint to x-d-p-gtk, and its answer comes back with GTK's types (the
// settings' strings, the page setup's doubles, the token); anything else in it is dropped.
TEST_F(PrintTest, NoSheetGoesToGtkAndItsAnswerIsRelayed)
{
    printer->setUiLoader([] { return false; });
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("PreparePrint %1").arg(kHandle));
    const QVariantMap settings{{QStringLiteral("n-copies"), QStringLiteral("1")}, {QStringLiteral("odd"), 7}};
    const QVariantMap pageSetup{{QStringLiteral("Width"), 210.0}, {QStringLiteral("Name"), QStringLiteral("iso_a4_210x297mm")},
                                {QStringLiteral("bad"), QStringList{QStringLiteral("x")}}};
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u),
                                                   QVariantMap{{QStringLiteral("settings"), settings},
                                                               {QStringLiteral("page-setup"), pageSetup},
                                                               {QStringLiteral("token"), QVariant::fromValue(77u)},
                                                               {QStringLiteral("extra"), QStringLiteral("x")}}}));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(mapOf(reply->results.value("settings")), (QVariantMap{{QStringLiteral("n-copies"), QStringLiteral("1")}}));
    EXPECT_EQ(mapOf(reply->results.value("page-setup")),
              (QVariantMap{{QStringLiteral("Width"), 210.0}, {QStringLiteral("Name"), QStringLiteral("iso_a4_210x297mm")}}));
    EXPECT_EQ(reply->results.value("token").toUInt(), 77u);
    EXPECT_FALSE(reply->results.contains("extra"));
    // x-d-p-gtk's token is x-d-p-gtk's: Print with it goes there.
    printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/gtkjob"), "%PDF-1.4", {{QStringLiteral("token"), QVariant::fromValue(77u)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 2; }));
    EXPECT_TRUE(system.jobs.isEmpty());
}

// Close during the sheet: it goes, and nothing is answered after.
// SP-16: a Print with a ticket whose request is closed while its job runs: Save as PDF stops writing (no file, no temporary
// file left), and a CUPS job is told to stop; the frontend gets its answer at once.
TEST_F(PrintTest, CloseStopsTheJobOfAPrintWithATicket)
{
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    const QString target = dir.filePath(QStringLiteral("Closed.pdf"));
    auto prepared = savedAs(kHandle, target);
    ASSERT_EQ(prepared->response, 0u);
    // The document is still coming (the application renders it) when the frontend closes the request.
    int ends[2];
    ASSERT_EQ(::pipe2(ends, O_CLOEXEC), 0);
    ASSERT_EQ(::write(ends[1], "%PDF-1.7 first", 14), 14);
    const QString handle = QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/closed");
    QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                    QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("Print"));
    m << QVariant::fromValue(QDBusObjectPath(handle)) << QStringLiteral("org.example.Writer") << QString() << QStringLiteral("Print")
      << QVariant::fromValue(QDBusUnixFileDescriptor(ends[0])) << QVariantMap{{QStringLiteral("token"), QVariant::fromValue(prepared->results.value("token").toUInt())}};
    ::close(ends[0]);
    auto job = send(m);
    QTest::qWait(300); // the writer reads the first bytes and waits for more
    EXPECT_FALSE(job->done);
    frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), handle, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                          QStringLiteral("Close")));
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_NE(job->response, 0u);
    // The rest arrives: nothing is written any more, well before the source's own idle limit (2 s here).
    ::write(ends[1], " the rest", 9);
    ::close(ends[1]);
    QTest::qWait(500);
    EXPECT_FALSE(QFile::exists(target)) << "a closed request writes no file";
    EXPECT_EQ(QDir(dir.path()).entryList({QStringLiteral(".*Closed*"), QStringLiteral("*Closed*")}, QDir::Files | QDir::Hidden), QStringList{});

    // A CUPS job: the print system is told to stop it.
    system.holdJobs = true;
    const qsizetype before = chosen.size();
    auto second = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/cups"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }));
    ASSERT_TRUE(printer->answer(chosen.last().id, 0, chosen.last().choices));
    ASSERT_TRUE(waitFor([&] { return second->done; }));
    const QString jobHandle = QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/cupsjob");
    auto held = printWith(jobHandle, second, "%PDF-1.7 to the printer");
    QTest::qWait(200);
    EXPECT_FALSE(held->done);
    const int stopsBefore = system.stops;
    frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), jobHandle, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                          QStringLiteral("Close")));
    ASSERT_TRUE(waitFor([&] { return held->done; }));
    EXPECT_EQ(system.stops, stopsBefore + 1);
    system.holdJobs = false;
}

// SP-16: the frontend (xdg-desktop-portal) leaving the bus ends its open requests: their sheets go instead of staying with
// nobody to answer.
TEST_F(PrintTest, AFrontendThatLeavesTheBusEndsItsRequests)
{
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    {
        // A frontend of its own, which nothing else holds: its connection closes when it goes.
        QDBusConnection leaving = QDBusConnection::connectToBus(g_address, QStringLiteral("print-leaving-frontend"));
        ASSERT_TRUE(leaving.isConnected());
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("PreparePrint"));
        m << QVariant::fromValue(QDBusObjectPath(kHandle)) << QStringLiteral("org.example.Writer") << QStringLiteral("wayland:abc")
          << QStringLiteral("Print") << QVariantMap{} << QVariantMap{} << QVariantMap{};
        ASSERT_TRUE(leaving.send(m));
        ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
        EXPECT_EQ(printer->pending(), 1);
        QDBusConnection::disconnectFromBus(QStringLiteral("print-leaving-frontend"));
    }
    const int id = chosen.first().id;
    ASSERT_TRUE(waitFor([&] { return closed.contains(id); }));
    EXPECT_EQ(printer->pending(), 0);
    EXPECT_TRUE(printer->answer(id, 0, chosen.first().choices)) << "gone: ignored";
}

TEST_F(PrintTest, CloseTakesTheSheetAway)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    QDBusMessage close = QDBusMessage::createMethodCall(QString::fromLatin1(kService), kHandle, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                        QStringLiteral("Close"));
    frontendBus->asyncCall(close);
    ASSERT_TRUE(waitFor([&] { return closed.contains(chosen.first().id); }));
    EXPECT_TRUE(printer->answer(chosen.first().id, 0, chosen.first().choices)) << "gone: ignored";
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_NE(reply->response, 0u);
}

// Save as PDF's writer: a PDF read to its end whatever the pieces it comes in, written through a temporary file renamed over the
// name; anything that is not a PDF (fewer than five bytes of "%PDF-" too), a source that stops, a document over the limit, or a
// last step that fails writes nothing, leaves the file there as it was and no temporary file. Never through a link: a link at the
// name is replaced (its target untouched), a link in the folder's path fails (integrator security review of step 6a, MAJOR 1). A
// file there keeps its permissions.
TEST(WritePdf, OnlyAWholePdfIsWrittenAndNeverThroughALink)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString folder = dir.path();
    const QString target = dir.filePath(QStringLiteral("out.pdf"));
    const auto pipeOf = [](const QList<QByteArray> &pieces, bool close) {
        int ends[2];
        EXPECT_EQ(::pipe2(ends, O_CLOEXEC), 0);
        for (const QByteArray &piece : pieces)
            EXPECT_EQ(::write(ends[1], piece.constData(), size_t(piece.size())), piece.size());
        if (close)
            ::close(ends[1]);
        return std::make_pair(ends[0], ends[1]);
    };
    const auto source = [&](const QList<QByteArray> &pieces) { return pipeOf(pieces, true).first; };
    const auto contents = [](const QString &path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray("(none)");
    };
    const auto leftovers = [](const QString &path) {
        return QDir(path).entryList({QStringLiteral(".grassfield-print-*")}, QDir::Files | QDir::Hidden);
    };
    // The header in two pieces (fewer than five bytes first): nothing of it lost.
    EXPECT_EQ(writePdf(source({QByteArray("%P"), QByteArray("DF-1.7 body")}), folder, QStringLiteral("out.pdf"), 2000), QString());
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 body"));
    // Exactly the five bytes of the header: a PDF; four of them: not one.
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-")}), folder, QStringLiteral("five.pdf"), 2000), QString());
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("five.pdf"))), QByteArray("%PDF-"));
    EXPECT_EQ(writePdf(source({QByteArray("%PDF")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(writePdf(source({QByteArray("%!PS-Adobe-3.0")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(writePdf(source({QByteArray("%PD")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    // A source that stops halfway: no half document.
    auto [silent, silentWriter] = pipeOf({QByteArray("%PDF-1.7 half")}, false);
    EXPECT_EQ(writePdf(silent, folder, QStringLiteral("out.pdf"), 200), QStringLiteral("the document stopped coming"));
    ::close(silentWriter);
    // Over the limit: nothing.
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 "), QByteArray(64, 'x')}), folder, QStringLiteral("out.pdf"), 2000, 32),
              QStringLiteral("the document is too large"));
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 body")) << "the file there is untouched";
    // A folder that is not there.
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("missing")), QStringLiteral("out.pdf"), 2000)
                    .startsWith(QStringLiteral("cannot open the folder")));
    // The last step failing (the name is a folder): nothing replaced, no temporary file.
    ASSERT_TRUE(QDir(folder).mkdir(QStringLiteral("taken.pdf")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral("taken.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("taken.pdf"))).isDir());
    EXPECT_EQ(leftovers(folder), QStringList()) << "no temporary file left";

    // A link at the name: replaced by the file, what it pointed to untouched.
    QTemporaryDir elsewhere;
    ASSERT_TRUE(elsewhere.isValid());
    const QString secret = elsewhere.filePath(QStringLiteral("bashrc"));
    {
        QFile f(secret);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("keep");
    }
    ASSERT_TRUE(QFile::link(secret, dir.filePath(QStringLiteral("link.pdf"))));
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7\necho owned")}), folder, QStringLiteral("link.pdf"), 2000), QString());
    EXPECT_EQ(contents(secret), QByteArray("keep"));
    EXPECT_FALSE(QFileInfo(dir.filePath(QStringLiteral("link.pdf"))).isSymLink());
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("link.pdf"))), QByteArray("%PDF-1.7\necho owned"));
    // A link in the folder's path (the folder itself, or one above it): refused, nothing written where it leads.
    ASSERT_TRUE(QFile::link(elsewhere.path(), dir.filePath(QStringLiteral("swapped"))));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("swapped")), QStringLiteral("x.pdf"), 2000)
                    .endsWith(QStringLiteral("changed since it was chosen")));
    ASSERT_TRUE(QDir(elsewhere.path()).mkdir(QStringLiteral("inner")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("swapped/inner")), QStringLiteral("x.pdf"), 2000)
                    .endsWith(QStringLiteral("changed since it was chosen")));
    EXPECT_EQ(QDir(elsewhere.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("bashrc")});
    EXPECT_TRUE(QDir(elsewhere.filePath(QStringLiteral("inner"))).isEmpty());
    // Not a file name (a folder of that name there too: never written into).
    ASSERT_TRUE(QDir(folder).mkdir(QStringLiteral("a")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral("a/b.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_TRUE(QDir(dir.filePath(QStringLiteral("a"))).isEmpty());
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral(".."), 2000).startsWith(QStringLiteral("cannot write")));

    // Over the limit past the first read (a document longer than one read: the limit holds on every piece).
    QFile big(elsewhere.filePath(QStringLiteral("big.pdf")));
    ASSERT_TRUE(big.open(QIODevice::WriteOnly));
    big.write("%PDF-1.7 ");
    big.write(QByteArray(100000, 'x'));
    big.close();
    const int bigFd = ::open(QFile::encodeName(big.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(bigFd, 0);
    EXPECT_EQ(writePdf(bigFd, folder, QStringLiteral("big.pdf"), 2000, 70000), QStringLiteral("the document is too large"));
    EXPECT_FALSE(QFileInfo::exists(dir.filePath(QStringLiteral("big.pdf"))));
    EXPECT_EQ(leftovers(folder), QStringList());

    // A file there keeps its permissions; one that may not be written stays as it is (as QSaveFile refused it).
    ASSERT_EQ(::chmod(QFile::encodeName(target).constData(), 0600), 0);
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 again")}), folder, QStringLiteral("out.pdf"), 2000), QString());
    struct stat st;
    ASSERT_EQ(::stat(QFile::encodeName(target).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0600u);
    ASSERT_EQ(::chmod(QFile::encodeName(target).constData(), 0400), 0);
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7 over")}), folder, QStringLiteral("out.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 again"));
    EXPECT_EQ(leftovers(folder), QStringList());

    // A folder one may write in but not list (a drop box, 0300): written in.
    const QString dropBox = dir.filePath(QStringLiteral("drop"));
    ASSERT_TRUE(QDir(folder).mkdir(QStringLiteral("drop")));
    ASSERT_EQ(::chmod(QFile::encodeName(dropBox).constData(), 0300), 0);
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 dropped")}), dropBox, QStringLiteral("in.pdf"), 2000), QString());
    ASSERT_EQ(::chmod(QFile::encodeName(dropBox).constData(), 0700), 0);
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("drop/in.pdf"))), QByteArray("%PDF-1.7 dropped"));

    // Stopped (Print going away) while the source is silent: it ends at once, without its temporary file.
    auto [held, heldWriter] = pipeOf({QByteArray("%PDF-1.7 started")}, false);
    QElapsedTimer clock;
    clock.start();
    EXPECT_EQ(writePdf(held, folder, QStringLiteral("stopped.pdf"), 30000, print::kMaxDocumentBytes, [&clock] { return clock.elapsed() > 100; }),
              QStringLiteral("cancelled"));
    EXPECT_LT(clock.elapsed(), 2000) << "not the 30 s of silence";
    ::close(heldWriter);
    EXPECT_FALSE(QFileInfo::exists(dir.filePath(QStringLiteral("stopped.pdf"))));
    EXPECT_EQ(leftovers(folder), QStringList());
}

// Step 6b: the child that draws a page confines itself before it reads the document (ADR-0035 6-10, 6-20; the security review of
// step 6b's BLOCKER 1 and MAJOR 2, whose probes these checks are): it reads files under /usr (the fonts) and nothing else (no
// file of the user's, no /proc, no terminal), writes, makes, truncates, removes, renames or changes no file, opens no socket (no
// bus, no network), runs no program, makes no process (a thread only, never a namespace), signals, re-limits or re-schedules no
// other process, takes no lock and watches no file.
TEST(PrintPreview, TheChildThatDrawsIsConfined)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QByteArray existing = QFile::encodeName(dir.filePath(QStringLiteral("existing")));
    const QByteArray made = QFile::encodeName(dir.filePath(QStringLiteral("made")));
    QFile keep(QFile::decodeName(existing));
    ASSERT_TRUE(keep.open(QIODevice::WriteOnly));
    keep.write("keep");
    keep.close();
    const QByteArray environ = "/proc/" + QByteArray::number(::getpid()) + "/environ";
    int report[2];
    ASSERT_EQ(::pipe2(report, O_CLOEXEC), 0);
    // A descriptor opened before, read-only, as the document is.
    const int document = ::open(existing.constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(document, 0);
    const pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        // The child: each check that fails sets its bit.
        quint64 failed = 0;
        int bit = 0;
        const auto check = [&](bool ok) {
            if (!ok)
                failed |= quint64(1) << bit;
            ++bit;
        };
        // Refused: by the seccomp list (EPERM for a listed call with an argument it refuses, ENOSYS for an unlisted call) or by
        // Landlock (EACCES).
        const auto refused = [](long result) { return result < 0 && (errno == EPERM || errno == EACCES || errno == ENOSYS); };
        if (!confineRenderer())
            failed = ~quint64(0);
        // 0-1: what it may do: read what it was given, read under /usr.
        char byte = 0;
        check(::read(document, &byte, 1) == 1 && byte == 'k');
        const int fonts = ::open("/usr", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        check(fonts >= 0);
        // 2-4: no file of the user's, no /proc (another process's environment: the review's probe), no terminal.
        check(refused(::open(existing.constData(), O_RDONLY | O_CLOEXEC)));
        check(refused(::open(environ.constData(), O_RDONLY | O_CLOEXEC)));
        check(refused(::open("/dev/tty", O_RDONLY | O_CLOEXEC)));
        // 5-11: no write, creation, truncation or append anywhere.
        check(refused(::open(existing.constData(), O_WRONLY | O_CLOEXEC)));
        check(refused(::open(existing.constData(), O_RDWR | O_CLOEXEC)));
        check(refused(::open(existing.constData(), O_RDONLY | O_TRUNC | O_CLOEXEC)));
        check(refused(::open(existing.constData(), O_WRONLY | O_APPEND | O_CLOEXEC)));
        check(refused(::open(made.constData(), O_RDONLY | O_CREAT | O_CLOEXEC, 0600)));
        check(refused(::openat(AT_FDCWD, made.constData(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600)));
        check(refused(::open("/usr/.grassfield-probe", O_WRONLY | O_CREAT | O_CLOEXEC, 0600)));
        // 12-13: no socket.
        check(refused(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)));
        check(refused(::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)));
        // 14-20: no change to a file or a folder.
        check(refused(::unlink(existing.constData())));
        check(refused(::rename(existing.constData(), made.constData())));
        check(refused(::mkdir(made.constData(), 0700)));
        check(refused(::symlink(existing.constData(), made.constData())));
        check(refused(::link(existing.constData(), made.constData())));
        check(refused(::chmod(existing.constData(), 0777)));
        check(refused(::truncate(existing.constData(), 0)));
        // 21-26: no program, no process, no namespace (clone with CLONE_NEWUSER: the review's probe), io_uring refused.
        char *const argv[] = {const_cast<char *>("/bin/true"), nullptr};
        check(refused(::execv("/bin/true", argv)));
        const long forked = ::fork();
        if (forked == 0)
            ::_exit(0);
        check(refused(forked));
        const long cloned = ::syscall(SYS_clone, long(SIGCHLD), 0L, 0L, 0L, 0L);
        if (cloned == 0)
            ::_exit(0);
        check(refused(cloned));
        const long user = ::syscall(SYS_clone, long(CLONE_NEWUSER | SIGCHLD), 0L, 0L, 0L, 0L);
        if (user == 0)
            ::_exit(0);
        check(refused(user));
        check(refused(::unshare(CLONE_NEWUSER)));
        check(refused(::syscall(SYS_io_uring_setup, 1, nullptr)));
        // 27-28: a thread of its own still starts (glibc falls back from clone3 to clone).
        pthread_t thread;
        const int started = ::pthread_create(&thread, nullptr, [](void *) -> void * { return reinterpret_cast<void *>(42); }, nullptr);
        void *returned = nullptr;
        check(started == 0 && ::pthread_join(thread, &returned) == 0 && returned == reinterpret_cast<void *>(42));
        check(::kill(::getpid(), 0) == 0);
        // 29-36: nothing done to another process (its parent stands for grassfield-portal): no signal, no resource limit, no
        // priority or scheduling change (the review's probes, with values that would change nothing if they went).
        const pid_t parent = ::getppid();
        check(refused(::kill(parent, 0)));
        check(refused(::kill(0, 0)));
        check(refused(::syscall(SYS_tgkill, parent, parent, 0)));
        struct rlimit limit {};
        check(refused(::syscall(SYS_prlimit64, parent, RLIMIT_NOFILE, nullptr, &limit)));
        check(::syscall(SYS_prlimit64, 0, RLIMIT_NOFILE, nullptr, &limit) == 0);
        check(refused(::setpriority(PRIO_PROCESS, id_t(parent), 0)));
        struct sched_param param {};
        check(refused(::sched_setscheduler(parent, SCHED_OTHER, &param)));
        check(refused(::syscall(SYS_ioprio_set, 1 /* IOPRIO_WHO_PROCESS */, parent, 0)));
        // 37: another task's processors (it would tell that the task exists; a sanitizer build allows it, for its own threads).
        cpu_set_t processors;
#ifdef __SANITIZE_ADDRESS__
        check(true);
#else
        check(refused(::sched_getaffinity(parent, sizeof processors, &processors)));
#endif
        check(::sched_getaffinity(0, sizeof processors, &processors) == 0);
        // 39-42: no lock (a covert channel: the review's probe), no watch, no terminal input (TIOCSTI), no ioctl at all.
        check(refused(::flock(document, LOCK_EX | LOCK_NB)));
        struct flock region {};
        region.l_type = F_RDLCK;
        check(refused(::fcntl(document, F_SETLK, &region)));
        check(refused(::inotify_init1(IN_CLOEXEC)));
        char c = '#';
        check(refused(::ioctl(STDERR_FILENO, TIOCSTI, &c)));
        ::write(report[1], &failed, sizeof failed);
        ::_exit(0);
    }
    ::close(report[1]);
    ::close(document);
    quint64 failed = ~quint64(0);
    ASSERT_EQ(::read(report[0], &failed, sizeof failed), ssize_t(sizeof failed));
    ::close(report[0]);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);
    EXPECT_TRUE(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    EXPECT_EQ(failed, 0u) << "the checks that failed, as bits (in the child's order)";
    ASSERT_TRUE(keep.open(QIODevice::ReadOnly));
    EXPECT_EQ(keep.readAll(), QByteArray("keep"));
    EXPECT_FALSE(QFileInfo::exists(QFile::decodeName(made)));
    EXPECT_FALSE(QFileInfo::exists(QStringLiteral("/usr/.grassfield-probe")));
}

// Landlock confines the thread that installs it and the ones it starts after (the counter-review of step 6b, MINOR 2): a process
// with another thread already running is not confined at all, and draws nothing.
TEST(PrintPreview, AChildWithAnotherThreadDrawsNothing)
{
    int report[2];
    ASSERT_EQ(::pipe2(report, O_CLOEXEC), 0);
    const pid_t pid = ::fork();
    ASSERT_GE(pid, 0);
    if (pid == 0) {
        pthread_t thread;
        int hold[2];
        if (::pipe(hold) != 0)
            ::_exit(2);
        // A thread that waits (on a pipe nobody writes) while the confinement is tried.
        ::pthread_create(&thread, nullptr, [](void *fd) -> void * {
            char byte;
            ::read(*static_cast<int *>(fd), &byte, 1);
            return nullptr;
        }, &hold[0]);
        const char confined = confineRenderer() ? 1 : 0;
        ::write(report[1], &confined, 1);
        ::_exit(0);
    }
    ::close(report[1]);
    char confined = 1;
    ASSERT_EQ(::read(report[0], &confined, 1), 1);
    ::close(report[0]);
    int status = 0;
    ASSERT_EQ(::waitpid(pid, &status, 0), pid);
    EXPECT_EQ(confined, 0) << "two threads: no confinement, no preview";
}

// The child's environment is allow-listed (the review's MAJOR 2): the locale only, never the bus address, the display or the
// user's own variables; it starts in a session of its own (no terminal, not its parent's process group).
TEST(PrintPreview, TheChildGetsOnlyTheLocale)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    qputenv("GRASSFIELD_TEST_SECRET", "hunter2");
    const QStringList env = rendererEnvironment();
    for (const QString &entry : env)
        EXPECT_TRUE(entry.startsWith(QStringLiteral("LANG=")) || entry.startsWith(QStringLiteral("LC_")) || entry.startsWith(QStringLiteral("ASAN_OPTIONS=")))
            << entry.toStdString();
    // A stand-in for the child that writes what it got: its environment, and whether it leads a session of its own.
    QFile document(dir.filePath(QStringLiteral("doc.pdf")));
    ASSERT_TRUE(document.open(QIODevice::WriteOnly));
    document.write("%PDF-1.4\n");
    document.close();
    const int fd = ::open(QFile::encodeName(document.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    const QString out = dir.filePath(QStringLiteral("env"));
    EXPECT_FALSE(renderPreview({QStringLiteral("/bin/sh"), QStringLiteral("-c"),
                                QStringLiteral("env >\"$0\"; read -r line </proc/$$/stat; set -- $line; echo \"session $6 of $1\" >>\"$0\""), out},
                               fd, 0, QSize(10, 10), 3000)
                     .ok);
    ::close(fd);
    qunsetenv("GRASSFIELD_TEST_SECRET");
    QFile got(out);
    ASSERT_TRUE(got.open(QIODevice::ReadOnly));
    const QString text = QString::fromUtf8(got.readAll());
    EXPECT_FALSE(text.contains(QStringLiteral("hunter2")));
    EXPECT_FALSE(text.contains(QStringLiteral("DBUS_SESSION_BUS_ADDRESS")));
    EXPECT_FALSE(text.contains(QStringLiteral("WAYLAND_DISPLAY")));
    EXPECT_FALSE(text.contains(QStringLiteral("HOME=")));
    // Its session is its own (setsid): its session id is its own pid.
    const QStringList session = text.split(QLatin1Char('\n'), Qt::SkipEmptyParts).filter(QStringLiteral("session ")).value(0).split(QLatin1Char(' '));
    ASSERT_EQ(session.size(), 4) << text.toStdString();
    EXPECT_EQ(session.at(1), session.at(3));
    EXPECT_NE(session.at(1), QString::number(::getsid(0))) << "not the session it was started from";
}

// Step 6b: a document sent first is kept in an unlinked file of the backend's own (0600), only when it is a PDF and within the
// limit; a file is read where it is (its descriptor's position untouched: the call can go on to x-d-p-gtk as it came), a pipe as
// it flows (then it cannot). Each reader of the kept file gets its own position.
TEST(PrintPreview, TheDocumentIsKeptPrivately)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QByteArray pdf = twoPages();
    const auto source = [&dir](const QByteArray &bytes) {
        static int n = 0;
        QFile f(dir.filePath(QStringLiteral("source-%1").arg(++n)));
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(bytes);
        f.close();
        return ::open(QFile::encodeName(f.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    };
    QTemporaryDir spoolDir;
    ASSERT_TRUE(spoolDir.isValid());
    const int original = source(pdf);
    Spooled kept = spoolDocument(::dup(original), spoolDir.path(), 2000, print::kMaxDocumentBytes);
    ASSERT_GE(kept.fd, 0) << kept.error.toStdString();
    EXPECT_EQ(kept.size, pdf.size());
    EXPECT_FALSE(kept.notPdf);
    EXPECT_FALSE(kept.consumed);
    EXPECT_EQ(::lseek(original, 0, SEEK_CUR), 0) << "the application's descriptor where it was";
    ::close(original);
    struct stat st;
    ASSERT_EQ(::fstat(kept.fd, &st), 0);
    EXPECT_EQ(st.st_nlink, 0u) << "no name anyone could open";
    EXPECT_EQ(st.st_mode & 0777, 0600u);
    EXPECT_TRUE(QDir(spoolDir.path()).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot).isEmpty());
    const int a = reopenSpool(kept.fd), b = reopenSpool(kept.fd);
    ASSERT_GE(a, 0);
    ASSERT_GE(b, 0);
    char head[5];
    ASSERT_EQ(::read(a, head, 5), 5);
    QByteArray all(pdf.size(), Qt::Uninitialized);
    ASSERT_EQ(::read(b, all.data(), size_t(all.size())), ssize_t(pdf.size())) << "its own position";
    EXPECT_EQ(all, pdf);
    ::close(a);
    ::close(b);
    ::close(kept.fd);

    const int ps = source("%!PS-Adobe-3.0\nshowpage\n");
    const Spooled notPdf = spoolDocument(ps, spoolDir.path(), 2000, print::kMaxDocumentBytes);
    EXPECT_TRUE(notPdf.notPdf);
    EXPECT_FALSE(notPdf.consumed) << "a file: it can go on as it came";
    EXPECT_EQ(notPdf.fd, -1);

    int ends[2];
    ASSERT_EQ(::pipe2(ends, O_CLOEXEC), 0);
    ASSERT_EQ(::write(ends[1], pdf.constData(), size_t(pdf.size())), pdf.size());
    ::close(ends[1]);
    const Spooled flowed = spoolDocument(ends[0], spoolDir.path(), 2000, print::kMaxDocumentBytes);
    ASSERT_GE(flowed.fd, 0);
    EXPECT_TRUE(flowed.consumed);
    EXPECT_EQ(flowed.size, pdf.size());
    ::close(flowed.fd);

    const Spooled large = spoolDocument(source(pdf), spoolDir.path(), 2000, 100);
    EXPECT_EQ(large.fd, -1);
    EXPECT_EQ(large.error, QStringLiteral("the document is too large"));
    EXPECT_TRUE(QDir(spoolDir.path()).entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot).isEmpty());

    // A descriptor that does not stand at the start: what x-d-p-gtk would read from it, from where it stands (the review's NIT).
    const int moved = source("junk" + pdf);
    ASSERT_EQ(::lseek(moved, 4, SEEK_SET), 4);
    const int mine = ::dup(moved);
    Spooled fromThere = spoolDocument(mine, spoolDir.path(), 2000, print::kMaxDocumentBytes);
    ASSERT_GE(fromThere.fd, 0) << fromThere.error.toStdString();
    EXPECT_EQ(fromThere.size, pdf.size());
    EXPECT_EQ(::lseek(moved, 0, SEEK_CUR), 4) << "its position untouched";
    ::close(moved);
    ::close(fromThere.fd);

    // A folder that is not there yet is made, for this user only (the cache folder of a first print).
    const QString fresh = spoolDir.filePath(QStringLiteral("cache/grassfield/print"));
    Spooled first = spoolDocument(source(pdf), fresh, 2000, print::kMaxDocumentBytes);
    ASSERT_GE(first.fd, 0) << first.error.toStdString();
    ::close(first.fd);
    struct stat folder;
    ASSERT_EQ(::stat(QFile::encodeName(fresh).constData(), &folder), 0);
    EXPECT_EQ(folder.st_mode & 0777, 0700u);

    // A pipe is read only once the caller agrees (the call has not gone to x-d-p-gtk meanwhile; the review's MINOR 6).
    int held[2];
    ASSERT_EQ(::pipe2(held, O_CLOEXEC), 0);
    ASSERT_EQ(::write(held[1], pdf.constData(), size_t(pdf.size())), pdf.size());
    ::close(held[1]);
    SpoolHooks refuse;
    refuse.mayConsume = [] { return false; };
    const Spooled notRead = spoolDocument(held[0], spoolDir.path(), 2000, print::kMaxDocumentBytes, refuse);
    EXPECT_EQ(notRead.fd, -1);
    EXPECT_FALSE(notRead.consumed) << "not a byte read";
}

// The documents kept at once share one budget (ADR-0035 6-21; the review's MAJOR 3): one that would go over it is not kept, and
// what a document took comes back when it goes.
TEST(PrintPreview, TheDocumentsKeptShareOneBudget)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QByteArray pdf = twoPages();
    const auto source = [&dir, &pdf] {
        static int n = 0;
        QFile f(dir.filePath(QStringLiteral("budget-%1").arg(++n)));
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(pdf);
        f.close();
        return ::open(QFile::encodeName(f.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    };
    SpoolHooks hooks;
    hooks.budget = std::make_shared<SpoolBudget>(pdf.size() + pdf.size() / 2);
    const Spooled first = spoolDocument(source(), dir.path(), 2000, print::kMaxDocumentBytes, hooks);
    ASSERT_GE(first.fd, 0);
    EXPECT_EQ(first.reserved, pdf.size());
    EXPECT_EQ(hooks.budget->used(), pdf.size());
    const Spooled second = spoolDocument(source(), dir.path(), 2000, print::kMaxDocumentBytes, hooks);
    EXPECT_EQ(second.fd, -1) << "over the budget the first one left";
    EXPECT_EQ(second.error, QStringLiteral("the documents waiting to print take all the room they may"));
    EXPECT_EQ(hooks.budget->used(), pdf.size()) << "what the refused one took came back";
    ::close(first.fd);
    hooks.budget->give(first.reserved);
    const Spooled third = spoolDocument(source(), dir.path(), 2000, print::kMaxDocumentBytes, hooks);
    EXPECT_GE(third.fd, 0) << "room again once the first one went";
    ::close(third.fd);
}

// Step 6b: the pages are drawn by the confined child: the page count and the page's size, the page fitted in the size asked on
// white; a page beyond the last, a document it cannot read, a child that does not answer in time or answers more than it was
// asked give no page.
TEST(PrintPreview, PagesAreDrawnByTheChild)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const auto keep = [&dir](const QByteArray &bytes) {
        QFile f(dir.filePath(QStringLiteral("doc")));
        EXPECT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write(bytes);
        f.close();
        return spoolDocument(::open(QFile::encodeName(f.fileName()).constData(), O_RDONLY | O_CLOEXEC), dir.path(), 2000, print::kMaxDocumentBytes).fd;
    };
    const int fd = keep(twoPages());
    ASSERT_GE(fd, 0);
    const Rendered info = renderPreview(renderer(), fd, 0, {}, 8000);
    ASSERT_TRUE(info.ok);
    EXPECT_EQ(info.pages, 2);
    EXPECT_NEAR(info.pageSize.width(), 595, 0.5);
    EXPECT_NEAR(info.pageSize.height(), 842, 0.5);
    EXPECT_TRUE(info.image.isNull()) << "no size asked";

    const Rendered first = renderPreview(renderer(), fd, 0, QSize(200, 300), 8000);
    ASSERT_TRUE(first.ok);
    ASSERT_FALSE(first.image.isNull());
    EXPECT_EQ(first.image.width(), 200);
    EXPECT_NEAR(first.image.height(), 283, 1);
    const double k = 200.0 / 595;
    // The band (x 100-495, y 100-342 from the top, in points) is black; the corner is the paper's white.
    EXPECT_EQ(first.image.pixelColor(int(300 * k), int(200 * k)), QColor(Qt::black));
    EXPECT_EQ(first.image.pixelColor(2, 2), QColor(Qt::white));
    const Rendered second = renderPreview(renderer(), fd, 1, QSize(200, 300), 8000);
    ASSERT_TRUE(second.ok);
    EXPECT_NEAR(second.pageSize.width(), 842, 0.5) << "landscape";
    EXPECT_EQ(second.image.width(), 200);
    EXPECT_NEAR(second.image.height(), 141, 1);
    EXPECT_FALSE(renderPreview(renderer(), fd, 2, QSize(200, 300), 8000).ok) << "beyond the last page";
    ::close(fd);

    const int garbage = keep("%PDF-1.4 nothing a reader can read\n");
    ASSERT_GE(garbage, 0);
    EXPECT_FALSE(renderPreview(renderer(), garbage, 0, QSize(200, 300), 8000).ok);
    QElapsedTimer clock;
    clock.start();
    EXPECT_FALSE(renderPreview({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("sleep 5"), QStringLiteral("sh")}, garbage, 0,
                               QSize(200, 300), 300)
                     .ok);
    EXPECT_LT(clock.elapsed(), 3000) << "killed at its deadline";
    EXPECT_FALSE(renderPreview({QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf 'GFPP1 2 595 842 4000 4000\\n'"),
                                QStringLiteral("sh")},
                               garbage, 0, QSize(200, 300), 3000)
                     .ok)
        << "more than it was asked";
    ::close(garbage);
}

// PR2 without a token (step 6b): the sheet with the document's preview (its pages drawn on demand), the paper of its first page
// chosen where the printer has it; the job goes at once from the kept document, the printer applying the pages chosen; the sheet
// goes at once, the request when the job is sent; the pages drawn go with the request.
TEST_F(PrintTest, ADocumentSentFirstGetsTheSheetWithItsPreview)
{
    make([this](Print::Options &o) {
        o.uiDeadlineMs = 60000;
        o.spoolFolder = dir.path();
    });
    // The printer's own default paper is A4 (the sheet's first state too): the document's A5 wins.
    QList<QPair<int, int>> ready;
    QList<int> kept;
    QList<QVariantMap> papers;
    QList<std::tuple<int, int, QString>> drawn;
    QList<int> dismissed;
    QObject::connect(printer.get(), &Print::documentReady, printer.get(), [&ready](int id, int pages) { ready.append({id, pages}); });
    QObject::connect(printer.get(), &Print::documentRead, printer.get(), [&kept](int id) { kept.append(id); });
    QObject::connect(printer.get(), &Print::documentPaper, printer.get(), [&papers](int, const QVariantMap &media) { papers.append(media); });
    QObject::connect(printer.get(), &Print::pageRendered, printer.get(),
                     [&drawn](int id, int page, const QString &source) { drawn.append({id, page, source}); });
    QObject::connect(printer.get(), &Print::dismissed, printer.get(), [&dismissed](int id) { dismissed.append(id); });
    const int imagesBefore = PreviewImages::size();
    // The fixture with its first page A5 (420 x 595 points; the same length, so its cross-reference table still holds).
    QByteArray pdf = twoPages();
    pdf.replace("/MediaBox [0 0 595 842]", "/MediaBox [0 0 420 595]");
    auto reply = printDocument(kHandle, pdf, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty() && !ready.isEmpty(); }, 15000));
    ASSERT_EQ(opened.size(), 1);
    const int id = opened.first().first;
    EXPECT_TRUE(opened.first().second.value("document").toBool());
    EXPECT_TRUE(opened.first().second.value("canSavePdf").toBool()) << "the document is a PDF";
    EXPECT_EQ(kept, QList<int>{id}) << "kept, so printable, before (or whatever) its preview";
    EXPECT_EQ(ready, (QList<QPair<int, int>>{{id, 2}}));
    // The document's paper: chosen with the printer's options when its size came first, else suggested to the sheet after.
    const QString paper = papers.isEmpty() ? chosen.first().choices.value("media").toMap().value("name").toString()
                                           : papers.last().value("name").toString();
    EXPECT_EQ(paper, QStringLiteral("iso_a5_148x210mm")) << "the document's paper over the printer's A4";
    EXPECT_TRUE(gtk.calls.isEmpty());

    printer->renderPage(id, 0, 120, 160);
    ASSERT_TRUE(waitFor([&] { return !drawn.isEmpty(); }, 15000));
    const auto [drawnId, drawnPage, source] = drawn.first();
    EXPECT_EQ(drawnId, id);
    EXPECT_EQ(drawnPage, 0);
    ASSERT_TRUE(source.startsWith(QStringLiteral("image://printpreview/"))) << source.toStdString();
    const QImage image = PreviewImages::value(source.mid(21));
    EXPECT_FALSE(image.isNull());
    EXPECT_LE(image.width(), 120);
    EXPECT_LE(image.height(), 160);
    printer->renderPage(id, 5, 120, 160);
    ASSERT_EQ(drawn.size(), 2);
    EXPECT_EQ(std::get<2>(drawn.last()), QString()) << "no such page";

    QVariantMap choices = chosen.first().choices;
    choices.insert(QStringLiteral("pages"), QStringLiteral("ranges"));
    choices.insert(QStringLiteral("ranges"), QStringLiteral("2"));
    choices.insert(QStringLiteral("copies"), 2);
    ASSERT_TRUE(printer->answer(id, 0, choices));
    EXPECT_EQ(dismissed, QList<int>{id}) << "the sheet goes at once";
    ASSERT_TRUE(waitFor([&] { return reply->done; }, 15000));
    EXPECT_EQ(reply->response, 0u);
    EXPECT_TRUE(reply->results.isEmpty()) << "no token: the job went";
    ASSERT_EQ(system.jobs.size(), 1);
    EXPECT_EQ(system.jobs.first().document, pdf);
    EXPECT_EQ(system.jobs.first().printer, QStringLiteral("Office"));
    EXPECT_TRUE(system.jobs.first().options.contains({QStringLiteral("page-ranges"), QStringLiteral("2-2")})) << "the printer prints the pages";
    EXPECT_TRUE(system.jobs.first().options.contains({QStringLiteral("copies"), QStringLiteral("2")}));
    EXPECT_EQ(PreviewImages::size(), imagesBefore) << "the pages drawn go with the request";
}

// A document sent first that is not a PDF: x-d-p-gtk prints it as before step 6b, the document as it came (a file read in place);
// from a pipe, where it cannot be sent on, the print fails (only a PDF reaches a printer through Grassfield, decision 6-4).
TEST_F(PrintTest, ADocumentThatIsNotAPdfGoesToGtkAsItCame)
{
    make([this](Print::Options &o) { o.spoolFolder = dir.path(); });
    auto ps = printDocument(kHandle, "%!PS-Adobe-3.0\nshowpage\n", {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }, 15000));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("Print %1 token 0 fd valid").arg(kHandle));
    EXPECT_EQ(gtk.offsets, QList<qint64>{0}) << "the document as it came";
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return ps->done; }));
    EXPECT_EQ(ps->response, 0u) << "x-d-p-gtk's answer, relayed";
    EXPECT_TRUE(system.jobs.isEmpty());

    auto piped = printPipe(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/piped"), "%!PS-Adobe-3.0\nshowpage\n", {});
    ASSERT_TRUE(waitFor([&] { return piped->done; }, 15000));
    EXPECT_EQ(piped->response, 2u);
    EXPECT_EQ(gtk.calls.size(), 1);
}

// Open in Preview (step 6b), over PreparePrint and over a document sent first: the document goes to a private copy (a folder of
// its own in a folder only the user may enter, written as Save as PDF writes) that Preview opens; the application gets no path;
// an application that cannot make a PDF has no Open in Preview, and a private folder that is not private refuses the copy.
TEST_F(PrintTest, OpenInPreviewOpensAPrivateCopy)
{
    const QString base = dir.filePath(QStringLiteral("private"));
    const QString launched = dir.filePath(QStringLiteral("launched"));
    make([&](Print::Options &o) {
        o.uiDeadlineMs = 60000;
        o.spoolFolder = dir.path();
        o.previewFolder = base;
        o.previewCommand = {QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf '%s\\n' \"$1\" >>\"$0\""), launched};
    });
    const auto launches = [&launched] {
        QFile f(launched);
        return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts) : QStringList();
    };
    auto reply = preparedAnswer(kHandle, {{QStringLiteral("preview"), true}}, {{QStringLiteral("output-basename"), QStringLiteral("Quarterly Report")}});
    ASSERT_EQ(reply->response, 0u);
    const QVariantMap settings = mapOf(reply->results.value("settings"));
    EXPECT_EQ(settings.value("output-uri").toString(), QStringLiteral("file:///dev/null")) << "never a path";
    EXPECT_EQ(settings.value("output-file-format").toString(), QStringLiteral("pdf"));
    EXPECT_FALSE(settings.contains("printer"));
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), reply, "%PDF-1.7 the report");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u);
    ASSERT_TRUE(waitFor([&] { return launches().size() == 1; }));
    const QString copy = launches().first();
    EXPECT_EQ(QFileInfo(copy).fileName(), QStringLiteral("Quarterly Report.pdf"));
    EXPECT_EQ(QFileInfo(QFileInfo(copy).absolutePath()).absolutePath(), QFileInfo(base).canonicalFilePath());
    QFile written(copy);
    ASSERT_TRUE(written.open(QIODevice::ReadOnly));
    EXPECT_EQ(written.readAll(), QByteArray("%PDF-1.7 the report"));
    struct stat st;
    ASSERT_EQ(::stat(QFile::encodeName(base).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    ASSERT_EQ(::stat(QFile::encodeName(QFileInfo(copy).absolutePath()).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    EXPECT_TRUE(system.jobs.isEmpty());

    // A document sent first.
    const qsizetype before = chosen.size();
    auto sent = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/sent"), twoPages(), {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }, 15000));
    QVariantMap choices = chosen.last().choices;
    choices.insert(QStringLiteral("preview"), true);
    ASSERT_TRUE(printer->answer(chosen.last().id, 0, choices));
    ASSERT_TRUE(waitFor([&] { return sent->done; }, 15000));
    EXPECT_EQ(sent->response, 0u);
    ASSERT_TRUE(waitFor([&] { return launches().size() == 2; }));
    QFile second(launches().last());
    ASSERT_TRUE(second.open(QIODevice::ReadOnly));
    EXPECT_EQ(second.readAll(), twoPages());
    EXPECT_EQ(QFileInfo(launches().last()).fileName(), QStringLiteral("Print.pdf")) << "the document's title";

    // An application that makes PostScript only: no Open in Preview.
    const qsizetype count = chosen.size();
    auto ps = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/ps"), {}, {},
                      {{QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("ps")}}});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > count; }));
    choices = chosen.last().choices;
    choices.insert(QStringLiteral("preview"), true);
    EXPECT_FALSE(printer->answer(chosen.last().id, 0, choices));
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));

    // A private folder others may enter: no copy, the print fails.
    ASSERT_EQ(::chmod(QFile::encodeName(base).constData(), 0755), 0);
    auto open = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/open"), {{QStringLiteral("preview"), true}});
    auto refused = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/refused"), open, "%PDF-1.7 x");
    ASSERT_TRUE(waitFor([&] { return refused->done; }));
    EXPECT_EQ(refused->response, 2u);
    EXPECT_EQ(launches().size(), 2);
}

// Presets (step 6b): Last Used Settings are kept at each print (in the state file, for every printer) and the next sheet opens on
// them, where the printer takes them; Default Settings bring back the application's and the printer's; what belongs to the
// document (the copies) is never kept; a state file that does not read is no Last Used Settings.
TEST_F(PrintTest, LastUsedSettingsAreKeptForEveryPrinter)
{
    const QString state = dir.filePath(QStringLiteral("state/portal-print.json"));
    system.officeOptions = officeOptions();
    make([&state](Print::Options &o) { o.stateFile = state; });
    auto first = preparedAnswer(kHandle, {{QStringLiteral("duplex"), QStringLiteral("vertical")},
                                          {QStringLiteral("color"), false},
                                          {QStringLiteral("copies"), 3},
                                          {QStringLiteral("options"), QVariantMap{{QStringLiteral("print-quality"), QStringLiteral("5")},
                                                                                  {QStringLiteral("media-source"), QStringLiteral("auto")}}}});
    ASSERT_EQ(first->response, 0u);
    EXPECT_FALSE(opened.first().second.value("hasLastUsed").toBool());
    EXPECT_EQ(chosen.first().choices.value("preset").toString(), QStringLiteral("default"));
    QFile file(state);
    ASSERT_TRUE(file.open(QIODevice::ReadOnly));
    const QJsonObject kept = QJsonDocument::fromJson(file.readAll()).object().value(QStringLiteral("lastUsed")).toObject();
    file.close();
    EXPECT_EQ(kept.value(QStringLiteral("duplex")).toString(), QStringLiteral("vertical"));
    EXPECT_FALSE(kept.value(QStringLiteral("color")).toBool());
    EXPECT_EQ(kept.value(QStringLiteral("options")).toObject().value(QStringLiteral("print-quality")).toString(), QStringLiteral("5"));
    EXPECT_FALSE(kept.contains(QStringLiteral("copies")));

    // A new process reads them back: the sheet opens on Last Used Settings.
    make([&state](Print::Options &o) { o.stateFile = state; });
    const qsizetype before = chosen.size();
    auto second = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }));
    EXPECT_TRUE(opened.last().second.value("hasLastUsed").toBool());
    const int id = chosen.last().id;
    QVariantMap choices = chosen.last().choices;
    EXPECT_EQ(choices.value("preset").toString(), QStringLiteral("last"));
    EXPECT_EQ(choices.value("duplex").toString(), QStringLiteral("vertical"));
    EXPECT_FALSE(choices.value("color").toBool());
    EXPECT_EQ(choices.value("options").toMap().value("print-quality").toString(), QStringLiteral("5"));
    EXPECT_EQ(choices.value("copies").toInt(), 1) << "the copies are the document's";
    // Default Settings, then Last Used Settings again.
    choices.insert(QStringLiteral("copies"), 4);
    printer->choosePreset(id, QStringLiteral("default"), choices);
    ASSERT_EQ(chosen.last().id, id);
    choices = chosen.last().choices;
    EXPECT_EQ(choices.value("preset").toString(), QStringLiteral("default"));
    EXPECT_EQ(choices.value("duplex").toString(), QStringLiteral("simplex"));
    EXPECT_TRUE(choices.value("color").toBool());
    EXPECT_EQ(choices.value("options").toMap().value("print-quality").toString(), QStringLiteral("4")) << "the printer's default";
    EXPECT_EQ(choices.value("copies").toInt(), 4) << "what the user chose for the document stays";
    printer->choosePreset(id, QStringLiteral("last"), choices);
    EXPECT_EQ(chosen.last().choices.value("duplex").toString(), QStringLiteral("vertical"));
    // A printer with neither two sides nor colour takes neither.
    const qsizetype mono = chosen.size();
    printer->choosePrinter(id, QStringLiteral("Mono"), chosen.last().choices);
    ASSERT_TRUE(waitFor([&] { return chosen.size() > mono; }));
    EXPECT_EQ(chosen.last().choices.value("duplex").toString(), QStringLiteral("simplex"));
    EXPECT_FALSE(chosen.last().choices.value("color").toBool());
    EXPECT_TRUE(chosen.last().choices.value("options").toMap().isEmpty());
    EXPECT_TRUE(printer->answer(id, 1));
    ASSERT_TRUE(waitFor([&] { return second->done; }));

    // A state file that does not read: Default Settings only.
    ASSERT_TRUE(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write("{\"version\": 1, \"lastUsed\": {\"duplex\": 3}}");
    file.close();
    make([&state](Print::Options &o) { o.stateFile = state; });
    const qsizetype count = opened.size();
    auto third = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/third"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return opened.size() > count; }));
    EXPECT_FALSE(opened.last().second.value("hasLastUsed").toBool());
    EXPECT_TRUE(printer->answer(opened.last().first, 1));
    ASSERT_TRUE(waitFor([&] { return third->done; }));
}

// A printer's own options (step 6b): read with its options, at its defaults; the job carries the ones chosen, each only with a
// value the printer listed (another value, or an option it does not report, never goes); another printer starts from its own.
TEST_F(PrintTest, APrintersOwnOptionsGoWithTheJob)
{
    system.officeOptions = officeOptions();
    const qsizetype before = chosen.size();
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }));
    const int id = chosen.last().id;
    EXPECT_EQ(chosen.last().capabilities.value("options").toList().size(), 2);
    QVariantMap choices = chosen.last().choices;
    EXPECT_EQ(choices.value("options").toMap(),
              (QVariantMap{{QStringLiteral("media-source"), QStringLiteral("auto")}, {QStringLiteral("print-quality"), QStringLiteral("4")}}));
    choices.insert(QStringLiteral("options"), QVariantMap{{QStringLiteral("print-quality"), QStringLiteral("5")},
                                                          {QStringLiteral("media-source"), QStringLiteral("tray-9")},
                                                          {QStringLiteral("output-bin"), QStringLiteral("lower")}});
    ASSERT_TRUE(printer->answer(id, 0, choices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), reply, "%PDF-1.4 x");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    ASSERT_EQ(system.jobs.size(), 1);
    const auto &options = system.jobs.first().options;
    EXPECT_TRUE(options.contains({QStringLiteral("print-quality"), QStringLiteral("5")}));
    EXPECT_FALSE(options.contains({QStringLiteral("media-source"), QStringLiteral("auto")})) << "a default is not sent (the review's MINOR 5)";
    for (const auto &o : options) {
        EXPECT_NE(o.first, QStringLiteral("media-source")) << "a value Office does not list";
        EXPECT_NE(o.first, QStringLiteral("output-bin")) << "an option Office does not report";
    }

    const qsizetype count = chosen.size();
    auto other = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/other"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > count; }));
    const qsizetype mono = chosen.size();
    printer->choosePrinter(chosen.last().id, QStringLiteral("Mono"), chosen.last().choices);
    ASSERT_TRUE(waitFor([&] { return chosen.size() > mono; }));
    EXPECT_TRUE(chosen.last().choices.value("options").toMap().isEmpty()) << "Mono reports none";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));
    ASSERT_TRUE(waitFor([&] { return other->done; }));
}

// The review's MINOR 6: a call whose document came on a pipe that is being read cannot go to x-d-p-gtk any more (it would get
// it truncated): when the sheet does not show in time, it ends with response 2 instead; a file read in place still goes on.
TEST_F(PrintTest, ADocumentReadFromAPipeIsNeverSentOnTruncated)
{
    make([this](Print::Options &o) {
        // Long enough for the reader to have taken the pipe's first bytes (a deadline before that sends the untouched pipe to
        // x-d-p-gtk whole, which is right too, but not this test's case).
        o.uiDeadlineMs = 1500;
        o.spoolFolder = dir.path();
    });
    std::shared_ptr<Reply> reply;
    const int writer = printHeldPipe(kHandle, "%PDF-1.4\n% the first bytes", &reply);
    ASSERT_TRUE(waitFor([&] { return reply->done; }, 5000));
    EXPECT_EQ(reply->response, 2u);
    EXPECT_TRUE(gtk.calls.isEmpty()) << "nothing went to x-d-p-gtk";
    ::close(writer);
    // The same from a file: it goes to x-d-p-gtk as it came.
    auto file = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/file"), twoPages(), {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }, 5000));
    EXPECT_EQ(gtk.offsets, QList<qint64>{0});
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return file->done; }));
    EXPECT_EQ(file->response, 1u);
}

// The documents sent first share one budget across requests (ADR-0035 6-21; the review's MAJOR 3): one that would go over what
// the others waiting left fails (response 2), and a request that ends gives its share back.
TEST_F(PrintTest, DocumentsWaitingShareOneBudget)
{
    const QByteArray pdf = twoPages();
    make([this, &pdf](Print::Options &o) {
        o.uiDeadlineMs = 60000;
        o.spoolFolder = dir.path();
        o.spoolBudget = pdf.size() + pdf.size() / 2;
    });
    auto first = printDocument(kHandle, pdf, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }, 15000));
    const int firstId = chosen.last().id;
    // Over the budget the first one left: a file read in place goes to x-d-p-gtk as it came (ADR-0035 6-28), a pipe fails.
    auto second = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), pdf, {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }, 15000));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("Print /org/freedesktop/portal/desktop/request/1_1/second token 0 fd valid"));
    EXPECT_EQ(gtk.offsets, QList<qint64>{0}) << "as it came";
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return second->done; }));
    EXPECT_EQ(second->response, 0u) << "x-d-p-gtk's answer, relayed";
    auto piped = printPipe(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/piped"), pdf, {});
    ASSERT_TRUE(waitFor([&] { return piped->done; }, 15000));
    EXPECT_EQ(piped->response, 2u) << "a pipe read already cannot go on";
    EXPECT_EQ(gtk.calls.size(), 1);
    EXPECT_TRUE(printer->answer(firstId, 1));
    ASSERT_TRUE(waitFor([&] { return first->done; }));
    const qsizetype before = chosen.size();
    auto third = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/third"), pdf, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }, 15000)) << "room again once the first one ended";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));
    ASSERT_TRUE(waitFor([&] { return third->done; }));
}

// Open in Preview's copies (the review's MINOR 4): a name within a file name's 255 bytes (a long title in Japanese); the old
// copies go (older than a day, or beyond the newest 16), never through a link; in the session, systemd-run is told not to expand
// ${NAME} in the copy's path.
TEST_F(PrintTest, OpenInPreviewKeepsItsCopiesInBounds)
{
    const QString base = dir.filePath(QStringLiteral("private"));
    const QString launched = dir.filePath(QStringLiteral("launched"));
    make([&](Print::Options &o) {
        o.uiDeadlineMs = 60000;
        o.previewFolder = base;
        o.previewCommand = {QStringLiteral("/bin/sh"), QStringLiteral("-c"), QStringLiteral("printf '%s\\n' \"$1\" >>\"$0\""), launched};
    });
    ASSERT_TRUE(QDir().mkpath(base));
    ASSERT_EQ(::chmod(QFile::encodeName(base).constData(), 0700), 0);
    // 20 copies of earlier days and of just now, and a link named like one, to a folder that must be left alone.
    QTemporaryDir elsewhere;
    ASSERT_TRUE(elsewhere.isValid());
    QFile precious(elsewhere.filePath(QStringLiteral("precious")));
    ASSERT_TRUE(precious.open(QIODevice::WriteOnly));
    precious.write("keep");
    precious.close();
    ASSERT_TRUE(QFile::link(elsewhere.path(), QDir(base).filePath(QStringLiteral("print-link"))));
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    for (int i = 0; i < 20; ++i) {
        const QString folder = QDir(base).filePath(QStringLiteral("print-%1").arg(i, 6, 10, QLatin1Char('0')));
        ASSERT_TRUE(QDir().mkpath(folder));
        QFile copy(QDir(folder).filePath(QStringLiteral("Old.pdf")));
        ASSERT_TRUE(copy.open(QIODevice::WriteOnly));
        copy.write("%PDF-1.4 old");
        copy.close();
        // The first four of two days ago, the others of the last minutes (the newest last).
        const qint64 when = i < 4 ? now - 2 * 24 * 3600 : now - 600 + i;
        const struct timespec times[2] = {{time_t(when), 0}, {time_t(when), 0}};
        ASSERT_EQ(::utimensat(AT_FDCWD, QFile::encodeName(folder).constData(), times, 0), 0);
    }
    const QString title = QString(120, QChar(0x65E5)); // 日, 3 bytes each: 360 bytes
    auto reply = preparedAnswer(kHandle, {{QStringLiteral("preview"), true}}, {{QStringLiteral("output-basename"), title}});
    ASSERT_EQ(reply->response, 0u);
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), reply, "%PDF-1.7 a long title");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u) << "a long name is cut, not refused";
    QFile out(launched);
    ASSERT_TRUE(waitFor([&] { return out.exists(); }));
    ASSERT_TRUE(out.open(QIODevice::ReadOnly));
    const QString copy = QString::fromUtf8(out.readAll()).trimmed();
    EXPECT_LE(QFile::encodeName(QFileInfo(copy).fileName()).size(), 255);
    EXPECT_TRUE(QFileInfo(copy).fileName().endsWith(QStringLiteral(".pdf")));
    EXPECT_TRUE(QFileInfo(copy).isFile());
    const QStringList left = QDir(base).entryList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::System, QDir::Name);
    QStringList folders = left.filter(QRegularExpression(QStringLiteral("^print-[0-9]{6}$")));
    EXPECT_EQ(folders.size(), Print::kKeptCopies - 1) << "the newest 15 of the old ones, and the new copy beside them";
    EXPECT_FALSE(folders.contains(QStringLiteral("print-000000"))) << "two days old";
    EXPECT_FALSE(folders.contains(QStringLiteral("print-000004"))) << "beyond the newest 16";
    EXPECT_TRUE(folders.contains(QStringLiteral("print-000019")));
    EXPECT_TRUE(QFileInfo(QDir(base).filePath(QStringLiteral("print-link"))).isSymLink()) << "a link is not a copy's folder";
    EXPECT_TRUE(precious.exists());

    // A name with dollar signs (systemd-run, and uwsm's own when it starts services, would expand ${NAME}): none in the copy's
    // name, which stays within 255 bytes (each sign becomes a 3-byte character before the cap).
    out.remove();
    auto dollars = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/dollars"), {{QStringLiteral("preview"), true}},
                                  {{QStringLiteral("output-basename"), QStringLiteral("${HOME}") + QString(120, QLatin1Char('$'))}});
    ASSERT_EQ(dollars->response, 0u);
    auto dollarJob = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/dollarjob"), dollars, "%PDF-1.7 dollars");
    ASSERT_TRUE(waitFor([&] { return dollarJob->done; }));
    EXPECT_EQ(dollarJob->response, 0u);
    QFile second(launched);
    ASSERT_TRUE(waitFor([&] { return second.exists(); }));
    ASSERT_TRUE(second.open(QIODevice::ReadOnly));
    const QString dollarCopy = QString::fromUtf8(second.readAll()).trimmed();
    EXPECT_FALSE(QFileInfo(dollarCopy).fileName().contains(QLatin1Char('$'))) << dollarCopy.toStdString();
    EXPECT_TRUE(QFileInfo(dollarCopy).fileName().startsWith(QString(QChar(0xFF04)) + QStringLiteral("{HOME}")));
    EXPECT_LE(QFile::encodeName(QFileInfo(dollarCopy).fileName()).size(), 255);
    EXPECT_TRUE(QFileInfo(dollarCopy).isFile());

    // systemd-run: --expand-environment=no where systemd knows it, uwsm-app where there is one.
    EXPECT_EQ(Print::sessionPreviewCommand(true, true),
              (QStringList{QStringLiteral("systemd-run"), QStringLiteral("--user"), QStringLiteral("--collect"), QStringLiteral("--quiet"),
                           QStringLiteral("--expand-environment=no"), QStringLiteral("--"), QStringLiteral("uwsm-app"), QStringLiteral("--"),
                           QStringLiteral("grassfield-preview"), QStringLiteral("--")}));
    EXPECT_FALSE(Print::sessionPreviewCommand(false, false).contains(QStringLiteral("--expand-environment=no")));
    EXPECT_FALSE(Print::sessionPreviewCommand(false, false).contains(QStringLiteral("uwsm-app")));
}

// Open in Preview's old copies go when the portal starts too, not only at the next copy (the counter-review of step 6b, NIT).
TEST_F(PrintTest, OldCopiesGoWhenThePortalStarts)
{
    const QString base = dir.filePath(QStringLiteral("startup"));
    ASSERT_TRUE(QDir().mkpath(base));
    ASSERT_EQ(::chmod(QFile::encodeName(base).constData(), 0700), 0);
    const QString old = QDir(base).filePath(QStringLiteral("print-old000"));
    const QString recent = QDir(base).filePath(QStringLiteral("print-new000"));
    ASSERT_TRUE(QDir().mkpath(old));
    ASSERT_TRUE(QDir().mkpath(recent));
    const qint64 then = QDateTime::currentSecsSinceEpoch() - 3 * 24 * 3600;
    const struct timespec times[2] = {{time_t(then), 0}, {time_t(then), 0}};
    ASSERT_EQ(::utimensat(AT_FDCWD, QFile::encodeName(old).constData(), times, 0), 0);
    make([&base](Print::Options &o) { o.previewFolder = base; });
    EXPECT_TRUE(waitFor([&] { return !QFileInfo::exists(old); })) << "three days old";
    EXPECT_TRUE(QFileInfo::exists(recent));
}

// The user's own default (lpoptions) reaches the job when it differs from the queue's (the counter-review of step 6b, MINOR 1:
// libcups does not add lpoptions to a job, as lp does).
TEST_F(PrintTest, TheUsersOwnDefaultReachesTheJob)
{
    QList<print::PrinterOption> options = officeOptions();
    options[1].defaultValue = QStringLiteral("5"); // lpoptions print-quality=5; the queue's own stays 4
    system.officeOptions = options;
    auto reply = preparedAnswer(kHandle, {});
    ASSERT_EQ(reply->response, 0u);
    EXPECT_EQ(chosen.last().choices.value("options").toMap().value("print-quality").toString(), QStringLiteral("5")) << "shown first";
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), reply, "%PDF-1.4 x");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    ASSERT_EQ(system.jobs.size(), 1);
    EXPECT_TRUE(system.jobs.first().options.contains({QStringLiteral("print-quality"), QStringLiteral("5")}));
    for (const auto &o : system.jobs.first().options)
        EXPECT_NE(o.first, QStringLiteral("media-source")) << "the queue's own default is not sent";
}

// The libcups side against a real scheduler (A-PR1): tests/integration/print_cups.sh runs this with a scratch cupsd whose default
// queue GF_TEST_CUPS_PRINTER writes its jobs to a file, its PPD offering A4, US Letter and A5, two sides and colour; skipped
// elsewhere. The printers listed (the default flagged, its name and place), what it supports read off the GUI thread (its own
// options too, step 6b), a job sent with its options (the scheduler keeps them on the job), and a printer CUPS does not know
// refused.
TEST(CupsPrintSystem, ListsReadsAndPrintsThroughTheScheduler)
{
    const QString queue = qEnvironmentVariable("GF_TEST_CUPS_PRINTER");
    if (queue.isEmpty())
        GTEST_SKIP() << "needs tests/integration/print_cups.sh (a scratch cupsd)";
    CupsPrintSystem system;
    QObject context;
    const auto wait = [](const std::function<bool()> &done) {
        QDeadlineTimer deadline(20000);
        while (!done() && !deadline.hasExpired())
            QTest::qWait(20);
        return done();
    };

    bool listed = false, ok = false;
    QList<print::Destination> found;
    system.destinations(&context, [&](const QList<print::Destination> &list, bool answered) {
        found = list;
        ok = answered;
        listed = true;
    });
    ASSERT_TRUE(wait([&] { return listed; }));
    EXPECT_TRUE(ok);
    const auto it = std::find_if(found.cbegin(), found.cend(), [&](const print::Destination &d) { return d.name == queue; });
    ASSERT_NE(it, found.cend()) << "the queue is listed";
    EXPECT_TRUE(it->isDefault);
    EXPECT_EQ(it->displayName, QStringLiteral("Office Printer"));
    EXPECT_EQ(it->location, QStringLiteral("Hall"));

    bool read = false;
    print::Capabilities caps;
    system.capabilities(queue, &context, [&](const print::Capabilities &c) {
        caps = c;
        read = true;
    });
    ASSERT_TRUE(wait([&] { return read; }));
    EXPECT_TRUE(caps.known);
    QStringList names;
    for (const print::Media &m : caps.media)
        names << m.name;
    EXPECT_TRUE(names.contains(QStringLiteral("iso_a4_210x297mm"))) << names.join(QLatin1Char(' ')).toStdString();
    EXPECT_TRUE(names.contains(QStringLiteral("na_letter_8.5x11in")));
    EXPECT_TRUE(names.contains(QStringLiteral("iso_a5_148x210mm")));
    EXPECT_EQ(caps.defaultMedia, QStringLiteral("iso_a4_210x297mm"));
    const print::Media a4 = print::findMedia(caps.media, QStringLiteral("iso_a4_210x297mm"));
    EXPECT_NEAR(a4.widthMm, 210, 0.5);
    EXPECT_NEAR(a4.heightMm, 297, 0.5);
    EXPECT_GT(a4.leftMm, 0) << "the PPD's printable area";
    EXPECT_FALSE(a4.displayName.isEmpty());
    EXPECT_TRUE(caps.twoSided);
    EXPECT_TRUE(caps.color);
    EXPECT_GT(caps.maxCopies, 1);
    // Step 6b: the queue's own options as CUPS reports them (its PPD's InputSlot, MediaType, cupsPrintQuality, OutputBin and
    // finishings), in the sheet's order, with their names (CUPS's, from the PPD; an enum CUPS does not name by its keyword) and
    // defaults (media-col-default's paper source and type, the others' -default).
    QStringList optionNames;
    for (const print::PrinterOption &o : caps.options)
        optionNames << o.name;
    EXPECT_EQ(optionNames, (QStringList{QStringLiteral("media-source"), QStringLiteral("media-type"), QStringLiteral("print-quality"),
                                        QStringLiteral("output-bin"), QStringLiteral("finishings")}));
    const auto values = [&caps](const QString &name) {
        QStringList out;
        if (const print::PrinterOption *o = caps.option(name)) {
            for (const print::OptionValue &v : o->values)
                out << v.value + QLatin1Char('=') + v.label;
        }
        return out;
    };
    EXPECT_EQ(values(QStringLiteral("media-source")),
              (QStringList{QStringLiteral("auto=Automatic"), QStringLiteral("tray-1=Tray 1"), QStringLiteral("manual=Manual Feed")}));
    EXPECT_EQ(values(QStringLiteral("media-type")), (QStringList{QStringLiteral("stationery=Plain Paper"), QStringLiteral("photo=Photo Paper")}));
    EXPECT_EQ(values(QStringLiteral("output-bin")), (QStringList{QStringLiteral("upper=Upper Bin"), QStringLiteral("lower=Lower Bin")}));
    EXPECT_EQ(values(QStringLiteral("finishings")), (QStringList{QStringLiteral("3=None"), QStringLiteral("20=Staple Top Left")}));
    ASSERT_NE(caps.option(QStringLiteral("finishings")), nullptr);
    EXPECT_EQ(caps.option(QStringLiteral("finishings"))->values.at(1).keyword, QStringLiteral("staple-top-left")) << "the sheet names it by its keyword";
    QStringList qualities;
    for (const QString &v : values(QStringLiteral("print-quality")))
        qualities << v.section(QLatin1Char('='), 0, 0);
    EXPECT_EQ(qualities, (QStringList{QStringLiteral("3"), QStringLiteral("4"), QStringLiteral("5")}));
    const auto defaultOf = [&caps](const QString &name) { return caps.option(name) ? caps.option(name)->defaultValue : QString(); };
    const auto queueDefaultOf = [&caps](const QString &name) { return caps.option(name) ? caps.option(name)->queueDefault : QString(); };
    // print_cups.sh sets the user's lpoptions print-quality=5 (GF_TEST_CUPS_LPOPTIONS): shown first, the queue's own 4 kept apart.
    const bool lpoptions = qEnvironmentVariable("GF_TEST_CUPS_LPOPTIONS") == QLatin1String("print-quality=5");
    EXPECT_EQ(defaultOf(QStringLiteral("media-source")), QStringLiteral("auto"));
    EXPECT_EQ(defaultOf(QStringLiteral("media-type")), QStringLiteral("stationery"));
    EXPECT_EQ(defaultOf(QStringLiteral("print-quality")), lpoptions ? QStringLiteral("5") : QStringLiteral("4"));
    EXPECT_EQ(queueDefaultOf(QStringLiteral("print-quality")), QStringLiteral("4"));
    EXPECT_EQ(queueDefaultOf(QStringLiteral("media-source")), QStringLiteral("auto"));
    EXPECT_EQ(defaultOf(QStringLiteral("output-bin")), QStringLiteral("upper"));
    EXPECT_EQ(defaultOf(QStringLiteral("finishings")), QStringLiteral("3"));
    // The sheet's first state sends the user's own quality and nothing the queue does by itself (counter-review, MINOR 1).
    const print::Choices firstState = print::initialChoices(queue, caps, {}, {}, false, false);
    const PrintSystem::Options firstOptions = print::cupsOptions(firstState, caps);
    if (lpoptions) {
        EXPECT_TRUE(firstOptions.contains({QStringLiteral("print-quality"), QStringLiteral("5")}));
    }
    for (const auto &o : firstOptions) {
        if (o.first != QLatin1String("print-quality")) {
            EXPECT_TRUE(print::optionSection(o.first).isEmpty()) << o.first.toStdString() << " is the queue's own default";
        }
    }

    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile document(dir.filePath(QStringLiteral("doc.pdf")));
    ASSERT_TRUE(document.open(QIODevice::WriteOnly));
    document.write("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n");
    document.close();
    const int fd = ::open(QFile::encodeName(document.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(fd, 0);
    bool sent = false;
    QString error = QStringLiteral("not answered");
    const PrintSystem::Options options{{QStringLiteral("copies"), QStringLiteral("2")},
                                       {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-collated-copies")},
                                       {QStringLiteral("media"), QStringLiteral("iso_a5_148x210mm")},
                                       {QStringLiteral("sides"), QStringLiteral("two-sided-long-edge")},
                                       {QStringLiteral("print-color-mode"), QStringLiteral("monochrome")},
                                       {QStringLiteral("media-source"), QStringLiteral("tray-1")},
                                       {QStringLiteral("media-type"), QStringLiteral("photo")},
                                       {QStringLiteral("print-quality"), QStringLiteral("5")},
                                       {QStringLiteral("output-bin"), QStringLiteral("lower")},
                                       {QStringLiteral("finishings"), QStringLiteral("20")}};
    system.submit(queue, QStringLiteral("Grassfield test page"), options, fd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_TRUE(error.isEmpty()) << error.toStdString();

    // The job as the scheduler keeps it (its newest on the queue): the name and the options sent.
    cups_job_t *jobs = nullptr;
    const int count = cupsGetJobs2(CUPS_HTTP_DEFAULT, &jobs, queue.toUtf8().constData(), 0, CUPS_WHICHJOBS_ALL);
    ASSERT_GT(count, 0);
    int newest = 0;
    QString title;
    for (int i = 0; i < count; ++i) {
        if (jobs[i].id > newest) {
            newest = jobs[i].id;
            title = QString::fromUtf8(jobs[i].title);
        }
    }
    cupsFreeJobs(count, jobs);
    EXPECT_EQ(title, QStringLiteral("Grassfield test page"));
    char uri[1024];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof uri, "ipp", nullptr, "localhost", 0, "/printers/%s", queue.toUtf8().constData());
    ipp_t *request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nullptr, uri);
    ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", newest);
    ipp_t *response = cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/");
    ASSERT_NE(response, nullptr) << cupsLastErrorString();
    const auto keyword = [response](const char *name) {
        ipp_attribute_t *a = ippFindAttribute(response, name, IPP_TAG_ZERO);
        return a ? QString::fromUtf8(ippGetString(a, 0, nullptr)) : QString();
    };
    ipp_attribute_t *copies = ippFindAttribute(response, "copies", IPP_TAG_INTEGER);
    EXPECT_EQ(copies ? ippGetInteger(copies, 0) : 0, 2);
    EXPECT_EQ(keyword("sides"), QStringLiteral("two-sided-long-edge"));
    EXPECT_EQ(keyword("print-color-mode"), QStringLiteral("monochrome"));
    EXPECT_EQ(keyword("media"), QStringLiteral("iso_a5_148x210mm"));
    // Step 6b: the printer's own options, kept on the job as they were sent.
    EXPECT_EQ(keyword("media-source"), QStringLiteral("tray-1"));
    EXPECT_EQ(keyword("media-type"), QStringLiteral("photo"));
    EXPECT_EQ(keyword("output-bin"), QStringLiteral("lower"));
    ipp_attribute_t *quality = ippFindAttribute(response, "print-quality", IPP_TAG_ENUM);
    EXPECT_EQ(quality ? ippGetInteger(quality, 0) : 0, 5);
    ipp_attribute_t *finishings = ippFindAttribute(response, "finishings", IPP_TAG_ENUM);
    EXPECT_EQ(finishings ? ippGetInteger(finishings, 0) : 0, 20);
    ippDelete(response);

    // Only a PDF or PostScript is sent: a printer language (PJL here) is refused before any job is made.
    QFile raw(dir.filePath(QStringLiteral("raw.prn")));
    ASSERT_TRUE(raw.open(QIODevice::WriteOnly));
    raw.write("\x1b%-12345X@PJL ENTER LANGUAGE=PCL\n");
    raw.close();
    const int rawFd = ::open(QFile::encodeName(raw.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(rawFd, 0);
    sent = false;
    system.submit(queue, QStringLiteral("raw"), {}, rawFd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_EQ(error, QStringLiteral("the document is not a PDF"));
    const auto jobCount = [&queue] {
        cups_job_t *list = nullptr;
        const int n = cupsGetJobs2(CUPS_HTTP_DEFAULT, &list, queue.toUtf8().constData(), 0, CUPS_WHICHJOBS_ALL);
        cupsFreeJobs(n, list);
        return n;
    };
    EXPECT_EQ(jobCount(), count) << "no job made";
    // PostScript neither (it can program a PostScript printer; GTK always sends a PDF here).
    ASSERT_TRUE(raw.open(QIODevice::WriteOnly | QIODevice::Truncate));
    raw.write("%!PS-Adobe-3.0\nserverdict begin 0 exitserver\n");
    raw.close();
    const int psFd = ::open(QFile::encodeName(raw.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(psFd, 0);
    sent = false;
    system.submit(queue, QStringLiteral("ps"), {}, psFd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_EQ(error, QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(jobCount(), count) << "no job made";

    // A document over the limit: refused before any job when its first read is already over it, else its job cancelled.
    // (40 bytes: over within the first read; 70000: over only past it, the first read being 64 KiB.)
    for (const auto &[size, limit] : {std::pair<qsizetype, qint64>(60, 40), std::pair<qsizetype, qint64>(200000, 70000)}) {
        CupsPrintSystem::Limits small;
        small.maxDocumentBytes = limit;
        CupsPrintSystem limited(small, nullptr);
        QFile over(dir.filePath(QStringLiteral("over.pdf")));
        ASSERT_TRUE(over.open(QIODevice::WriteOnly | QIODevice::Truncate));
        over.write("%PDF-1.4\n");
        over.write(QByteArray(size, ' '));
        over.close();
        const int overFd = ::open(QFile::encodeName(over.fileName()).constData(), O_RDONLY | O_CLOEXEC);
        ASSERT_GE(overFd, 0);
        const int before = jobCount();
        sent = false;
        limited.submit(queue, QStringLiteral("over"), {}, overFd, &context, [&](const QString &why) {
            error = why;
            sent = true;
        });
        ASSERT_TRUE(wait([&] { return sent; }));
        EXPECT_EQ(error, QStringLiteral("the document is too large")) << size;
        if (size < 65536) {
            EXPECT_EQ(jobCount(), before) << "no job made";
        }
    }

    // A printer CUPS does not know: refused, the document closed.
    const int other = ::open(QFile::encodeName(document.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    sent = false;
    system.submit(QStringLiteral("NoSuchPrinter"), QStringLiteral("x"), {}, other, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_FALSE(error.isEmpty());
    EXPECT_EQ(::fcntl(other, F_GETFD), -1) << "the document's descriptor was closed";
    bool none = false;
    print::Capabilities unknown;
    system.capabilities(QStringLiteral("NoSuchPrinter"), &context, [&](const print::Capabilities &c) {
        unknown = c;
        none = true;
    });
    ASSERT_TRUE(wait([&] { return none; }));
    EXPECT_FALSE(unknown.known);
}

#include "tst_print.moc"
