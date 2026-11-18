#include "processtable.h"

#include "format.h"

#include <QCoreApplication>
#include <QHash>

#include <algorithm>
#include <functional>
#include <map>

namespace activity {

namespace {

struct ViewInfo {
    View view;
    const char *key;
    const char *title;
};

const ViewInfo kViews[] = {
    {View::All, "all", QT_TRANSLATE_NOOP("ActivityView", "All Processes")},
    {View::Tree, "tree", QT_TRANSLATE_NOOP("ActivityView", "All Processes, Hierarchically")},
    {View::Mine, "mine", QT_TRANSLATE_NOOP("ActivityView", "My Processes")},
    {View::System, "system", QT_TRANSLATE_NOOP("ActivityView", "System Processes")},
    {View::OtherUsers, "otherUsers", QT_TRANSLATE_NOOP("ActivityView", "Other User Processes")},
    {View::Active, "active", QT_TRANSLATE_NOOP("ActivityView", "Active Processes")},
    {View::Inactive, "inactive", QT_TRANSLATE_NOOP("ActivityView", "Inactive Processes")},
    {View::Gpu, "gpu", QT_TRANSLATE_NOOP("ActivityView", "GPU Processes")},
    {View::Windowed, "windowed", QT_TRANSLATE_NOOP("ActivityView", "Windowed Processes")},
    {View::Selected, "selected", QT_TRANSLATE_NOOP("ActivityView", "Selected Processes")},
    {View::ByType, "byType", QT_TRANSLATE_NOOP("ActivityView", "Processes, by Type")},
    {View::ByGpu, "byGpu", QT_TRANSLATE_NOOP("ActivityView", "Processes, by GPU")},
};

// A group's header has no process: its identity is the group's alone.
constexpr RowId kHeaderId{-2, 0};

bool own(const TableRow &row)
{
    return !row.kernel && row.process.own;
}

QString kindText(const TableRow &row)
{
    if (!own(row))
        return dash();
    switch (row.process.kind) {
    case Kind::App:
        return QCoreApplication::translate("ActivityTable", "App");
    case Kind::Session:
        return QCoreApplication::translate("ActivityTable", "Session");
    case Kind::Background:
    case Kind::System:
    case Kind::OtherUser:
        break;
    }
    return QCoreApplication::translate("ActivityTable", "Background");
}

} // namespace

QString viewKey(View view)
{
    for (const ViewInfo &v : kViews) {
        if (v.view == view)
            return QString::fromLatin1(v.key);
    }
    return QStringLiteral("all");
}

std::optional<View> viewFromKey(const QString &key)
{
    for (const ViewInfo &v : kViews) {
        if (key == QLatin1String(v.key))
            return v.view;
    }
    return std::nullopt;
}

QString viewTitle(View view)
{
    for (const ViewInfo &v : kViews) {
        if (v.view == view)
            return QCoreApplication::translate("ActivityView", v.title);
    }
    return QString();
}

const std::vector<View> &views()
{
    // macOS's order, the grouped views last: by Type (Windows 11's, AM65), then by GPU.
    static const std::vector<View> all{View::All,      View::Tree, View::Mine,     View::System,   View::OtherUsers,
                                       View::Active,   View::Inactive, View::Gpu,  View::Windowed, View::Selected,
                                       View::ByType,   View::ByGpu};
    return all;
}

unsigned readsForView(View view)
{
    return view == View::Gpu || view == View::ByGpu ? ReadDescriptors | ReadGpu : 0u;
}

RowId rowId(const TableRow &row)
{
    if (row.kernel)
        return RowId{};
    return RowId{row.process.pid, row.process.start};
}

QString rowKey(const TableRow &row)
{
    if (row.kernel)
        return QStringLiteral("kernel");
    return QString::number(row.process.pid) + QLatin1Char(':') + QString::number(row.process.start);
}

ProcessTable::ProcessTable(QObject *parent)
    : QAbstractListModel(parent)
{
    m_collator.setCaseSensitivity(Qt::CaseInsensitive);
    m_collator.setNumericMode(true);
    m_columns = tabColumns(Tab::Cpu).defaults;
}

void ProcessTable::setColumns(const std::vector<Column> &shown)
{
    m_columns = shown;
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {CellsRole, AccessibleRole});
}

void ProcessTable::setSort(Column column, bool descending)
{
    if (column == m_sort && descending == m_descending)
        return;
    m_sort = column;
    m_descending = descending;
    rebuild();
}

void ProcessTable::setView(View view)
{
    if (view == View::Selected)
        m_selectedView = m_selected; // kept until another view is chosen (AM12)
    if (view == m_view && view != View::Selected)
        return;
    m_view = view;
    rebuild();
}

void ProcessTable::setSearch(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed == m_search)
        return;
    m_search = trimmed;
    rebuild();
}

