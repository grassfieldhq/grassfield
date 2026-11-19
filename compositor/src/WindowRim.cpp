#include "WindowRim.hpp"

#include "Plugin.hpp"
#include "Titlebar.hpp"
#include "core/Theme.hpp"
#include "core/WindowRim.hpp"

#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include "HyprCompat.hpp"
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/BorderPassElement.hpp>

#include <algorithm>
#include <cmath>

namespace rim = gf::rim;

namespace {
    // The rim's width in points (token window.rimDarkWidth): Hyprland's border takes whole points and rounds them to device
    // pixels itself, as core rim::widthPx does.
    constexpr int kWidthPt = gf::theme::tokens::kWindowRimDarkWidth;

    // The window that was key when the rims were last drawn for it (its rim is drawn again when it loses that).
    PHLWINDOWREF& lastActive() {
        static PHLWINDOWREF window;
        return window;
    }

    // Hyprland draws this window's edges: mapped and shown, not an X11 window that wants no border, decorations allowed.
    bool edged(const PHLWINDOW& w) {
        if (!gf::compat::mapped(w) || w->isHidden())
            return false;
        if (gf::compat::x11Borderless(w))
            return false;
        return !w->m_ruleApplicator || w->m_ruleApplicator->decorate().valueOrDefault();
    }

    rim::WindowState stateOf(const PHLWINDOW& w) {
        const auto& fs = Fullscreen::controller();
        return rim::WindowState{.appearance      = gf::state().appearance.current,
                                .appearanceKnown = gf::state().appearance.known,
                                .active          = Desktop::focusState() && Desktop::focusState()->window() == w,
                                .fullscreen      = fs && fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN,
                                .edged           = edged(w)};
    }

    void damageRimOf(const PHLWINDOW& w) {
        if (!w)
            return;
        for (auto* deco : gf::state().rims) {
            if (deco->window() == w)
                deco->damageEntire();
        }
    }
} // namespace

CGrassfieldRim::CGrassfieldRim(const PHLWINDOW& window) : CDecorationBase(window), m_owner(window) {
    gf::state().rims.push_back(this);
    damageBands(); // a rim added to a window already on screen (the plugin loaded) shows at once
}

CGrassfieldRim::~CGrassfieldRim() {
    std::erase(gf::state().rims, this);
    gf::forgetRegisteredDecoration(this);
}

PHLWINDOW CGrassfieldRim::window() const {
    return m_owner.lock();
}

SDecorationPositioningInfo CGrassfieldRim::getPositioningInfo() {
    // Inside the window: no extents, nothing reserved (the frame is the surface and the titlebar's reserved band).
    SDecorationPositioningInfo info;
    info.policy   = DECORATION_POSITION_ABSOLUTE;
    info.reserved = false;
    return info;
}

void CGrassfieldRim::onPositioningReply(const SDecorationPositioningReply& /*reply*/) {
    // The frame is read from the window and its titlebar when drawing.
}

eDecorationType CGrassfieldRim::getDecorationType() {
    return DECORATION_CUSTOM;
}

void CGrassfieldRim::updateWindow(PHLWINDOW /*window*/) {
    // Drawn from the window's state each frame; Hyprland damages the window when it moves or resizes.
}

eDecorationLayer CGrassfieldRim::getDecorationLayer() {
    // Over the surface (macOS lights the content's edge pixel), under the window's popups (menus are windows of their own).
    return DECORATION_LAYER_OVER;
}

uint64_t CGrassfieldRim::getDecorationFlags() {
    return 0; // no input, no extents of its own
}

std::string CGrassfieldRim::getDisplayName() {
    return "grassfield-rim";
}

