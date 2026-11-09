#include "WindowTransform.hpp"

#include "CapturePrivacy.hpp"
#include "Plugin.hpp"
#include "core/CapturePrivacy.hpp"
#include "core/Overview.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/render/Renderer.hpp>

namespace gf::transform {

    Box toBox(const CBox& b) {
        return Box{b.x, b.y, b.w, b.h};
    }

    CBox toCBox(const Box& b) {
        return CBox{b.x, b.y, b.w, b.h};
    }

    bool hasArea(const Box& b) {
        return b.w > 0 && b.h > 0;
    }

    Box surfaceBox(const PHLWINDOW& w) {
        return toBox(w->getWindowMainSurfaceBox());
    }

    Vector2D renderOffset(const PHLWINDOW& w) {
        Vector2D off = w->m_floatingOffset;
        if (!w->m_pinned && w->m_workspace && w->m_workspace->m_renderOffset)
            off = off + w->m_workspace->m_renderOffset->value();
        return off;
    }

    namespace {
        Box translated(const Box& b, const Vector2D& by) {
            return Box{b.x + by.x, b.y + by.y, b.w, b.h};
        }

        // Hyprland leaves the render damage at the window's own box once it has rendered the window into the work buffer
        // (CRenderPass::render stores its damage). Clears and draws here must cover the whole buffer: a work buffer keeps
        // the content of its previous use, and the composite samples all of it. The damage is restored afterwards.
        class CWholeBufferDamage {
          public:
            explicit CWholeBufferDamage(const PHLMONITOR& mon) : m_saved(g_pHyprRenderer->m_renderData.damage.copy()) {
                g_pHyprRenderer->m_renderData.damage = CRegion{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y};
            }
            ~CWholeBufferDamage() {
                g_pHyprRenderer->m_renderData.damage = m_saved;
            }
            CWholeBufferDamage(const CWholeBufferDamage&)            = delete;
            CWholeBufferDamage& operator=(const CWholeBufferDamage&) = delete;
            CWholeBufferDamage(CWholeBufferDamage&&)                 = delete;
            CWholeBufferDamage& operator=(CWholeBufferDamage&&)      = delete;

          private:
            CRegion m_saved;
        };
    } // namespace

    Box fullBox(const PHLWINDOW& w) {
        CBox box = w->getWindowMainSurfaceBox();
        box.addExtents(w->getWindowExtentsUnified(Desktop::View::FULL_EXTENTS | Desktop::View::RESERVED_EXTENTS));
        return toBox(box.expand(2.0));
    }

    Box visualBox(const PHLWINDOW& w, const Box& rect) {
        const Box surface = surfaceBox(w);
        return translated(gf::minimize::mapBox(fullBox(w), surface, gf::overview::drawBox(surface, rect)), renderOffset(w));
    }

    bool monitorFrame() {
        return g_pHyprRenderer && !g_pHyprRenderer->m_bRenderingSnapshot && g_pHyprRenderer->m_renderData.projectionType == Render::RPT_MONITOR;
    }

    SP<Render::IFramebuffer> drawFitted(const PHLWINDOW& w, const Box& rect, const SP<Render::IFramebuffer>& in, bool& warnedNoBuffer, uint64_t address) {
        if (!in || !w || !g_pHyprRenderer)
            return in;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        const auto tex = in->getTexture();
        if (!mon || !tex)
            return drawNothing(in); // as nothing where possible (drawNothing needs the monitor), never at its real place
        // resources() is a weak reference to a unique pointer: it must not be lock()ed (hyprutils aborts), only checked and
        // dereferenced, as Hyprland's own drawTransformedWindow does.
        const auto resources = mon->resources();
        auto       out       = resources && !resources.expired() ? resources->getUnusedWorkBuffer() : nullptr;
        if (!out) {
            // Never at its real place: a Stages strip window is hidden there (and input-blocked), an overview window is
            // laid out elsewhere. It is drawn as nothing for this frame.
            if (!warnedNoBuffer)
                gf::log(Log::WARN, "window transform: no free work buffer; window {:x} not drawn this frame", address);
            warnedNoBuffer = true;
            return drawNothing(in);
        }

        // The whole buffer is drawn scaled and moved so that the window's surface box lands on its rect (same math as the
        // minimize snapshot, on the same monitor). Decorations and shadow scale with it.
        const Box                             surface = surfaceBox(w);
        const auto                            off     = renderOffset(w);
        const Box                             src     = translated(surface, off);
        const Box                             dst     = translated(gf::overview::drawBox(surface, rect), off);
        const gf::minimize::SSnapshotGeometry geometry{.visible      = src,
                                                       .monitorX     = mon->m_position.x,
                                                       .monitorY     = mon->m_position.y,
                                                       .monitorScale = mon->m_scale,
                                                       .texW         = mon->m_transformedSize.x,
                                                       .texH         = mon->m_transformedSize.y};
        const Box texBox = gf::minimize::textureBox(geometry, dst, mon->m_position.x, mon->m_position.y, mon->m_scale);
        // SEC-01: Hyprland blacks out a window hidden from captures at its real place only, never here
        // (core/CapturePrivacy.hpp). While this display is captured the miniature's surface is a black plate, on screen
        // too; without a plate the window is drawn as nothing.
        const bool hidden = !gf::capturePrivacy::mayDrawContent(w, mon);
        const Box  plate  = hidden ? gf::privacy::platePx(dst, mon->m_position.x, mon->m_position.y, mon->m_scale) : Box{};
        const CRegion bufferRegion{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y};

        const CWholeBufferDamage whole{mon};
        const auto               guard = g_pHyprRenderer->bindTempFB(out);
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        if (hidden && !hasArea(plate))
            return out;
        CTexPassElement::SRenderData data;
        data.tex = tex;
        data.box = toCBox(texBox);
        data.a   = 1.F;
        g_pHyprRenderer->draw(data, bufferRegion);
        if (hidden) {
            CRectPassElement::SRectData black;
            black.box   = toCBox(plate);
            black.color = CHyprColor(0, 0, 0, 1);
            g_pHyprRenderer->draw(black, bufferRegion);
        }
        return out;
    }

    SP<Render::IFramebuffer> drawNothing(const SP<Render::IFramebuffer>& in) {
        if (!in || !g_pHyprRenderer)
            return in;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return in;
        const CWholeBufferDamage whole{mon};
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        return in;
    }

} // namespace gf::transform
