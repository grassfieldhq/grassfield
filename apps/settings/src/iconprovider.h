#pragma once

#include <QFileInfo>
#include <QIcon>
#include <QImage>
#include <QImageReader>
#include <QQuickImageProvider>

#include <memory>

#include "iconlookup.h"
#include "systemguard.h"

// image://icon/<name>: a desktop entry's Icon for Login Items and the application picker: a freedesktop icon name from the
// current icon theme (iconlookup.h), or an absolute path to a small regular raster file (systemguard.h isIconFile), decoded only
// in the format its extension names (Qt would otherwise pick the decoder by content: an SVG named .png, whose references QtSvg
// follows, is refused). An Image provider (SP-09): with AppIcon's `asynchronous: true` Qt Quick calls it on its image threads,
// so the theme lookup, the SVG rendering and the decoding of hundreds of rows never run on the GUI thread; the theme's name and
// search paths are read once here, on the GUI thread. An unknown icon is a 1 x 1 transparent image (a null one would log a
// warning per row): AppIcon.qml then shows its own tile.
class IconProvider : public QQuickImageProvider
{
public:
    IconProvider()
        : QQuickImageProvider(QQuickImageProvider::Image)
        , m_lookup(std::make_shared<grassfield::settings::IconLookup>(QIcon::themeSearchPaths(), QIcon::themeName(), QIcon::fallbackThemeName()))
    {
    }

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override
    {
        const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
        QString path;
        bool themed = false;
        if (!id.startsWith(QLatin1Char('/'))) {
            path = m_lookup->find(id, qMax(want.width(), want.height()));
            themed = true;
        } else if (grassfield::settings::isIconFile(id)) {
            path = id;
        }
        QImage image;
        if (!path.isEmpty()) {
            // A theme's own file may be an SVG (the themes are the system's or the user's, as QIcon reads them); a path from a
            // desktop entry is one of the raster formats isIconFile allows.
            QString format = QFileInfo(path).suffix().toLower();
            if (format == QLatin1String("jpeg"))
                format = QStringLiteral("jpg"); // i18n-ignore: an image format name
            if (themed || format != QLatin1String("svg")) {
                QImageReader reader(path, format.toLatin1());
                reader.setAutoDetectImageFormat(false);
                if (format == QLatin1String("svg")) {
                    const QSize natural = reader.size();
                    reader.setScaledSize(natural.isValid() && !natural.isEmpty() ? natural.scaled(want, Qt::KeepAspectRatio) : want);
                }
                image = reader.read();
                if (!image.isNull() && image.size() != want)
                    image = image.scaled(want, Qt::KeepAspectRatio, Qt::SmoothTransformation);
            }
        }
        if (image.isNull()) {
            image = QImage(1, 1, QImage::Format_ARGB32_Premultiplied);
            image.fill(Qt::transparent);
        }
        if (size)
            *size = image.size();
        return image;
    }

private:
    std::shared_ptr<grassfield::settings::IconLookup> m_lookup;
};
