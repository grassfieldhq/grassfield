#pragma once

// The dark appearance's light inner rim (ADR-0024 note 2026-11-03; core/WindowRim.hpp holds the geometry and the rules):
// a window decoration on Hyprland's OVER layer, so drawn right after the window's surface and under its popups, that adds
// one ring of Hyprland's border shader (CBorderPassElement) inside the window's frame: its surface, and the plugin's
// titlebar above it while that is shown. One per window, next to its titlebar (main.cpp decorate()); nothing reserved,
// no input. Without the plugin there is no rim (gate C2); the unload removes every rim and damages where it was.

#include "HyprCompat.hpp"
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>

#include <optional>
#include <string>

class CGrassfieldRim : public gf::compat::CDecorationBase {
  public:
    explicit CGrassfieldRim(const PHLWINDOW& window);
    ~CGrassfieldRim() override;

    CGrassfieldRim(const CGrassfieldRim&)            = delete;
    CGrassfieldRim& operator=(const CGrassfieldRim&) = delete;

    SDecorationPositioningInfo getPositioningInfo() override;
    void                       onPositioningReply(const SDecorationPositioningReply& reply) override;
    void                       drawGf(PHLMONITOR monitor, float alpha) override;
    eDecorationType            getDecorationType() override;
    void                       updateWindow(PHLWINDOW window) override;
    void                       damageEntire() override;
    eDecorationLayer           getDecorationLayer() override;
    uint64_t                   getDecorationFlags() override;
    std::string                getDisplayName() override;

    PHLWINDOW                  window() const;

    // The key window changed (Event::bus()->m_events.window.active): the rims of the window that lost it and of the one
    // that got it are drawn again (0.08 and 0.10 per point).
    static void onActiveWindowChanged(const PHLWINDOW& window);

    // The appearance changed (config "appearance"): every rim is drawn again, or goes (light).
    static void onAppearanceChanged();

    // Unload (main.cpp teardown, after every rim is removed): the rims' own globals as on a fresh load. Hyprland keeps an
    // unloaded plugin's library mapped, so a reload would otherwise find them as they were (the last key window).
    static void resetGlobals();

  private:
    // The frame in global layout coordinates as drawn now: the surface and its shown titlebar, at the window's animated
    // position, moved by its floating offset and its workspace's render offset (as Hyprland moves its border); nothing
    // without a window.
    std::optional<CBox> frameBox() const;

    // Damages the frame's four sides with their corner arcs, the only places the rim draws (damageEntire, and the
    // constructor, which must not call a virtual).
    void damageBands() const;

    PHLWINDOWREF m_owner;
};
