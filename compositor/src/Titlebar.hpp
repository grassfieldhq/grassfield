#pragma once

// Grassfield titlebar: a window decoration with close / minimize / zoom buttons and a centered title.
// Geometry and hit-testing live in core/TitlebarLayout.* (no Hyprland dependency).

#include "core/TitlebarLayout.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>

#include <array>
#include <optional>
#include <string>

namespace Render {
    class ITexture;
}

class CGrassfieldTitlebar : public IHyprWindowDecoration {
  public:
    explicit CGrassfieldTitlebar(const PHLWINDOW& window);
    ~CGrassfieldTitlebar() override;

    CGrassfieldTitlebar(const CGrassfieldTitlebar&)            = delete;
    CGrassfieldTitlebar& operator=(const CGrassfieldTitlebar&) = delete;

    SDecorationPositioningInfo getPositioningInfo() override;
    void                       onPositioningReply(const SDecorationPositioningReply& reply) override;
    void                       draw(PHLMONITOR monitor, float const& alpha) override;
    eDecorationType            getDecorationType() override;
    void                       updateWindow(PHLWINDOW window) override;
    void                       damageEntire() override;
    bool                       onInputOnDeco(const eInputType type, const Vector2D& coords, std::any data = {}) override;
    eDecorationLayer           getDecorationLayer() override;
    uint64_t                   getDecorationFlags() override;
    std::string                getDisplayName() override;

    PHLWINDOW                  window() const;

    // Floating, not full screen, decorations allowed by window rules, and not a window that draws its own chrome (the
    // Hyprland tag grassfield-client-chrome, ADR-0015 P1: re-evaluated on window.updateRules, never decorate = false). Not a
    // Split View member either (tiling.md TL33, step 6e, ADR-0036 D73): its bar is away, revealed at the top edge (P6).
    bool shouldShow() const;

    // Re-evaluates visibility (floating / full screen / rule changes) and requests new extents if needed.
    void refresh();

    // refresh() of `w`'s titlebar, if it has one: the tiler calls it when `w` joins or leaves a Split View Desktop (its bar
    // goes away or comes back, D73).
    static void refreshWindow(const PHLWINDOW& w);

    // Window title changed: the cached title texture is rebuilt on the next draw.
    void onTitleChanged();

    // The titlebar is shown and its bar contains `pos` (global layout coordinates, the pointer's space).
    bool barContains(const Vector2D& pos) const;

    // The titlebar is shown and `pos` (global layout coordinates) is over its group of lights (hover glyphs).
    bool buttonGroupContains(const Vector2D& pos) const;

    // Global pointer button listener (Event::bus()->m_events.input.mouse.button), called before any
    // titlebar or client sees the event; it never cancels it. Tracks press ownership (so a titlebar
    // consumes only the releases of presses a titlebar consumed) and ends gestures (drag, armed button)
    // on their release or on a new press.
    static void onGlobalMouseButton(const IPointer::SButtonEvent& e);

    // Global pointer motion listener (Event::bus()->m_events.input.mouse.move): moves a dragged window,
    // or cancels the gesture when no button is held any more or the pressing device may be gone; tracks which
    // titlebar's lights the pointer is over (their glyphs show, macOS).
    static void onGlobalMouseMove();

    // The session lock (g_pSessionLockManager's lock and unlock events; tiling.md TL22, D24): either ends the zoom light's hover
    // and forgets the light under the pointer; the unlock then looks at that light again from the event loop (after Hyprland's
    // own handling: its lock gone), so a pointer resting on a light through the lock gives a hover after the delay, unmoved.
    static void onSessionLock(bool locked);

    // Drops any gesture and press ownership (plugin unload).
    static void cancelPointerGrab();

    // Window focus listener (Event::bus()->m_events.window.active): the lights of the window that lost the focus turn grey,
    // those of the newly active one take their colours (macOS).
    static void onActiveWindowChanged(const PHLWINDOW& window);

    // The appearance changed (config "appearance", audit UX-06): every titlebar is drawn again in its palette.
    static void onAppearanceChanged();

    // Keyboard listener (Event::bus()->m_events.input.keyboard.key, observed only): the lights under the pointer are drawn
    // again, so that their zoom glyph follows Alt (the full-screen arrows while it is held, ADR-0015 P6).
    static void onKey();

    // P6, the titlebar of a full-screen window (macOS; core gf::chrome::nextRevealed): away in full screen, revealed by the
    // pointer at the top edge of the window's monitor, below the shell's menu bar, over the window's content. Hyprland draws
    // no decoration on a full-screen window and its decoration input sits above the window, outside the monitor: the
    // revealed bar is drawn from the render stage and takes its presses from the bus.
    // A Split View member's bar alike (tiling.md TL33, step 6e, ADR-0036 D74): the pointer at the top edge over its half
    // reveals it, over that half alone; while it is there, the pointer moving across within the bar's band brings the other
    // half's instead.
    // Pointer motion (and a change of the window) re-evaluates it.
    static void updateReveal();
    // RENDER_POST_WINDOWS (after the windows, before the overlay layers: the menu bar stays above it): the revealed
    // titlebars on the monitor being rendered.
    static void drawRevealed();
    // TL30, TL34: the desktop under `pos` is covered for the plugin's pointer affordances (the zoom light's hover, the
    // shared-edge handle): the session is locked, a foreign Exclusive layer is mapped, or a Top or Overlay layer (or a layer
    // popup) is under the point (core hoverCoverEffect is not None). Read only.
    static bool pointerCovered(const Vector2D& pos);
    // A pointer button, before Hyprland handles it: true when it is a press on a revealed titlebar or the release of such
    // a press, which the caller cancels on the bus (core gf::chrome::CRevealPresses: Hyprland's held-button state is not
    // touched by a cancelled press and its cancelled release). The zoom light leaves full screen, close closes; minimize
    // is unavailable in full screen. On a Split View member's revealed bar (step 6e, ADR-0036 D75) the zoom light leaves the
    // Split View, minimize is unavailable (D56), and a left press away from the lights starts the member's drag (D59): the
    // window follows the pointer with its bar; released over the other half the two swap halves, anywhere else, or ended
    // by another press, it goes back in its half.
    static bool onRevealedBarButton(const IPointer::SButtonEvent& e);

