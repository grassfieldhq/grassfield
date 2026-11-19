#include "access.h"

#include <QCoreApplication>
#include <QRegularExpression>
#include <QSet>

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

// The text xdg-desktop-portal 1.22.1 asks its questions with (src/camera.c, location.c, screenshot.c, wallpaper.c,
// background.c), "%s" written "%1": its French catalog is empty, so a French session got English alerts (integrator nested
// pass of 1745c0c, MINOR 6). The ones without a name come first: "Allow Apps to …" would match "Allow %1 to …" too.
constexpr char kContext[] = "AccessAlert";
const char *const kFrontendText[] = {
    QT_TRANSLATE_NOOP("AccessAlert", "Allow Apps to Use the Camera?"),
    QT_TRANSLATE_NOOP("AccessAlert", "An app wants to access the camera"),
    QT_TRANSLATE_NOOP("AccessAlert", "This permission can be changed at any time from the privacy settings"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow Apps to Access Your Location?"),
    QT_TRANSLATE_NOOP("AccessAlert", "An app wants to use your location"),
    QT_TRANSLATE_NOOP("AccessAlert", "Location access can be changed at any time from the privacy settings"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow Apps to Take Screenshots?"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow to Take a Screenshot?"),
    QT_TRANSLATE_NOOP("AccessAlert", "An app wants to take screenshots at any time"),
    QT_TRANSLATE_NOOP("AccessAlert", "An app wants to take a screenshot"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow Apps to Set Backgrounds?"),
    QT_TRANSLATE_NOOP("AccessAlert", "An app wants to change the background image"),
    QT_TRANSLATE_NOOP("AccessAlert", "The ‘run in background’ permission can be changed at any time from the app settings"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Use the Camera?"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to access the camera"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Access Your Location?"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to use your location"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Take Screenshots?"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Take a Screenshot?"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to take screenshots at any time"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to take a screenshot"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Set Backgrounds?"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to change the background image"),
    QT_TRANSLATE_NOOP("AccessAlert", "Allow %1 to Run in the Background?"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to be started automatically and run in the background"),
    QT_TRANSLATE_NOOP("AccessAlert", "%1 wants to run in the background"),
};

// One of the frontend's texts in Grassfield's language, the application's name kept; any other text (another version's
// wording, or one the frontend translated) as it came.
QString inLanguage(const QString &text)
{
    for (const char *source : kFrontendText) {
        const QString english = QString::fromUtf8(source);
        const qsizetype at = english.indexOf(QLatin1String("%1"));
        if (at < 0) {
            if (text == english)
                return QCoreApplication::translate(kContext, source);
            continue;
        }
        const QString before = english.left(at);
        const QString after = english.mid(at + 2);
        if (text.size() > before.size() + after.size() && text.startsWith(before) && text.endsWith(after))
            return QCoreApplication::translate(kContext, source).arg(text.mid(before.size(), text.size() - before.size() - after.size()));
    }
    return text;
}

// The frontend's own button labels (location: "Deny Access" and "Grant Access"; screenshots: "Deny" and "Allow"; running in
// the background: "Don't allow" and "Allow"): the alert's own "Don't Allow" and "Allow" instead, in Grassfield's language, the
// words macOS gives every privacy alert (ADR-0035 5a-9).
bool frontendLabel(const QString &label)
{
    static const QSet<QString> known{QStringLiteral("Deny Access"), QStringLiteral("Grant Access"), QStringLiteral("Deny"),
                                     QStringLiteral("Allow"), QStringLiteral("Don't allow")};
    return known.contains(label);
}

} // namespace

Access::Access(const QDBusConnection &bus, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.Access"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending, true}, parent)
{
    chooser::registerTypes();
}

QVariantMap Access::toQml(const QString &appId, const QString &parentWindow, const QString &title, const QString &subtitle,
                          const QString &body, const QVariantMap &options)
{
    // The frontend's icon names the question (src/camera.c, screenshot.c, location.c, wallpaper.c, background.c of
    // xdg-desktop-portal 1.22.1): a symbolic icon name, nothing else.
    static const QRegularExpression iconName(QStringLiteral("^[A-Za-z0-9_.-]{1,128}$"));
    QString icon = stringOption(options, QStringLiteral("icon"));
    if (!iconName.match(icon).hasMatch())
        icon.clear();
    // macOS asks about the camera and screen recording with neither button the default: Return does nothing until a button
    // has the keyboard (AC2). (Its microphone question has no xdg-desktop-portal 1.22.1 counterpart: no icon for it here.)
    static const QSet<QString> noDefault{QStringLiteral("camera-web-symbolic"), QStringLiteral("applets-screenshooter-symbolic")};
    const auto label = [&](const char *key) {
        const QString text = chooser::oneLine(chooser::withoutMnemonic(stringOption(options, QLatin1String(key))));
        return frontendLabel(text) ? QString() : text;
    };
    return {
        {QStringLiteral("appId"), appId},
        {QStringLiteral("title"), inLanguage(chooser::oneLine(title))},
        {QStringLiteral("subtitle"), inLanguage(chooser::oneLine(subtitle))},
        {QStringLiteral("body"), inLanguage(chooser::oneLine(body))},
        {QStringLiteral("denyLabel"), label("deny_label")},
        {QStringLiteral("grantLabel"), label("grant_label")},
        {QStringLiteral("icon"), icon},
        {QStringLiteral("modal"), boolOption(options, QStringLiteral("modal"), true)},
        {QStringLiteral("parented"), parentWindow.startsWith(QLatin1String("wayland:")) && parentWindow.size() > 8},
        {QStringLiteral("noDefault"), noDefault.contains(icon)},
        {QStringLiteral("choices"), chooser::choicesToQml(chooser::parseChoices(options.value(QStringLiteral("choices"))))},
    };
}

void Access::handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                    const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    m_choices.insert(id, chooser::parseChoices(options.value(QStringLiteral("choices"))));
    if (!startUi(id))
        return;
    // The frontend's title names the application already ("Allow Example to Use the Camera?"): no line of its own.
    QVariantMap alert = toQml(appId, parentWindow, title, subtitle, body, options);
    // The application's icon (its desktop entry's Icon=: a theme name or a file, IconSource.js), "" when the frontend could
    // not name it or it has none: read on a worker (SP-18: a stale ksycoca is rebuilt there, never on the GUI thread inside
    // the alert's first-frame deadline), the alert made once it is known.
    whenAppKnown(id, [this, id, alert, appId]() mutable {
        alert.insert(QStringLiteral("appIcon"), appIcon(appId));
        emit opened(id, alert);
    });
}

void Access::answer(int id, bool grant, const QVariantList &choices)
{
    if (!isOpen(id))
        return;
    QVariantMap results;
    const QList<chooser::Pair> answered = chooser::answerChoices(m_choices.value(id), choices);
    if (!answered.isEmpty())
        results.insert(QStringLiteral("choices"), QVariant::fromValue(answered));
    finish(id, grant ? 0 : 1, results);
}

QVariantMap Access::relayed(const QVariantMap &gtkResults) const
{
    // The interface's one result: the choices (a(ss)), with their D-Bus type.
    const QVariantMap relayed = chooser::relayed(gtkResults);
    QVariantMap out;
    if (relayed.contains(QStringLiteral("choices")))
        out.insert(QStringLiteral("choices"), relayed.value(QStringLiteral("choices")));
    return out;
}

AccessAdaptor::AccessAdaptor(QObject *exported, Access *access)
    : QDBusAbstractAdaptor(exported)
    , m_access(access)
{
}

uint AccessAdaptor::AccessDialog(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                 const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message,
                                 QVariantMap &results)
{
    Q_UNUSED(results)
    m_access->handle(handle, app_id, parent_window, title, subtitle, body, options, message);
    return 2;
}

} // namespace grassfield::portal
