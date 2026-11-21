.pragma library

// The shell's own health sample (owner's report of 2026-11-21: two SIGKILLs with nothing in the journal naming the sender, and
// a memory peak of 1.3 GB against gate P2's ~600 MB). services/process-health.sh prints one line of key=value pairs read from
// /proc (memory in kB, the threads under a realtime policy, RLIMIT_RTTIME); ShellHealth.qml logs what this file makes of it at
// start, after every display change and every few minutes, and keeps the last one in the runtime directory, where the unit's
// ExecStopPost (services/shell-stopped.sh) finds it after a SIGKILL. Pure (tests/unit/tst_processhealth.qml).

var POLICIES = {"1": "FIFO", "2": "RR", "6": "DEADLINE"};

function kb(v) {
    var n = parseInt(v, 10);
    return isFinite(n) && n >= 0 && String(n) === String(v) ? n : -1;
}

function mb(k) {
    return k < 0 ? -1 : Math.round(k / 1024);
}

// The sample, or null when the line has no VmRSS.
function parse(line) {
    var out = {rss: -1, peak: -1, anon: -1, file: -1, shmem: -1, pss: -1, threads: -1, rtSoft: "", rtHard: "", rt: [],
        cgCurrent: -1, cgPeak: -1, cgAnon: -1, cgFile: -1, cgShmem: -1, cgKernel: -1};
    var parts = String(line || "").trim().split(/\s+/);
    var keys = {VmRSS: "rss", VmHWM: "peak", RssAnon: "anon", RssFile: "file", RssShmem: "shmem", Pss: "pss", Threads: "threads",
        CgCurrent: "cgCurrent", CgPeak: "cgPeak", CgAnon: "cgAnon", CgFile: "cgFile", CgShmem: "cgShmem", CgKernel: "cgKernel"};
    for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq <= 0)
            continue;
        var k = parts[i].slice(0, eq), v = parts[i].slice(eq + 1);
        if (keys[k] !== undefined) {
            out[keys[k]] = kb(v);
        } else if (k === "RtTimeSoft" || k === "RtTimeHard") {
            if (v === "unlimited" || /^[0-9]{1,12}$/.test(v))
                out[k === "RtTimeSoft" ? "rtSoft" : "rtHard"] = v;
        } else if (k === "Rt" && v !== "none") {
            var threads = v.split(",");
            for (var j = 0; j < threads.length && out.rt.length < 16; j++) {
                var m = /^([A-Za-z0-9._-]{1,16}):([0-9]{1,2}):([0-9]{1,3})$/.exec(threads[j]);
                if (m)
                    out.rt.push({name: m[1], policy: POLICIES[m[2]] || ("policy " + m[2]), priority: parseInt(m[3], 10)});
            }
        }
    }
    return out.rss < 0 ? null : out;
}

// A realtime thread under a realtime CPU limit: the kernel kills the whole process with SIGKILL, silently, once one of them
// runs that long without sleeping.
function rtKillable(sample) {
    return sample !== null && sample.rt.length > 0 && sample.rtHard !== "" && sample.rtHard !== "unlimited";
}

function rtText(sample) {
    if (sample.rt.length === 0)
        return "none";
    return sample.rt.map(function (t) {
        return t.name + " (" + t.policy + " " + t.priority + ")";
    }).join(", ");
}

// The journal line (after "grassfield-shell: health <why>: ").
function describe(sample) {
    return "rss " + mb(sample.rss) + " MB (anon " + mb(sample.anon) + ", file " + mb(sample.file) + ", shmem " + mb(sample.shmem)
        + "), pss " + mb(sample.pss) + " MB, peak rss " + mb(sample.peak) + " MB, " + sample.threads + " threads, realtime threads "
        + rtText(sample) + ", realtime CPU limit " + (sample.rtHard === "" ? "?" : sample.rtHard + (sample.rtHard === "unlimited" ? "" : " us"))
        + (sample.cgCurrent < 0 ? "" : ", unit " + mb(sample.cgCurrent) + " MB (anon " + mb(sample.cgAnon) + ", file " + mb(sample.cgFile)
            + ", shmem " + mb(sample.cgShmem) + ", kernel " + mb(sample.cgKernel) + "), unit peak " + mb(sample.cgPeak) + " MB");
}

// The runtime file's one line: "at=<unix s> <why> <journal text>".
function record(sample, why, nowMs) {
    return "at=" + Math.floor(nowMs / 1000) + " " + why + ": " + describe(sample);
}

// "grassfield-shell-health" in the session's runtime directory, "" without one.
function recordPath(runtimeDir) {
    var dir = String(runtimeDir || "");
    return dir !== "" && dir.charAt(0) === "/" ? dir + "/grassfield-shell-health" : "";
}
