.pragma library

// The Search results list as a keyed model (audit B-05): the view's ListModel of {key, itemIndex} rows is brought in line with
// the new result keys by removes, moves and inserts, never rebuilt. A JS array as the ListView's model reset the view on every
// keystroke: every row delegate (icons, texts, the clipboard row's buttons) was destroyed and made again inside onTextChanged,
// and its icons reloaded. A row whose result stays keeps its delegate; only its itemIndex moves.
// Keys are made unique (a repeated key gets "#<position>"), so two results with one key never share a row.
// Returns {removed, inserted, moved} (counts, for tests).

function uniqueKeys(keys) {
    const out = [];
    const seen = Object.create(null);
    for (let i = 0; i < keys.length; i++) {
        let k = String(keys[i]);
        if (seen[k] === true)
            k = k + "#" + i;
        seen[k] = true;
        out.push(k);
    }
    return out;
}

function sync(model, keys) {
    const want = uniqueKeys(keys);
    const wanted = Object.create(null);
    for (const k of want)
        wanted[k] = true;
    const stats = {removed: 0, inserted: 0, moved: 0};
    for (let i = model.count - 1; i >= 0; i--) {
        if (wanted[model.get(i).key] !== true) {
            model.remove(i);
            stats.removed++;
        }
    }
    for (let i = 0; i < want.length; i++) {
        if (i < model.count && model.get(i).key === want[i]) {
            if (model.get(i).itemIndex !== i)
                model.setProperty(i, "itemIndex", i);
            continue;
        }
        let j = -1;
        for (let m = i + 1; m < model.count; m++) {
            if (model.get(m).key === want[i]) {
                j = m;
                break;
            }
        }
        if (j > i) {
            model.move(j, i, 1);
            model.setProperty(i, "itemIndex", i);
            stats.moved++;
        } else {
            model.insert(i, {key: want[i], itemIndex: i});
            stats.inserted++;
        }
    }
    return stats;
}