std::optional<CBox> CGrassfieldRim::frameBox() const {
    const auto w = window();
    if (!w)
        return std::nullopt;
    const CBox surface = w->getWindowMainSurfaceBox();
    const auto frame   = rim::frameOf(rim::Box{.x = surface.x, .y = surface.y, .w = surface.w, .h = surface.h}, CGrassfieldTitlebar::shownBarHeight(w));
    Vector2D   offset  = gf::compat::floatingOffset(w);
    if (w->m_workspace && !gf::compat::pinned(w))
        offset = offset + w->m_workspace->m_renderOffset->value();
    CBox box{frame.x, frame.y, frame.w, frame.h};
    box.translate(offset);
    return box;
}

void CGrassfieldRim::drawGf(PHLMONITOR monitor, float alpha) {
    gf::guarded("rim draw", [&] {
        const auto w = window();
        if (!w || !monitor || !g_pHyprRenderer)
            return;
        const auto perPt = rim::opacityPerPt(stateOf(w));
        if (!perPt)
            return;
        auto frame = frameBox();
        if (!frame)
            return;
        frame->translate(-monitor->m_position);
        const float scale = monitor->m_scale;
        const auto  ring  = rim::ring(rim::snap(rim::Box{.x = frame->x, .y = frame->y, .w = frame->w, .h = frame->h}, scale),
                                      gf::titlebar::windowCornerPx(gf::compat::rounding(w), scale), kWidthPt, scale);
        if (!ring.valid)
            return; // also keeps Hyprland's renderBorder from an empty box, which it asserts against

        CBorderPassElement::SBorderData data;
        data.box           = CBox{ring.inner.x, ring.inner.y, ring.inner.w, ring.inner.h};
        data.grad1         = Config::CGradientValueData(CHyprColor{1.F, 1.F, 1.F, static_cast<float>(rim::pixelOpacity(*perPt, kWidthPt, scale))});
        data.a             = alpha;
        data.round         = ring.round;
        data.outerRound    = ring.outerRound;
        data.roundingPower = gf::compat::roundingPower(w);
        data.borderSize    = ring.borderPt;
        data.window        = w;
        gf::compat::addPassElement(makeUnique<CBorderPassElement>(data));
    });
}

void CGrassfieldRim::damageEntire() {
    damageBands();
}

void CGrassfieldRim::damageBands() const {
    gf::guarded("rim damageBands", [this] {
        const auto w = window();
        if (!w || !g_pHyprRenderer)
            return;
        const auto frame = frameBox();
        if (!frame || frame->w <= 0 || frame->h <= 0)
            return;
        // The four sides with their corner arcs: the rim is never further in than the corner radius.
        const double band = std::max(0.0, static_cast<double>(gf::compat::rounding(w))) + 2.0;
        const CBox&  f    = *frame;
        g_pHyprRenderer->damageBox(CBox{f.x - 1, f.y - 1, f.w + 2, band + 1});
        g_pHyprRenderer->damageBox(CBox{f.x - 1, f.y + f.h - band, f.w + 2, band + 1});
        g_pHyprRenderer->damageBox(CBox{f.x - 1, f.y - 1, band + 1, f.h + 2});
        g_pHyprRenderer->damageBox(CBox{f.x + f.w - band, f.y - 1, band + 1, f.h + 2});
    });
}

void CGrassfieldRim::onActiveWindowChanged(const PHLWINDOW& window) {
    gf::guarded("rim onActiveWindowChanged", [&] {
        const auto previous = lastActive().lock();
        lastActive()        = window;
        if (!gf::state().appearance.known || gf::state().appearance.current != gf::theme::Appearance::Dark)
            return; // no rim to change
        damageRimOf(previous);
        if (window != previous)
            damageRimOf(window);
    });
}

void CGrassfieldRim::resetGlobals() {
    gf::guarded("rim resetGlobals", [] { lastActive() = PHLWINDOWREF{}; });
}

void CGrassfieldRim::onAppearanceChanged() {
    gf::guarded("rim onAppearanceChanged", [] {
        for (auto* deco : gf::state().rims)
            deco->damageEntire();
    });
}
