#include "print.h"

#include "chooserlogic.h"
#include "printpreview.h"
#include "printsystem.h"
#include "runmode.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QCoreApplication>
#include <QDateTime>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QProcess>
#include <QRandomGenerator>
#include <QSaveFile>
#include <QStandardPaths>
#include <QThread>
#include <QTimer>

#include <KIO/CommandLauncherJob>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>

#include <algorithm>
#include <limits>
#include <memory>

namespace grassfield::portal {

namespace {

constexpr int kMaxTickets = 64;

// A vardict as the frontend passes it, or as x-d-p-gtk answers it: a nested a{sv} is a QDBusArgument until read.
QVariantMap mapOf(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusArgument>())
        return qdbus_cast<QVariantMap>(value.value<QDBusArgument>());
    if (value.metaType() == QMetaType::fromType<QVariantMap>())
        return value.toMap();
    return {};
}

// GTK's settings are strings; its page setup strings and doubles: anything else is dropped on the way.
QVariantMap typed(const QVariantMap &map, bool doubles)
{
    QVariantMap out;
    for (auto it = map.cbegin(); it != map.cend() && out.size() < 128; ++it) {
        const QMetaType t = it.value().metaType();
        if (t == QMetaType::fromType<QString>() && it.key().size() <= 64)
            out.insert(it.key(), it.value().toString().left(4096));
        else if (doubles && t == QMetaType::fromType<double>() && it.key().size() <= 64)
            out.insert(it.key(), it.value().toDouble());
    }
    return out;
}

// A file name as given (one line, no folder), or "".
QString plainName(const QVariant &value)
{
    if (value.metaType() != QMetaType::fromType<QString>())
        return {};
    const QString name = chooser::oneLine(value.toString()).left(200);
    return name.contains(QLatin1Char('/')) || name == QLatin1String(".") || name == QLatin1String("..") ? QString() : name;
}

// A new private folder for one copy, in `base` (made 0700 when missing; refused when it is not a folder of this user's that
// no one else may enter): its path with the links resolved, "" and `error` set on failure.
QString privateFolder(const QString &base, QString *error)
{
    const QByteArray b = QFile::encodeName(base);
    if (b.isEmpty() || !b.startsWith('/')) {
        *error = QStringLiteral("no private folder for Open in Preview");
        return {};
    }
    QDir().mkpath(QFileInfo(base).absolutePath());
    if (::mkdir(b.constData(), 0700) != 0 && errno != EEXIST) {
        *error = QStringLiteral("cannot make “%1”: %2").arg(base, QString::fromLocal8Bit(std::strerror(errno)));
        return {};
    }
    struct stat st;
    if (::lstat(b.constData(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 077) != 0) {
        *error = QStringLiteral("“%1” is not a private folder").arg(base);
        return {};
    }
    QByteArray made = b + "/print-XXXXXX";
    if (!::mkdtemp(made.data())) {
        *error = QStringLiteral("cannot make a folder in “%1”: %2").arg(base, QString::fromLocal8Bit(std::strerror(errno)));
        return {};
    }
    const QString folder = QFileInfo(QFile::decodeName(made)).canonicalFilePath();
    if (folder.isEmpty())
        *error = QStringLiteral("cannot resolve “%1”").arg(QFile::decodeName(made));
    return folder;
}

// Removes the folder `name` in `base` (an open folder) and the copy it holds, never through a link: its entries removed where
// they are (a link is removed, not followed), then the folder.
void removeCopyFolder(int base, const char *name)
{
    const int folder = ::openat(base, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (folder < 0)
        return;
    if (DIR *entries = ::fdopendir(folder)) {
        while (const dirent *e = ::readdir(entries)) {
            if (std::strcmp(e->d_name, ".") != 0 && std::strcmp(e->d_name, "..") != 0)
                ::unlinkat(::dirfd(entries), e->d_name, 0);
        }
        ::closedir(entries);
    } else {
        ::close(folder);
    }
    ::unlinkat(base, name, AT_REMOVEDIR);
}

} // namespace

void Print::removeOldCopies(const QString &base, qint64 now)
{
    // Open in Preview's copies (ADR-0035 6-22): a folder print-XXXXXX of this user's each; the ones older than a day, and all but
    // the newest kKeptCopies - 1 (room for the one about to be made), go (Preview keeps a copy it has open readable: its file
    // stays until it lets go).
    const int folder = ::open(QFile::encodeName(base).constData(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (folder < 0)
        return;
    DIR *entries = ::fdopendir(folder);
    if (!entries) {
        ::close(folder);
        return;
    }
    QList<QPair<qint64, QByteArray>> copies;
    while (const dirent *e = ::readdir(entries)) {
        struct stat st;
        if (std::strncmp(e->d_name, "print-", 6) != 0 || ::fstatat(::dirfd(entries), e->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0
            || !S_ISDIR(st.st_mode) || st.st_uid != ::getuid())
            continue;
        copies.append({qint64(st.st_mtime), QByteArray(e->d_name)});
    }
    std::sort(copies.begin(), copies.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    for (qsizetype i = 0; i < copies.size(); ++i) {
        if (i >= kKeptCopies - 1 || now - copies.at(i).first > kCopyLifetimeSeconds)
            removeCopyFolder(::dirfd(entries), copies.at(i).second.constData());
    }
    ::closedir(entries);
}

QStringList Print::sessionPreviewCommand(bool uwsmApp, bool keepsArguments)
{
    QStringList command{QStringLiteral("systemd-run"), QStringLiteral("--user"), QStringLiteral("--collect"), QStringLiteral("--quiet")};
    // systemd-run expands ${NAME} in a command's arguments, and the copy's name is the document's (security review of step 6b,
    // MINOR 4): not where systemd knows how to say so (254 and later).
    if (keepsArguments)
        command << QStringLiteral("--expand-environment=no");
    command << QStringLiteral("--");
    if (uwsmApp)
        command << QStringLiteral("uwsm-app") << QStringLiteral("--");
    return command << QStringLiteral("grassfield-preview") << QStringLiteral("--");
}

namespace {

// Whether this systemd-run takes --expand-environment=no (asked once; blocking: off the GUI thread).
bool systemdRunKeepsArguments()
{
    static const bool keeps = [] {
        QProcess help;
        help.start(QStringLiteral("systemd-run"), {QStringLiteral("--help")});
        return help.waitForFinished(3000) && help.readAllStandardOutput().contains("--expand-environment");
    }();
    return keeps;
}

// How Preview opens a copy when nothing else is set (Options::previewCommand empty), the copy's path added last; whether its
// arguments reach Preview as they are (`keepsArguments`). In the session: as the Dock starts an application (uwsm-app: a scope
// of its own), from a transient unit of the user manager (systemd-run --user), so that Preview inherits neither this unit's
// limits nor its sandbox and outlives it (grassfield-crash-watch's Reopen does the same). In a dev session: a child of this
// process, on its display (the user manager's display is the owner's own session, which a dev run never touches: runmode.h),
// the grassfield-preview next to this binary first. Blocking (it may ask systemd-run once): off the GUI thread.
QStringList defaultPreviewCommand(bool *keepsArguments)
{
    if (grassfield::apps::runmode::session()) {
        *keepsArguments = systemdRunKeepsArguments();
        return Print::sessionPreviewCommand(!QStandardPaths::findExecutable(QStringLiteral("uwsm-app")).isEmpty(), *keepsArguments);
    }
    *keepsArguments = true;
    const QString sibling = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-preview");
    return {QFileInfo(sibling).isExecutable() ? sibling : QStringLiteral("grassfield-preview"), QStringLiteral("--")};
}

constexpr qint64 kMaxStateBytes = 64 * 1024;
// Pages drawn kept for each sheet (the one shown and the ones around it).
constexpr int kKeptPages = 4;

} // namespace

void Print::SpoolFile::giveBack()
{
    if (budget && !givenBack.exchange(true))
        budget->give(reserved);
}

Print::SpoolFile::~SpoolFile()
{
    if (fd >= 0)
        ::close(fd);
    giveBack();
}

Print::Print(const QDBusConnection &bus, PrintSystem *system, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.Print"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending, false}, parent)
    , m_system(system)
    , m_options(options)
    , m_budget(std::make_shared<SpoolBudget>(options.spoolBudget))
{
    // Open in Preview's old copies go when the portal starts too, not only at the next copy (counter-review of step 6b, NIT).
    if (!m_options.previewFolder.isEmpty()) {
        const QString base = m_options.previewFolder;
        QThread *pruner = QThread::create([base] { removeOldCopies(base, QDateTime::currentSecsSinceEpoch()); });
        pruner->setParent(this);
        connect(pruner, &QThread::finished, pruner, &QObject::deleteLater);
        pruner->start();
    }
}

Print::~Print()
{
    // Save as PDF's writers (told to stop) and folder lookups, all within one deadline.
    m_stopWriting->store(true);
    const QDeadlineTimer deadline(3500);
    for (QThread *writer : findChildren<QThread *>(Qt::FindDirectChildrenOnly)) {
        if (!writer->wait(deadline))
            writer->setParent(nullptr); // never destroyed while it runs
    }
    // The writes that ended meanwhile answer their requests (their queued answers), before RequestHost ends the rest.
    QCoreApplication::sendPostedEvents(this, QEvent::MetaCall);
}

qint64 Print::quietFor() const
{
    for (const Ticket &t : m_tickets)
        if (t.age.elapsed() <= m_options.tokenLifetimeMs)
            return 0;
    return RequestHost::quietFor();
}

QVariantMap Print::toQml(const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &settings,
                         const QVariantMap &pageSetup, const QVariantMap &options)
{
    const QVariantMap o = print::prepareOptions(options);
    const bool current = o.value(QStringLiteral("hasCurrentPage")).toBool();
    const bool selection = o.value(QStringLiteral("hasSelection")).toBool();
    const print::Choices choices = print::initialChoices({}, {}, typed(settings, false), typed(pageSetup, true), current, selection);
    return {
        {QStringLiteral("appId"), appId},
        {QStringLiteral("title"), chooser::oneLine(title)},
        {QStringLiteral("modal"), o.value(QStringLiteral("modal"))},
        {QStringLiteral("parented"), !parentWindow.isEmpty()},
        {QStringLiteral("acceptLabel"), o.value(QStringLiteral("acceptLabel"))},
        {QStringLiteral("hasCurrentPage"), current},
        {QStringLiteral("hasSelection"), selection},
        {QStringLiteral("canSavePdf"), o.value(QStringLiteral("formats")).toStringList().contains(QStringLiteral("pdf"))},
        {QStringLiteral("outputBasename"), plainName(settings.value(QStringLiteral("output-basename")))},
        {QStringLiteral("choices"), print::toQml(choices)},
        {QStringLiteral("document"), false},
        {QStringLiteral("hasLastUsed"), false},
    };
}

void Print::handlePrepare(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                          const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    QVariantMap sheet = toQml(appId, parentWindow, title, settings, pageSetup, options);
    Pending p;
    p.appId = appId;
    p.parentWindow = parentWindow;
    p.title = sheet.value(QStringLiteral("title")).toString();
    p.settings = typed(settings, false);
    p.pageSetup = typed(pageSetup, true);
    p.hasCurrentPage = sheet.value(QStringLiteral("hasCurrentPage")).toBool();
    p.hasSelection = sheet.value(QStringLiteral("hasSelection")).toBool();
    p.canSavePdf = sheet.value(QStringLiteral("canSavePdf")).toBool();
    p.choices = print::fromQml(sheet.value(QStringLiteral("choices")).toMap(), print::Choices{});
    // Last Used Settings when there are some (macOS opens its panel on them), applied once the printer's options are read.
    const bool last = lastUsed().has_value();
    p.choices.preset = last ? QStringLiteral("last") : QStringLiteral("default");
    p.applyPresetOnRead = last;
    sheet.insert(QStringLiteral("hasLastUsed"), last);
    sheet.insert(QStringLiteral("choices"), print::toQml(p.choices));
    m_pending.insert(id, p);
    if (!startUi(id))
        return;
    emit opened(id, sheet);
    listPrinters(id);
}

void Print::listPrinters(int id)
{
    if (!m_pending.contains(id) || !isOpen(id) || !m_system)
        return;
    m_system->destinations(this, [this, id](const QList<print::Destination> &found, bool ok) {
        const auto it = m_pending.find(id);
        if (it == m_pending.end() || !isOpen(id))
            return;
        QList<print::Destination> list = found;
        // The default first, then by name.
        std::stable_sort(list.begin(), list.end(), [](const print::Destination &a, const print::Destination &b) {
            if (a.isDefault != b.isDefault)
                return a.isDefault;
            return a.displayName.localeAwareCompare(b.displayName) < 0;
        });
        QVariantList printers;
        QString current;
        const QString asked = it->settings.value(QStringLiteral("printer")).toString();
        for (const print::Destination &d : std::as_const(list)) {
            printers.append(print::toQml(d));
            // The one the application last printed with (its settings' "printer"), else the default, else the first.
            if (d.name == asked)
                current = d.name;
        }
        if (current.isEmpty() && !list.isEmpty())
            current = list.first().name;
        if (!it->printer.isEmpty() && std::any_of(list.cbegin(), list.cend(), [&](const print::Destination &d) { return d.name == it->printer; }))
            current = it->printer;
        emit printersListed(id, printers, current, ok);
        if (!current.isEmpty() && (current != it->printer || !it->capabilities.known))
            choosePrinter(id, current, print::toQml(it->choices));
    });
}

void Print::choosePrinter(int id, const QString &printer, const QVariantMap &choices)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id) || !m_system)
        return;
    it->choices = print::fromQml(choices, it->choices);
    it->printer = printer;
    it->capabilities = {};
    it->reading = true;
    m_system->capabilities(printer, this, [this, id, printer](const print::Capabilities &caps) {
        const auto p = m_pending.find(id);
        // Another printer chosen meanwhile: its own answer comes.
        if (p == m_pending.end() || !isOpen(id) || p->printer != printer)
            return;
        p->capabilities = caps;
        p->reading = false;
        // The choices made so far, as the new printer takes them (its paper, two sides and colour where it has them).
        print::Choices current = p->choices;
        current.printer = printer;
        current.outputUri.clear();
        // Pages being typed may not read yet: they are carried as typed, apart from the rest.
        print::Choices rest = current;
        if (rest.pages == QLatin1String("ranges"))
            rest.pages = QStringLiteral("all");
        QVariantMap settings, pageSetup;
        print::Choices carried = print::toGtk(rest, &settings, &pageSetup)
            ? print::initialChoices(printer, caps, settings, pageSetup, p->hasCurrentPage, p->hasSelection)
            : print::initialChoices(printer, caps, p->settings, p->pageSetup, p->hasCurrentPage, p->hasSelection);
        if (current.pages == QLatin1String("ranges")) {
            carried.pages = current.pages;
            carried.ranges = current.ranges;
        }
        // The copies are the job's, not GTK's (GTK gets one): carried as chosen, within the printer's limit.
        carried.copies = std::clamp(current.copies, 1, std::clamp(caps.known ? caps.maxCopies : print::kMaxCopies, 1, print::kMaxCopies));
        carried.collate = current.collate;
        // The printer's own options chosen so far where it lists them, its defaults for the rest; the preset as chosen.
        carried.options = print::optionChoices(caps, current.options);
        carried.preset = current.preset;
        if (p->applyPresetOnRead && caps.known) {
            p->applyPresetOnRead = false;
            carried = presetChoices(*p, carried);
        }
        // A document sent first whose size is known: its paper, where this printer lists it, the first time a printer's options
        // are read (later the user's paper is carried as for any other choice). Its size known later: documentPaper (6-28).
        if (p->document && !p->documentPaperApplied && caps.known && p->pageSetup.contains(QStringLiteral("Width"))) {
            p->documentPaperApplied = true;
            const print::Media paper = print::findMedia(caps.media, {}, p->pageSetup.value(QStringLiteral("Width")).toDouble(),
                                                        p->pageSetup.value(QStringLiteral("Height")).toDouble());
            if (!paper.name.isEmpty())
                carried.media = paper;
        }
        p->choices = carried;
        emit printerChosen(id, printer, print::toQml(caps), print::toQml(carried));
    });
}

QString Print::tidyRanges(const QString &ranges) const
{
    QList<print::PageRange> parsed;
    return print::parseRanges(ranges, &parsed) ? print::shownRanges(parsed) : QString();
}

bool Print::answer(int id, int response, const QVariantMap &choices)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id))
        return true;
    if (response != 0) {
        finish(id, 1, {});
        return true;
    }
    print::Choices c = print::fromQml(choices, it->choices);
    if (!c.outputUri.isEmpty()) {
        // Save as PDF: only when the application can make a PDF, and only to the file the Save panel answered; no printer.
        if (!it->canSavePdf || it->pdfName.isEmpty() || print::localPdfPath(c.outputUri) != print::localPdfPath(it->pdfUri))
            return false;
        c.printer.clear();
        c.preview = false;
    } else if (c.preview) {
        // Open in Preview: a PDF too.
        if (!it->canSavePdf)
            return false;
        c.printer.clear();
    } else if (c.printer.isEmpty() || c.printer != it->printer || it->reading) {
        // To print, the printer the sheet chose (choosePrinter), once its options are read.
        return false;
    }
    // A document sent first: only once it is read.
    if (it->document && !it->spool)
        return false;
    QVariantMap settings, pageSetup;
    if (!print::toGtk(c, &settings, &pageSetup))
        return false;
    Ticket t;
    t.appId = it->appId;
    t.printer = c.printer;
    t.capabilities = it->capabilities;
    t.choices = c;
    t.document = it->document;
    // The copy Open in Preview opens is named after the document, never with a dollar sign: systemd-run, and uwsm's own when it
    // starts applications as services, would expand ${NAME} in it (counter-review of step 6b, NIT); replaced before the
    // 255-byte cap, so the name stays within it.
    QStringList names{it->settings.value(QStringLiteral("output-basename")).toString(), it->document ? it->title : QString(), appName(it->appId),
                      it->title};
    for (QString &name : names)
        name.replace(QLatin1Char('$'), QChar(0xFF04));
    t.documentName = print::pdfFileName(names);
    if (!c.outputUri.isEmpty()) {
        t.pdfFolder = it->pdfFolder;
        t.pdfName = it->pdfName;
    }
    // What this print was printed with is Last Used Settings from now on (macOS keeps them when Print is clicked).
    if (c.outputUri.isEmpty() && !c.preview)
        rememberLastUsed(c);
    if (it->document) {
        // The document is here: the job goes now, from the private file; the sheet goes at once, the request when the job is sent.
        const int fd = reopenSpool(it->spool->fd);
        const QString title = it->title;
        emit dismissed(id);
        if (fd < 0) {
            qWarning("grassfield-portal: cannot read the document kept for the print");
            finish(id, 2, {});
            return true;
        }
        printWithTicket(id, t, title, fd);
        return true;
    }
    const uint token = issue(t);
    finish(id, 0, {{QStringLiteral("settings"), settings}, {QStringLiteral("page-setup"), pageSetup}, {QStringLiteral("token"), QVariant::fromValue(token)}});
    return true;
}

void Print::choosePreset(int id, const QString &preset, const QVariantMap &choices)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id))
        return;
    print::Choices current = print::fromQml(choices, it->choices);
    current.preset = preset == QLatin1String("last") && lastUsed() ? QStringLiteral("last") : QStringLiteral("default");
    if (it->reading || !it->capabilities.known) {
        // Applied once the printer's options are read.
        it->choices = current;
        it->applyPresetOnRead = true;
        return;
    }
    it->choices = presetChoices(*it, current);
    emit printerChosen(id, it->printer, print::toQml(it->capabilities), print::toQml(it->choices));
}

