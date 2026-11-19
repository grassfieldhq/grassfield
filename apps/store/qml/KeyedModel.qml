import QtQuick

// A list model of keys, kept in step with a list of keys by the fewest changes (SU-06): rows whose key is gone are removed,
// new keys inserted, moved keys moved; a list with the same keys in the same order changes nothing, so a view's delegates
// stay where they are (they read their data by key from their view, which can change in place). When less than half of the
// rows survive, the model is reset in one step instead.
ListModel {
    id: root

    // The keys in the model, in order (a mirror of the rows: look-ups never go through get()).
    property var current: []

    function sync(keys: var): void {
        const want = keys || [];
        const now = root.current;
        let same = now.length === want.length;
        for (let i = 0; same && i < want.length; ++i)
            same = now[i] === want[i];
        if (same)
            return;
        const wanted = new Set(want);
        let kept = 0;
        for (const k of now) {
            if (wanted.has(k))
                ++kept;
        }
        if (kept * 2 < now.length || now.length === 0) {
            root.clear();
            if (want.length > 0)
                root.append(want.map(k => ({key: k})));
            root.current = want.slice();
            return;
        }
        const keys_ = now.slice();
        for (let i = keys_.length - 1; i >= 0; --i) {
            if (!wanted.has(keys_[i])) {
                root.remove(i, 1);
                keys_.splice(i, 1);
            }
        }
        for (let i = 0; i < want.length; ++i) {
            if (i < keys_.length && keys_[i] === want[i])
                continue;
            const j = keys_.indexOf(want[i], i + 1);
            if (j > i) {
                root.move(j, i, 1);
                keys_.splice(j, 1);
                keys_.splice(i, 0, want[i]);
            } else {
                root.insert(i, {key: want[i]});
                keys_.splice(i, 0, want[i]);
            }
        }
        root.current = keys_;
    }
}
