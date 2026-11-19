// org.freedesktop.impl.portal.Print for the Grassfield session (ADR-0035 D-7, steps 6a and 6b; docs/specs/system-dialogs.md
// section 7, PR1-PR5): an application's Print… becomes Grassfield's print sheet (apps/files/qml/PrintSheet.qml) on its window.
//
// GTK's flow (gtk/print/gtkprintoperation-portal.c): PreparePrint shows the sheet and answers GTK's settings, page setup and a
// token; GTK renders the document with them and sends it to Print with the token, which prints it with no sheet: the job goes
// to the CUPS printer chosen (PrintSystem), Save as PDF writes it to the file chosen in the Save panel, Open in Preview to a
// private copy that Preview opens. A token is good once, for the application that got it, for five minutes (x-d-p-gtk's rule,
// src/print.c); one this backend did not give (x-d-p-gtk's, after a PreparePrint it served) goes to x-d-p-gtk.
//
// A Print with no token (an application that sends the document first: libportal's callers) shows the same sheet with the
// document's preview on the left (step 6b): the document is read into a private file (printpreview.h), its pages drawn by a
// confined child, and the sheet's answer prints that file at once, or saves it, or opens it in Preview. A document that is not
// a PDF goes to x-d-p-gtk as it came, as before step 6b (only a PDF reaches a printer through Grassfield, decision 6-4).
//
// The Presets (Default Settings, Last Used Settings) and the printer's own options (Media & Quality, Printer Options) are the
// sheet's in both flows; Last Used Settings is kept in grassfield-portal's state (Options::stateFile).
//
// The request lifecycle is RequestHost's (a Request object at the frontend's handle, Close, the 3-s forward to x-d-p-gtk when
// the sheet cannot show, the idle quit).
#pragma once

#include "printlogic.h"
#include "printpreview.h"
#include "requesthost.h"

#include <QDBusAbstractAdaptor>
#include <QDBusUnixFileDescriptor>
#include <QElapsedTimer>
#include <QHash>
#include <QVariantMap>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <tuple>

namespace grassfield::portal {

class PrintSystem;

class Print : public RequestHost
{
    Q_OBJECT

public:
    struct Options {
        // The backend x-d-p-gtk serves Print under (the forward of FC7, and Print without a token of ours).
        QString gtkService = QStringLiteral("org.freedesktop.impl.portal.desktop.gtk");
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        int maxPending = 16;
        int tokenLifetimeMs = 300000;
        // Save as PDF: a document that stops coming for this long is not written.
        int fileIdleMs = 30000;
        // How Settings > Printers opens (Add Printer…): the program and its arguments.
        QStringList addPrinterCommand{QStringLiteral("grassfield-settings"), QStringLiteral("--section=printers")};
        // Last Used Settings (a JSON file of grassfield-portal's state); "": none kept.
        QString stateFile;
        // Where a document sent first is kept while its sheet is up (an unlinked file, on disk: grassfield-portal sets the user's
        // cache folder); "": the temporary folder.
        QString spoolFolder;
        // What the documents kept at once may take together, across requests (ADR-0035 6-21).
        qint64 spoolBudget = print::kMaxDocumentBytes;
        // The private folder Open in Preview's copies go to (made 0700, this user's; grassfield-portal sets one in the user's cache
        // folder); "": no Open in Preview.
        QString previewFolder;
        // How Preview opens a copy: the program and its arguments, the copy's path added last; empty: in the session, as the Dock
        // starts an application, from a unit of the user manager (systemd-run --user, then uwsm-app where it is, then
        // grassfield-preview); in a dev session, grassfield-preview as a child of this process.
        QStringList previewCommand;
        // The child that draws a page (printpreview.h): this binary and "--print-preview" when empty; its deadline.
        QStringList rendererCommand;
        int renderDeadlineMs = 8000;
    };

    Print(const QDBusConnection &bus, PrintSystem *system, const Options &options, QObject *parent = nullptr);
    // Waits a short while for the Save as PDF writes still running (a file the frontend handed is read to its end at once).
    ~Print() override;

    // The connection Save as PDF calls this process's FileChooser on: a second one to the same bus (QtDBus answers a call on
    // the connection the service is on in place, without the delayed reply the panel needs). None: no Save as PDF.
    void setPanelBus(const QDBusConnection &bus) { m_panelBus = std::make_unique<QDBusConnection>(bus); }

    // The D-Bus methods (PrintAdaptor). handle*: a delayed reply, sent when the request ends.
    void handlePrepare(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                       const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options, const QDBusMessage &message);
    void handlePrint(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                     const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message);