print::Choices Print::presetChoices(const Pending &p, const print::Choices &current)
{
    const print::Choices base = print::initialChoices(p.printer, p.capabilities, p.settings, p.pageSetup, p.hasCurrentPage, p.hasSelection);
    print::Choices out = current;
    out.collate = base.collate;
    out.duplex = base.duplex;
    out.color = base.color;
    out.options = base.options;
    if (current.preset == QLatin1String("last")) {
        if (const auto last = lastUsed())
            out = print::withPreset(out, *last, p.capabilities);
    }
    return out;
}

std::optional<print::Preset> Print::lastUsed()
{
    if (m_lastUsedRead)
        return m_lastUsed;
    m_lastUsedRead = true;
    QFile f(m_options.stateFile);
    if (m_options.stateFile.isEmpty() || !f.exists())
        return m_lastUsed;
    if (f.size() > kMaxStateBytes || !f.open(QIODevice::ReadOnly)) {
        qWarning("grassfield-portal: Last Used Settings are not readable or too large; Default Settings apply");
        return m_lastUsed;
    }
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(f.read(kMaxStateBytes), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject() || doc.object().value(QLatin1String("version")).toInt() != 1) {
        qWarning("grassfield-portal: Last Used Settings are malformed; Default Settings apply");
        return m_lastUsed;
    }
    m_lastUsed = print::presetFromJson(doc.object().value(QLatin1String("lastUsed")).toObject());
    return m_lastUsed;
}

