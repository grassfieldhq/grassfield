.pragma library

// Where the sound goes when outputs come and go (ADR-0047 part A). A pure state machine: Audio.qml feeds it what PipeWire
// reports, each event with its time in milliseconds, and carries out the "switch" actions it returns; it keeps no timer of
// its own (nextDeadline() says when to call tick()). It never asks the person anything.
//
// Rules (macOS model): headphones, headsets, earbuds and Bluetooth audio the person connects take the sound at once; displays,
// docks, USB sound cards, virtual and other outputs never do; network outputs are never chosen. Outputs present at start or
// appearing within STARTUP_GRACE_MS change nothing. Arrivals settle together (SETTLE_MS after the last, at most MAX_SETTLE_MS
// after the first). Moving the sound away from such a device while it stays connected (still there MANUAL_WINDOW_MS later)
// is remembered: it no longer takes the sound; choosing it again restores that. A default change within RESTORE_WINDOW_MS of
// the new default's arrival is WirePlumber restoring its history, not a choice. When a device leaves, WirePlumber already
// returns the sound to the previous configured default: nothing is done here then.
//
// Inspired by Project Luma's luma-audio-devices routing rules (MPL-2.0); no code copied.

var STARTUP_GRACE_MS = 12000;
var SETTLE_MS = 2000;
var MAX_SETTLE_MS = 8000;
var MANUAL_WINDOW_MS = 1500;
var RESTORE_WINDOW_MS = 1000;
// A device whose last node left less than this ago and comes back is the same connection (a Bluetooth profile switch).
var RECONNECT_MS = 3000;
// Remembered devices (those that stopped taking the sound), the most recent kept.
var MEMORY_LIMIT = 64;
var VERSION = 1;

var NETWORK_PREFIXES = ["raop_sink.", "tunnel.", "rtp_session.", "rtp-sink", "roc-sink", "roc_sink", "snapcast", "netjack2_"];
var NETWORK_PROPS = ["raop.ip", "raop.hostname", "tunnel.mode", "pulse.server.address", "rtp.destination.ip", "snapcast.name", "roc.remote.source.endpoint"];
var PERSONAL_FORMS = ["headphone", "headset", "hands-free", "handset"];
var PERSONAL_ICONS = ["audio-headphones", "audio-headset"];

function text(v) {
    return v === undefined || v === null ? "" : String(v);
}

function truthy(v) {
    return v === true || v === "true" || v === "1";
}

// ---- Classification -------------------------------------------------------------------------------------------------------

// A property of the node, else of its device.
function lookup(node, device, key) {
    const n = text(node ? node[key] : undefined);
    return n !== "" ? n : text(device ? device[key] : undefined);
}

function isNetwork(node, device) {
    const name = text(node ? node["node.name"] : undefined);
    if (truthy(lookup(node, device, "node.network")) || lookup(node, device, "sess.media") === "raop")
        return true;
    if (NETWORK_PROPS.some(k => lookup(node, device, k) !== ""))
        return true;
    return NETWORK_PREFIXES.some(p => name.startsWith(p));
}

function bluetoothAddress(node, device) {
    const a = lookup(node, device, "api.bluez5.address");
    if (/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(a))
        return a.toUpperCase();
    const m = /^bluez_output\.([0-9A-Fa-f]{2}(?:[_:][0-9A-Fa-f]{2}){5})(\.|$)/.exec(text(node ? node["node.name"] : undefined));
    return m ? m[1].replace(/_/g, ":").toUpperCase() : "";
}

// Worn by the person: a form factor or an icon of headphones or a headset, on the node or on its device (an ALSA node's own
// icon is the card's generic one, so the device's counts too).
function isPersonal(node, device) {
    for (const props of [node, device]) {
        if (!props)
            continue;
        if (PERSONAL_FORMS.indexOf(text(props["device.form-factor"])) >= 0)
            return true;
        for (const key of ["device.icon-name", "device.icon_name"]) {
            if (PERSONAL_ICONS.indexOf(text(props[key]).replace(/-symbolic$/, "")) >= 0)
                return true;
        }
    }
    return false;
}

