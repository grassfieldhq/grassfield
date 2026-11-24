import QtQuick
import QtTest
import "../../shell/search/LocalModel.js" as LocalModel

// Detection of a local Ollama (ADR-0067 D-4, palette A1): the /proc/net/tcp listener check, the answers of /api/version and
// /api/tags, remote models dropped, timeouts, the 60 s cache, and that no URL can be configured.
TestCase {
    name: "SearchLocalModel"

    readonly property string head: "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

    function row(addr, st, uid) {
        return "   0: " + addr + " 00000000:0000 " + st + " 00000000:00000000 00:00000000 00000000  " + uid + "        0 12345 1 0000000000000000 100 0 0 10 0\n";
    }

    readonly property string v4Loop: "0100007F:2CAA"
    readonly property string v4Any: "00000000:2CAA"
    readonly property string v6Loop: "00000000000000000000000001000000:2CAA"
    readonly property string v6Any: "00000000000000000000000000000000:2CAA"
    readonly property string passwd: "root:x:0:0::/root:/bin/bash\nollama:x:963:963:Ollama:/var/lib/ollama:/usr/bin/nologin\nchap:x:1000:1000::/home/chap:/bin/bash\n"

    function test_parseProcNet() {
        compare(LocalModel.parseProcNet(head + row(v4Loop, "0A", 1000)).length, 1);
        const r = LocalModel.parseProcNet(head + row(v4Loop, "0A", 963))[0];
        compare(r.uid, 963);
        compare(r.kind, "loopback4");
        compare(LocalModel.parseProcNet(head + row(v6Loop, "0A", 1000))[0].kind, "loopback6");
        compare(LocalModel.parseProcNet(head + row(v6Any, "0A", 1000))[0].kind, "any6");
        compare(LocalModel.parseProcNet(head + row(v4Any, "0A", 1000))[0].kind, "any4");
        // not LISTEN, other port, other address, garbage
        compare(LocalModel.parseProcNet(head + row(v4Loop, "01", 1000)).length, 0);
        compare(LocalModel.parseProcNet(head + row("0100007F:1F90", "0A", 1000)).length, 0);
        compare(LocalModel.parseProcNet(head + row("0200007F:2CAA", "0A", 1000)).length, 0);
        compare(LocalModel.parseProcNet(head + row("0100A8C0:2CAA", "0A", 1000)).length, 0);
        compare(LocalModel.parseProcNet(head + "garbage\n\n   1: zz\n").length, 0);
        compare(LocalModel.parseProcNet(null).length, 0);
        compare(LocalModel.parseProcNet(head + row(v4Loop, "0A", "x")).length, 0);
    }

    function test_serviceUid() {
        compare(LocalModel.serviceUid(passwd), 963);
        compare(LocalModel.serviceUid("ollama:x:0:0::/:/bin/sh\n"), -1);
        compare(LocalModel.serviceUid("ollama:x:1001:1001::/:/bin/sh\n"), -1);
        compare(LocalModel.serviceUid("notollama:x:963:963::/:/bin/sh\n"), -1);
        compare(LocalModel.serviceUid(""), -1);
        compare(LocalModel.serviceUid(undefined), -1);
    }

    function test_checkListener() {
        const tcp = head + row(v4Loop, "0A", 1000);
        verify(LocalModel.checkListener(tcp, head, 1000, passwd).ok);
        verify(LocalModel.checkListener(head + row(v4Loop, "0A", 963), head, 1000, passwd).ok);
        verify(LocalModel.checkListener(head, head + row(v6Loop, "0A", 963), 1000, passwd).ok);
        // another local user
        let c = LocalModel.checkListener(head + row(v4Loop, "0A", 1001), head, 1000, passwd);
        verify(!c.ok);
        compare(c.reason, "bad-uid");
        // the service account name absent, or not a system uid: only the user's own uid passes
        verify(!LocalModel.checkListener(head + row(v4Loop, "0A", 963), head, 1000, "chap:x:1000:1000::/h:/bin/sh\n").ok);
        // nobody listens
        compare(LocalModel.checkListener(head, head, 1000, passwd).reason, "no-listener");
        compare(LocalModel.checkListener(null, undefined, 1000, passwd).reason, "no-listener");
        // IPv4-mapped forms in tcp6: the user's Ollama on [::1], a stranger on ::ffff:127.0.0.1 or ::ffff:0.0.0.0
        const mine = row(v6Loop, "0A", 1000);
        verify(!LocalModel.checkListener(head, head + mine + row("0000000000000000FFFF00000100007F:2CAA", "0A", 4242), 1000, passwd).ok);
        verify(!LocalModel.checkListener(head, head + mine + row("0000000000000000FFFF000000000000:2CAA", "0A", 4242), 1000, passwd).ok);
        compare(LocalModel.parseProcNet(head + row("0000000000000000FFFF00000100007F:2CAA", "0A", 1))[0].kind, "loopback4");
        compare(LocalModel.parseProcNet(head + row("0000000000000000FFFF000000000000:2CAA", "0A", 1))[0].kind, "any4");
        // a second listener (SO_REUSEPORT, a wildcard socket) of a stranger fails the whole check
        c = LocalModel.checkListener(head + row(v4Loop, "0A", 1000) + row(v4Any, "0A", 1001), head, 1000, passwd);
        verify(!c.ok);
        c = LocalModel.checkListener(head + row(v4Loop, "0A", 1000), head + row(v6Any, "0A", 4242), 1000, passwd);
        verify(!c.ok);
        // root squatting is refused too
        verify(!LocalModel.checkListener(head + row(v4Loop, "0A", 0), head, 1000, passwd).ok);
    }

    function model(name, extra) {
        const m = {name: name, model: name, size: 2000000000, digest: "abc"};
        for (const k in extra || {})
            m[k] = extra[k];
        return m;
    }

    function test_remoteModelsDropped() {
        const tags = JSON.stringify({models: [
                model("llama3.2:3b"),
                model("gemma4:cloud", {size: 384}),
                model("gpt-oss:120b-cloud"),
                model("qwen3:8b", {remote_host: "https://ollama.com:443", remote_model: "qwen3:8b"}),
                model("viaother:1b", {remote_host: "http://10.0.0.5:11434"}),
                model("only-model:1b", {remote_model: "x"}),
                model("emptyfield:1b", {remote_host: ""}),
                model("tiny:1b", {size: 10}),
                model("nosize:1b", {size: undefined}),
                model("strsize:1b", {size: "2000000000"}),
                model("Bad Name"),
                {name: "alias:1b", model: "x:cloud", size: 2000000000},
                model("mistral:7b"),
                model("llama3.2:3b")
            ]});
        compare(LocalModel.parseTags(tags), ["llama3.2:3b", "mistral:7b"]);
        compare(LocalModel.parseTags("{}"), []);
        compare(LocalModel.parseTags("[]"), []);
        compare(LocalModel.parseTags("nope"), []);
        compare(LocalModel.parseTags('{"models": "x"}'), []);
        compare(LocalModel.parseTags('{"models": [null, 3, "a", []]}'), []);
    }

    function test_malformedModelFieldDropsEntry() {
        const tags = JSON.stringify({models: [
                model("ok:1b"),
                model("a:1b", {model: 5}),
                model("b:1b", {model: "bad name"}),
                model("c:1b", {model: ""}),
                model("d:1b", {model: null})
            ]});
        compare(LocalModel.parseTags(tags), ["ok:1b"]);
    }

    function test_versionAndChoice() {
        compare(LocalModel.parseVersion('{"version":"0.40.17"}'), "0.40.17");
        compare(LocalModel.parseVersion('{"version":"0.0.0-rc1+x"}'), "0.0.0-rc1+x");
        for (const bad of ['{"version":5}', '{"version":"<b>"}', '{}', '', 'x', '[]', '{"version":""}'])
            compare(LocalModel.parseVersion(bad), "", bad);
        compare(LocalModel.chooseModel(["a", "b"], "b"), "b");
        compare(LocalModel.chooseModel(["a", "b"], "gone"), "a");
        compare(LocalModel.chooseModel(["a", "b"], ""), "a");
        compare(LocalModel.chooseModel([], "a"), "");
    }

    // ---- the detector with a fake responder ----

    property var requests: []
    property var timers: []
    property real clock: 0
    property var routes: ({})        // url -> {status, body} or "hang" or "throw"
    property int identityReads: 0
    property var identity: null
    property var logs: []

    function fakeXhr() {
        const x = {readyState: 0, status: 0, responseText: "", onreadystatechange: null, aborted: false, url: ""};
        x.open = (m, u) => {
            x.url = u;
            requests.push(m + " " + u);
        };
        x.abort = () => {
            x.aborted = true;
        };
        x.send = () => {
            const r = routes[x.url];
            if (r === "throw")
                throw new Error("refused");
            if (r === "hang")
                return;
            // an unrouted URL is a refused connection: done, status 0
            x.responseURL = r !== undefined && r.finalUrl !== undefined ? r.finalUrl : x.url;
            x.status = r === undefined ? 0 : r.status;
            x.responseText = r === undefined ? "" : r.body;
            x.readyState = 4;
            x.onreadystatechange();
        };
        return x;
    }

    function detector() {
        return LocalModel.create({
            newRequest: fakeXhr,
            startTimer: (ms, fn) => {
                const t = {ms: ms, fn: fn, live: true};
                timers.push(t);
                return () => {
                    t.live = false;
                };
            },
            now: () => clock,
            readIdentity: cb => {
                identityReads++;
                cb(identity);
            },
            log: m => logs.push(m),
            // ignored on purpose: nothing can redirect the detector
            url: "http://evil.example:80", baseUrl: "http://10.0.0.1:11434", host: "10.0.0.1", port: 80, proxy: "http://127.0.0.1:3128"
        });
    }

    function init() {
        requests = [];
        timers = [];
        clock = 1000;
        identityReads = 0;
        logs = [];
        identity = {tcp: head + row(v4Loop, "0A", 1000), tcp6: head, passwd: passwd, uid: 1000};
        routes = {
            "http://127.0.0.1:11434/api/version": {status: 200, body: '{"version":"0.40.17"}'},
            "http://127.0.0.1:11434/api/tags": {status: 200, body: JSON.stringify({models: [model("llama3.2:3b"), model("x:cloud", {size: 400})]})}
        };
    }

    function detectNow(d, force) {
        let r = null;
        d.detect(x => {
            r = x;
        }, force);
        return r;
    }

    function test_presentLocalOnly() {
        const r = detectNow(detector());
        compare(r.state, "present");
        compare(r.version, "0.40.17");
        compare(r.models, ["llama3.2:3b"]);
        compare(r.base, "http://127.0.0.1:11434");
        compare(requests, ["GET http://127.0.0.1:11434/api/version", "GET http://127.0.0.1:11434/api/tags"]);
        compare(timers.filter(t => t.live).length, 0);
    }

    function test_noUrlCanBeConfigured() {
        // every request, whatever the deps said, goes to a constant loopback URL
        routes = {};
        detectNow(detector());
        verify(requests.length > 0);
        for (const q of requests)
            verify(/^GET http:\/\/(127\.0\.0\.1|\[::1\]):11434\/api\/(version|tags)$/.test(q), q);
        compare(LocalModel.BASES, ["http://127.0.0.1:11434", "http://[::1]:11434"]);
    }

    function test_fallsBackToIpv6() {
        routes = {
            "http://[::1]:11434/api/version": {status: 200, body: '{"version":"1.2.3"}'},
            "http://[::1]:11434/api/tags": {status: 200, body: '{"models":[]}'}
        };
        const r = detectNow(detector());
        compare(r.state, "present");
        compare(r.base, "http://[::1]:11434");
        compare(r.models, []);
        compare(requests[0], "GET http://127.0.0.1:11434/api/version");
    }

    function test_absent() {
        routes = {};
        let r = detectNow(detector());
        compare(r.state, "absent");
        compare(r.reason, "no-answer");
        compare(r.models, []);
        // a wrong body, a wrong status, a throwing open/send
        routes = {"http://127.0.0.1:11434/api/version": {status: 200, body: "<html>"}};
        compare(detectNow(detector()).state, "absent");
        routes = {"http://127.0.0.1:11434/api/version": {status: 404, body: '{"version":"1.0"}'}};
        compare(detectNow(detector()).state, "absent");
        routes = {"http://127.0.0.1:11434/api/version": "throw", "http://[::1]:11434/api/version": "throw"};
        compare(detectNow(detector()).state, "absent");
        // version fine, tags not JSON
        routes = {
            "http://127.0.0.1:11434/api/version": {status: 200, body: '{"version":"1.0"}'},
            "http://127.0.0.1:11434/api/tags": {status: 200, body: "oops"}
        };
        compare(detectNow(detector()).state, "absent");
    }

    function test_strangerOnThePort() {
        identity.tcp = head + row(v4Loop, "0A", 1234);
        const r = detectNow(detector());
        compare(r.state, "absent");
        compare(r.reason, "bad-uid");
        compare(requests.length, 0);          // no request is made to a squatter
        compare(logs.length, 1);
        verify(logs[0].indexOf("1234") >= 0);
    }

    function test_noListenerNoRequest() {
        identity.tcp = head;
        const r = detectNow(detector());
        compare(r.reason, "no-listener");
        compare(requests.length, 0);
        identity = null;
        compare(detectNow(detector(), true).reason, "no-proc");
        compare(requests.length, 0);
    }

    function test_timeout() {
        routes["http://127.0.0.1:11434/api/version"] = "hang";
        routes["http://[::1]:11434/api/version"] = "hang";
        const d = detector();
        let r = null;
        d.detect(x => {
            r = x;
        });
        compare(r, null);
        compare(timers.length, 1);
        compare(timers[0].ms, 2000);
        timers[0].fn();                        // the clock runs out on 127.0.0.1 ...
        compare(requests[1], "GET http://[::1]:11434/api/version");   // ... the next base is tried
        compare(r, null);
        timers[1].fn();
        compare(r.state, "absent");
        compare(r.reason, "no-answer");
    }

    function test_timeoutOnTagsAndLateAnswer() {
        routes["http://127.0.0.1:11434/api/tags"] = "hang";
        routes["http://[::1]:11434/api/version"] = "hang";
        const d = detector();
        let calls = 0;
        let r = null;
        d.detect(x => {
            calls++;
            r = x;
        });
        timers[1].fn();                        // tags timed out
        timers[2].fn();                        // [::1] version timed out
        compare(calls, 1);
        compare(r.state, "absent");
    }

    function test_cacheSixtySeconds() {
        const d = detector();
        compare(detectNow(d).state, "present");
        const n = requests.length;
        clock += 59000;
        compare(detectNow(d).state, "present");
        compare(requests.length, n);
        compare(identityReads, 1);
        compare(d.cached().state, "present");
        clock += 2000;                         // 61 s
        compare(d.cached().state, "absent");   // an expired cache shows nothing
        detectNow(d);
        compare(requests.length, 2 * n);
        compare(identityReads, 2);
        detectNow(d, true);                    // force
        compare(identityReads, 3);
    }

    function test_redirectedAnswerRefused() {
        // a 302 followed by XHR: 200 with the target's JSON, but responseURL names another host
        routes["http://127.0.0.1:11434/api/version"] = {status: 200, body: '{"version":"9.9.9"}', finalUrl: "http://127.0.0.2:11434/api/version"};
        let r = detectNow(detector());
        compare(r.state, "absent");
        // tags redirected (version fine)
        init();
        routes["http://127.0.0.1:11434/api/tags"] = {status: 200, body: '{"models":[]}', finalUrl: "http://127.0.0.2:11434/api/tags"};
        r = detectNow(detector());
        compare(r.state, "absent");
        // an answer without a responseURL is refused too
        init();
        routes["http://127.0.0.1:11434/api/version"] = {status: 200, body: '{"version":"1.0"}', finalUrl: ""};
        compare(detectNow(detector()).state, "absent");
    }

    function test_clockGoingBackExpiresCache() {
        const d = detector();
        detectNow(d);
        const n = requests.length;
        clock -= 5000;
        compare(d.cached().state, "absent");
        detectNow(d);
        compare(requests.length, 2 * n);
    }

    function test_absentIsCachedToo() {
        routes = {};
        const d = detector();
        detectNow(d);
        const n = requests.length;
        clock += 1000;
        compare(detectNow(d).state, "absent");
        compare(requests.length, n);
    }

    function test_concurrentCallsShareOne() {
        routes["http://127.0.0.1:11434/api/version"] = "hang";
        const d = detector();
        const got = [];
        d.detect(x => got.push(x.state));
        d.detect(x => got.push(x.state));
        compare(identityReads, 1);
        compare(requests.length, 1);
        timers[0].fn();
        timers[1].fn();
        compare(got, ["absent", "absent"]);
    }
}