void ProcessTable::setSwappedMemory(bool swapped)
{
    m_swappedMemory = swapped;
}

void ProcessTable::setGpuNames(const QHash<QString, QString> &names)
{
    if (names == m_gpuNames)
        return;
    m_gpuNames = names;
    if (m_view == View::ByGpu)
        rebuild();
}

void ProcessTable::setLocale(const QLocale &locale)
{
    if (locale == m_locale)
        return;
    m_locale = locale;
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {CellsRole, AccessibleRole});
}

void ProcessTable::setRows(std::vector<TableRow> rows)
{
    // The rows shown point into the last sample: it stays alive until the new one's changes are signalled.
    m_previous = std::move(m_all);
    m_all = std::move(rows);
    // A collapsed row whose process ended is forgotten; a GPU's header stays collapsed while the app runs.
    if (!m_collapsed.isEmpty()) {
        QSet<RowId> alive;
        for (const TableRow &r : m_all)
            alive.insert(rowId(r));
        m_collapsed.removeIf([&](const EntryKey &k) { return !(k.id == kHeaderId) && !alive.contains(k.id); });
    }
    // An app unit that ended is forgotten too, with its collapsed header: each app ever launched left an entry for the run.
    // The kinds' and the GPUs' identities stay.
    if (!m_groupIds.isEmpty()) {
        QSet<quint64> units;
        for (const TableRow &r : m_all) {
            if (r.process.unitKey != 0)
                units.insert(r.process.unitKey);
        }
        const QLatin1String prefix("unit/");
        for (auto it = m_groupIds.begin(); it != m_groupIds.end();) {
            if (it.key().startsWith(prefix) && !units.contains(it.key().mid(prefix.size()).toULongLong(nullptr, 16))) {
                m_collapsed.remove(EntryKey{kHeaderId, it.value()});
                it = m_groupIds.erase(it);
            } else {
                ++it;
            }
        }
    }
    rebuild();
    m_previous = {};
}

std::vector<TableRow> ProcessTable::shownRows() const
{
    std::vector<TableRow> rows;
    rows.reserve(m_shown.size());
    for (const Entry &e : m_shown) {
        if (e.row)
            rows.push_back(*e.row);
    }
    return rows;
}

const TableRow *ProcessTable::processRow(int pid, quint64 start) const
{
    for (const TableRow &r : m_all) {
        if (!r.kernel && r.process.pid == pid && (start == 0 || r.process.start == start))
            return &r;
    }
    return nullptr;
}

std::vector<TableRow> ProcessTable::selectedRows() const
{
    std::vector<TableRow> rows;
    QSet<RowId> taken;
    for (const Entry &e : m_shown) {
        if (!e.row || !m_selected.contains(rowId(*e.row)) || taken.contains(rowId(*e.row)))
            continue;
        taken.insert(rowId(*e.row));
        rows.push_back(*e.row);
    }
    return rows;
}

int ProcessTable::currentRow() const
{
    return m_current ? indexOf(*m_current) : -1;
}

int ProcessTable::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : count();
}

QHash<int, QByteArray> ProcessTable::roleNames() const
{
    return {{CellsRole, "cells"},       {KeyRole, "rowKey"},         {PidRole, "pid"},       {NameRole, "name"},
            {IconRole, "icon"},         {SelectedRole, "selected"},  {CurrentRole, "current"}, {KernelRole, "kernel"},
            {OwnRole, "own"},           {AccessibleRole, "accessibleText"}, {DepthRole, "depth"},
            {ExpandableRole, "expandable"}, {ExpandedRole, "expanded"}, {GroupRole, "group"},
            {NotRespondingRole, "notResponding"}};
}

QVariant ProcessTable::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= count())
        return {};
    const Entry &entry = m_shown[static_cast<size_t>(index.row())];
    switch (role) {
    case DepthRole:
        return entry.depth;
    case ExpandableRole:
        return entry.expandable;
    case ExpandedRole:
        return entry.expanded;
    case GroupRole:
        return entry.row == nullptr;
    default:
        break;
    }
    if (!entry.row) { // a group's header (AM49, AM65): its name in the name column, nothing else
        switch (role) {
        case CellsRole: {
            QStringList cells(static_cast<qsizetype>(m_columns.size()));
            if (!cells.isEmpty())
                cells[0] = entry.title;
            return cells;
        }
        case KeyRole:
            return QStringLiteral("group:") + QString::number(entry.group);
        case PidRole:
            return -1;
        case NameRole:
        case Qt::DisplayRole:
        case AccessibleRole:
            return entry.title;
        case IconRole:
            return entry.icon;
        case SelectedRole:
        case CurrentRole:
        case KernelRole:
        case OwnRole:
        case NotRespondingRole:
            return false;
        default:
            return {};
        }
    }
    const TableRow &row = *entry.row;
    switch (role) {
    case CellsRole: {
        QStringList cells;
        cells.reserve(static_cast<qsizetype>(m_columns.size()));
        for (Column c : m_columns)
            cells << cellText(row, c);
        return cells;
    }
    case KeyRole:
        return rowKey(row);
    case PidRole:
        return row.kernel ? -1 : row.process.pid;
    case NameRole:
    case Qt::DisplayRole:
        return cellText(row, Column::Name);
    case IconRole:
        return row.icon;
    case SelectedRole:
        return m_selected.contains(rowId(row));
    case CurrentRole:
        return m_current && rowId(row) == *m_current;
    case KernelRole:
        return row.kernel;
    case OwnRole:
        return own(row);
    case NotRespondingRole:
        return row.notResponding;
    case AccessibleRole: {
        QStringList parts{cellText(row, Column::Name)};
        for (Column c : m_columns) {
            if (c != Column::Name)
                parts << columnTitle(c, m_swappedMemory) + QLatin1Char(' ') + cellText(row, c);
        }
        return parts.join(QStringLiteral(", "));
    }
    default:
        return {};
    }
}

