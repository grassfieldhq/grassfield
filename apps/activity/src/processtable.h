// The table of processes (spec AM10 to AM19, AM13, AM49): one row per process of the last sample and the Kernel row, filtered
// by the view and the search, sorted by one column. A new sample keeps each row's identity (pid and start time): rows of
// ended processes go, new ones come in, the others change in place and move to their sorted place, so the list view keeps
// its scroll position (no model reset) and the selection follows its processes (AM11). Two views group the rows (step 2b):
// All Processes, Hierarchically (a tree by parent, each level sorted) and Processes, by GPU (a header row per GPU, its
// client processes under it); a row of either can be collapsed, and stays so across samples.
#pragma once

#include "columns.h"

#include <QAbstractListModel>
#include <QCollator>
#include <QLocale>
#include <QSet>
#include <QString>

#include <optional>
#include <unordered_map>
#include <vector>

namespace activity {

// AM12's views of steps 2a, 2b, 3 (Windowed Processes with the shell's projection) and 4 (Processes, by Type).
enum class View { All, Tree, Mine, System, OtherUsers, Active, Inactive, Gpu, Windowed, Selected, ByGpu, ByType };

QString viewKey(View view);
std::optional<View> viewFromKey(const QString &key);
QString viewTitle(View view);
const std::vector<View> &views();
// What a view reads beyond its tab's files: the GPU views read the processes' GPU clients on every tab (AM45, AM49).
unsigned readsForView(View view);

// A row as the table needs it: the sampler's row and what the window adds to it.
struct TableRow {
    ProcessRow process;
    bool kernel = false;       // AM20a: every kernel thread summed; never selectable for an action
    double cpuSeconds = 0;     // utime + stime in seconds (the sampler counts ticks)
    QString name;              // sanitized by the sampler (AM17)
    QString user;              // the owner's login name, or the uid when it has none
    QString appName;           // the app's name from its desktop entry (own processes of an app unit), for the search
    QString icon;              // a theme icon name; "" for the generic executable glyph
    bool preventingSleep = false; // AM38
    // The shell's projection (AM60): it owns a window (Windowed Processes, AM12), and the shell marks it as not responding
    // (AM27: " (Not Responding)" after its name, in the destructive colour).
    bool windowed = false;
    bool notResponding = false;
};

// A row's identity across samples: the pid and its start time (pid -1 for the Kernel row). A plain value: the table
// compares thousands of them at each sample.
struct RowId {
    int pid = -1;
    quint64 start = 0;
    bool operator==(const RowId &other) const { return pid == other.pid && start == other.start; }
    bool operator!=(const RowId &other) const { return !(*this == other); }
};
inline size_t qHash(const RowId &id, size_t seed = 0)
{
    return qHashMulti(seed, id.pid, id.start);
}

// A row as the table lists it: a process (or the Kernel row) at its depth, or a group's header (Processes, by GPU, by Type).
struct Entry {
    const TableRow *row = nullptr; // nullptr: a group's header
    int depth = 0;                 // the tree's level, or 1 under a group's header (2 under an app's, AM65)
    bool expandable = false;       // a disclosure triangle: children in the tree, processes under a header
    bool expanded = true;
    quint64 group = 0;             // the group it heads or is in (a GPU, a kind, an app's unit), 0 outside the grouped views
    QString title;                 // a header's: the GPU's name, the kind's with its count, the app's with its count
    QString icon;                  // an app's header (AM65): its icon
};
// An entry's identity across samples: its process's (or none for a header) and its group's, since a process that uses two
// GPUs is listed under both.
struct EntryKey {
    RowId id;
    quint64 group = 0;
    bool operator==(const EntryKey &other) const { return id == other.id && group == other.group; }
};
inline size_t qHash(const EntryKey &key, size_t seed = 0)
{
    return qHashMulti(seed, key.id.pid, key.id.start, key.group);
}
RowId rowId(const TableRow &row);
// The identity as text ("<pid>:<start>", "kernel"), for the KeyRole.
QString rowKey(const TableRow &row);

class ProcessTable : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int selectedCount READ selectedCount NOTIFY selectionChanged)
    // The row the keyboard moves from (the last one clicked or moved to), -1 when none is shown.
    Q_PROPERTY(int currentRow READ currentRow NOTIFY selectionChanged)

