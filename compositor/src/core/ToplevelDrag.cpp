#include "ToplevelDrag.hpp"

#include <iterator>

namespace gf::toplevelDrag {

    Outcome outcomeOf(EndKind kind, bool releaseSeen) {
        switch (kind) {
            case EndKind::DropPerformed: return Outcome::Drop;
            case EndKind::Cancelled: return releaseSeen ? Outcome::Drop : Outcome::Cancel;
            case EndKind::SourceGone: return Outcome::Cancel;
        }
        return Outcome::Cancel;
    }

    Error CDrag::attach(Id toplevel, bool mapped, int32_t xOffset, int32_t yOffset) {
        if (m_attached)
            return Error::ToplevelAttached;
        m_attached = toplevel;
        m_mapped   = mapped;
        m_stepped  = false;
        // The offset is the client's hint for a window it maps while attached; a mapped window keeps where the pointer holds it.
        m_grab = mapped ? std::nullopt : std::optional<Point>{Point{.x = static_cast<double>(xOffset), .y = static_cast<double>(yOffset)}};
        return Error::None;
    }

    Error CDrag::destroy() const {
        return m_phase == Phase::Dragging ? Error::OngoingDrag : Error::None;
    }

    bool CDrag::start() {
        if (m_phase != Phase::Waiting)
            return false;
        m_phase = Phase::Dragging;
        return true;
    }

    std::optional<End> CDrag::release() {
        if (m_phase != Phase::Dragging || m_released)
            return std::nullopt;
        const bool followed = follows();
        m_released          = true;
        return End{.outcome = Outcome::Drop, .toplevel = followed ? m_attached : std::nullopt};
    }

    bool CDrag::dropBeforeCancel() {
        if (m_phase != Phase::Dragging || !m_released || m_dropSent)
            return false;
        m_dropSent = true;
        return true;
    }

    std::optional<End> CDrag::end(EndKind kind) {
        if (kind == EndKind::DropPerformed)
            m_dropSent = true;
        if (m_phase == Phase::Ended)
            return std::nullopt;
        const bool wasDragging = m_phase == Phase::Dragging;
        const bool followed    = follows(); // false once released: the release placed the window
        const auto toplevel    = m_attached;
        m_phase                = Phase::Ended;
        m_attached.reset();
        m_mapped  = false;
        m_stepped = false;
        m_grab.reset();
        if (!wasDragging)
            return std::nullopt;
        return End{.outcome = outcomeOf(kind, m_released), .toplevel = followed ? toplevel : std::nullopt};
    }

    void CDrag::mapped(Id toplevel) {
        if (m_attached != toplevel)
            return;
        m_mapped = true;
    }

    bool CDrag::unmapped(Id toplevel) {
        if (m_attached != toplevel)
            return false;
        m_attached.reset();
        m_mapped  = false;
        m_stepped = false;
        m_grab.reset();
        return true;
    }

    bool CDrag::gone(Id toplevel) {
        return unmapped(toplevel);
    }

    bool CDrag::follows() const {
        return m_phase == Phase::Dragging && !m_released && m_attached && m_mapped;
    }

    bool CDrag::excludes() const {
        return m_phase == Phase::Dragging && m_attached && m_mapped;
    }

    std::optional<Step> CDrag::step(Point pointer, Point topLeft) {
        if (!follows())
            return std::nullopt;
        if (!m_grab)
            m_grab = Point{.x = pointer.x - topLeft.x, .y = pointer.y - topLeft.y};
        const bool first = !m_stepped;
        m_stepped        = true;
        return Step{.topLeft = Point{.x = pointer.x - m_grab->x, .y = pointer.y - m_grab->y}, .first = first};
    }

    void CDrag::regrab(Point pointer, Point topLeft) {
        if (!follows())
            return;
        m_grab = Point{.x = pointer.x - topLeft.x, .y = pointer.y - topLeft.y};
    }

    void CDrag::holdAt(Point pointer, Point topLeft) {
        if (!m_attached || !m_mapped || m_grab)
            return;
        m_grab = Point{.x = pointer.x - topLeft.x, .y = pointer.y - topLeft.y};
    }

    bool misuseRaisable(std::optional<Id> managerClient, Id objectClient, std::optional<Id> sourceClient) {
        return managerClient && *managerClient == objectClient && (!sourceClient || *sourceClient == objectClient);
    }

    Target pickTarget(ITargetScene& scene, Id dragged) {
        if (scene.layerPopup())
            return Target{.kind = TargetKind::LayerPopup, .window = std::nullopt};
        for (const auto level : {TargetKind::Overlay, TargetKind::Top}) {
            if (scene.layer(level))
                return Target{.kind = level, .window = std::nullopt};
        }
        if (const auto w = scene.window(kTargetWindowProperties, dragged); w && *w != dragged)
            return Target{.kind = scene.windowSurface(*w) ? TargetKind::Window : TargetKind::WindowBorder, .window = w};
        for (const auto level : {TargetKind::Bottom, TargetKind::Background}) {
            if (scene.layer(level))
                return Target{.kind = level, .window = std::nullopt};
        }
        return Target{};
    }

    Error CSources::add(Id source, Id object) {
        if (m_bySource.contains(source))
            return Error::InvalidSource;
        m_bySource.emplace(source, object);
        return Error::None;
    }

    void CSources::removeObject(Id object) {
        for (auto it = m_bySource.begin(); it != m_bySource.end();)
            it = it->second == object ? m_bySource.erase(it) : std::next(it);
    }

    void CSources::removeSource(Id source) {
        m_bySource.erase(source);
    }

    std::optional<Id> CSources::objectOf(Id source) const {
        const auto it = m_bySource.find(source);
        if (it == m_bySource.end())
            return std::nullopt;
        return it->second;
    }

} // namespace gf::toplevelDrag