void Print::rememberLastUsed(const print::Choices &choices)
{
    lastUsed();
    m_lastUsed = print::presetOf(choices);
    if (m_options.stateFile.isEmpty())
        return;
    const QJsonObject root{{QLatin1String("version"), 1}, {QLatin1String("lastUsed"), print::toJson(*m_lastUsed)}};
    if (!QDir().mkpath(QFileInfo(m_options.stateFile).absolutePath())) {
        qWarning("grassfield-portal: cannot create the state directory; Last Used Settings are not kept");
        return;
    }
    QSaveFile out(m_options.stateFile);
    if (!out.open(QIODevice::WriteOnly) || out.write(QJsonDocument(root).toJson(QJsonDocument::Compact)) < 0 || !out.commit())
        qWarning("grassfield-portal: cannot write Last Used Settings");
}

void Print::addPrinter()
{
    if (m_options.addPrinterCommand.isEmpty())
        return;
    auto *job = new KIO::CommandLauncherJob(m_options.addPrinterCommand.first(), m_options.addPrinterCommand.mid(1), this);
    job->setDesktopName(QStringLiteral("org.grassfield.Settings"));
    connect(job, &KJob::result, this, [job] {
        if (job->error())
            qWarning("grassfield-portal: cannot open Settings > Printers: %s", qPrintable(job->errorString()));
    });
    job->start();
}

