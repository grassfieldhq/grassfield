#include "filechooser.h"

#include "panelstate.h"

#include <QDir>
#include <QStandardPaths>
#include <QUrl>

#include <utility>

namespace grassfield::portal {

FileChooser::FileChooser(const QDBusConnection &bus, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.FileChooser"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending}, parent)
    , m_options(options)
    , m_disk(DiskProbe::Options{options.probeDeadlineMs, options.probeTotalMs, options.statPath})
{
    connect(&m_disk, &DiskProbe::answered, this, [this](int token, const QHash<QString, int> &kinds) {
        if (const auto done = m_diskAsked.take(token))
            done(kinds);
    });
    chooser::registerTypes();
}

void FileChooser::handle(chooser::Kind kind, const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow,
                         const QString &title, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    chooser::Request parsed = chooser::parse(kind, appId, parentWindow, title, options);
    if (!parsed.error.isEmpty())
        return refuse(message, qPrintable(parsed.error));
    const int id = begin(handle, message, parsed.appId, parsed.parentWindow);
    if (id == 0)
        return;
    m_parsed.insert(id, parsed);
    if (!startUi(id))
        return;
    // The folders the panel may start in are asked about off the GUI thread first (FC7): the application's, the remembered
    // one and each place, a call each at once, so that none, hung, keeps the others from answering (re-reviews of 65311e0
    // and 24bdf58, MAJOR 1). One that does not answer in time is passed over, as one that does not exist is.
    QVariantMap qml = chooser::toQml(parsed);
    const QVariantMap places = placeUrls();
    QStringList placeList;
    for (const char *place : {"home", "documents", "desktop", "downloads"})
        placeList << places.value(QLatin1String(place)).toString();
    placeList.removeAll(QString());
    struct Gathered {
        int waiting = 0;
        QVariantMap kinds;
    };
    auto gathered = std::make_shared<Gathered>();
    const auto gather = [this, id, qml, places, gathered](const QVariantMap &kinds) mutable {
        mergeKinds(gathered->kinds, kinds);
        if (--gathered->waiting > 0)
            return;
        if (!isMaking(id))
            return;
        QVariantMap answered;
        for (auto it = places.cbegin(); it != places.cend(); ++it) {
            const bool folder = gathered->kinds.value(it.value().toString()).toInt() == 2 || it.key() == QLatin1String("home");
            answered.insert(it.key(), folder ? it.value() : QString());
        }
        qml.insert(QStringLiteral("places"), answered);
        qml.insert(QStringLiteral("folderKinds"), gathered->kinds);
        // The application's name (the panel's sentences) read off this thread first (SP-18).
        whenAppKnown(id, [this, id, qml] { emit opened(id, qml); });
    };
    QStringList calls{qml.value(QStringLiteral("currentFolder")).toString(), memory(parsed.appId).value(QStringLiteral("folder")).toString()};
    calls << placeList;
    calls.removeAll(QString());
    calls.removeDuplicates();
    gathered->waiting = int(calls.size());
    for (const QString &url : std::as_const(calls))
        askDisk({url}, gather);
}

void FileChooser::answer(int id, int response, const QVariantMap &given)
{
    if (!isOpen(id))
        return;
    if (response == 1) {
        finish(id, 1, {});
        return;
    }
    const chooser::Results results = response == 0 ? chooser::results(m_parsed.value(id), given) : chooser::Results{};
    if (!results.ok) {
        qWarning("grassfield-portal: the panel's answer breaks the interface; the request ends with an error");
        finish(id, 2, {});
        return;
    }
    finish(id, 0, results.map);
}

QVariantMap FileChooser::memory(const QString &appId) const
{
    if (!m_options.state)
        return {};
    const PanelState::Entry e = m_options.state->entry(appId);
    return {{QStringLiteral("folder"), e.folder}, {QStringLiteral("view"), e.view}, {QStringLiteral("expanded"), e.expanded}};
}

void FileChooser::remember(const QString &appId, const QVariantMap &entry)
{
    if (!m_options.state)
        return;
    PanelState::Entry e;
    e.folder = entry.value(QStringLiteral("folder")).toString();
    e.view = entry.value(QStringLiteral("view")).toString();
    e.expanded = entry.value(QStringLiteral("expanded")).toBool();
    m_options.state->remember(appId, e);
}

QVariantMap FileChooser::placeUrls() const
{
    // The addresses only: whether each is a folder is the probe's question.
    const auto folder = [](QStandardPaths::StandardLocation location) {
        const QString path = QStandardPaths::writableLocation(location);
        return path.isEmpty() || QDir::cleanPath(path) == QDir::cleanPath(QDir::homePath()) ? QString()
                                                                                            : QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
    };
    return {{QStringLiteral("home"), QUrl::fromLocalFile(QDir::homePath()).toString(QUrl::FullyEncoded)},
            {QStringLiteral("desktop"), folder(QStandardPaths::DesktopLocation)},
            {QStringLiteral("documents"), folder(QStandardPaths::DocumentsLocation)},
            {QStringLiteral("downloads"), folder(QStandardPaths::DownloadLocation)}};
}

int FileChooser::askDisk(const QStringList &urls, std::function<void(const QVariantMap &)> done)
{
    // Tolerant, as the panels' answers: QML prints a URL with its spaces as they are.
    // The paths in the order given (re-review of 24bdf58: a hash's order changes from one process to the next).
    QVariantMap kinds;
    QStringList paths;
    QHash<QString, QStringList> urlsOf;
    for (const QString &text : urls) {
        const QUrl url(text);
        const QString path = url.isLocalFile() ? QDir::cleanPath(url.toLocalFile()) : QString();
        if (!url.isValid() || !url.host().isEmpty() || url.hasQuery() || url.hasFragment() || !path.startsWith(u'/')) {
            kinds.insert(text, -1);
            continue;
        }
        if (!urlsOf.contains(path))
            paths << path;
        urlsOf[path].append(text);
    }
    const int token = m_disk.probe(paths);
    m_diskAsked.insert(token, [kinds, urlsOf, done = std::move(done)](const QHash<QString, int> &answered) mutable {
        for (auto it = urlsOf.cbegin(); it != urlsOf.cend(); ++it)
            for (const QString &url : it.value())
                kinds.insert(url, answered.value(it.key(), kNotResponding));
        done(kinds);
    });
    return token;
}

void FileChooser::mergeKinds(QVariantMap &into, const QVariantMap &from)
{
    for (auto it = from.cbegin(); it != from.cend(); ++it)
        if (it.value().toInt() != kNotResponding || !into.contains(it.key()))
            into.insert(it.key(), it.value());
}

int FileChooser::probe(const QStringList &urls)
{
    auto token = std::make_shared<int>(0);
    *token = askDisk(urls, [this, token](const QVariantMap &kinds) { emit probed(*token, kinds); });
    return *token;
}

FileChooserAdaptor::FileChooserAdaptor(FileChooser *chooser)
    : QDBusAbstractAdaptor(chooser)
    , m_chooser(chooser)
{
}

uint FileChooserAdaptor::OpenFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::Open, handle, app_id, parent_window, title, options, message);
    return 2;
}

uint FileChooserAdaptor::SaveFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::Save, handle, app_id, parent_window, title, options, message);
    return 2;
}

uint FileChooserAdaptor::SaveFiles(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                   const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::SaveFiles, handle, app_id, parent_window, title, options, message);
    return 2;
}

} // namespace grassfield::portal