    // For the sheet. The printers, again (printersListed answers).
    Q_INVOKABLE void listPrinters(int id);
    // What `printer` supports, and the sheet's choices carried over to it (`choices`: the sheet's current ones, toQml's form):
    // printerChosen answers.
    Q_INVOKABLE void choosePrinter(int id, const QString &printer, const QVariantMap &choices);
    // Whether `ranges` (as typed, 1-based) are pages the sheet can print, and their tidy form ("" when not).
    Q_INVOKABLE QString tidyRanges(const QString &ranges) const;
    // The sheet's answer: response 0 with its choices (to print; Save as PDF when outputUri is set; Open in Preview when preview
    // is true), or 1 (Cancel). False (and the sheet stays) when the choices cannot be printed; an answer for a request that is
    // gone is ignored (true). For a document sent first, the job goes now (the sheet goes at once: dismissed).
    Q_INVOKABLE bool answer(int id, int response, const QVariantMap &choices = {});
    // The Presets pop-up: "default" or "last", applied to `choices` (the sheet's current ones); printerChosen answers with them.
    Q_INVOKABLE void choosePreset(int id, const QString &preset, const QVariantMap &choices);
    // The preview of a document sent first: page `page` (0-based) drawn within width x height pixels; pageRendered answers (the
    // latest asked wins while one is drawn).
    Q_INVOKABLE void renderPage(int id, int page, int width, int height);
    // Add Printer…: Settings > Printers.
    Q_INVOKABLE void addPrinter();
    // Not quiet while a token waits for its Print (GTK may take a while to render the document): the process quitting would
    // lose it, and the Print would end in x-d-p-gtk's dialog (review of step 6a, MINOR 2).
    qint64 quietFor() const override;
    // Save as PDF…: grassfield-portal's own Save panel (FileChooser's SaveFile, called on this process's bus connection, so it
    // is the panel of D-4 with the application's remembered folder), over the application's window, suggesting `name`
    // (".pdf" added) under `title`; pdfChosen or pdfCancelled answers. The sheet then answers with outputUri, or comes back.
    Q_INVOKABLE void savePdf(int id, const QString &name, const QString &title);

    // What the sheet is given first (pure; the tests read it): {appId, title (one line), modal, parented, acceptLabel,
    // hasCurrentPage, hasSelection, canSavePdf (the application can make a PDF), outputBasename (the name the application
    // gives a file it prints to, a plain name or ""), choices (print::toQml, the printer not known yet), document (false: the
    // sheet of PreparePrint), hasLastUsed (false here; handlePrepare sets it)}.
    static QVariantMap toQml(const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &settings,
                             const QVariantMap &pageSetup, const QVariantMap &options);
    // How Preview opens a copy in the session (pure; the tests read it): systemd-run --user (with --expand-environment=no when
    // `keepsArguments`), then uwsm-app when there is one, then grassfield-preview; the copy's path is added last.
    static QStringList sessionPreviewCommand(bool uwsmApp, bool keepsArguments);
    // Open in Preview's old copies in `base` (folders print-*): those older than a day, and all but the newest kKeptCopies - 1
    // (room for the next), go with what they hold, never through a link. Blocking.
    static void removeOldCopies(const QString &base, qint64 nowSecondsSinceEpoch);
    static constexpr int kKeptCopies = 16;
    static constexpr qint64 kCopyLifetimeSeconds = 24 * 3600;

signals:
    // A sheet to make for request `id` (toQml).
    void opened(int id, const QVariantMap &sheet);
    // The printers for request `id`'s sheet ([print::toQml(Destination)], the default first), and the one to show first
    // ("" when none); `ok` false when CUPS did not answer.
    void printersListed(int id, const QVariantList &printers, const QString &current, bool ok);
    // What `printer` supports (print::toQml(Capabilities)) and the sheet's choices for it.
    void printerChosen(int id, const QString &printer, const QVariantMap &capabilities, const QVariantMap &choices);
    // Save as PDF's answer: the file chosen (a local file:// URI), or none.
    void pdfChosen(int id, const QString &uri);
    void pdfCancelled(int id);
    // A document sent first is kept: the sheet may print, save or open it (its preview comes apart: documentReady).
    void documentRead(int id);
    // Its pages are counted (0 when they cannot be drawn: no preview, the document still prints).
    void documentReady(int id, int pages);
    // The paper of its first page, as the printer lists it, found after the printer's options were read: the sheet takes it
    // unless the user chose a paper (print::toQml(Media)).
    void documentPaper(int id, const QVariantMap &media);
    // A page of its preview: an image://printpreview/ URL, "" when it could not be drawn.
    void pageRendered(int id, int page, const QString &source);
    // The sheet of request `id` goes now (a document's job is being sent; the request ends when it is).
    void dismissed(int id);

protected:
    QVariantMap relayed(const QVariantMap &gtkResults) const override;
    void ended(int id) override;
    void forwarded(int id) override;
    bool forwardable(int id) override;

private:
    // The private file of a document sent first, closed when the last of its users (the request, a page being drawn) lets go.
    struct SpoolFile {
        int fd = -1;
        // What it took of the budget, given back once: when its request ends (a document no longer waits, even while a child
        // that was drawing it is being stopped), else when it goes.
        std::shared_ptr<SpoolBudget> budget;
        qint64 reserved = 0;
        std::atomic<bool> givenBack{false};
        void giveBack();
        ~SpoolFile();
    };
    // Where a document sent first stands (Pending::source): untouched, a pipe being read (then it cannot go on to x-d-p-gtk), or
    // gone to x-d-p-gtk (then it is not read).
    static constexpr int kSourceUntouched = 0;
    static constexpr int kSourceRead = 1;
    static constexpr int kSourceForwarded = 2;
    struct Pending {
        QString appId;
        QString parentWindow;
        QString title;
        QVariantMap settings;
        QVariantMap pageSetup;
        bool hasCurrentPage = false;
        bool hasSelection = false;
        bool canSavePdf = false;
        QString printer;
        // The printer's options are being read: no answer prints on it meanwhile (review of step 6a, MINOR 4).
        bool reading = false;
        print::Capabilities capabilities;
        print::Choices choices;
        // The file the Save panel last answered: its URI as given, its folder with the links resolved then, its name. Save as
        // PDF writes only there (integrator security review of step 6a, NIT).
        QString pdfUri;
        QString pdfFolder;
        QString pdfName;
        // The Save panel last opened (its handle): only its answer is the sheet's.
        QString saveHandle;
        // A document sent first (Print with no token): its private file once read, its pages; what reads or draws it stops when
        // the request ends (stop).
        bool document = false;
        std::shared_ptr<SpoolFile> spool;
        int pages = 0;
        std::shared_ptr<std::atomic<bool>> stop = std::make_shared<std::atomic<bool>>(false);
        std::shared_ptr<std::atomic<int>> source = std::make_shared<std::atomic<int>>(kSourceUntouched);
        // A page being drawn, and the latest asked meanwhile (page, width, height); the pages drawn (PreviewImages' keys).
        bool rendering = false;
        std::optional<std::tuple<int, int, int>> wanted;
        QStringList images;
        // The preset is applied when the printer's options are read (the sheet's first printer, or a preset chosen meanwhile).
        bool applyPresetOnRead = false;
        // A document's own paper was chosen or suggested once (6-13, 6-28).
        bool documentPaperApplied = false;
    };
    struct Ticket {
        QString appId;
        QString printer;
        print::Capabilities capabilities;
        print::Choices choices;
        // Save as PDF's file (Pending's), empty to print.
        QString pdfFolder;
        QString pdfName;
        // A document sent first (its page ranges go to the printer: print::documentOptions).
        bool document = false;
        // The name the document is known by (the application's file name, else its name): Open in Preview's copy.
        QString documentName;
        QElapsedTimer age;
    };
    // A new token for `ticket`: random, not 0, not one in use.
    uint issue(const Ticket &ticket);
    // Drops the expired tokens; true when it dropped one.
    bool dropExpired();
    void printWithTicket(int id, const Ticket &ticket, const QString &title, int fd);
    // Open in Preview: `fd` (taken) written to a private copy, which Preview opens; the request ends with 0, or 2 when it could not.
    void openInPreview(int id, const Ticket &ticket, int fd);
    // Print with no token: the sheet over the document `fd` (taken), read into a private file meanwhile.
    void showDocument(int id, const QString &appId, const QString &parentWindow, const QString &title, int fd);
    // A kept document's page count and first page's size, from the child that draws it (off this thread).
    void inspectDocument(int id, const std::function<bool()> &stopped);
    void startRender(int id, int page, int width, int height);
    // The choices with the preset they name applied (Default Settings: the application's and the printer's; Last Used Settings:
    // those, then the last print's), what belongs to the document kept as chosen.
    print::Choices presetChoices(const Pending &pending, const print::Choices &current);
    // Last Used Settings: read once from Options::stateFile, kept there at each print.
    std::optional<print::Preset> lastUsed();
    void rememberLastUsed(const print::Choices &choices);