void Print::savePdf(int id, const QString &name, const QString &title)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id) || !it->canSavePdf || m_saving.contains(id) || !m_panelBus || !m_panelBus->isConnected()) {
        emit pdfCancelled(id);
        return;
    }
    it->pdfUri.clear();
    it->pdfFolder.clear();
    it->pdfName.clear();
    const QString file = print::pdfFileName({name});
    const QString handle = QStringLiteral("/org/freedesktop/portal/desktop/request/grassfield/print%1_%2").arg(id).arg(++m_saves);
    // This process's FileChooser, through the bus (its unique name: never another backend's), from the second connection: the
    // Open and Save panels' own path.
    QDBusMessage call = QDBusMessage::createMethodCall(m_bus.baseService(), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                       QStringLiteral("org.freedesktop.impl.portal.FileChooser"), QStringLiteral("SaveFile"));
    call << QVariant::fromValue(QDBusObjectPath(handle)) << it->appId << it->parentWindow << chooser::oneLine(title)
         << QVariantMap{{QStringLiteral("current_name"), file}, {QStringLiteral("modal"), true}};
    m_saving.insert(id, handle);
    it->saveHandle = handle;
    auto *watcher = new QDBusPendingCallWatcher(m_panelBus->asyncCall(call, std::numeric_limits<int>::max()), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, handle](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (m_saving.value(id) != handle)
            return;
        m_saving.remove(id);
        if (!m_pending.contains(id) || !isOpen(id))
            return;
        const QDBusMessage reply = w->reply();
        QString uri, path;
        if (reply.type() == QDBusMessage::ReplyMessage && reply.signature() == QLatin1String("ua{sv}")
            && reply.arguments().at(0).toUInt() == 0) {
            const QStringList uris = mapOf(reply.arguments().at(1)).value(QStringLiteral("uris")).toStringList();
            path = uris.size() == 1 ? print::localPdfPath(uris.first()) : QString();
            if (!path.isEmpty())
                uri = uris.first();
        }
        if (uri.isEmpty()) {
            emit pdfCancelled(id);
            return;
        }
        // The folder as the user chose it, its links resolved now (off this thread: a folder on a mount that hangs never holds
        // the panels): the file is written there or nowhere (writePdf; integrator security review of step 6a, MAJOR 1).
        auto folder = std::make_shared<QString>();
        const QString parent = QFileInfo(path).absolutePath();
        QThread *resolver = QThread::create([parent, folder] { *folder = QFileInfo(parent).canonicalFilePath(); });
        resolver->setParent(this);
        connect(resolver, &QThread::finished, this, [this, id, handle, uri, path, folder, resolver] {
            resolver->deleteLater();
            const auto p = m_pending.find(id);
            // Gone meanwhile, or another Save panel opened since (answered or not): no answer of this one's.
            if (p == m_pending.end() || !isOpen(id) || p->saveHandle != handle)
                return;
            if (folder->isEmpty()) {
                emit pdfCancelled(id);
                return;
            }
            p->pdfUri = uri;
            p->pdfFolder = *folder;
            p->pdfName = QFileInfo(path).fileName();
            emit pdfChosen(id, uri);
        });
        resolver->start();
    });
}