QString ProcessTable::cellText(const TableRow &row, Column column) const
{
    const ProcessRow &p = row.process;
    const QLocale &locale = m_locale;
    if (row.kernel) {
        switch (column) {
        case Column::Name:
            return QCoreApplication::translate("ActivityTable", "Kernel");
        case Column::CpuPercent:
            return formatDecimal(p.cpuPercent, locale);
        case Column::CpuTime:
            return formatCpuTime(row.cpuSeconds, locale);
        case Column::Threads:
            return formatCount(p.threads, locale);
        case Column::User:
            return row.user;
        default:
            return dash();
        }
    }
    const bool mine = p.own;
    switch (column) {
    case Column::Name:
        // AM27: the Force Quit panel's words (fr « (ne répond pas) »).
        return row.notResponding ? QCoreApplication::translate("ActivityTable", "%1 (Not Responding)").arg(row.name) : row.name;
    case Column::CpuPercent:
        return formatDecimal(p.cpuPercent, locale);
    case Column::CpuTime:
        return formatCpuTime(row.cpuSeconds, locale);
    case Column::Threads:
        return formatCount(p.threads, locale);
    case Column::WakeUps:
        return mine ? formatCount(p.wakeRate, locale) : dash();
    case Column::GpuPercent:
        // No client is no GPU work (0.0); another owner's descriptors cannot be read ("—"); a first sample has no rate yet.
        return !mine ? dash() : p.hasGpu ? formatDecimal(p.gpuPercent, locale) : formatDecimal(0, locale);
    case Column::GpuTime:
        return mine ? formatCpuTime(static_cast<double>(p.gpuNs) / 1e9, locale) : dash();
    case Column::OpenFiles:
        return mine ? formatCount(p.openFiles, locale) : dash();
    case Column::Kind:
        return kindText(row);
    case Column::Status:
        // AM27: what is wrong first (macOS's red mark), then Windows' Efficiency Mode leaf, then the kernel's states.
        if (row.notResponding)
            return QCoreApplication::translate("ActivityTable", "Not Responding");
        if (row.process.efficient)
            return QCoreApplication::translate("ActivityTable", "Efficiency Mode");
        if (p.state == 'T' || p.state == 't')
            return QCoreApplication::translate("ActivityTable", "Stopped");
        if (p.state == 'Z')
            return QCoreApplication::translate("ActivityTable", "Zombie");
        return QString();
    case Column::Command:
        return mine && !p.command.empty() ? QString::fromStdString(p.command) : dash();
    case Column::Memory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.memory), locale) : dash();
    case Column::RealMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.realMemory), locale) : dash();
    case Column::PrivateMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.privateMemory), locale) : dash();
    case Column::SharedMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.sharedMemory), locale) : dash();
    case Column::CompressedMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.swapped), locale) : dash();
    case Column::PeakMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.peakMemory), locale) : dash();
    case Column::PageIns:
        return formatCount(static_cast<double>(p.majorFaults), locale);
    case Column::EnergyImpact:
        return formatDecimal(p.energyImpact, locale);
    case Column::AverageEnergyImpact:
        return formatDecimal(p.averageEnergyImpact, locale);
    case Column::PreventingSleep:
        return row.preventingSleep ? QCoreApplication::translate("ActivityTable", "Yes") : QCoreApplication::translate("ActivityTable", "No");
    case Column::BytesWritten:
        return p.hasIo ? formatBytes(static_cast<double>(p.bytesWritten), locale) : dash();
    case Column::BytesRead:
        return p.hasIo ? formatBytes(static_cast<double>(p.bytesRead), locale) : dash();
    case Column::ReadRate:
        return p.hasIo ? formatBytes(p.readRate, locale) : dash();
    case Column::WriteRate:
        return p.hasIo ? formatBytes(p.writeRate, locale) : dash();
    case Column::SentBytes:
        return mine ? formatBytes(static_cast<double>(p.tcpSent), locale) : dash();
    case Column::ReceivedBytes:
        return mine ? formatBytes(static_cast<double>(p.tcpReceived), locale) : dash();
    case Column::SentPackets:
        return mine ? formatCount(static_cast<double>(p.tcpSegsOut), locale) : dash();
    case Column::ReceivedPackets:
        return mine ? formatCount(static_cast<double>(p.tcpSegsIn), locale) : dash();
    case Column::Pid:
        return QString::number(p.pid);
    case Column::User:
        return row.user;
    }
    return dash();
}

