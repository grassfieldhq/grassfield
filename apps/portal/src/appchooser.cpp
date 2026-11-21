#include "appchooser.h"

#include "chooserlogic.h"

#include <QDBusConnection>
#include <QSet>

#include <algorithm>

namespace grassfield::portal {

namespace {

// An option the frontend passes as a string or a boolean: a value of any other type is no value (any process on the session
// bus can call the backend directly, without the frontend's checks).
QString stringOption(const QVariantMap &options, const QString &key)
{
    const QVariant value = options.value(key);
    return value.metaType() == QMetaType::fromType<QString>() ? value.toString() : QString();
}

bool boolOption(const QVariantMap &options, const QString &key, bool fallback)
{
    const QVariant value = options.value(key);
    return value.metaType() == QMetaType::fromType<bool>() ? value.toBool() : fallback;
}

} // namespace

AppChooser::AppChooser(const QDBusConnection &bus, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.AppChooser"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending, false}, parent)
    , m_gtkService(options.gtkService)
{
}

bool AppChooser::isDesktopId(const QString &id)
{
    // A desktop file id without ".desktop", as the frontend gives it and takes it back (src/open-uri.c: get_app_id, then
    // g_desktop_app_info_new(id + ".desktop")) and as the Applications location makes it from a file's path ('/' written
    // '-'): a name, so no '/', no control character, not hidden, at most 255 bytes with its suffix. Spaces, '+' and any
    // letter are a name's (Wine's "wine-Programs-Notepad++", a game's "Some Game"; review of step 5b, m4).
    if (id.isEmpty() || id.startsWith(QLatin1Char('.')) || id.endsWith(QLatin1String(".desktop")) || id.toUtf8().size() > 255 - 8)
        return false;
    for (const QChar c : id)
        if (c == QLatin1Char('/') || c.category() == QChar::Other_Control || c.category() == QChar::Other_Format)
            return false;
    return true;
}

QStringList AppChooser::desktopIds(const QStringList &ids)
{
    QStringList out;
    QSet<QString> seen;
    // A bounded look: any process on the session bus can send a list of any length (review of step 5b, n9).
    const qsizetype looked = std::min<qsizetype>(ids.size(), 4 * kMaxApplications);
    for (qsizetype i = 0; i < looked; ++i) {
        const QString &id = ids.at(i);
        if (out.size() >= kMaxApplications)
            break;
        if (isDesktopId(id) && !seen.contains(id)) {
            seen.insert(id);
            out.append(id);
        }
    }
    return out;
}

QVariantMap AppChooser::toQml(const QString &appId, const QString &parentWindow, const QStringList &choices, const QVariantMap &options)
{
    // The document's name as the panel's message names it: a plain name, never a path.
    QString filename = chooser::oneLine(stringOption(options, QStringLiteral("filename")));
    if (filename.contains(QLatin1Char('/')) || filename == QLatin1String(".") || filename == QLatin1String(".."))
        filename.clear();
    const QString last = stringOption(options, QStringLiteral("last_choice"));
    return {
        {QStringLiteral("kind"), QStringLiteral("application")},
        {QStringLiteral("appId"), appId},
        // The panel's own title and button (Choose Application, Open).
        {QStringLiteral("title"), QString()},
        {QStringLiteral("acceptLabel"), QString()},
        {QStringLiteral("modal"), boolOption(options, QStringLiteral("modal"), true)},
        {QStringLiteral("parented"), parentWindow.startsWith(QLatin1String("wayland:")) && parentWindow.size() > 8},
        {QStringLiteral("multiple"), false},
        {QStringLiteral("directory"), false},
        // The Enable pop-up's two entries are the panel's own (FilePanel.qml); none of the Open panel's.
        {QStringLiteral("filters"), QVariantList()},
        {QStringLiteral("currentFilter"), -1},
        {QStringLiteral("choices"), QVariantList()},
        {QStringLiteral("currentName"), QString()},
        {QStringLiteral("files"), QVariantList()},
        {QStringLiteral("currentFolder"), QString()},
        {QStringLiteral("applications"), desktopIds(choices)},
        {QStringLiteral("lastChoice"), isDesktopId(last) ? last : QString()},
        {QStringLiteral("filename"), filename},
        {QStringLiteral("uri"), chooser::oneLine(stringOption(options, QStringLiteral("uri")))},
    };
}

void AppChooser::handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QStringList &choices,
                        const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    const QString token = stringOption(options, QStringLiteral("activation_token"));
    if (!token.isEmpty() && token.size() <= 1024)
        m_tokens.insert(id, token);
    m_callers.insert(id, message.service());
    if (!startUi(id))
        return;
    const QVariantMap chooser = toQml(appId, parentWindow, choices, options);
    whenAppKnown(id, [this, id, chooser] { emit opened(id, chooser); });
}

void AppChooser::updateChoices(const QDBusObjectPath &handle, const QStringList &choices, const QString &sender)
{
    const int id = requestId(handle.path());
    if (id == 0)
        return;
    if (sender != m_callers.value(id)) {
        qWarning("grassfield-portal: UpdateChoices from another caller than the request's; ignored");
        return;
    }
    const QStringList checked = desktopIds(choices);
    if (isOpen(id)) {
        m_updated.insert(id, {handle, checked});
        emit applicationsChanged(id, checked);
        return;
    }
    // Forwarded: x-d-p-gtk's dialog shows the frontend's new candidates.
    sendUpdate(handle, checked);
}

void AppChooser::forwarded(int id)
{
    // The forward carries the call's first candidates: an UpdateChoices the panel had follows them to x-d-p-gtk (on the same
    // connection, so after the call).
    if (m_updated.contains(id)) {
        const QPair<QDBusObjectPath, QStringList> update = m_updated.take(id);
        sendUpdate(update.first, update.second);
    }
}

void AppChooser::sendUpdate(const QDBusObjectPath &handle, const QStringList &choices)
{
    QDBusMessage call = QDBusMessage::createMethodCall(m_gtkService, QStringLiteral("/org/freedesktop/portal/desktop"),
                                                       QStringLiteral("org.freedesktop.impl.portal.AppChooser"),
                                                       QStringLiteral("UpdateChoices"));
    call.setArguments({QVariant::fromValue(handle), choices});
    m_bus.call(call, QDBus::NoBlock);
}

void AppChooser::ended(int id)
{
    m_tokens.remove(id);
    m_callers.remove(id);
    m_updated.remove(id);
}

void AppChooser::answer(int id, int response, const QVariantMap &answer)
{
    if (!isOpen(id))
        return;
    if (response != 0) {
        finish(id, 1, {});
        return;
    }
    const QVariant choice = answer.value(QStringLiteral("choice"));
    if (choice.metaType() != QMetaType::fromType<QString>() || !isDesktopId(choice.toString())) {
        qWarning("grassfield-portal: the panel chose no application; the request ends");
        finish(id, 2, {});
        return;
    }
    QVariantMap results{{QStringLiteral("choice"), choice.toString()}};
    // The token the request came with: the frontend starts the chosen application with it (the interface allows the same one
    // back; Hyprland gives a new window the keyboard either way).
    const QString token = m_tokens.value(id);
    if (!token.isEmpty())
        results.insert(QStringLiteral("activation_token"), token);
    finish(id, 0, results);
}

QVariantMap AppChooser::relayed(const QVariantMap &gtkResults) const
{
    // The interface's results: the choice and the activation token (strings; an empty one is none: x-d-p-gtk's Cancel gives
    // an empty choice, integrator nested pass of f9a25ce, NIT).
    QVariantMap out;
    for (const QString &key : {QStringLiteral("choice"), QStringLiteral("activation_token")}) {
        const QVariant value = gtkResults.value(key);
        if (value.metaType() == QMetaType::fromType<QString>() && !value.toString().isEmpty())
            out.insert(key, value.toString());
    }
    // A choice that is no desktop id is none, as the panel's own (the frontend starts what it is given; integrator review of
    // f9a25ce, NIT).
    if (out.contains(QStringLiteral("choice")) && !isDesktopId(out.value(QStringLiteral("choice")).toString()))
        out.remove(QStringLiteral("choice"));
    return out;
}

AppChooserAdaptor::AppChooserAdaptor(QObject *exported, AppChooser *chooser)
    : QDBusAbstractAdaptor(exported)
    , m_chooser(chooser)
{
}

uint AppChooserAdaptor::ChooseApplication(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window,
                                          const QStringList &choices, const QVariantMap &options, const QDBusMessage &message,
                                          QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(handle, app_id, parent_window, choices, options, message);
    return 2;
}

void AppChooserAdaptor::UpdateChoices(const QDBusObjectPath &handle, const QStringList &choices, const QDBusMessage &message)
{
    m_chooser->updateChoices(handle, choices, message.service());
}

} // namespace grassfield::portal
