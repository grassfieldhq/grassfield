#include "WindowTransform.hpp"

#include "CapturePrivacy.hpp"
#include "Plugin.hpp"
#include "core/CapturePrivacy.hpp"
#include "core/Overview.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/Color.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/output/MonitorResources.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

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

        // Sets the render damage for the draws below and restores it afterwards. Hyprland leaves the render damage at the
        // window's own box once it has rendered the window into its work buffer (CRenderPass::render stores its damage).
        class CDamageOverride {
          public:
            explicit CDamageOverride(const CRegion& damage) : m_saved(g_pHyprRenderer->m_renderData.damage.copy()) {
                g_pHyprRenderer->m_renderData.damage = damage;
            }
            ~CDamageOverride() {
                g_pHyprRenderer->m_renderData.damage = m_saved;
            }
            CDamageOverride(const CDamageOverride&)            = delete;
            CDamageOverride& operator=(const CDamageOverride&) = delete;
            CDamageOverride(CDamageOverride&&)                 = delete;
            CDamageOverride& operator=(CDamageOverride&&)      = delete;

          private:
            CRegion m_saved;
        };

        // WM-01, WM-02: the output buffers of the transforms. Hyprland composites a transformer's output over the whole frame
        // damage, so every pixel of it that is not the window must be transparent. A buffer of Hyprland's pool holds whatever
        // its previous use left: it had to be cleared whole, per window per frame (a monitor-sized clear for each strip
        // thumbnail and overview window). These buffers stay the plugin's while windows are transformed, and the plugin knows
        // what it left in each (`dirty`, the box it last drew): a frame clears that box and the new one, nothing else.
        // Taken from the monitor's pool (its format, size and colour description), at most kMaxScratch per monitor (a window
        // with blur is transformed twice in a frame: its content, then its blur matte, both alive until the composite); one
        // whose monitor's buffers changed (mode, format, colour description: compared with the monitor's blur buffer, made
        // with the pool's parameters) is dropped. Released (GL context current) when nothing is transformed any more.
        struct SScratch {
            PHLMONITORREF            monitor;
            SP<Render::IFramebuffer> fb;
            CBox                     dirty; // monitor pixels (the buffer's space) that may hold drawn pixels; empty: transparent
        };

        constexpr size_t kMaxScratch = 2;

        struct SScratchState {
            std::vector<SScratch> buffers;
            uint8_t               users = 0; // bits of EUser
        };

        // Constructed on first use inside a guarded call (R13). Emptied by release() before dlclose.
        SScratchState& scratchState() {
            static SScratchState s;
            return s;
        }

        bool fits(const SScratch& sc, const PHLMONITOR& mon) {
            const auto resources = mon->resources();
            if (!resources || resources.expired() || !resources->m_blurFB || !sc.fb)
                return false;
            const auto& ref = resources->m_blurFB;
            return sc.fb->m_size == ref->m_size && sc.fb->m_drmFormat == ref->m_drmFormat && sc.fb->imageDescription() == ref->imageDescription();
        }

        // A buffer of `mon` nothing else holds (Hyprland releases the previous window's output once it is composited), or a
        // new one from the pool (its content unknown: dirty whole). Only inside a frame (GL context current: a dropped
        // buffer is deleted here). Null when none can be had.
        SScratch* scratchFor(const PHLMONITOR& mon) {
            auto& all = scratchState().buffers;
            std::erase_if(all, [&mon](const SScratch& sc) {
                const auto m = sc.monitor.lock();
                return !m || !sc.fb || (m == mon && sc.fb.strongRef() == 1 && !fits(sc, mon));
            });
            size_t mine = 0;
            for (auto& sc : all) {
                if (sc.monitor.lock() != mon)
                    continue;
                ++mine;
                if (sc.fb.strongRef() == 1)
                    return &sc;
            }
            const auto resources = mon->resources();
            if (mine >= kMaxScratch || !resources || resources.expired())
                return nullptr;
            auto fb = resources->getUnusedWorkBuffer();
            if (!fb)
                return nullptr;
            all.push_back(SScratch{.monitor = mon, .fb = std::move(fb), .dirty = CBox{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y}});
            return &all.back();
        }

        // The pixels of `b` (monitor pixels, fractional) rounded outward: what a scissor of it touches, and more.
        Box outward(const Box& b) {
            const double x0 = std::floor(b.x), y0 = std::floor(b.y);
            return Box{x0, y0, std::ceil(b.x + b.w) - x0, std::ceil(b.y + b.h) - y0};
        }

        Box intersection(const Box& a, const Box& b) {
            const double x0 = std::max(a.x, b.x), y0 = std::max(a.y, b.y);
            const double x1 = std::min(a.x + a.w, b.x + b.w), y1 = std::min(a.y + a.h, b.y + b.h);
            return x1 > x0 && y1 > y0 ? Box{x0, y0, x1 - x0, y1 - y0} : Box{};
        }

        // Clears what `sc` holds (its dirty box) and `also`: the buffer is transparent there afterwards.
        void clearScratch(SScratch& sc, const Box& also) {
            CRegion region;
            if (hasArea(toBox(sc.dirty)))
                region.add(sc.dirty);
            if (hasArea(also))
                region.add(toCBox(also));
            sc.dirty = {};
            if (region.empty())
                return;
            const CDamageOverride damage{region};
            const auto            guard = g_pHyprRenderer->bindTempFB(sc.fb);
            g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        }

        // Draws the transformer's input `tex` at `texBox`, clipped to `drawn` (and a black plate there, SEC-01), into the
        // transparent `sc`; `drawn` is then what it holds.
        void drawInto(SScratch& sc, const SP<Render::ITexture>& tex, const Box& texBox, const Box& drawn, const std::optional<Box>& plate) {
            const CRegion         region{toCBox(drawn)};
            const CDamageOverride damage{region};
            const auto            guard = g_pHyprRenderer->bindTempFB(sc.fb);
            CTexPassElement::SRenderData data;
            data.tex = tex;
            data.box = toCBox(texBox);
            data.a   = 1.F;
            g_pHyprRenderer->draw(data, region);
            if (plate) {
                CRectPassElement::SRectData black;
                black.box   = toCBox(*plate);
                black.color = Colors::BLACK; // Hyprland's own box over a protected window (ScreenshareFrame.cpp renderMonitor)
                g_pHyprRenderer->draw(black, region);
            }
            sc.dirty = toCBox(drawn);
        }
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
        // (core/CapturePrivacy.hpp). While this display is captured the miniature's surface and subsurfaces are under a
        // black plate, on screen too (the bar above shows no title then: Titlebar.cpp); without a plate the window is
        // drawn as nothing.
        const bool hidden = !gf::capturePrivacy::mayDrawContent(w, mon);
        const Box  plate  = hidden ? gf::privacy::platePx(gf::privacy::miniatureCover(src, dst, gf::capturePrivacy::subsurfaceBoxes(w, src)), mon->m_position.x,
                                                          mon->m_position.y, mon->m_scale) :
                                     Box{};
        // What is drawn: the window with its decorations fitted at `rect`, in this monitor's pixels, and nothing beyond it
        // (the draws are clipped there, so the buffer holds nothing outside it). Off the monitor (a hidden strip): nothing.
        const Box     visual = gf::minimize::mapBox(fullBox(w), surface, gf::overview::drawBox(surface, rect));
        const Box     monPx{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y};
        const Box     visualPx{((visual.x + off.x - mon->m_position.x) * mon->m_scale) - 2.0, ((visual.y + off.y - mon->m_position.y) * mon->m_scale) - 2.0,
                           (visual.w * mon->m_scale) + 4.0, (visual.h * mon->m_scale) + 4.0};
        const Box     drawn = outward(intersection(intersection(visualPx, texBox), monPx));
        const bool    draws = hasArea(drawn) && !(hidden && !hasArea(plate));

        SScratch* sc = scratchFor(mon);
        if (!sc) {
            // Every scratch buffer of this monitor is in use: one of the pool's, cleared whole (its content is unknown).
            auto out = resources && !resources.expired() ? resources->getUnusedWorkBuffer() : nullptr;
            if (!out) {
                // Never at its real place: a Stages strip window is hidden there (and input-blocked), an overview window is
                // laid out elsewhere. It is drawn as nothing for this frame.
                if (!warnedNoBuffer)
                    gf::log(Log::WARN, "window transform: no free work buffer; window {:x} not drawn this frame", address);
                warnedNoBuffer = true;
                return drawNothing(in);
            }
            SScratch once{.monitor = mon, .fb = out, .dirty = toCBox(monPx)};
            clearScratch(once, {});
            if (draws)
                drawInto(once, tex, texBox, drawn, hidden ? std::optional<Box>{plate} : std::nullopt);
            return out;
        }
        clearScratch(*sc, draws ? drawn : Box{});
        if (draws)
            drawInto(*sc, tex, texBox, drawn, hidden ? std::optional<Box>{plate} : std::nullopt);
        return sc->fb;
    }

    SP<Render::IFramebuffer> drawNothing(const SP<Render::IFramebuffer>& in) {
        if (!in || !g_pHyprRenderer)
            return in;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return in;
        if (auto* sc = scratchFor(mon)) {
            clearScratch(*sc, {}); // usually nothing to clear: the buffer is transparent already
            return sc->fb;
        }
        const CDamageOverride whole{CRegion{0, 0, mon->m_transformedSize.x, mon->m_transformedSize.y}};
        g_pHyprRenderer->draw(CClearPassElement::SClearData{CHyprColor(0, 0, 0, 0)});
        return in;
    }

    void use(EUser user) {
        auto& s = scratchState();
        s.users = static_cast<uint8_t>(static_cast<unsigned>(s.users) | static_cast<unsigned>(user));
    }

    void release(EUser user) {
        auto& s = scratchState();
        s.users = static_cast<uint8_t>(static_cast<unsigned>(s.users) & ~static_cast<unsigned>(user));
        if (s.users != 0 || s.buffers.empty())
            return;
        if (g_pHyprRenderer && g_pHyprRenderer->type() == Render::IHyprRenderer::RT_GL && Render::GL::g_pHyprOpenGL)
            Render::GL::g_pHyprOpenGL->makeEGLCurrent(); // the buffers this releases last are deleted now
        s.buffers.clear();
    }

    CRegion frameDamage(const PHLMONITOR& mon) {
        return mon ? mon->m_damage.getBufferDamage(1) : CRegion{};
    }

    Box realBox(const PHLWINDOW& w) {
        return translated(fullBox(w), renderOffset(w));
    }

    bool touches(const CRegion& damage, const PHLMONITOR& mon, const Box& box) {
        if (!mon || !hasArea(box))
            return false;
        const double x0 = (box.x - mon->m_position.x) * mon->m_scale, y0 = (box.y - mon->m_position.y) * mon->m_scale;
        const double x1 = x0 + (box.w * mon->m_scale), y1 = y0 + (box.h * mon->m_scale);
        int         n     = 0;
        const auto* rects = pixman_region32_rectangles(damage.pixman(), &n);
        for (int i = 0; i < n; ++i) {
            if (rects[i].x1 < x1 && x0 < rects[i].x2 && rects[i].y1 < y1 && y0 < rects[i].y2)
                return true;
        }
        return false;
    }

} // namespace gf::transform