double ProcessTable::sortValue(const TableRow &row, Column column) const
{
    const ProcessRow &p = row.process;
    const bool mine = own(row);
    switch (column) {
    case Column::CpuPercent:
        return p.cpuPercent;
    case Column::CpuTime:
        return row.cpuSeconds;
    case Column::Threads:
        return p.threads;
    case Column::Pid:
        return row.kernel ? -1 : p.pid;
    default:
        break;
    }
    if (row.kernel)
        return -1;
    switch (column) {
    case Column::WakeUps:
        return mine ? p.wakeRate : -1;
    case Column::GpuPercent:
        return !mine ? -1 : p.hasGpu ? p.gpuPercent : 0;
    case Column::GpuTime:
        return mine ? static_cast<double>(p.gpuNs) : -1;
    case Column::OpenFiles:
        return mine ? p.openFiles : -1;
    case Column::Memory:
        return p.hasMemory ? static_cast<double>(p.memory) : -1;
    case Column::RealMemory:
        return p.hasMemory ? static_cast<double>(p.realMemory) : -1;
    case Column::PrivateMemory:
        return p.hasMemory ? static_cast<double>(p.privateMemory) : -1;
    case Column::SharedMemory:
        return p.hasMemory ? static_cast<double>(p.sharedMemory) : -1;
    case Column::CompressedMemory:
        return p.hasMemory ? static_cast<double>(p.swapped) : -1;
    case Column::PeakMemory:
        return p.hasMemory ? static_cast<double>(p.peakMemory) : -1;
    case Column::PageIns:
        return static_cast<double>(p.majorFaults);
    case Column::EnergyImpact:
        return p.energyImpact;
    case Column::AverageEnergyImpact:
        return p.averageEnergyImpact;
    case Column::BytesWritten:
        return p.hasIo ? static_cast<double>(p.bytesWritten) : -1;
    case Column::BytesRead:
        return p.hasIo ? static_cast<double>(p.bytesRead) : -1;
    case Column::ReadRate:
        return p.hasIo ? p.readRate : -1;
    case Column::WriteRate:
        return p.hasIo ? p.writeRate : -1;
    case Column::SentBytes:
        return mine ? static_cast<double>(p.tcpSent) : -1;
    case Column::ReceivedBytes:
        return mine ? static_cast<double>(p.tcpReceived) : -1;
    case Column::SentPackets:
        return mine ? static_cast<double>(p.tcpSegsOut) : -1;
    case Column::ReceivedPackets:
        return mine ? static_cast<double>(p.tcpSegsIn) : -1;
    default:
        return -1;
    }
}

QString ProcessTable::sortText(const TableRow &row, Column column) const
{
    return cellText(row, column);
}

bool ProcessTable::less(const TableRow &a, const TableRow &b) const
{
    if (columnIsNumeric(m_sort)) {
        // What is unknown ("—", -1) sorts below every value, whichever way.
        const double va = sortValue(a, m_sort), vb = sortValue(b, m_sort);
        if (va != vb)
            return m_descending ? va > vb : va < vb;
    } else {
        const int c = m_collator.compare(sortText(a, m_sort), sortText(b, m_sort));
        if (c != 0)
            return m_descending ? c > 0 : c < 0;
    }
    // Ties keep one order, the pid's (the Kernel row first): rows never swap between two samples for nothing.
    const int pa = a.kernel ? -1 : a.process.pid, pb = b.kernel ? -1 : b.process.pid;
    return pa < pb;
}

bool ProcessTable::accepts(const TableRow &row) const
{
    const ProcessRow &p = row.process;
    switch (m_view) {
    case View::All:
    case View::Tree:
    case View::ByType:
        break;
    case View::Mine:
        if (!own(row))
            return false;
        break;
    case View::System:
        if (!row.kernel && !p.systemAccount)
            return false;
        break;
    case View::OtherUsers:
        if (row.kernel || p.own || p.systemAccount)
            return false;
        break;
    case View::Active:
        if (!(p.cpuPercent > 0))
            return false;
        break;
    case View::Inactive:
        if (p.cpuPercent > 0)
            return false;
        break;
    case View::Gpu:
    case View::ByGpu:
        if (row.kernel || p.gpuDevices.empty())
            return false;
        break;
    case View::Windowed:
        if (!row.windowed)
            return false;
        break;
    case View::Selected:
        if (!m_selectedView.contains(rowId(row)))
            return false;
        break;
    }
    return matches(row);
}

