import QtQuick
import QtTest
import "../../shell/services/ProcessHealth.js" as Health

// The shell's health sample (shell/services/ProcessHealth.js; owner's report of 2026-11-21: two SIGKILLs with nothing naming
// the sender, a 1.3 GB memory peak): what services/process-health.sh prints, parsed; a realtime thread under a realtime CPU
// limit (the kernel's silent SIGKILL) told apart; the journal text and the runtime file's line.
TestCase {
    name: "ProcessHealth"

    readonly property string owner: "VmHWM=1363148 VmRSS=905216 RssAnon=640000 RssFile=200000 RssShmem=65216 Threads=48 Pss=880000 RtTimeSoft=200000 RtTimeHard=200000 Rt=data-loop.0:1:83"

    function test_parse() {
        const s = Health.parse(owner);
        compare(s.rss, 905216);
        compare(s.peak, 1363148);
        compare(s.anon, 640000);
        compare(s.file, 200000);
        compare(s.shmem, 65216);
        compare(s.pss, 880000);
        compare(s.threads, 48);
        compare(s.rtSoft, "200000");
        compare(s.rtHard, "200000");
        compare(s.rt.length, 1);
        compare(s.rt[0].name, "data-loop.0");
        compare(s.rt[0].policy, "FIFO");
        compare(s.rt[0].priority, 83);
        compare(Health.parse(""), null);
        compare(Health.parse("Threads=3"), null, "no VmRSS: no sample");
        const odd = Health.parse("VmRSS=10 Pss=-4 Threads=x RtTimeHard=$(rm) Rt=bad!:1:2,ok:2:5,bad:1:1234,x:6:0");
        compare(odd.pss, -1);
        compare(odd.threads, -1);
        compare(odd.rtHard, "");
        compare(odd.rt.map(t => t.name + "/" + t.policy), ["ok/RR", "x/DEADLINE"]);
    }

    function test_rtKillable() {
        verify(Health.rtKillable(Health.parse(owner)), "a realtime thread with RLIMIT_RTTIME: the kernel's silent SIGKILL");
        verify(!Health.rtKillable(Health.parse(owner.replace("RtTimeHard=200000", "RtTimeHard=unlimited"))));
        verify(!Health.rtKillable(Health.parse(owner.replace("Rt=data-loop.0:1:83", "Rt=none"))));
        verify(!Health.rtKillable(null));
    }

    // The unit's cgroup (systemd's "memory peak"): GPU buffers in shared memory and page cache show there, not in the RSS.
    function test_cgroup() {
        const s = Health.parse(owner + " CgCurrent=1258291 CgPeak=1363148 CgAnon=700000 CgFile=150000 CgShmem=380000 CgKernel=28291");
        compare(s.cgCurrent, 1258291);
        compare(s.cgShmem, 380000);
        verify(Health.describe(s).endsWith(", unit 1229 MB (anon 684, file 146, shmem 371, kernel 28), unit peak 1331 MB"), Health.describe(s));
        compare(Health.parse(owner).cgCurrent, -1);
        verify(Health.describe(Health.parse(owner)).indexOf("unit") < 0);
    }

    function test_describe() {
        const s = Health.parse(owner);
        compare(Health.describe(s), "rss 884 MB (anon 625, file 195, shmem 64), pss 859 MB, peak rss 1331 MB, 48 threads, realtime threads data-loop.0 (FIFO 83), realtime CPU limit 200000 us");
        compare(Health.record(s, "displays (3)", 1795259712345), "at=1795259712 displays (3): " + Health.describe(s));
        compare(Health.recordPath("/run/user/1000"), "/run/user/1000/grassfield-shell-health");
        compare(Health.recordPath(""), "");
        compare(Health.recordPath("x"), "");
    }
}
