// SPDX-License-Identifier: MIT
// A frameless Qt window (Qt::FramelessWindowHint) for tests/compositor/frameless_chrome.sh, the rc7 audit's R7-REQ-01 case.
// QtWayland binds the xdg-decoration manager and makes no decoration object for a frameless window, whatever it draws, so the
// negotiation alone cannot tell the two kinds apart:
//   frameless TITLE                 draws nothing but its colour: no title bar, no controls (the window the plugin must give
//                                   its titlebar);
//   frameless --own-bar N TITLE     draws its own title bar with three lights and an N px shadow around the window, and tells
//                                   QtWayland about the shadow through its custom margins (QNativeInterface::Private::
//                                   QWaylandWindow::setCustomMargins), which QtWayland turns into an xdg window geometry inside
//                                   the surface; while maximized or in full screen it drops the shadow and the margins. That
//                                   is what Telegram Desktop's lib_ui does for its own title bar (ui/platform/linux/
//                                   ui_utility_linux.cpp SetWindowMargins; ui/platform/ui_platform_window.cpp
//                                   DefaultWindowHelper::updateWindowMargins and resizeArea; read as data, 2026-11-08).
// Built by frameless_chrome.sh into .dev/tools/ (Qt 6 Gui and its private headers; no moc). Never run it on the owner's
// session: the test starts it on the verified nested socket only.
#include <QColor>
#include <QGuiApplication>
#include <QMargins>
#include <QPainter>
#include <QRasterWindow>
#include <QSurfaceFormat>
#include <qpa/qplatformwindow_p.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
    constexpr int kWidth  = 420; // the window, without its shadow (layout px)
    constexpr int kHeight = 260;
    constexpr int kBar    = 36; // its own title bar

    class CFramelessWindow final : public QRasterWindow {
      public:
        explicit CFramelessWindow(int shadow) : m_shadow(shadow), m_inset(shadow) {}

        // The shadow and the custom margins, dropped while maximized or in full screen (lib_ui's resizeArea).
        bool applyMargins() {
            if (m_shadow == 0)
                return true;
            auto* native = nativeInterface<QNativeInterface::Private::QWaylandWindow>();
            if (!native)
                return false;
            const bool sized = (windowStates() & (Qt::WindowMaximized | Qt::WindowFullScreen)) != 0;
            m_inset          = sized ? 0 : m_shadow;
            native->setCustomMargins(QMargins(m_inset, m_inset, m_inset, m_inset));
            update();
            return true;
        }

      protected:
        void paintEvent(QPaintEvent* /*event*/) override {
            QPainter p(this);
            p.setCompositionMode(QPainter::CompositionMode_Source);
            p.fillRect(QRect(QPoint(0, 0), size()), QColor(0, 0, 0, m_inset > 0 ? 48 : 0));
            const QRect body = QRect(QPoint(0, 0), size()).marginsRemoved(QMargins(m_inset, m_inset, m_inset, m_inset));
            p.fillRect(body, QColor(0x3a, 0x6e, 0xa5));
            if (m_shadow == 0)
                return; // draws nothing else: no bar, no controls
            p.setCompositionMode(QPainter::CompositionMode_SourceOver);
            p.fillRect(QRect(body.topLeft(), QSize(body.width(), kBar)), QColor(0xe8, 0xe8, 0xe8));
            p.setRenderHint(QPainter::Antialiasing);
            const QColor lights[] = {QColor(0xff, 0x5f, 0x57), QColor(0xfe, 0xbc, 0x2e), QColor(0x28, 0xc8, 0x40)};
            int          x        = body.left() + 12;
            for (const QColor& c : lights) {
                p.setBrush(c);
                p.setPen(Qt::NoPen);
                p.drawEllipse(QRect(x, body.top() + (kBar - 12) / 2, 12, 12));
                x += 20;
            }
        }

      private:
        int m_shadow = 0; // the shadow asked for (0: a window that draws nothing)
        int m_inset  = 0; // the shadow drawn now
    };
} // namespace

int main(int argc, char** argv) {
    int         shadow = 0;
    const char* title  = nullptr;
    if (argc == 2) {
        title = argv[1];
    } else if (argc == 4 && std::strcmp(argv[1], "--own-bar") == 0) {
        char*      end = nullptr;
        const long v   = std::strtol(argv[2], &end, 10);
        if (!end || *end != '\0' || v < 1 || v > 64) {
            std::fprintf(stderr, "frameless: the shadow must be 1-64 px\n");
            return 2;
        }
        shadow = static_cast<int>(v);
        title  = argv[3];
    } else {
        std::fprintf(stderr, "usage: frameless [--own-bar SHADOW_PX] TITLE\n");
        return 2;
    }
    QGuiApplication  app(argc, argv);
    CFramelessWindow window(shadow);
    QSurfaceFormat   format = window.format();
    format.setAlphaBufferSize(8);
    window.setFormat(format);
    window.setFlags(Qt::Window | Qt::FramelessWindowHint);
    window.setTitle(QString::fromLocal8Bit(title));
    window.resize(kWidth + 2 * shadow, kHeight + 2 * shadow);
    window.create();
    if (!window.applyMargins()) {
        std::fprintf(stderr, "frameless: not a QtWayland window (QT_QPA_PLATFORM=wayland needed)\n");
        return 1;
    }
    QObject::connect(&window, &QWindow::windowStateChanged, &window, [&window](Qt::WindowState /*state*/) { window.applyMargins(); });
    window.show();
    std::printf("READY\n");
    std::fflush(stdout);
    return QGuiApplication::exec();
}