bool ProcessTable::matches(const TableRow &row) const
{
    const ProcessRow &p = row.process;
    if (m_search.isEmpty())
        return true;
    // AM14: the name, the app's name, the user, the command (own processes only, AD25), or a pid that starts with the
    // digits typed; case-insensitive.
    const QString name = row.kernel ? cellText(row, Column::Name) : row.name;
    if (name.contains(m_search, Qt::CaseInsensitive) || row.appName.contains(m_search, Qt::CaseInsensitive)
        || row.user.contains(m_search, Qt::CaseInsensitive))
        return true;
    if (own(row) && QString::fromStdString(p.command).contains(m_search, Qt::CaseInsensitive))
        return true;
    bool digits = !m_search.isEmpty();
    for (const QChar ch : m_search)
        digits = digits && ch.isDigit();
    return digits && !row.kernel && QString::number(p.pid).startsWith(m_search);
}

int ProcessTable::indexOf(const RowId &id) const
{
    for (size_t i = 0; i < m_shown.size(); ++i) {
        if (m_shown[i].row && rowId(*m_shown[i].row) == id)
            return static_cast<int>(i);
    }
    return -1;
}

const TableRow *ProcessTable::processAt(int row) const
{
    return row >= 0 && row < count() ? m_shown[static_cast<size_t>(row)].row : nullptr;
}

EntryKey ProcessTable::keyOf(const Entry &entry) const
{
    return EntryKey{entry.row ? rowId(*entry.row) : kHeaderId, entry.group};
}

// AM13: a tree by parent pid, each level sorted by the sort column. A row whose parent is not listed, or is not older than
// it (its pid was reused), is a root, and so is a row no root leads to (two rows that name each other, read in a race).
// The search keeps a row that matches and every row above it (AM14).
std::vector<Entry> ProcessTable::tree() const
{
    QHash<int, const TableRow *> byPid;
    byPid.reserve(static_cast<qsizetype>(m_all.size()));
    for (const TableRow &r : m_all) {
        if (!r.kernel)
            byPid.insert(r.process.pid, &r);
    }
    QHash<const TableRow *, std::vector<const TableRow *>> children;
    std::vector<const TableRow *> roots;
    for (const TableRow &r : m_all) {
        const TableRow *parent = nullptr;
        if (!r.kernel && r.process.ppid != r.process.pid) {
            const auto it = byPid.constFind(r.process.ppid);
            if (it != byPid.constEnd() && (*it)->process.start <= r.process.start)
                parent = *it;
        }
        if (parent)
            children[parent].push_back(&r);
        else
            roots.push_back(&r);
    }
    const auto order = [this](const TableRow *a, const TableRow *b) { return less(*a, *b); };
    const bool searching = !m_search.isEmpty();
    QSet<const TableRow *> kept, seen;
    // Both walks below call themselves once per level: a chain of forks tens of thousands deep (within a user's process
    // limit) would overflow the stack. Past this depth the rows under a row start again as rows of the first level.
    constexpr int kMaxTreeDepth = 1000;
    // Post-order: a row is kept when it or a row under it matches.
    const std::function<bool(const TableRow *, int)> keep = [&](const TableRow *r, int depth) -> bool {
        seen.insert(r);
        bool any = matches(*r);
        if (depth < kMaxTreeDepth) {
            for (const TableRow *c : children.value(r)) {
                if (!seen.contains(c) && keep(c, depth + 1))
                    any = true;
            }
        }
        if (any)
            kept.insert(r);
        return any;
    };
    for (const TableRow *r : roots)
        keep(r, 0);
    for (const TableRow &r : m_all) { // rows no root leads to
        if (!seen.contains(&r)) {
            roots.push_back(&r);
            keep(&r, 0);
        }
    }
    std::stable_sort(roots.begin(), roots.end(), order);
    std::vector<Entry> out;
    out.reserve(m_all.size());
    QSet<const TableRow *> placed;
    const std::function<void(const TableRow *, int)> place = [&](const TableRow *r, int depth) {
        if ((searching && !kept.contains(r)) || placed.contains(r))
            return;
        placed.insert(r);
        std::vector<const TableRow *> kids;
        if (depth < kMaxTreeDepth) {
            for (const TableRow *c : children.value(r)) {
                if ((!searching || kept.contains(c)) && !placed.contains(c))
                    kids.push_back(c);
            }
        }
        std::stable_sort(kids.begin(), kids.end(), order);
        Entry e;
        e.row = r;
        e.depth = depth;
        e.expandable = !kids.empty();
        e.expanded = !m_collapsed.contains(EntryKey{rowId(*r), 0});
        out.push_back(e);
        if (!e.expandable || !e.expanded)
            return;
        for (const TableRow *c : kids)
            place(c, depth + 1);
    };
    for (const TableRow *r : roots)
        place(r, 0);
    return out;
}