    // The titlebar of this full-screen window (or Split View member) is revealed.
    bool revealed() const;

    // The height of `w`'s titlebar while it is drawn above the surface (shown, and placed by the positioner), 0 otherwise
    // (client chrome, a window that is not floating, full screen, a Split View member): the window rim's frame
    // (WindowRim.cpp) starts at its top.
    static double shownBarHeight(const PHLWINDOW& w);

    // TL22, TL24 (docs/specs/tiling.md): the zoom light of `w` in global layout coordinates: its titlebar's while the bar is
    // shown or revealed, or the light a Grassfield app draws itself (the client-chrome tag on an org.grassfield.* window,
    // its row named by its xdg-toplevel tag: "info" the titlebar row, any other role the unified toolbar row); nullopt for
    // any other window (third-party client chrome: no popover on hover).
    static std::optional<CBox> zoomLightOf(const PHLWINDOW& w);

    // hl.plugin.grassfield.tile_popover(address) (TL26): a tile-hover "open" event for that window, with its zoom light, or
    // the top-left corner of its frame when it has no known light. Untrusted: the address is compared with the live windows.
    static void popoverRequest(std::string_view address);

  private:
    CBox layoutBox() const; // titlebar box in global logical (layout) coordinates
    CBox revealBox() const; // the revealed bar of a full-screen window or member, global logical coordinates (P6, D74)
    CBox barBox() const;    // revealBox() while revealed, layoutBox() otherwise
    bool barShown() const;  // revealed, or shouldShow()
    // Mapped, not hidden, decorations allowed, not an X11 window without borders, not a client-chrome window.
    bool titlebarAllowed() const;
    // The window is in full screen or a Split View member (D74), on a visible workspace, drawn in place, and may have a
    // titlebar.
    bool revealable() const;
    void damageRevealed();
    // A member's drag by its revealed bar ends (D75): where its bar hung above the window is drawn again, the gesture goes and
    // the member is dropped at `at` (gf::tiler::memberDrop: over the other half they swap; nullopt: back in its half).
    static void endRevealedDrag(std::optional<Vector2D> at);
    // Background, lights, glyphs and title on `bar` (monitor-local logical coordinates) on `monitor`, the display being
    // drawn; `fullscreen`: a revealed bar. No title for a window hidden from captures while that display is captured (SEC-01).
    void drawBar(const PHLMONITOR& monitor, const PHLWINDOW& w, const CBox& bar, float scale, double rounding, float power, float alpha, bool hovered,
                 bool fullscreen);
    bool onButtonPress(const Vector2D& coords, const IPointer::SButtonEvent& e);
    void activate(gf::titlebar::Button button);
    void drawTitlebar(const PHLMONITOR& monitor, float alpha);
    // The tiling preview of a drag of this window (gf::tiler::previewOf), under the window and over the windows behind it;
    // also for a window whose bar is hidden (client chrome: Hyprland's move, tiling.md TL16).
    void drawPreview(const PHLMONITOR& monitor, float alpha);
    // The glyphs over the lights; `bar` in monitor-local logical coordinates. `fullscreen`: the zoom light shows the arrows
    // and minimize none (unavailable); `fixedSize` and `sized`: a window of fixed size neither zoomed nor in full screen shows
    // no zoom glyph (its light is disabled, core lightAvailable).
    void drawGlyphs(const CBox& bar, float scale, float alpha, bool fullscreen, bool fixedSize, bool sized);
    // The content's own pixels in the surface's rounded top corners (under the surface), when its texture maps 1:1 and,
    // for a window hidden from captures, while `monitor` is not captured (SEC-01: outside the box Hyprland blacks out).
    void drawContentCorners(const PHLMONITOR& monitor, const PHLWINDOW& w, const CBox& bar, double rounding, float scale, float alpha);

    PHLWINDOWREF                m_owner;
    bool                        m_lastShown = false;
    bool                        m_revealed  = false; // P6: the full-screen window's titlebar is revealed
    gf::titlebar::CClickTracker m_clicks;

    struct {
        SP<Render::ITexture> texture;
        std::string          text;
        float                scale      = 0.F;
        int                  maxWidthPx = 0;
        gf::theme::Appearance appearance = gf::theme::kDefaultAppearance; // the title colour is in the texture
    } m_title;

    // One glyph texture per light (kButtonOrder), built on the first hover at a given size and scale.
    struct SGlyph {
        SP<Render::ITexture> texture;
        int                  sizePx = 0;
        float                scale  = 0.F;
        bool                 arrows = false; // the zoom light's full-screen arrows (Alt held) instead of its +
    };
    std::array<SGlyph, gf::titlebar::kButtonOrder.size()> m_glyphs;
};