uint Print::issue(const Ticket &ticket)
{
    dropExpired();
    // The oldest go first when an application keeps asking without printing.
    while (m_tickets.size() >= kMaxTickets) {
        auto oldest = m_tickets.begin();
        for (auto it = m_tickets.begin(); it != m_tickets.end(); ++it)
            if (it->age.elapsed() > oldest->age.elapsed())
                oldest = it;
        m_tickets.erase(oldest);
    }
    uint token = 0;
    do {
        token = QRandomGenerator::system()->generate();
    } while (token == 0 || m_tickets.contains(token));
    Ticket t = ticket;
    t.age.start();
    m_tickets.insert(token, t);
    // When it expires unused, the idle time starts again (quietFor kept the process for it meanwhile). Precise: a coarse timer
    // may fire up to 5% early, before the token has expired, and nothing would start the idle time then.
    QTimer::singleShot(m_options.tokenLifetimeMs + 50, Qt::PreciseTimer, this, [this] {
        if (dropExpired() && pending() == 0)
            armIdle();
    });
    return token;
}

bool Print::dropExpired()
{
    const auto before = m_tickets.size();
    for (auto it = m_tickets.begin(); it != m_tickets.end();)
        it = it->age.elapsed() > m_options.tokenLifetimeMs ? m_tickets.erase(it) : std::next(it);
    return m_tickets.size() != before;
}