function isDisplay(node, device) {
    const name = text(node ? node["node.name"] : undefined);
    const profile = lookup(node, device, "device.profile.name");
    if (/(^|[.-])(hdmi|dp|displayport)-/.test(name) || /^(hdmi|dp)-/.test(profile))
        return true;
    for (const props of [node, device]) {
        if (props && (text(props["device.icon-name"]) === "video-display" || text(props["device.icon_name"]) === "video-display"))
            return true;
    }
    return false;
}

// The stable key of the device a node belongs to: bluez:<MAC>, usb:<vendor>:<product>[:<serial>], else node:<node.name>.
function deviceKey(node, device) {
    const name = text(node ? node["node.name"] : undefined);
    if (isNetwork(node, device))
        return "network:" + name;
    const mac = bluetoothAddress(node, device);
    if (mac !== "")
        return "bluez:" + mac;
    if (lookup(node, device, "device.bus") === "usb") {
        const vendor = lookup(node, device, "device.vendor.id").toLowerCase();
        const product = lookup(node, device, "device.product.id").toLowerCase();
        if (vendor !== "" && product !== "") {
            const serial = lookup(node, device, "device.serial");
            return "usb:" + vendor + ":" + product + (serial !== "" ? ":" + serial : "");
        }
    }
    return "node:" + name;
}

// One output as the router sees it: {node, key, name, priority, network, virtual, bluetooth, personal, display, takesSound}.
// `node` and `device` are PipeWire property maps (the device's may be null or {}).
function describe(node, device) {
    const name = text(node ? node["node.name"] : undefined);
    const api = lookup(node, device, "device.api");
    const network = isNetwork(node, device);
    const bluetooth = !network && (api === "bluez5" || bluetoothAddress(node, device) !== "");
    const virtual = !network && !bluetooth && api !== "alsa";
    const personal = !network && !virtual && isPersonal(node, device);
    const display = !network && !virtual && isDisplay(node, device);
    let priority = parseInt(lookup(node, device, "priority.session"), 10);
    if (!isFinite(priority))
        priority = parseInt(lookup(node, device, "priority.driver"), 10);
    return {
        node: name,
        key: deviceKey(node, device),
        name: text(node ? (node["node.description"] || node["node.nick"]) : undefined) || lookup(null, device, "device.description") || name,
        priority: isFinite(priority) ? priority : 0,
        network: network,
        virtual: virtual,
        bluetooth: bluetooth,
        personal: personal,
        display: display,
        takesSound: !network && !virtual && !display && (bluetooth || personal)
    };
}

// ---- State ----------------------------------------------------------------------------------------------------------------

// memory: {devices: {key: {auto: false, name}}} (parseMemory). `dirty` turns on when the memory changed (the caller saves it
// and clears the flag).
function create(memory) {
    return {
        memory: memory && memory.devices ? memory : {devices: {}},
        startedAt: null,
        outputs: {},      // node name -> output (describe)
        connected: {},    // device key -> when this connection began
        left: {},         // device key -> {at, since}: the last node left (RECONNECT_MS)
        pending: {},      // device key -> {first, due}: an arrival waiting to settle
        defaultNode: "",
        expected: "",     // the node this router asked to make the default, until that change is reported
        routed: "",       // the router's last switch, until a default change that is not its own
        away: null,       // {key, due, at}: was the move away from `key` a person's choice?
        hadSound: {},     // device key -> true: the device was the default during this connection
        dirty: false
    };
}

function note(event, out, reason) {
    return {type: "note", event: event, key: out.key, name: out.name, reason: reason};
}

function autoOf(st, key) {
    const m = st.memory.devices[key];
    return !(m && m.auto === false);
}

