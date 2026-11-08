// Qt platform-theme plugin keyed "grassfield" (ADR-0054). Qt's xdgdesktopportal theme sends QFileDialog to the desktop
// portal (Grassfield's Open and Save panels) and takes its base theme (palette, font, colour scheme, icons) from the
// first item of XDG_CURRENT_DESKTOP, lower-cased, which is "grassfield" in this session. This plugin answers that name
// with Qt's own gtk3 theme, so the look the session had under QT_QPA_PLATFORMTHEME=gtk3 (owner decision Q3) is kept.
// QPA is private API: this file builds against Qt's private headers and is rebuilt with every Qt minor release.
#include <QtCore/QLoggingCategory>
#include <QtCore/QStringList>
#include <qpa/qplatformtheme.h>
#include <qpa/qplatformthemefactory_p.h>
#include <qpa/qplatformthemeplugin.h>

Q_LOGGING_CATEGORY(lcGrassfieldTheme, "grassfield.platformtheme")

class GrassfieldThemePlugin : public QPlatformThemePlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QPlatformThemeFactoryInterface_iid FILE "grassfield-theme.json")

public:
    QPlatformTheme *create(const QString &key, const QStringList &) override
    {
        if (key.compare(QLatin1String("grassfield"), Qt::CaseInsensitive) != 0) {
            return nullptr;
        }
        QPlatformTheme *base = QPlatformThemeFactory::create(QStringLiteral("gtk3"));
        if (base == nullptr) {
            // Never silent: Qt then goes on to its generic theme (Fusion, "Sans Serif 9"). The usual cause is the
            // absence of a GDK display, as offscreen or on a bare TTY.
            qCWarning(lcGrassfieldTheme) << "Qt's gtk3 platform theme did not load; the base theme falls back to Qt's generic one";
        }
        return base;
    }
};

#include "GrassfieldThemePlugin.moc"