void Print::handlePrint(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                        const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    dropExpired();
    const QVariant given = options.value(QStringLiteral("token"));
    const uint token = given.metaType() == QMetaType::fromType<uint>() ? given.toUInt() : 0;
    const auto it = m_tickets.find(token);
    if (token == 0) {
        // No sheet before it (an application that sends the document first): the sheet with the document's preview.
        const int document = fd.isValid() ? ::fcntl(fd.fileDescriptor(), F_DUPFD_CLOEXEC, 3) : -1;
        if (document < 0) {
            qWarning("grassfield-portal: Print came without a readable document");
            finish(id, 2, {});
            return;
        }
        showDocument(id, appId, parentWindow, title, document);
        return;
    }
    if (it == m_tickets.end() || it->appId != appId) {
        // A token this backend did not give (x-d-p-gtk's, after a PreparePrint it served), another application's, or one that
        // expired: x-d-p-gtk prints it, with its own dialog if it must ask.
        forward(id);
        return;
    }
    const Ticket t = it.value();
    m_tickets.erase(it);
    const int document = fd.isValid() ? ::fcntl(fd.fileDescriptor(), F_DUPFD_CLOEXEC, 3) : -1;
    if (document < 0) {
        qWarning("grassfield-portal: Print came without a readable document");
        finish(id, 2, {});
        return;
    }
    printWithTicket(id, t, chooser::oneLine(title), document);
}

void Print::printWithTicket(int id, const Ticket &ticket, const QString &title, int fd)
{
    // What this job does stops when its request ends first (ended()): the writer removes its temporary file, the CUPS job is
    // cancelled.
    m_jobs.insert(id, JobStop{});
    if (ticket.choices.preview) {
        openInPreview(id, ticket, fd);
        return;
    }
    if (!ticket.choices.outputUri.isEmpty()) {
        if (ticket.pdfFolder.isEmpty() || ticket.pdfName.isEmpty()) {
            ::close(fd);
            finish(id, 2, {});
            return;
        }
        auto error = std::make_shared<QString>();
        const int idle = m_options.fileIdleMs;
        const QString folder = ticket.pdfFolder, file = ticket.pdfName;
        const auto stop = m_stopWriting;
        const auto closed = m_jobs.value(id).flag;
        QThread *writer = QThread::create([fd, folder, file, idle, error, stop, closed] {
            *error = writePdf(fd, folder, file, idle, print::kMaxDocumentBytes, [stop, closed] { return stop->load() || closed->load(); });
        });
        writer->setParent(this);
        connect(writer, &QThread::finished, this, [this, id, writer, error] {
            writer->deleteLater();
            if (!error->isEmpty())
                qWarning("grassfield-portal: Save as PDF: %s", qPrintable(*error));
            finish(id, error->isEmpty() ? 0 : 2, {});
        });
        writer->start();
        return;
    }
    if (!m_system) {
        ::close(fd);
        finish(id, 2, {});
        return;
    }
    // The job's name in the printer's queue: the application's (GTK's title is "Print" for every job).
    const QString app = appName(ticket.appId);
    const QString name = !app.isEmpty() ? app : !title.isEmpty() ? title : QStringLiteral("Document");
    const PrintSystem::Options options = ticket.document ? print::documentOptions(ticket.choices, ticket.capabilities)
                                                         : print::cupsOptions(ticket.choices, ticket.capabilities);
    PrintSystem::Stop stop = m_system->submit(ticket.printer, name, options, fd, this, [this, id](const QString &error) {
        if (!error.isEmpty())
            qWarning("grassfield-portal: the print job did not go: %s", qPrintable(error));
        finish(id, error.isEmpty() ? 0 : 2, {});
    });
    // The fake print systems of the tests may answer at once: the request may have ended already.
    if (const auto it = m_jobs.find(id); it != m_jobs.end())
        it->cups = std::move(stop);
}

void Print::openInPreview(int id, const Ticket &ticket, int fd)
{
    if (m_options.previewFolder.isEmpty()) {
        ::close(fd);
        finish(id, 2, {});
        return;
    }
    auto error = std::make_shared<QString>();
    auto path = std::make_shared<QString>();
    auto command = std::make_shared<QStringList>(m_options.previewCommand);
    const QString base = m_options.previewFolder, name = ticket.documentName;
    const int idle = m_options.fileIdleMs;
    const auto stopAll = m_stopWriting;
    const auto closed = m_jobs.value(id).flag;
    const auto stop = std::make_shared<std::function<bool()>>([stopAll, closed] { return stopAll->load() || closed->load(); });
    // The old copies go, a folder of its own is made in the private folder, the copy is written there as Save as PDF writes (only
    // a PDF, never through a link) and the way Preview opens it is found: off this thread.
    QThread *writer = QThread::create([fd, base, name, idle, error, path, command, stop] {
        bool keepsArguments = true;
        if (command->isEmpty())
            *command = defaultPreviewCommand(&keepsArguments);
        // The name has no dollar sign already (answer()).
        const QString file = name;
        removeOldCopies(base, QDateTime::currentSecsSinceEpoch());
        const QString folder = privateFolder(base, error.get());
        if (folder.isEmpty()) {
            ::close(fd);
            return;
        }
        *error = writePdf(fd, folder, file, idle, print::kMaxDocumentBytes, *stop);
        if (error->isEmpty())
            *path = QDir(folder).filePath(file);
    });
    writer->setParent(this);
    connect(writer, &QThread::finished, this, [this, id, writer, error, path, command] {
        writer->deleteLater();
        // The request closed meanwhile: Preview does not open (the copy goes with the old ones).
        if (!m_jobs.contains(id))
            return;
        if (!error->isEmpty()) {
            qWarning("grassfield-portal: Open in Preview: %s", qPrintable(*error));
            finish(id, 2, {});
            return;
        }
        QStringList arguments = *command;
        const QString program = arguments.takeFirst();
        const bool started = QProcess::startDetached(program, arguments << *path);
        if (!started)
            qWarning("grassfield-portal: Open in Preview: %s could not be started", qPrintable(program));
        finish(id, started ? 0 : 2, {});
    });
    writer->start();
}

