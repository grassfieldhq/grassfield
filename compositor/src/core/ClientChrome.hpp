#pragma once

// Windows that draw their own chrome (ADR-0015 "unified toolbar"; docs/specs/compositor.md "Plugin work item: client
// chrome"): Grassfield's apps draw their lights and toolbar themselves and tag their toplevel; the session rule
// gf-client-chrome (config/hypr/grassfield/windows.lua) turns that xdg tag into the Hyprland tag below, and the plugin
// steps aside for those windows. The rules here are pure (no Hyprland include): unit-tested in tests/ClientChromeTest.cpp.

#include "Theme.hpp"
#include "TitlebarLayout.hpp"

#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace gf::chrome {

    // The Hyprland tag of such windows. The shell's copy is shell/overview/ClientChrome.js (TAG): the plugin and the
    // shell's Overview decide by the same name (tests/shell/client_chrome_rules.sh checks the rule, the shell and the spec).
    inline constexpr std::string_view kTag = "grassfield-client-chrome";

    // P1: Hyprland's tags of a window (CTagKeeper::getTags) hold kTag. A dynamic tag, one a window rule set, is kept with a
    // trailing '*'; the name is what counts. Nothing else matches (no prefix, no case folding).
    bool hasClientChromeTag(const std::set<std::string>& tags);

    // The band the plugin reserves above a window's surface: its titlebar, none for a window that draws its own chrome
    // (P3: Stages thumbnails; also the tiling and restore frames, so that no empty strip is left above such a window).
    double band(bool clientChrome);
    // TL33 (step 6e, ADR-0036 D73): none either above a Split View member, whose titlebar is away as a full-screen window's
    // is (the pointer at the top edge of its half reveals it, P6): its half is filled from the output's top edge.
    double band(bool clientChrome, bool splitMember);

    // ---- P9: the decoration the client negotiated (owner report on 1.0.0-rc6: two title bars on Telegram and ArtCraft) ----
    // A Wayland client says whether it draws its own title bar through xdg-decoration (zxdg_toplevel_decoration_v1.set_mode:
    // client_side 1, server_side 2; unset_mode: the compositor's choice) or KDE's server-decoration
    // (org_kde_kwin_server_decoration.request_mode: none 0, client 1, server 2; GTK 3 and GTK 4 announce their header bars
    // there). Hyprland 0.56.2 answers server_side to every request of both (read from the binary: xdgModeOnRequestCSD and
    // kdeModeOnRequestCSD return 2) and keeps what the client asked (mostRecentlyRequested, public). The values are the
    // protocols' enums. What a request proves (review of 3ca47a4b, nested at 1.25): an xdg client_side request does not prove a
    // title bar (foot -o csd.preferred=client asks it, takes Hyprland's server_side answer and draws nothing; Chromium asks it
    // and draws its tab strip: S1b names it), and neither does the absence of any negotiation (imv binds no decoration manager
    // and draws nothing). A KDE client request does (GTK's header bars draw themselves whatever the answer), and so does a
    // client that bound a decoration manager yet made no decoration object at all (Qt does that for a frameless window:
    // Telegram).
    inline constexpr uint32_t kXdgModeClientSide = 1;
    inline constexpr uint32_t kXdgModeServerSide = 2;
    inline constexpr uint32_t kKdeModeClient     = 1;
    inline constexpr uint32_t kKdeModeServer     = 2;

    // What one toplevel negotiated: whether it made each protocol's decoration object, and its latest request there (0 when
    // it never asked, or unset its mode), read from Hyprland's private containers; `managerBound`: its client bound
    // zxdg_decoration_manager_v1 or org_kde_kwin_server_decoration_manager (it knows the compositor offers server-side
    // decorations); `clientHasObject`: its client holds a decoration object of either protocol, for any of its windows. The
    // last two come from libwayland's public list of the client's resources, so they hold whatever Hyprland keeps privately.
    struct DecorationRequest {
        bool     xdgObject       = false;
        uint32_t xdgRequested    = 0;
        bool     kdeObject       = false;
        uint32_t kdeRequested    = 0;
        bool     managerBound    = false;
        bool     clientHasObject = false;
    };

    // The client draws its own title bar, proved by the protocol alone: a KDE client request, or a decoration manager bound
    // and no decoration object in the whole client. Anything else keeps the plugin's titlebar: any xdg request, client_side
    // included; a KDE server request or a KDE object without a client request (0 is both "never asked" and KDE's "none", which
    // no toolkit seen sends); a client that bound no manager; a client that holds an object not found for this window
    // (another of its windows is decorated, or Hyprland's private containers changed meaning). The invariant: a window the
    // plugin tags always has a bar of its own; an app whose request proves nothing and that does draw its own goes in the
    // per-app list S1b.
    bool drawsOwnTitlebar(const DecorationRequest& request);

    // A Wayland interface name, as libwayland lists a client's resources: one of the two decoration managers
    // (DecorationRequest::managerBound: zxdg_decoration_manager_v1, org_kde_kwin_server_decoration_manager), one of their
    // decoration objects (DecorationRequest::clientHasObject: zxdg_toplevel_decoration_v1, org_kde_kwin_server_decoration),
    // or anything else. Exact names.
    enum class DecorationInterface : uint8_t {
        Other,
        Manager,
        Object,
    };
    DecorationInterface decorationInterface(std::string_view interfaceName);

    // Whether the plugin's own Hyprland tag (kTag, static: rules never clear it) should be added to or removed from a window
    // now. `drawsOwn`: drawsOwnTitlebar; `tagged`: the window carries kTag from anyone; `ours`: the plugin added it.
    // Add when the client draws its own title bar and nothing tagged it; remove only a tag the plugin added once the client
    // no longer draws its own (a session rule's tag, the per-app fallback, is never removed).
    enum class TagChange : uint8_t {
        None,
        Add,
        Remove,
    };
    TagChange tagChange(bool drawsOwn, bool tagged, bool ours);

    // ---- P8: the minimize capability (GF-056 part 2) ----
    // xdg_toplevel.wm_capabilities (xdg-shell v5) tells a client which window controls work; GTK4 greys the ones that are
    // missing. Hyprland 0.56.2 sends every toplevel fullscreen and maximize, once, from CXDGToplevelResource's
    // constructor (read from the binary: no minimize, no window menu): it does nothing with set_minimized on its own. A
    // window that draws its own controls is minimized by the plugin (P5: the titlebar light's path, Dock target and
    // effect), so while it is client chrome it is told minimize too. The values are the protocol's enum.
    inline constexpr uint32_t kCapWindowMenu = 1;
    inline constexpr uint32_t kCapMaximize   = 2;
    inline constexpr uint32_t kCapFullscreen = 3;
    inline constexpr uint32_t kCapMinimize   = 4;
    inline constexpr uint32_t kWmCapabilitiesSince = 5; // the xdg_toplevel version that has the event

    // The capabilities a window is told: Hyprland's own (fullscreen, maximize, in its order), plus minimize when the
    // window is client chrome and the plugin bridges its set_minimized (P5).
    std::vector<uint32_t> wmCapabilities(bool clientChrome, bool minimizeBridged);

    // The xdg_toplevel resource is private in CXDGToplevelResource: the glue walks the client's resources. A resource is
    // handed to CXDGToplevelResource::fromResource only when it is an xdg_toplevel with the event (v5 or later) and still
    // has its user data: fromResource reads the user data without a check (read from the 0.56.2 binary), and it is null
    // while the resource is being destroyed (a rule change can run inside another object's destroy chain).
    bool capabilityCandidate(std::string_view interfaceName, int version, bool hasUserData);
    // P9: the same walk for the key of Hyprland's xdg-decoration map: an xdg_toplevel of any version that still has its user data.
    bool toplevelCandidate(std::string_view interfaceName, bool hasUserData);

    // What one window was told. `unreachable`: its xdg_toplevel resource was not found (older than v5, or going), so it
    // cannot be told anything: no further walk for it (every rule change would repeat it).
    struct CapabilityTell {
        bool minimizeTold = false;
        bool unreachable  = false;
    };

    // Whether the window must be told again for the answer `withMinimize` (the answer changed and it can be told).
    bool needsTell(const CapabilityTell& tell, bool withMinimize);

    // ---- P4: dragging a zoomed window by its own toolbar ----
    // The app starts Hyprland's interactive move (xdg_toplevel.move) from a press on its toolbar. macOS takes a window that
    // fills the screen out of that state at its previous size, under the pointer at the same place in its toolbar row.
    // The press is recorded before Hyprland handles it (the window is still zoomed then); the move request that follows
    // answers it when it comes for the same window while the button is still held, soon enough.
    inline constexpr uint64_t kMovePressMaxAgeMs = 3000;

    struct ZoomedPress {
        uint64_t       window = 0; // the window's address
        titlebar::Rect zoomed;     // its surface box while zoomed (layout px)
        double         x      = 0; // the press (layout px)
        double         y      = 0;
        uint64_t       timeMs = 0;
    };

    // The move request of `window` at `nowMs` answers `press`: same window, a button still held, at most
    // kMovePressMaxAgeMs after the press (a clock that went backwards answers nothing).
    bool moveAnswersPress(const std::optional<ZoomedPress>& press, uint64_t window, bool buttonHeld, uint64_t nowMs);

    // Where the window goes when such a move starts: its floating size back (restoredW x restoredH), the pointer at the
    // same horizontal fraction of the window and the same height below its top edge as at the press (titlebar::
    // unzoomedDragBox, the plugin titlebar's own rule).
    titlebar::Rect unzoomedBox(const ZoomedPress& press, double restoredW, double restoredH, double pointerX, double pointerY);

    // ---- P6: Option(Alt)+click on the zoom light ----
    // macOS: the green light zooms; with Option held it enters full screen (and the glyph shows the full-screen arrows).
    enum class ZoomAction : uint8_t {
        Zoom,             // maximize (FSMODE_MAXIMIZED)
        Unzoom,           // back from maximized
        EnterFullscreen,  // FSMODE_FULLSCREEN (the shell hides the menu bar as for any full screen)
        LeaveFullscreen,  // back from full screen
    };

    // What a press on the zoom light does, from the window's state and whether Alt is held. A window in full screen
    // leaves it whatever the modifier (macOS: the green light of a full-screen window exits it).
    ZoomAction zoomAction(bool maximized, bool fullscreen, bool altHeld);

    // The zoom glyph shows the full-screen arrows while Alt is held (over the group, where glyphs show at all), and always
    // on the titlebar of a full-screen window (its light leaves full screen).
    bool zoomGlyphIsArrows(bool altHeld, bool fullscreen);

    // ---- P6: the titlebar of a full-screen window (macOS) ----
    // In full screen the titlebar is away. The pointer at the top edge of the window's monitor brings it back, below the
    // menu bar and over the window's content; it goes when the pointer leaves it, or with the full screen. Its zoom light
    // leaves full screen (the pointer's way out); its minimize light is unavailable (greyed and inert, as on macOS).
    // A Split View member's titlebar is away too (TL33, step 6e, ADR-0036 D73, D74): the pointer at the top edge over its half
    // brings that half's bar alone, and while one half's bar is there the pointer brings the other's by moving across
    // within the bar's band (macOS, one menu bar over both).
    inline constexpr double kRevealEdge  = 2.0; // the pointer this close to the monitor's top edge (layout px) reveals it
    inline constexpr double kRevealSlack = 8.0; // it stays until the pointer is this far below it (layout px)

    struct RevealInput {
        bool   revealable = false; // the window is in full screen or a Split View member, on a visible workspace, and has a plugin titlebar
        bool   onMonitor  = false; // the pointer is on the window's monitor
        double pointerY   = 0.0;   // the pointer below the monitor's top edge (layout px)
        double barTop     = 0.0;   // where the bar starts below the top edge (the menu bar's height, or 0)
        bool   pressing   = false; // a press on a revealed bar is not released yet (a light decided at its release, a member's drag)
        bool   inSpan     = true;  // the pointer is within the window's width (a Split View member: its half; full screen: the monitor)
        bool   handOver   = false; // another bar is revealed on this monitor (the other half's): within the band this one comes
        bool   overOther  = false; // the pointer is over the other half of its Split View (that member's width; never in full screen)
    };

    // Whether the titlebar is revealed after a pointer motion (or a change of the window), from whether it was. While a
    // press on a revealed bar lasts, that bar stays and no other comes. A revealed member's bar stays until the pointer is
    // over the other half: the gap between the halves is its own (the review of #99: walked in small steps, the bar was
    // lost in the gap and the other never came).
    bool nextRevealed(bool revealed, const RevealInput& in);

    // Whether a light of a full-screen window's titlebar can be used (minimize cannot).
    bool lightAvailableInFullscreen(titlebar::Button button);

    // What a left press on a revealed titlebar does (TL33, step 6e, ADR-0036 D75). A light that can be used is armed (it acts
    // at its release over it); minimize is inert. Away from the lights, a Split View member in its half (`memberInPlace`:
    // neither in full screen nor zoomed) starts its drag (D59: over the other half the two swap); any other press focuses
    // and raises the window only.
    enum class RevealedPress : uint8_t {
        Nothing,
        ArmLight,
        MemberDrag,
    };
    RevealedPress revealedPress(titlebar::HitTarget hit, bool memberInPlace);

    // Whether a light of the plugin's titlebar can be used: drawn in colour with its glyph, its click acting. `fullscreen`: the
    // bar of a window in full screen (lightAvailableInFullscreen); `fixedSize`: the window's minimum is its maximum on both
    // axes (core tiling::fixedSize); `sized`: it is zoomed or in full screen now. The zoom light of a window of fixed size is
    // disabled, as macOS disables the green button of a window that cannot be resized and the Window menu greys its Zoom and
    // Enter Full Screen (ADR-0040 step 1b's review: a click zoomed About-like windows); once such a window is zoomed or in full
    // screen anyway, the light brings it back (Unzoom, Exit Full Screen stay in the menu too).
    bool lightAvailable(titlebar::Button button, bool fullscreen, bool fixedSize, bool sized);

    // The presses on a revealed titlebar are the plugin's alone: they are cancelled on Hyprland's event bus with their
    // releases. Hyprland 0.56.2 returns from CInputManager::onMouseButton right after the bus when an event is cancelled,
    // before it records the button as held or released (read from the binary), so a cancelled press and its cancelled
    // release leave its held-button state as it was. This tracks the releases owed, per button: the bus event names no
    // device, so the caller takes a press on the bar only when no device holds that button already (no other device's
    // release of the same button can then be mistaken for the bar's).
    class CRevealPresses {
      public:
        // A press, on the revealed bar or not. A release still owed for the same button was lost (its device went away):
        // forgotten, so that the release of this press, which Hyprland records, is never cancelled.
        void onPress(uint32_t button, bool onBar);
        // A release: true when it belongs to a press on the bar (cancel it too); the debt is paid.
        bool takeRelease(uint32_t button);
        // A press on the bar is not released yet (the bar stays while it is).
        bool pressing() const;
        void reset();

      private:
        std::set<uint32_t> m_owed;
    };

    // ---- Zoom is Fill for client chrome (ADR-0036 D78, ADR-0015 Q4 amended) ----
    // While the plugin's window-tiling is advertised, a client-chrome window's own maximize request (its green light, its
    // toolbar double-click: xdg_toplevel.set_maximized or unset_maximized, which Hyprland toggles whatever its value) is the
    // plugin's: Hyprland is told to ignore it (SUPPRESS_MAXIMIZE on that window, set by the plugin only) and the plugin zooms
    // (Fill and back). Without window-tiling, or for a window that is not client chrome, Hyprland's own maximize, as before
    // (gate C2: the unload clears what the plugin set).
    bool ownsMaximize(bool ready, bool windowTiling, bool clientChrome);

    // Hyprland arms itself to swallow the set_maximized a client may echo right after it leaves full screen (it reports
    // every window as maximized, Window.hpp m_suppressNextMaximize). With the request the plugin's, the plugin does the same:
    // a maximize request within kMaximizeEchoMs of the window leaving full screen is that echo, not the user's zoom; bounded,
    // so a later real request is never swallowed when the client sent no echo.
    inline constexpr uint64_t kMaximizeEchoMs = 1000;
    // `armedAtMs`: when the window left full screen (0: never). True when a request at `nowMs` is the echo.
    bool maximizeEcho(uint64_t armedAtMs, uint64_t nowMs);

    // The buttons Hyprland holds, as the bus shows them (its own list, CInputManager::m_currentlyHeldButtons, is private;
    // hasHeldButtons() only says whether it is empty). A press it processes adds its button, a release it processes removes
    // it. Unknown until the plugin has seen Hyprland hold nothing (a button held when the plugin loaded would otherwise
    // be missed, and its device's release delayed behind a bar press; review of part B, 2026-10-24): until then, and
    // whenever reset, no press is taken by the bar.
    class CHeldButtons {
      public:
        // A button event Hyprland processed (the bar did not cancel it).
        void observe(uint32_t button, bool pressed);
        // Whether the bar may take a press of `button`. `hyprlandHoldsNone`: hasHeldButtons() was false before this press
        // (the list is then known to be empty, and the record starts over from it).
        bool mayTake(uint32_t button, bool hyprlandHoldsNone);
        bool known() const;
        // Unknown again (unload).
        void reset();

      private:
        std::set<uint32_t> m_held;
        bool               m_known = false;
    };

} // namespace gf::chrome