    PrintSystem *m_system;
    Options m_options;
    QHash<int, Pending> m_pending;
    QHash<uint, Ticket> m_tickets;
    // The Save panel each sheet opened (its handle), closed if the sheet's request ends first.
    QHash<int, QString> m_saving;
    // Set when Print goes: the writes still running stop and remove their temporary files.
    std::shared_ptr<std::atomic<bool>> m_stopWriting = std::make_shared<std::atomic<bool>>(false);
    // SP-16: the job of a request that prints with a ticket (Save as PDF's write, Open in Preview's copy, the CUPS job) stops when
    // its request ends without it (Close, the frontend gone): a flag for the writers, and the print system's stop for a job.
    struct JobStop {
        std::shared_ptr<std::atomic<bool>> flag = std::make_shared<std::atomic<bool>>(false);
        std::function<void()> cups;
    };
    QHash<int, JobStop> m_jobs;
    int m_saves = 0;
    std::unique_ptr<QDBusConnection> m_panelBus;
    std::shared_ptr<SpoolBudget> m_budget;
    bool m_lastUsedRead = false;
    std::optional<print::Preset> m_lastUsed;
};

// The interface on /org/freedesktop/portal/desktop (the object FileChooser is exported as; this adaptor is its child and
// calls into Print).
class PrintAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Print")

public:
    PrintAdaptor(QObject *exported, Print *print);

public Q_SLOTS:
    uint PreparePrint(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                      const QVariantMap &settings, const QVariantMap &page_setup, const QVariantMap &options, const QDBusMessage &message,
                      QVariantMap &results);
    uint Print(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
               const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message, QVariantMap &results);

private:
    grassfield::portal::Print *m_print;
};

} // namespace grassfield::portal