function setAuto(st, out, on, now) {
    if (autoOf(st, out.key) === on)
        return false;
    if (on)
        delete st.memory.devices[out.key];
    else
        st.memory.devices[out.key] = {auto: false, name: out.name, at: now};
    st.dirty = true;
    return true;
}

function inGrace(st, now) {
    return st.startedAt === null || now - st.startedAt < STARTUP_GRACE_MS;
}

function nodesOf(st, key) {
    return Object.keys(st.outputs).filter(n => st.outputs[n].key === key);
}

function decides(out) {
    return !out.network && !out.virtual;
}

// The shell connected to PipeWire: what is there now was there at login.
function start(st, outputs, defaultNode, now) {
    st.startedAt = now;
    st.defaultNode = text(defaultNode);
    for (const out of outputs) {
        st.outputs[out.node] = out;
        if (decides(out) && st.connected[out.key] === undefined)
            st.connected[out.key] = now - STARTUP_GRACE_MS;
        if (out.node === st.defaultNode)
            st.hadSound[out.key] = true;
    }
    return [];
}

function prune(st, now) {
    for (const key of Object.keys(st.left)) {
        if (now - st.left[key].at > RECONNECT_MS)
            delete st.left[key];
    }
}

function added(st, out, now) {
    prune(st, now);
    const known = st.outputs[out.node];
    if (known && known.key !== out.key)
        return updated(st, out, now);
    st.outputs[out.node] = out;
    if (out.node === st.defaultNode)
        st.hadSound[out.key] = true;
    if (known || !decides(out) || st.connected[out.key] !== undefined)
        return [];
    const back = st.left[out.key];
    if (back !== undefined) {
        delete st.left[out.key];
        st.connected[out.key] = back.since;
        return [];
    }
    st.connected[out.key] = now;
    if (inGrace(st, now))
        return [note("kept", out, "present at start")];
    if (st.pending[out.key] === undefined)
        st.pending[out.key] = {first: now, due: now + SETTLE_MS};
    // One burst (a dock, a profile change) settles as a whole.
    for (const key of Object.keys(st.pending)) {
        const p = st.pending[key];
        p.due = Math.max(p.due, Math.min(now + SETTLE_MS, p.first + MAX_SETTLE_MS));
    }
    return [];
}

// A node's properties changed (its device's arrived late): the output is described again. A new key moves the connection.
function updated(st, out, now) {
    const known = st.outputs[out.node];
    if (!known)
        return added(st, out, now);
    st.outputs[out.node] = out;
    if (known.key !== out.key && nodesOf(st, known.key).length === 0) {
        for (const table of [st.connected, st.pending, st.hadSound]) {
            if (table[known.key] !== undefined) {
                if (table[out.key] === undefined)
                    table[out.key] = table[known.key];
                delete table[known.key];
            }
        }
        if (st.away && st.away.key === known.key)
            st.away.key = out.key;
    }
    // The same connection under its better key (never a new arrival: the node was already there).
    if (decides(out) && st.connected[out.key] === undefined)
        st.connected[out.key] = st.connected[known.key] !== undefined ? st.connected[known.key] : now;
    if (out.node === st.defaultNode)
        st.hadSound[out.key] = true;
    return [];
}

// The properties of the device object `id` in `pw-dump <id>`'s JSON answer (an array of objects), or null.
function deviceProps(textValue, id) {
    let list;
    try {
        list = JSON.parse(textValue);
    } catch (e) {
        return null;
    }
    if (!Array.isArray(list))
        return null;
    for (const o of list) {
        if (o && o.id === id && typeof o.type === "string" && o.type.indexOf("Device") >= 0 && o.info && o.info.props
                && typeof o.info.props === "object")
            return o.info.props;
    }
    return null;
}