// AM49: a header per GPU (drm-pdev), in pdev order, then its client processes sorted; a process that uses two GPUs is under
// both. A GPU without a process the search keeps is not listed (AM14).
std::vector<Entry> ProcessTable::byGpu()
{
    std::map<QString, std::vector<const TableRow *>> groups;
    for (const TableRow &r : m_all) {
        if (!accepts(r))
            continue;
        for (const std::string &pdev : r.process.gpuDevices)
            groups[QString::fromStdString(pdev)].push_back(&r);
    }
    std::vector<Entry> out;
    for (auto &[pdev, rows] : groups) {
        const quint64 id = groupId(pdev);
        std::stable_sort(rows.begin(), rows.end(), [this](const TableRow *a, const TableRow *b) { return less(*a, *b); });
        Entry header;
        header.group = id;
        header.title = m_gpuNames.value(pdev, pdev);
        header.expandable = true;
        header.expanded = !m_collapsed.contains(EntryKey{kHeaderId, id});
        out.push_back(header);
        if (!header.expanded)
            continue;
        for (const TableRow *r : rows) {
            Entry e;
            e.row = r;
            e.depth = 1;
            e.group = id;
            out.push_back(e);
        }
    }
    return out;
}

quint64 ProcessTable::groupId(const QString &key)
{
    quint64 &id = m_groupIds[key];
    if (id == 0)
        id = ++m_nextGroupId; // not the count: an entry that was forgotten must not give its identity to a new group
    return id;
}

// AM65 (Windows 11's Processes tab): a header per kind with its count, in the order Apps, Background Processes, Session
// Processes, System Processes (the Kernel row there), Other Users; a kind without a process the search keeps is not listed.
// Under Apps, a header per app unit with its processes (the app's name and icon: its window's, its desktop entry's, the
// unit's name, from the window's rows), then the processes Apps holds outside such a unit (a window's owner).
std::vector<Entry> ProcessTable::byType()
{
    struct KindGroup {
        Kind kind;
        const char *key;
        const char *title;
    };
    static const KindGroup kinds[] = {
        {Kind::App, "type/apps", QT_TRANSLATE_NOOP("ActivityType", "Apps")},
        {Kind::Background, "type/background", QT_TRANSLATE_NOOP("ActivityType", "Background Processes")},
        {Kind::Session, "type/session", QT_TRANSLATE_NOOP("ActivityType", "Session Processes")},
        {Kind::System, "type/system", QT_TRANSLATE_NOOP("ActivityType", "System Processes")},
        {Kind::OtherUser, "type/otherUsers", QT_TRANSLATE_NOOP("ActivityType", "Other Users")},
    };
    const auto kindOf = [](const TableRow &r) { return r.kernel ? Kind::System : r.process.kind; };
    const auto sorted = [this](std::vector<const TableRow *> &rows) {
        std::stable_sort(rows.begin(), rows.end(), [this](const TableRow *a, const TableRow *b) { return less(*a, *b); });
    };
    const auto withCount = [this](const QString &name, size_t count) {
        return QCoreApplication::translate("ActivityType", "%1 (%2)").arg(name, m_locale.toString(static_cast<qulonglong>(count)));
    };
    std::vector<Entry> out;
    for (const KindGroup &k : kinds) {
        std::vector<const TableRow *> rows;
        for (const TableRow &r : m_all) {
            if (kindOf(r) == k.kind && accepts(r))
                rows.push_back(&r);
        }
        if (rows.empty())
            continue;
        Entry header;
        header.group = groupId(QLatin1String(k.key));
        header.title = withCount(QCoreApplication::translate("ActivityType", k.title), rows.size());
        header.expandable = true;
        header.expanded = !m_collapsed.contains(EntryKey{kHeaderId, header.group});
        out.push_back(header);
        if (!header.expanded)
            continue;
        if (k.kind != Kind::App) {
            sorted(rows);
            for (const TableRow *r : rows) {
                Entry e;
                e.row = r;
                e.depth = 1;
                e.group = header.group;
                out.push_back(e);
            }
            continue;
        }
        // The app units, in the order of their first process once sorted (the sort column's leader first), then the rest.
        sorted(rows);
        std::vector<quint64> order;
        QHash<quint64, std::vector<const TableRow *>> units;
        std::vector<const TableRow *> loose;
        for (const TableRow *r : rows) {
            const quint64 unit = r->process.unitKey;
            if (unit == 0) {
                loose.push_back(r);
                continue;
            }
            auto it = units.find(unit);
            if (it == units.end()) {
                order.push_back(unit);
                it = units.insert(unit, {});
            }
            it->push_back(r);
        }
        for (const quint64 unit : order) {
            const std::vector<const TableRow *> &members = units[unit];
            // The window's name first (the projection's app), else the desktop entry's, else the unit's own name.
            const TableRow *named = members.front();
            for (const TableRow *r : members) {
                if (r->windowed && !r->appName.isEmpty()) {
                    named = r;
                    break;
                }
            }
            QString name = named->appName;
            QString icon = named->icon;
            for (const TableRow *r : members) {
                if (name.isEmpty() && !r->appName.isEmpty())
                    name = r->appName;
                if (icon.isEmpty() && !r->icon.isEmpty())
                    icon = r->icon;
            }
            if (name.isEmpty())
                name = QString::fromStdString(named->process.appId);
            Entry app;
            app.group = groupId(QStringLiteral("unit/") + QString::number(unit, 16));
            app.depth = 1;
            app.title = withCount(name, members.size());
            app.icon = icon;
            app.expandable = true;
            app.expanded = !m_collapsed.contains(EntryKey{kHeaderId, app.group});
            out.push_back(app);
            if (!app.expanded)
                continue;
            for (const TableRow *r : members) {
                Entry e;
                e.row = r;
                e.depth = 2;
                e.group = app.group;
                out.push_back(e);
            }
        }
        for (const TableRow *r : loose) {
            Entry e;
            e.row = r;
            e.depth = 1;
            e.group = header.group;
            out.push_back(e);
        }
    }
    return out;
}

