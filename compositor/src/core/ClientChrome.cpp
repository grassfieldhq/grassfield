#include "ClientChrome.hpp"

#include <algorithm>

namespace gf::chrome {

    bool hasClientChromeTag(const std::set<std::string>& tags) {
        return std::ranges::any_of(tags, [](const std::string& tag) {
            std::string_view name = tag;
            if (name.ends_with('*'))
                name.remove_suffix(1);
            return name == kTag;
        });
    }

    double band(bool clientChrome) {
        return clientChrome ? 0.0 : theme::kTitlebarHeight;
    }

    double band(bool clientChrome, bool splitMember) {
        return splitMember ? 0.0 : band(clientChrome);
    }

    bool drawsOwnTitlebar(const DecorationRequest& request) {
        if (request.xdgObject)
            return request.xdgRequested == kXdgModeClientSide;
        if (request.kdeObject)
            return request.kdeRequested == kKdeModeClient;
        return true; // negotiated nothing: it decorates itself (xdg-decoration's and KDE's rule)
    }

    TagChange tagChange(bool drawsOwn, bool tagged, bool ours) {
        if (drawsOwn)
            return tagged ? TagChange::None : TagChange::Add;
        return ours && tagged ? TagChange::Remove : TagChange::None;
    }

    std::vector<uint32_t> wmCapabilities(bool clientChrome, bool minimizeBridged) {
        std::vector<uint32_t> caps{kCapFullscreen, kCapMaximize};
        if (clientChrome && minimizeBridged)
            caps.push_back(kCapMinimize);
        return caps;
    }

    bool capabilityCandidate(std::string_view interfaceName, int version, bool hasUserData) {
        return interfaceName == "xdg_toplevel" && version >= static_cast<int>(kWmCapabilitiesSince) && hasUserData;
    }

    bool toplevelCandidate(std::string_view interfaceName, bool hasUserData) {
        return interfaceName == "xdg_toplevel" && hasUserData;
    }

    bool needsTell(const CapabilityTell& tell, bool withMinimize) {
        return !tell.unreachable && withMinimize != tell.minimizeTold;
    }

    bool moveAnswersPress(const std::optional<ZoomedPress>& press, uint64_t window, bool buttonHeld, uint64_t nowMs) {
        if (!press || press->window == 0 || press->window != window || !buttonHeld)
            return false;
        return nowMs >= press->timeMs && nowMs - press->timeMs <= kMovePressMaxAgeMs;
    }

    titlebar::Rect unzoomedBox(const ZoomedPress& press, double restoredW, double restoredH, double pointerX, double pointerY) {
        return titlebar::unzoomedDragBox(press.zoomed, restoredW, restoredH, press.x, press.y, pointerX, pointerY);
    }

    ZoomAction zoomAction(bool maximized, bool fullscreen, bool altHeld) {
        if (fullscreen)
            return ZoomAction::LeaveFullscreen;
        if (altHeld)
            return ZoomAction::EnterFullscreen;
        return maximized ? ZoomAction::Unzoom : ZoomAction::Zoom;
    }

    bool zoomGlyphIsArrows(bool altHeld, bool fullscreen) {
        return altHeld || fullscreen;
    }

    bool nextRevealed(bool revealed, const RevealInput& in) {
        if (!in.revealable)
            return false;
        if (in.pressing)
            return revealed; // a press on a light is decided at its release, over the bar; a member's drag holds its bar
        if (!in.onMonitor || in.pointerY < 0.0)
            return false;
        const bool onBand = in.pointerY < in.barTop + theme::kTitlebarHeight + kRevealSlack;
        if (revealed)
            return onBand && !in.overOther; // across the gap between the halves too, until the other half
        return in.inSpan && (in.pointerY <= kRevealEdge || (in.handOver && onBand));
    }

    bool lightAvailableInFullscreen(titlebar::Button button) {
        return button != titlebar::Button::Minimize;
    }

    RevealedPress revealedPress(titlebar::HitTarget hit, bool memberInPlace) {
        if (const auto light = titlebar::buttonForHit(hit))
            return lightAvailableInFullscreen(*light) ? RevealedPress::ArmLight : RevealedPress::Nothing;
        return hit == titlebar::HitTarget::DragArea && memberInPlace ? RevealedPress::MemberDrag : RevealedPress::Nothing;
    }

    bool lightAvailable(titlebar::Button button, bool fullscreen, bool fixedSize, bool sized) {
        if (fullscreen && !lightAvailableInFullscreen(button))
            return false;
        return button != titlebar::Button::Zoom || !fixedSize || sized;
    }

    void CRevealPresses::onPress(uint32_t button, bool onBar) {
        m_owed.erase(button);
        if (onBar)
            m_owed.insert(button);
    }

    bool CRevealPresses::takeRelease(uint32_t button) {
        return m_owed.erase(button) > 0;
    }

    bool CRevealPresses::pressing() const {
        return !m_owed.empty();
    }

    void CRevealPresses::reset() {
        m_owed.clear();
    }

    void CHeldButtons::observe(uint32_t button, bool pressed) {
        if (pressed)
            m_held.insert(button);
        else
            m_held.erase(button);
    }

    bool CHeldButtons::mayTake(uint32_t button, bool hyprlandHoldsNone) {
        if (hyprlandHoldsNone) {
            m_held.clear();
            m_known = true;
        }
        return m_known && !m_held.contains(button);
    }

    bool CHeldButtons::known() const {
        return m_known;
    }

    bool ownsMaximize(bool ready, bool windowTiling, bool clientChrome) {
        return ready && windowTiling && clientChrome;
    }

    bool maximizeEcho(uint64_t armedAtMs, uint64_t nowMs) {
        return armedAtMs != 0 && nowMs >= armedAtMs && nowMs - armedAtMs <= kMaximizeEchoMs;
    }

    void CHeldButtons::reset() {
        m_held.clear();
        m_known = false;
    }

} // namespace gf::chrome