void Print::showDocument(int id, const QString &appId, const QString &parentWindow, const QString &title, int fd)
{
    if (!startUi(id)) {
        ::close(fd);
        return;
    }
    QVariantMap sheet = toQml(appId, parentWindow, title, {}, {}, {});
    Pending p;
    p.appId = appId;
    p.parentWindow = parentWindow;
    p.title = sheet.value(QStringLiteral("title")).toString();
    p.document = true;
    // The document is a PDF (nothing else is kept): it can be saved and opened in Preview.
    p.canSavePdf = true;
    p.choices = print::fromQml(sheet.value(QStringLiteral("choices")).toMap(), print::Choices{});
    const bool last = lastUsed().has_value();
    p.choices.preset = last ? QStringLiteral("last") : QStringLiteral("default");
    p.applyPresetOnRead = last;
    sheet.insert(QStringLiteral("document"), true);
    sheet.insert(QStringLiteral("canSavePdf"), true);
    sheet.insert(QStringLiteral("hasLastUsed"), last);
    sheet.insert(QStringLiteral("outputBasename"), plainName(QVariant(p.title)));
    sheet.insert(QStringLiteral("choices"), print::toQml(p.choices));
    const auto stop = p.stop;
    const auto source = p.source;
    m_pending.insert(id, p);
    emit opened(id, sheet);

    // The document read into a private file, off this thread; then, apart, its page count and first page's size (the paper it
    // asks for) from the child that draws it: the sheet can print as soon as the document is kept, whatever the preview does
    // (counter-review of step 6b, NIT: the preview waits its turn behind other sheets' children).
    auto spooled = std::make_shared<Spooled>();
    const QString folder = m_options.spoolFolder;
    const int idle = m_options.fileIdleMs;
    const auto stopAll = m_stopWriting;
    SpoolHooks hooks;
    hooks.stopped = [stop, stopAll] { return stop->load() || stopAll->load(); };
    // A pipe is read only while the call has not gone to x-d-p-gtk, and once it is read the call cannot go there (forwardable).
    hooks.mayConsume = [source] {
        int untouched = kSourceUntouched;
        return source->compare_exchange_strong(untouched, kSourceRead);
    };
    hooks.budget = m_budget;
    QThread *reader = QThread::create([fd, folder, idle, spooled, hooks] { *spooled = spoolDocument(fd, folder, idle, print::kMaxDocumentBytes, hooks); });
    reader->setParent(this);
    connect(reader, &QThread::finished, this, [this, id, reader, spooled, hooks] {
        reader->deleteLater();
        auto file = std::make_shared<SpoolFile>();
        file->fd = spooled->fd;
        file->budget = spooled->reserved > 0 ? m_budget : nullptr;
        file->reserved = spooled->reserved;
        const auto p = m_pending.find(id);
        if (p == m_pending.end() || !isOpen(id))
            return;
        if (spooled->notPdf) {
            // Not a PDF: x-d-p-gtk prints it as before step 6b when the document is still as it came (a file read in place),
            // else the print fails (only a PDF reaches a printer through Grassfield, decision 6-4).
            qWarning("grassfield-portal: the document sent to print is not a PDF; %s", spooled->consumed ? "it is not printed" : "it goes to x-d-p-gtk");
            if (spooled->consumed)
                finish(id, 2, {});
            else
                forward(id);
            return;
        }
        if (spooled->overBudget && !spooled->consumed) {
            // The budget is full (other documents wait): a file read in place goes to x-d-p-gtk as it came, as before step 6b,
            // rather than fail (ADR-0035 6-28); one on a pipe cannot.
            qWarning("grassfield-portal: the documents waiting to print take all their room; this one goes to x-d-p-gtk");
            forward(id);
            return;
        }
        if (file->fd < 0) {
            qWarning("grassfield-portal: the document sent to print could not be read: %s", qPrintable(spooled->error));
            finish(id, 2, {});
            return;
        }
        p->spool = file;
        emit documentRead(id);
        listPrinters(id);
        inspectDocument(id, hooks.stopped);
    });
    reader->start();
}

void Print::inspectDocument(int id, const std::function<bool()> &stopped)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !it->spool)
        return;
    const auto spool = it->spool;
    const int deadline = m_options.renderDeadlineMs;
    const QStringList renderer = m_options.rendererCommand.isEmpty()
        ? QStringList{QCoreApplication::applicationFilePath(), QStringLiteral("--print-preview")}
        : m_options.rendererCommand;
    auto info = std::make_shared<Rendered>();
    QThread *inspector = QThread::create([spool, deadline, renderer, info, stopped] { *info = renderPreview(renderer, spool->fd, 0, {}, deadline, stopped); });
    inspector->setParent(this);
    connect(inspector, &QThread::finished, this, [this, id, inspector, info] {
        inspector->deleteLater();
        const auto p = m_pending.find(id);
        if (p == m_pending.end() || !isOpen(id))
            return;
        p->pages = info->ok ? info->pages : 0;
        qInfo("grassfield-portal: a document of %d pages to print", p->pages);
        emit documentReady(id, p->pages);
        if (!info->ok)
            return;
        // The paper of its first page (portrait, in millimetres) is the one first chosen where the printer has it: by the
        // printer's options when they are read after this, by the sheet (unless the user chose a paper) when they were before.
        const double w = info->pageSize.width() * 25.4 / 72, h = info->pageSize.height() * 25.4 / 72;
        p->pageSetup = {{QStringLiteral("Width"), std::min(w, h)}, {QStringLiteral("Height"), std::max(w, h)}};
        if (p->capabilities.known && !p->reading && !p->documentPaperApplied) {
            p->documentPaperApplied = true;
            const print::Media paper = print::findMedia(p->capabilities.media, {}, std::min(w, h), std::max(w, h));
            if (!paper.name.isEmpty()) {
                p->choices.media = paper;
                emit documentPaper(id, print::toQml(paper));
            }
        }
    });
    inspector->start();
}