void ProcessTable::rebuild()
{
    const int before = count();
    // The target: the rows the view and the search keep, sorted (and grouped); pointers into the last sample, nothing copied.
    std::vector<Entry> target;
    if (m_view == View::Tree) {
        target = tree();
    } else if (m_view == View::ByGpu) {
        target = byGpu();
    } else if (m_view == View::ByType) {
        target = byType();
    } else {
        std::vector<const TableRow *> rows;
        rows.reserve(m_all.size());
        for (const TableRow &r : m_all) {
            if (accepts(r))
                rows.push_back(&r);
        }
        std::stable_sort(rows.begin(), rows.end(), [this](const TableRow *a, const TableRow *b) { return less(*a, *b); });
        target.resize(rows.size());
        for (size_t i = 0; i < rows.size(); ++i)
            target[i].row = rows[i];
    }
    QHash<EntryKey, int> wanted;
    wanted.reserve(static_cast<qsizetype>(target.size()));
    for (size_t i = 0; i < target.size(); ++i)
        wanted.insert(keyOf(target[i]), static_cast<int>(i));

    // The rows that left: removed from the end, one run at a time. m_shown still points into the sample before (kept in
    // m_previous until this returns), so a view that reads the rows while it hears of the change reads them as they were.
    for (int i = count() - 1; i >= 0;) {
        if (wanted.contains(keyOf(m_shown[static_cast<size_t>(i)]))) {
            --i;
            continue;
        }
        const int last = i;
        while (i >= 0 && !wanted.contains(keyOf(m_shown[static_cast<size_t>(i)])))
            --i;
        beginRemoveRows(QModelIndex(), i + 1, last);
        m_shown.erase(m_shown.begin() + (i + 1), m_shown.begin() + (last + 1));
        endRemoveRows();
    }
    // The rows that stay take their new values where they are; the new ones come in at the end.
    QSet<EntryKey> present;
    present.reserve(static_cast<qsizetype>(m_shown.size()));
    for (Entry &e : m_shown) {
        const EntryKey key = keyOf(e);
        present.insert(key);
        e = target[static_cast<size_t>(wanted.value(key))];
    }
    std::vector<Entry> added;
    for (const Entry &e : target) {
        if (!present.contains(keyOf(e)))
            added.push_back(e);
    }
    if (!added.empty()) {
        beginInsertRows(QModelIndex(), count(), count() + static_cast<int>(added.size()) - 1);
        m_shown.insert(m_shown.end(), added.begin(), added.end());
        endInsertRows();
    }
    // Then every row moves to its sorted place: a layout change, which keeps the view's scroll position (AM11).
    bool ordered = true;
    for (size_t i = 0; i < m_shown.size() && ordered; ++i)
        ordered = keyOf(m_shown[i]) == keyOf(target[i]);
    if (!ordered) {
        emit layoutAboutToBeChanged({}, QAbstractItemModel::VerticalSortHint);
        const QModelIndexList from = persistentIndexList();
        QModelIndexList to;
        to.reserve(from.size());
        for (const QModelIndex &i : from) {
            const int row = i.row() >= 0 && i.row() < count() ? wanted.value(keyOf(m_shown[static_cast<size_t>(i.row())]), -1) : -1;
            to << (row >= 0 ? index(row) : QModelIndex());
        }
        m_shown = std::move(target);
        changePersistentIndexList(from, to);
        emit layoutChanged({}, QAbstractItemModel::VerticalSortHint);
    } else {
        m_shown = std::move(target);
    }
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1));
    pruneSelection();
    if (count() != before)
        emit countChanged();
}

