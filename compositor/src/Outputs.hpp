#pragma once

// The outputs window management works with (Tiling, Stages, Minimize, the top clamp): Hyprland's ENABLED monitors. Hyprland
// keeps a disconnected monitor (m_enabled false) in its list for a while, with its old box; none of these modules may place,
// clamp, draw or validate against it (audit WM-08). Read in place from Hyprland's list, never copied: these run per pointer
// motion and per frame (WM-13). Compositor thread only. Header only (glue, Hyprland 0.56.2).

#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <string_view>

namespace gf::outputs {

    // The first enabled monitor `pred` accepts (Hyprland's order), or null.
    template <typename Pred>
    PHLMONITOR find(Pred&& pred) {
        const auto& state = State::monitorState();
        if (!state)
            return nullptr;
        for (const auto& m : state->monitors()) {
            if (m && m->m_enabled && pred(m))
                return m;
        }
        return nullptr;
    }

    // Calls `f` with every enabled monitor (Hyprland's order).
    template <typename F>
    void forEach(F&& f) {
        find([&f](const PHLMONITOR& m) {
            f(m);
            return false;
        });
    }

    // The enabled monitor whose logical box holds `p`.
    inline PHLMONITOR at(const Vector2D& p) {
        return find([&p](const PHLMONITOR& m) { return m->logicalBox().containsPoint(p); });
    }

    // The enabled monitor named `name`.
    inline PHLMONITOR byName(std::string_view name) {
        return find([name](const PHLMONITOR& m) { return m->m_name == name; });
    }

} // namespace gf::outputs
