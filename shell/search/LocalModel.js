.pragma library

// Detection of a local Ollama for Search (ADR-0067 D-4, docs/specs/command-palette.md A1). Pure: no QML type, no service;
// the QML side hands in an XMLHttpRequest factory, a timer, the clock and the text of /proc/net/tcp, /proc/net/tcp6 and
// /etc/passwd. Nothing here can be pointed elsewhere: the two base URLs are constants and `create` has no URL option.
//
// Fail closed everywhere: no listener, a listener of another uid, no answer, an answer that is not what Ollama sends, or a
// model that cannot be shown to run on this machine -> nothing is offered.

const PORT = 11434;
// The only bases ever requested (127.0.0.1 first, then [::1]).
const BASES = ["http://127.0.0.1:11434", "http://[::1]:11434"];
const CACHE_MS = 60000;
const TIMEOUT_MS = 2000;
const MAX_BODY = 4 * 1024 * 1024;
const MAX_MODELS = 200;
const MIN_LOCAL_SIZE = 1024 * 1024;   // a cloud model's stub in /api/tags is a few hundred bytes (UNCONFIRMED threshold, spec A1)
const SERVICE_ACCOUNT = "ollama";
const MAX_SYSTEM_UID = 999;

// ---- /proc/net/tcp and tcp6 -------------------------------------------------------------------------------------------------

// Address kinds that can receive a connection to the loopback address: exact loopback, the wildcard, or the IPv4-mapped forms.
function _kind(hex) {
    const h = hex.toUpperCase();
    if (h.length === 8) {
        if (h === "0100007F")
            return "loopback4";
        if (h === "00000000")
            return "any4";
        return "";
    }
    if (h.length === 32) {
        if (h === "00000000000000000000000001000000")
            return "loopback6";
        if (h === "00000000000000000000000000000000")
            return "any6";
        if (h === "0000000000000000FFFF00000100007F")
            return "loopback4";
        if (h === "0000000000000000FFFF000000000000")
            return "any4";
        return "";
    }
    return "";
}

// Rows of a /proc/net/tcp{,6} text: [{kind, port, state, uid}] for every LISTEN (state 0A) entry on PORT whose address can be
// reached through the loopback. Malformed lines are skipped.
function parseProcNet(text) {
    const out = [];
    if (typeof text !== "string")
        return out;
    const lines = text.split("\n");
    for (let i = 1; i < lines.length; i++) {
        const f = lines[i].trim().split(/\s+/);
        if (f.length < 8)
            continue;
        const m = /^([0-9A-Fa-f]{8}|[0-9A-Fa-f]{32}):([0-9A-Fa-f]{4})$/.exec(f[1]);
        if (!m || parseInt(m[2], 16) !== PORT || f[3].toUpperCase() !== "0A")
            continue;
        const kind = _kind(m[1]);
        const uid = /^[0-9]+$/.test(f[7]) ? parseInt(f[7], 10) : -1;
        if (kind !== "" && uid >= 0)
            out.push({kind: kind, port: PORT, state: "LISTEN", uid: uid});
    }
    return out;
}

// The uid of the system account "ollama" in an /etc/passwd text, or -1 (absent, or not a system uid: 1..999).
function serviceUid(passwd) {
    if (typeof passwd !== "string")
        return -1;
    for (const line of passwd.split("\n")) {
        const f = line.split(":");
        if (f.length >= 3 && f[0] === SERVICE_ACCOUNT && /^[0-9]+$/.test(f[2])) {
            const uid = parseInt(f[2], 10);
            return uid >= 1 && uid <= MAX_SYSTEM_UID ? uid : -1;
        }
    }
    return -1;
}

// {ok, reason} for the listener(s) on 127.0.0.1:11434 / [::1]:11434 (and the wildcard sockets that also answer there): at
// least one must exist and every one must belong to the user (myUid) or to the packaged service account.
function checkListener(tcp, tcp6, myUid, passwd) {
    const rows = parseProcNet(tcp).concat(parseProcNet(tcp6));
    if (rows.length === 0)
        return {ok: false, reason: "no-listener"};
    const svc = serviceUid(passwd);
    for (const r of rows) {
        if (r.uid !== myUid && (svc < 0 || r.uid !== svc))
            return {ok: false, reason: "bad-uid", uid: r.uid};
    }
    return {ok: true, reason: ""};
}

// ---- answers ----------------------------------------------------------------------------------------------------------------

function _json(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_BODY)
        return null;
    try {
        const v = JSON.parse(text);
        return v !== null && typeof v === "object" && !Array.isArray(v) ? v : null;
    } catch (e) {
        return null;
    }
}

// The version string of a /api/version answer, or "" when it is not one.
function parseVersion(text) {
    const o = _json(text);
    return o && typeof o.version === "string" && /^[0-9A-Za-z.+_-]{1,40}$/.test(o.version) ? o.version : "";
}

function _goodName(n) {
    return typeof n === "string" && n.length >= 1 && n.length <= 128 && /^[A-Za-z0-9][A-Za-z0-9._:\/@+-]*$/.test(n);
}

function _present(v) {
    return v !== undefined && v !== null && v !== "";
}