void ProcessTable::pruneSelection()
{
    // A process that ended, or that the view or the search no longer shows, leaves the selection: an action never applies to
    // a row the user cannot see (AM11).
    QSet<RowId> shown;
    shown.reserve(static_cast<qsizetype>(m_shown.size()));
    for (const Entry &e : m_shown) {
        if (e.row)
            shown.insert(rowId(*e.row));
    }
    const QSet<RowId> was = m_selected;
    const std::optional<RowId> current = m_current;
    m_selected.intersect(shown);
    if (m_anchor && !shown.contains(*m_anchor))
        m_anchor.reset();
    if (m_current && !shown.contains(*m_current))
        m_current.reset();
    if (m_selected != was || m_current != current)
        emit selectionChanged();
}

void ProcessTable::selectRange(int from, int to)
{
    m_selected.clear();
    const int lo = std::min(from, to), hi = std::max(from, to);
    for (int i = lo; i <= hi; ++i) {
        if (const TableRow *r = processAt(i))
            m_selected.insert(rowId(*r));
    }
}

void ProcessTable::click(int row, int modifiers)
{
    const TableRow *process = processAt(row);
    if (!process)
        return; // a GPU's header is not a process: nothing to select
    const RowId id = rowId(*process);
    if ((modifiers & Qt::ShiftModifier) && m_anchor) {
        selectRange(indexOf(*m_anchor), row);
    } else if (modifiers & Qt::ControlModifier) {
        if (m_selected.contains(id))
            m_selected.remove(id);
        else
            m_selected.insert(id);
        m_anchor = id;
    } else {
        m_selected = {id};
        m_anchor = id;
    }
    m_current = id;
    emit dataChanged(index(0), index(count() - 1), {SelectedRole, CurrentRole});
    emit selectionChanged();
}

void ProcessTable::moveCurrent(int delta, bool extend)
{
    if (m_shown.empty())
        return;
    const int from = currentRow();
    int to = std::clamp(from < 0 ? (delta >= 0 ? 0 : count() - 1) : from + delta, 0, count() - 1);
    // A GPU's header is passed over, in the direction of the move (or back, at an end of the list).
    const int step = delta >= 0 ? 1 : -1;
    while (to >= 0 && to < count() && !processAt(to))
        to += step;
    if (to < 0 || to >= count()) {
        to = std::clamp(to, 0, count() - 1);
        while (to >= 0 && to < count() && !processAt(to))
            to -= step;
        if (to < 0 || to >= count())
            return;
    }
    const RowId id = rowId(*processAt(to));
    if (extend && m_anchor) {
        selectRange(indexOf(*m_anchor), to);
    } else {
        m_selected = {id};
        m_anchor = id;
    }
    m_current = id;
    emit dataChanged(index(0), index(count() - 1), {SelectedRole, CurrentRole});
    emit selectionChanged();
}

void ProcessTable::selectAll()
{
    for (const Entry &e : m_shown) {
        if (e.row)
            m_selected.insert(rowId(*e.row));
    }
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {SelectedRole});
    emit selectionChanged();
}

void ProcessTable::clearSelection()
{
    if (m_selected.isEmpty())
        return;
    m_selected.clear();
    emit dataChanged(index(0), index(count() - 1), {SelectedRole});
    emit selectionChanged();
}

QString ProcessTable::copyText() const
{
    QStringList lines;
    QStringList header;
    for (Column c : m_columns)
        header << columnTitle(c, m_swappedMemory);
    lines << header.join(QLatin1Char('\t'));
    QSet<RowId> copied; // a process under two GPUs is copied once
    for (const Entry &e : m_shown) {
        if (!e.row || !m_selected.contains(rowId(*e.row)) || copied.contains(rowId(*e.row)))
            continue;
        copied.insert(rowId(*e.row));
        QStringList cells;
        for (Column c : m_columns)
            cells << cellText(*e.row, c);
        lines << cells.join(QLatin1Char('\t'));
    }
    return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
}

void ProcessTable::setExpanded(int row, bool expanded)
{
    if (row < 0 || row >= count())
        return;
    const Entry &e = m_shown[static_cast<size_t>(row)];
    if (!e.expandable || e.expanded == expanded)
        return;
    const EntryKey key = keyOf(e);
    if (expanded)
        m_collapsed.remove(key);
    else
        m_collapsed.insert(key);
    rebuild();
}

void ProcessTable::toggleExpanded(int row)
{
    if (row >= 0 && row < count())
        setExpanded(row, !m_shown[static_cast<size_t>(row)].expanded);
}

} // namespace activity