// `configured`: WirePlumber's configured default when the node left, if known ("" or null: unknown). It records the
// person's last choice even when the default change itself came late or not at all: only while the leaving node is still the
// default as far as the router knows (a reported change is the away check's), and never when the configured default is the
// router's own switch (Audio.qml writes the same configured default a person's choice does).
function removed(st, node, now, configured) {
    const out = st.outputs[node];
    if (!out)
        return [];
    delete st.outputs[node];
    if (nodesOf(st, out.key).length > 0 || st.connected[out.key] === undefined)
        return [];
    const actions = [];
    const conf = text(configured);
    if (out.takesSound && st.hadSound[out.key] && conf !== "") {
        const chosenElsewhere = conf !== node && conf !== st.routed && st.defaultNode === node;
        if (chosenElsewhere && setAuto(st, out, false, now))
            actions.push(note("remembered", out, "moved away from it: it no longer takes the sound when it connects"));
        else if (conf === node && setAuto(st, out, true, now))
            actions.push(note("remembered", out, "chosen: it takes the sound again when it connects"));
    }
    st.left[out.key] = {at: now, since: st.connected[out.key]};
    delete st.connected[out.key];
    delete st.pending[out.key];
    delete st.hadSound[out.key];
    if (st.away && st.away.key === out.key)
        st.away = null;
    return actions;
}

function defaultChanged(st, node, now) {
    const name = text(node);
    const previous = st.outputs[st.defaultNode];
    st.defaultNode = name;
    const current = st.outputs[name];
    if (current)
        st.hadSound[current.key] = true;
    if (name !== "" && name === st.expected) {
        // The router's own switch: what WirePlumber's configured default now names (`routed`) is not a person's choice.
        st.expected = "";
        return [];
    }
    st.expected = "";
    st.routed = "";
    const actions = [];
    if (current && current.takesSound && !autoOf(st, current.key)) {
        const arrived = st.connected[current.key] !== undefined ? st.connected[current.key] : -Infinity;
        if (now - arrived > RESTORE_WINDOW_MS && setAuto(st, current, true, now))
            actions.push(note("remembered", current, "chosen: it takes the sound again when it connects"));
    }
    if (previous && previous.takesSound && (!current || current.key !== previous.key))
        st.away = {key: previous.key, due: now + MANUAL_WINDOW_MS, at: now};
    return actions;
}

function best(st, key) {
    let out = null;
    for (const n of nodesOf(st, key)) {
        const o = st.outputs[n];
        if (out === null || o.priority > out.priority)
            out = o;
    }
    return out;
}

function tick(st, now) {
    prune(st, now);
    const actions = [];
    if (st.away && st.away.due <= now) {
        const a = st.away;
        st.away = null;
        const current = st.outputs[st.defaultNode];
        const currentArrived = current && st.connected[current.key] !== undefined ? st.connected[current.key] : -Infinity;
        const restored = !!current && a.at - currentArrived <= RESTORE_WINDOW_MS;
        const left = best(st, a.key);
        if (st.connected[a.key] !== undefined && left && !restored && (!current || current.key !== a.key)
                && setAuto(st, left, false, now))
            actions.push(note("remembered", left, "moved away from it: it no longer takes the sound when it connects"));
    }
    const due = Object.keys(st.pending).filter(k => st.pending[k].due <= now);
    if (due.length === 0)
        return actions;
    const arrivals = [];
    for (const key of due) {
        delete st.pending[key];
        const out = best(st, key);
        if (out)
            arrivals.push(out);
    }
    const current = st.outputs[st.defaultNode];
    const takers = [];
    for (const out of arrivals) {
        if (current && current.key === out.key)
            actions.push(note("kept", out, "already the output"));
        else if (!out.takesSound)
            actions.push(note("kept", out, out.display ? "a display never takes the sound by itself" : "docks, sound cards and other outputs never take the sound by themselves"));
        else if (!autoOf(st, out.key))
            actions.push(note("kept", out, "the sound was moved away from it last time"));
        else
            takers.push(out);
    }
    if (takers.length > 0) {
        let chosen = takers[0];
        for (const out of takers) {
            if (out.priority > chosen.priority)
                chosen = out;
        }
        const reason = chosen.personal ? "headphones or headset connected" : "Bluetooth audio connected";
        st.expected = chosen.node;
        st.routed = chosen.node;
        actions.push(note("switched", chosen, reason));
        actions.push({type: "switch", node: chosen.node, key: chosen.key, name: chosen.name, reason: reason});
        for (const out of takers) {
            if (out !== chosen)
                actions.push(note("kept", out, chosen.name + " connected at the same time"));
        }
    }
    return actions;
}