// A /api/tags entry that runs on this machine. Dropped: a remote_host or remote_model field (Ollama's documented marker of a
// model served by another host, docs.ollama.com/api/tags), a ":cloud" or "-cloud" tag (the documented names of Ollama's cloud
// models, docs.ollama.com/cloud/models), and anything without a real local size (fail closed).
function isLocalModel(m) {
    if (!m || typeof m !== "object" || !_goodName(m.name))
        return false;
    if (_present(m.remote_host) || _present(m.remote_model) || "remote_host" in m || "remote_model" in m)
        return false;
    if (m.model !== undefined && !_goodName(m.model))
        return false;
    if (/(^|[:\-])cloud$/i.test(m.name) || (m.model !== undefined && /(^|[:\-])cloud$/i.test(m.model)))
        return false;
    return typeof m.size === "number" && isFinite(m.size) && m.size >= MIN_LOCAL_SIZE;
}

// The names of the local models of a /api/tags answer ([] when it is not one), sorted, at most MAX_MODELS.
function parseTags(text) {
    const o = _json(text);
    if (!o || !Array.isArray(o.models))
        return [];
    const names = [];
    for (const m of o.models) {
        if (isLocalModel(m) && names.indexOf(m.name) < 0)
            names.push(m.name);
        if (names.length >= MAX_MODELS)
            break;
    }
    return names.sort();
}

// The model to use: the setting when it is still installed, else the first one ("" without any).
function chooseModel(models, wanted) {
    if (!Array.isArray(models) || models.length === 0)
        return "";
    return typeof wanted === "string" && models.indexOf(wanted) >= 0 ? wanted : models[0];
}

// ---- the detector -----------------------------------------------------------------------------------------------------------

const ABSENT = {state: "absent", reason: "", version: "", models: [], base: ""};

// deps:
//   newRequest()          -> an XMLHttpRequest-like (open, send, abort, onreadystatechange, readyState, status, responseText)
//   startTimer(ms, fn)    -> a function that cancels the timer
//   now()                 -> milliseconds
//   readIdentity(cb)      -> cb({tcp, tcp6, passwd, uid}) : the texts of /proc/net/tcp, /proc/net/tcp6, /etc/passwd and the
//                            user's uid (null on a read error -> absent)
//   log(msg)              -> optional journal line
// Any other key is ignored: there is no URL, host, port or proxy option.
function create(deps) {
    const d = deps || {};
    let cache = null;
    let cachedAt = 0;
    let waiting = null;

    function log(msg) {
        if (typeof d.log === "function")
            d.log("search: local model: " + msg);
    }

    function result(state, reason, version, models, base) {
        return {state: state, reason: reason, version: version || "", models: models || [], base: base || ""};
    }

    // One GET of a constant URL: cb(status, text) with status 0 on a timeout or a network error. A real QML XHR follows a
    // redirect (a 302 from 127.0.0.1 to another host answers 200 with the target's body), so an answer whose responseURL is
    // not exactly the URL asked is refused (status 0, as a network error).
    function get(url, cb) {
        let done = false;
        let cancel = function () {};
        const xhr = d.newRequest();
        const finish = (status, text) => {
            if (done)
                return;
            done = true;
            cancel();
            cb(status, text);
        };
        cancel = d.startTimer(TIMEOUT_MS, () => {
            try {
                xhr.abort();
            } catch (e) {}
            finish(0, "");
        });
        xhr.onreadystatechange = () => {
            if (xhr.readyState === 4)
                {
                if (xhr.responseURL !== url)
                    finish(0, "");
                else
                    finish(xhr.status, xhr.status === 200 ? xhr.responseText : "");
            }
        };
        try {
            xhr.open("GET", url);
            xhr.send();
        } catch (e) {
            finish(0, "");
        }
    }

    function tryBase(i, cb) {
        if (i >= BASES.length) {
            cb(result("absent", "no-answer"));
            return;
        }
        const base = BASES[i];
        get(base + "/api/version", (st, text) => {
            const version = st === 200 ? parseVersion(text) : "";
            if (version === "") {
                tryBase(i + 1, cb);
                return;
            }
            get(base + "/api/tags", (st2, text2) => {
                if (st2 !== 200 || _json(text2) === null) {
                    tryBase(i + 1, cb);
                    return;
                }
                cb(result("present", "", version, parseTags(text2), base));
            });
        });
    }

    function run(cb) {
        d.readIdentity(id => {
            if (!id) {
                cb(result("absent", "no-proc"));
                return;
            }
            const c = checkListener(id.tcp, id.tcp6, id.uid, id.passwd);
            if (!c.ok) {
                if (c.reason === "bad-uid")
                    log("port " + PORT + " is held by uid " + c.uid + ", not offered");
                cb(result("absent", c.reason));
                return;
            }
            tryBase(0, cb);
        });
    }

    // detect(cb, force): cb(result) once; the result is cached for 60 s, an absent one too. Calls made while one is running
    // share its answer.
    // The clock is not monotonic: a backward jump (now < cachedAt) expires the cache.
    function fresh() {
        const age = d.now() - cachedAt;
        return cache !== null && age >= 0 && age < CACHE_MS;
    }

    function detect(cb, force) {
        if (!force && fresh()) {
            cb(cache);
            return;
        }
        if (waiting !== null) {
            waiting.push(cb);
            return;
        }
        waiting = [cb];
        run(r => {
            cache = r;
            cachedAt = d.now();
            const list = waiting;
            waiting = null;
            for (const f of list)
                f(r);
        });
    }

    return {
        detect: detect,
        cached: () => (fresh() ? cache : ABSENT),
        invalidate: () => {
            cache = null;
        }
    };
}
