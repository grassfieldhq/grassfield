.pragma library

// Filter chips of Search (macOS 26 Spotlight keeps a row of them under the field). Pure: Search.qml owns the
// state. A chip narrows the results to one kind of item; the inline answers (calculator, conversion) belong to
// no chip and are hidden while one is selected.

const CHIPS = [
    {id: "apps", kinds: ["app"]},
    {id: "commands", kinds: ["command"]},
    {id: "settings", kinds: ["setting"]},
    {id: "documents", kinds: ["file", "recent"]}
];

// The chip ids that have at least one item in `groups` ([{id, title, items}]), in the fixed chip order.
function chipsOf(groups) {
    const out = [];
    for (const c of CHIPS) {
        if (groups.some(g => g.items.some(it => c.kinds.indexOf(it.kind) >= 0)))
            out.push(c.id);
    }
    return out;
}

// `groups` narrowed to the chip `filter` (a chip id): one group with every matching item, the Top Hit included, in
// the order the groups had. An empty or unknown filter returns `groups` unchanged. `title` names the group.
function apply(groups, filter, title) {
    const chip = CHIPS.find(c => c.id === filter);
    if (!chip)
        return groups;
    const items = [];
    for (const g of groups) {
        for (const it of g.items) {
            if (chip.kinds.indexOf(it.kind) >= 0)
                items.push(it);
        }
    }
    return items.length > 0 ? [{id: chip.id, title: title, items: items}] : [];
}

// Keyboard reach of the chips (the field keeps the text focus, as in the Apps panel: a "chips" zone draws the ring on
// chip `index` and the field's key handler routes the keys here). `action` is next | prev | left | right | home | end |
// escape | activate | other. Returns {zone, index, toggle, handled}: handled = false hands the key back to the field
// (typing, Up, Down ... leave the chips and act as usual); toggle = true selects or clears chip `index`.
function chipKey(zone, index, count, action) {
    if (zone !== "chips")
        return {zone: "field", index: -1, toggle: false, handled: false};
    const to = i => ({zone: "chips", index: Math.max(0, Math.min(count - 1, i)), toggle: false, handled: true});
    const leave = {zone: "field", index: -1, toggle: false, handled: true};
    switch (action) {
    case "right":
        return to(index + 1);
    case "left":
        return to(index - 1);
    case "home":
        return to(0);
    case "end":
        return to(count - 1);
    case "next":
        return index + 1 < count ? to(index + 1) : leave;
    case "prev":
        return index > 0 ? to(index - 1) : leave;
    case "escape":
        return leave;
    case "activate":
        return {zone: "chips", index: index, toggle: true, handled: true};
    default:
        return {zone: "field", index: -1, toggle: false, handled: false};
    }
}