// The time tick() must run next, or null.
function nextDeadline(st) {
    let t = null;
    for (const key of Object.keys(st.pending)) {
        if (t === null || st.pending[key].due < t)
            t = st.pending[key].due;
    }
    if (st.away && (t === null || st.away.due < t))
        t = st.away.due;
    return t;
}

// A device key as the journal shows it (rc7 audit R7-SEC-04): never a hardware identifier, since the journal reaches the
// diagnostic report and the report can reach a public issue. A USB device loses its serial (usb:<vendor>:<product>), a
// Bluetooth device its address, a node name a USB device's udev ID_SERIAL. The routing keeps the whole key (deviceKey); the
// log does not need to tell two identical devices apart.
function logKey(key) {
    const k = String(key || "");
    const usb = /^usb:([^:]*):([^:]*)(?::.*)?$/.exec(k);
    if (usb)
        return "usb:" + usb[1] + ":" + usb[2];
    if (k.indexOf("bluez:") === 0)
        return "bluez:XX:XX:XX:XX:XX:XX";
    return k.replace(/(\.usb-)[A-Za-z0-9._-]+?(-[0-9]{2})(?=[.]|$)/, "$1[usb device]$2");
}

// The log line of a note: the key through logKey.
function describeNote(a) {
    return "audio routing: " + a.event + " " + a.name + " (" + logKey(a.key) + "): " + a.reason;
}

// ---- Persistence (audio-routing.json, state class, ADR-0020) ----------------------------------------------------------------

// {devices: {key: {auto: false, name, at}}, readOnly}. Anything unreadable is an empty memory; a newer version is read as
// empty and read-only (never rewritten).
function parseMemory(textValue) {
    const empty = {devices: {}, readOnly: false};
    let o;
    try {
        o = JSON.parse(textValue);
    } catch (e) {
        return empty;
    }
    if (!o || typeof o !== "object" || Array.isArray(o))
        return empty;
    if (Number.isInteger(o.version) && o.version > VERSION)
        return {devices: {}, readOnly: true};
    if (o.version !== VERSION || !o.devices || typeof o.devices !== "object" || Array.isArray(o.devices))
        return empty;
    const devices = {};
    for (const key of Object.keys(o.devices)) {
        const d = o.devices[key];
        if (typeof key !== "string" || key.length > 512 || !/^(bluez|usb|node|network):/.test(key))
            continue;
        if (!d || typeof d !== "object" || d.auto !== false)
            continue;
        devices[key] = {auto: false, name: typeof d.name === "string" ? d.name.slice(0, 256) : "", at: Number.isFinite(d.at) ? d.at : 0};
    }
    return {devices: devices, readOnly: false};
}

function serializeMemory(memory) {
    const keys = Object.keys(memory.devices).sort((a, b) => (memory.devices[b].at || 0) - (memory.devices[a].at || 0)).slice(0, MEMORY_LIMIT);
    keys.sort();
    const devices = {};
    for (const key of keys) {
        const d = memory.devices[key];
        devices[key] = {auto: false, name: d.name || "", at: d.at || 0};
    }
    return JSON.stringify({version: VERSION, devices: devices}, null, 2) + "\n";
}