public:
    enum Role {
        CellsRole = Qt::UserRole + 1, // the shown columns' texts, in order (the name first)
        KeyRole,
        PidRole,
        NameRole,
        IconRole,
        SelectedRole,
        CurrentRole,
        KernelRole,
        OwnRole,
        AccessibleRole, // the name and the values with their headers (spec "Accessibility")
        DepthRole,      // the tree's level (AM13), 1 under a group's header
        ExpandableRole, // a disclosure triangle shows
        ExpandedRole,
        GroupRole,      // a group's header (AM49): not a process, never selected
        NotRespondingRole, // AM27: the name in the destructive colour
    };

    explicit ProcessTable(QObject *parent = nullptr);

    void setColumns(const std::vector<Column> &shown); // the name first
    const std::vector<Column> &columns() const { return m_columns; }
    void setSort(Column column, bool descending);
    void setView(View view);
    void setSearch(const QString &text);
    void setSwappedMemory(bool swapped);
    // AM47: the GPUs' names by drm-pdev, for the headers of Processes, by GPU (the pdev itself when none is known).
    void setGpuNames(const QHash<QString, QString> &names);
    // The formats' locale (grassfield.json region.formats, as the Store): sizes, decimals and counts (AM16).
    void setLocale(const QLocale &locale);
    // A new sample's rows: every process and the Kernel row.
    void setRows(std::vector<TableRow> rows);

    int count() const { return static_cast<int>(m_shown.size()); }
    int selectedCount() const { return static_cast<int>(m_selected.size()); }
    int currentRow() const;
    // The rows shown, in order (a copy, for the tests).
    std::vector<TableRow> shownRows() const;
    // The selected processes as the table shows them, once each (a process under two GPUs), in the table's order (AM50).
    std::vector<TableRow> selectedRows() const;
    // A shown row's process (nullptr for a header or past the end), and a process of the last sample whatever the view:
    // by its pid and start time, or by its pid alone when `start` is 0 (AM57's names).
    const TableRow *rowAt(int row) const { return processAt(row); }
    const TableRow *processRow(int pid, quint64 start) const;
    // Every process of the last sample, whatever the view and the search.
    const std::vector<TableRow> &allRows() const { return m_all; }

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // AM11: a click selects the row; Ctrl toggles it; Shift selects from the anchor to it.
    Q_INVOKABLE void click(int row, int modifiers);
    // The keyboard (spec "Keyboard"): Up, Down, Page Up, Page Down, Home and End move the current row; Shift extends.
    Q_INVOKABLE void moveCurrent(int delta, bool extend);
    Q_INVOKABLE void selectAll();
    Q_INVOKABLE void clearSelection();
    // AM19: the shown columns' headers, then one line per selected row in the table's order, values as shown, tab-separated.
    Q_INVOKABLE QString copyText() const;
    // AM13, AM49: a row's children (the tree) or a header's processes shown or hidden; kept across samples.
    Q_INVOKABLE void setExpanded(int row, bool expanded);
    Q_INVOKABLE void toggleExpanded(int row);

    QString cellText(const TableRow &row, Column column) const;

signals:
    void countChanged();
    void selectionChanged();

private:
    bool accepts(const TableRow &row) const;
    bool matches(const TableRow &row) const; // the search alone (AM14)
    bool less(const TableRow &a, const TableRow &b) const;
    const QString &sortKeyOf(const TableRow &row) const;
    // Whether an entry that stays shows other values than before (its row in the last sample, its row now).
    bool entryChanged(const Entry &before, const Entry &now) const;
    std::vector<Entry> tree() const;
    std::vector<Entry> byGpu();
    std::vector<Entry> byType();
    quint64 groupId(const QString &key);
    EntryKey keyOf(const Entry &entry) const;
    double sortValue(const TableRow &row, Column column) const;
    QString sortText(const TableRow &row, Column column) const;
    void rebuild();
    void pruneSelection();
    int indexOf(const RowId &id) const;
    void selectRange(int from, int to);
    const TableRow *processAt(int row) const; // nullptr for a header

    std::vector<Column> m_columns;
    Column m_sort = Column::CpuPercent;
    bool m_descending = true;
    View m_view = View::All;
    QString m_search;
    bool m_swappedMemory = false;
    QLocale m_locale;
    std::vector<TableRow> m_all;      // the last sample
    std::vector<TableRow> m_previous; // the sample before, alive while a new one's changes are signalled
    // What the view and the search keep, sorted (and grouped): rows of m_all (of m_previous while a new sample comes in),
    // never copied.
    std::vector<Entry> m_shown;
    QSet<EntryKey> m_collapsed;           // the tree's rows and the GPU headers collapsed (AM13)
    QHash<QString, QString> m_gpuNames;   // by drm-pdev
    QHash<QString, quint64> m_groupIds;   // by drm-pdev, kind or unit, from 1: a group's identity for the run
    quint64 m_nextGroupId = 0;            // the last identity given (never given twice: the units that ended are forgotten)
    QSet<RowId> m_selected;
    QSet<RowId> m_selectedView; // Selected Processes: the rows selected when the view was chosen
    std::optional<RowId> m_anchor, m_current;
    QCollator m_collator;
    // The sort texts of the rows of one rebuild (by row), made at their first comparison.
    mutable std::unordered_map<const TableRow *, QString> m_sortKeys;
};

} // namespace activity
