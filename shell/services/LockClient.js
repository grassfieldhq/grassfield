.pragma library

// The UI's calls into the security process (ADR-0041 step 1, S2), pure (tests/security/tst_lockstate.qml). The UI holds no
// lock: the Grassfield menu, the screen corners and Search ask the security instance to lock, and the UI leases it the
// applications' org.freedesktop.ScreenSaver inhibitors, which the menu bridge serves to the UI. Each call is one `qs ipc`
// process against the security root by its path (the UI's own shellDir + "/security.qml": the packaged
// /usr/share/grassfield/shell/security.qml, or the dev tree's), with Quickshell's option variables cleared as every
// `qs ipc` caller of the session does (a stray QS_MANIFEST made `qs ipc -p` exit 108: the re-review of bf9e280), and bounded
// (a hung security process answers nothing within 5 s: the request is tried again, then handed to the stand-in).

// IPC target and function of each call (tests/security/ipc_inventory.sh reads this table as a real-session caller).
var IPC = {
    lock: ["lock", "lock"],
    inhibit: ["idle", "inhibit"]
};

// A lock request is retried this often (ms) for at most REQUEST_BUDGET_MS while the security process does not answer (it is
// restarting: systemd brings it back within about a second, then it loads).
var REQUEST_RETRY_MS = 250;
var REQUEST_BUDGET_MS = 10000;

// The security root next to the UI's root.
function securityRoot(shellDir) {
    var dir = String(shellDir || "");
    while (dir.length > 1 && dir.charAt(dir.length - 1) === "/")
        dir = dir.slice(0, -1);
    return dir === "" ? "" : dir + "/security.qml";
}

// argv of a call (`name` a key of IPC), or null without a root.
function command(name, root, args) {
    var target = IPC[name];
    if (!target || root === "")
        return null;
    var argv = ["env", "-u", "QS_CONFIG_PATH", "-u", "QS_CONFIG_NAME", "-u", "QS_MANIFEST", "timeout", "-k", "1", "5", "qs", "ipc", "-p", root, "call", target[0], target[1]];
    var extra = args || [];
    for (var i = 0; i < extra.length; i++)
        argv.push(String(extra[i]));
    return argv;
}

// `lock lock` answered: the request is done (the lock decides; "refused: missing-pam" is its answer too). Anything else
// (nothing, "Not ready to accept queries yet", an error) is no answer: the request is tried again.
function lockAnswered(stdout) {
    var a = String(stdout || "").trim();
    return a === "ok" || a === "already-locked" || a.indexOf("refused:") === 0;
}

// The lease to ask for: INHIBIT_SECONDS while an application holds an inhibitor, 0 (end it) otherwise. Renewed every
// INHIBIT_RENEW_MS (shell/security/idle/IdleModel.js holds the bound on the security side: 150 s).
var INHIBIT_SECONDS = 150;
var INHIBIT_RENEW_MS = 60000;

function inhibitSeconds(inhibited) {
    return inhibited === true ? INHIBIT_SECONDS : 0;
}
