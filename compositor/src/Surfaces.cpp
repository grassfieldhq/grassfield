#include "Surfaces.hpp"

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/Popup.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include "HyprCompat.hpp"
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/protocols/core/Subcompositor.hpp>

namespace gf::surfaces {

    namespace {
        SP<CWLSurfaceResource> topLevelOf(SP<CWLSurfaceResource> surface) {
            for (int depth = 0; surface && depth < 16; ++depth) {
                if (!surface->m_role || surface->m_role->role() != SURFACE_ROLE_SUBSURFACE)
                    return surface;
                // role() said subsurface: the role object is a CSubsurfaceRole (single, non-virtual inheritance).
                const auto* role = static_cast<const CSubsurfaceRole*>(surface->m_role.get());
                const auto  sub  = role->m_subsurface.lock();
                surface          = sub ? sub->m_parent.lock() : nullptr;
            }
            return nullptr;
        }
    } // namespace

    SOwner ownerOf(const SP<CWLSurfaceResource>& surface) {
        SOwner out;
        const auto top = surface ? topLevelOf(surface) : nullptr;
        if (!top)
            return out;
        const auto hl   = Desktop::View::CWLSurface::fromResource(top);
        const auto view = hl ? hl->view() : nullptr;
        if (!view)
            return out;
        out.visible = gf::compat::aliveAndVisible(view);
        switch (view->type()) {
            case Desktop::View::VIEW_TYPE_WINDOW: out.window = Desktop::View::CWindow::fromView(view); break;
            case Desktop::View::VIEW_TYPE_LAYER_SURFACE: out.layer = Desktop::View::CLayerSurface::fromView(view); break;
            case Desktop::View::VIEW_TYPE_POPUP: {
                const auto popup = Desktop::View::CPopup::fromView(view);
                if (!popup)
                    break;
                out.popup = true;
                out.layer = popup->layerOwner();
                if (!out.layer) {
                    const auto t1     = popup->getT1Owner();
                    const auto t1view = t1 ? t1->view() : nullptr;
                    if (t1view && t1view->type() == Desktop::View::VIEW_TYPE_WINDOW)
                        out.window = Desktop::View::CWindow::fromView(t1view);
                }
                break;
            }
            case Desktop::View::VIEW_TYPE_SUBSURFACE:
            case Desktop::View::VIEW_TYPE_LOCK_SCREEN: break;
        }
        out.known = out.window || out.layer;
        return out;
    }

    SP<CWLSurfaceResource> keyboardFocus() {
        return g_pSeatManager ? g_pSeatManager->m_state.keyboardFocus.lock() : nullptr;
    }

    uint32_t interactivity(const PHLLS& layer) {
        const auto resource = layer ? layer->m_layerSurface.lock() : nullptr;
        return resource ? gf::compat::keyboardInteractivity(resource) : 0;
    }

} // namespace gf::surfaces