void Print::renderPage(int id, int page, int width, int height)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id) || !it->spool || page < 0 || page >= it->pages || width <= 0 || height <= 0) {
        emit pageRendered(id, page, QString());
        return;
    }
    if (it->rendering) {
        it->wanted = std::make_tuple(page, width, height);
        return;
    }
    startRender(id, page, width, height);
}

void Print::startRender(int id, int page, int width, int height)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end())
        return;
    it->rendering = true;
    const auto spool = it->spool;
    const auto stop = it->stop;
    const auto stopAll = m_stopWriting;
    const QStringList renderer = m_options.rendererCommand.isEmpty()
        ? QStringList{QCoreApplication::applicationFilePath(), QStringLiteral("--print-preview")}
        : m_options.rendererCommand;
    const int deadline = m_options.renderDeadlineMs;
    const QSize size = QSize(width, height).boundedTo(QSize(kMaxPreviewSide, kMaxPreviewSide));
    auto result = std::make_shared<Rendered>();
    QThread *drawer = QThread::create([spool, page, size, deadline, renderer, result, stop, stopAll] {
        *result = renderPreview(renderer, spool->fd, page, size, deadline, [stop, stopAll] { return stop->load() || stopAll->load(); });
    });
    drawer->setParent(this);
    connect(drawer, &QThread::finished, this, [this, id, page, width, height, drawer, result] {
        drawer->deleteLater();
        const auto p = m_pending.find(id);
        if (p == m_pending.end() || !isOpen(id))
            return;
        p->rendering = false;
        QString source;
        if (result->ok && !result->image.isNull()) {
            const QString key = PreviewImages::insert(result->image);
            p->images << key;
            while (p->images.size() > kKeptPages)
                PreviewImages::remove(p->images.takeFirst());
            source = QStringLiteral("image://printpreview/") + key;
        }
        emit pageRendered(id, page, source);
        if (p->wanted) {
            const auto [nextPage, nextWidth, nextHeight] = *p->wanted;
            p->wanted.reset();
            if (nextPage != page || nextWidth != width || nextHeight != height)
                startRender(id, nextPage, nextWidth, nextHeight);
        }
    });
    drawer->start();
}

bool Print::forwardable(int id)
{
    // A document on a pipe that is being read, or was, would reach x-d-p-gtk truncated: the call ends instead (response 2). A file
    // read in place, or a pipe not read yet (it is not read after this), goes on as it came.
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !it->document)
        return true;
    int untouched = kSourceUntouched;
    return it->source->compare_exchange_strong(untouched, kSourceForwarded) || it->source->load() == kSourceForwarded;
}

void Print::forwarded(int id)
{
    // Gone to x-d-p-gtk (the sheet could not show, or the document is not a PDF): what reads or draws its document stops.
    if (const auto it = m_pending.find(id); it != m_pending.end())
        it->stop->store(true);
}

void Print::ended(int id)
{
    // A job printing with a ticket stops with its request: a Close during the write or the send means "do not" (SP-16). A job
    // whose own answer ends the request finds nothing left to stop.
    if (const auto job = m_jobs.find(id); job != m_jobs.end()) {
        job->flag->store(true);
        if (job->cups)
            job->cups();
        m_jobs.erase(job);
    }
    const auto it = m_pending.find(id);
    if (it != m_pending.end()) {
        // What reads or draws its document stops; the pages drawn go; its room in the budget comes back now (a child that was
        // drawing it may hold the file a moment longer while it is stopped).
        it->stop->store(true);
        if (it->spool)
            it->spool->giveBack();
        for (const QString &key : std::as_const(it->images))
            PreviewImages::remove(key);
    }
    m_pending.remove(id);
    // Its Save panel goes too (the application closed the request meanwhile).
    const QString saving = m_saving.take(id);
    if (!saving.isEmpty() && m_panelBus)
        m_panelBus->asyncCall(QDBusMessage::createMethodCall(m_bus.baseService(), saving, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                             QStringLiteral("Close")));
}

QVariantMap Print::relayed(const QVariantMap &gtkResults) const
{
    // The interface's results: GTK's settings (strings), page setup (strings and doubles) and token (u).
    QVariantMap out;
    if (gtkResults.contains(QStringLiteral("settings")))
        out.insert(QStringLiteral("settings"), typed(mapOf(gtkResults.value(QStringLiteral("settings"))), false));
    if (gtkResults.contains(QStringLiteral("page-setup")))
        out.insert(QStringLiteral("page-setup"), typed(mapOf(gtkResults.value(QStringLiteral("page-setup"))), true));
    const QVariant token = gtkResults.value(QStringLiteral("token"));
    if (token.metaType() == QMetaType::fromType<uint>())
        out.insert(QStringLiteral("token"), token);
    return out;
}

PrintAdaptor::PrintAdaptor(QObject *exported, grassfield::portal::Print *print)
    : QDBusAbstractAdaptor(exported)
    , m_print(print)
{
}

uint PrintAdaptor::PreparePrint(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                const QVariantMap &settings, const QVariantMap &page_setup, const QVariantMap &options,
                                const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_print->handlePrepare(handle, app_id, parent_window, title, settings, page_setup, options, message);
    return 2;
}

uint PrintAdaptor::Print(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                         const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_print->handlePrint(handle, app_id, parent_window, title, fd, options, message);
    return 2;
}

} // namespace grassfield::portal
