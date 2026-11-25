// The Store's operations (apps/store/src/operations.h; ADR-0037 b, f; spec SR17-SR20; acceptance A6, A7) with fake programs:
// a fake pkexec standing for the helper (it writes the helper's files and pacman's log lines, then exits with the code its
// mode file says), a fake pacman answering -Q from a list, a fake Omarchy command writing or removing a web app's launcher,
// and a fake Omarchy terminal whose script stands for grassfield-store-run (b.2: its started and exit files, each way it
// can end). One operation at a time; success = exit code 0 AND the state; the locks; the time limits; store.json's record
// and the recovery at start.
#include "flatpak.h"
#include "operations.h"
#include "statefile.h"
#include "storetest.h"

#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QTemporaryDir>
#include <QTimer>

#include <gtest/gtest.h>

#include <sys/wait.h>
#include <unistd.h>

using namespace grassfield::store;

namespace {

// pkexec's stand-in: `<helper> <verb> <op> <names>`; its mode file says what happens.
const QByteArray kPkexec = R"SH(root=$(dirname "$0")
shift; verb=$1; op=$2; shift 2
# The Store writes the operation's record before the helper starts (recover() needs it): one started without it is noted.
grep -q "$op" "$root/state/store.json" 2>/dev/null || echo "$op" >>"$root/norecord"
mode=$(cat "$root/mode" 2>/dev/null)
[ "$mode" = cancel ] && exit 126
[ "$mode" = wait ] && exec sleep 30
# The helper's run in its transient system unit (SU-03): pkexec's side ends without an exit file (killed with the session, say)
# while the unit's process, named by the started file, installs and writes the exit file a second later.
if [ "$mode" = unit ]; then
  sh -c 'sleep 1; root=$1; op=$2; shift 2
    for p in "$@"; do echo "[x] [ALPM] installed $p (1-1)" >>"$root/pacman.log"; echo "$p 1-1" >>"$root/installed"; done
    echo 0 >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"' unit "$root" "$op" "$@" </dev/null >/dev/null 2>&1 &
  child=$!
  start=$(awk '{sub(/.*\) /, ""); print $20}' /proc/$child/stat)
  echo "$child $start" >"$root/run/$op.started"
  echo "grassfield-store-helper: $verb $* (operation $op)" >"$root/run/$op.log"
  exit 143
fi
start=$(awk '{sub(/.*\) /, ""); print $20}' /proc/$$/stat)
echo "$$ $start" >"$root/run/$op.started"
echo "grassfield-store-helper: $verb $* (operation $op)" >"$root/run/$op.log"
if [ "$mode" = refuse ]; then
  echo 4 >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
  exit 4
fi
# pacman -Sw failing as the owner's rc1-7 did (a file the mirror no longer has), or on a mirror that does not answer.
if [ "$mode" = gone ] || [ "$mode" = unreachable ]; then
  why="The requested URL returned error: 404"
  [ "$mode" = unreachable ] && why="Could not resolve host: mirror.example"
  echo "error: failed retrieving file '$1-1-1-x86_64.pkg.tar.zst' from mirror.example : $why" >>"$root/run/$op.log"
  echo "error: failed to commit transaction (failed to retrieve some files)" >>"$root/run/$op.log"
  echo "grassfield-store-helper: pacman could not download the packages" >>"$root/run/$op.log"
  echo 1 >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
  exit 1
fi
n=0
for p in "$@"; do
  n=$((n + 1))
  [ "$mode" = partial ] && [ $n -gt 1 ] && break
  if [ "$verb" = install ]; then
    echo "[2026-10-27T10:00:00+0000] [ALPM] installed $p (1-1)" >>"$root/pacman.log"; echo "$p 1-1" >>"$root/installed"
  else
    echo "[2026-10-27T10:00:00+0000] [ALPM] removed $p (1-1)" >>"$root/pacman.log"; grep -v "^$p " "$root/installed" >"$root/i2"; mv "$root/i2" "$root/installed"
  fi
done
[ "$mode" = slow ] && sleep 1
code=0
[ "$mode" = partial ] && { echo "error: failed to commit transaction (conflicting files)" >>"$root/run/$op.log"; code=1; }
echo $code >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
exit $code)SH";

const QByteArray kPacman = R"SH(root=$(dirname "$0")
[ "$1" = -Q ] || exit 1
shift; [ "$1" = -- ] && shift
rc=0
for p in "$@"; do grep "^$p " "$root/installed" || rc=1; done
exit $rc)SH";

// Omarchy's web app commands' stand-in: `<command> <args>`.
const QByteArray kInstaller = R"SH(root=$(dirname "$0")
cmd=$1; shift
case $cmd in
  omarchy-webapp-install)
    [ "$1" = Gone ] && { echo "error: failed retrieving file 'gone-1-1-any.pkg.tar.zst' from mirror.example : The requested URL returned error: 404"; exit 1; }
    printf '[Desktop Entry]\nName=%s\nExec=omarchy-launch-webapp %s\nIcon=%s\n' "$1" "$2" "$3" >"$root/apps/$1.desktop" ;;
  omarchy-webapp-remove) [ "$OMARCHY_REMOVE_NOTIFY" = false ] || exit 3; rm -f "$root/apps/$1.desktop" ;;
  omarchy-launch-floating-terminal-with-presentation)
    [ $# = 1 ] || exit 2
    echo "$1" >>"$root/commands"
    # What the Store left for the script: its pins and their modes.
    set -- $1
    cp "$root/runstore/$2.pins" "$root/pins-seen"
    stat -c %a "$root/runstore" "$root/runstore/$2.pins" >"$root/modes"
    "$root/fakerun" "$@" </dev/null >/dev/null 2>&1 & ;;
  *) exit 2 ;;
esac)SH";

// grassfield-store-run's stand-in, `<run> <op> <deadline> setup|aur|flatpak <recipe> [<arg>...]`: its tmode file says how it goes,
// its tpackages file which packages the recipe installs or removes (the AUR's at a version of its build's own, 9-1).
const QByteArray kFakeRun = R"SH(root=$(dirname "$0"); run=$root/runstore
op=$2; recipe=$5
mode=$(cat "$root/tmode" 2>/dev/null)
fin() { echo "$1" >"$run/.$op.exit" && mv "$run/.$op.exit" "$run/$op.exit"; exit "$1"; }
case $mode in never) exit 0 ;; late) fin 6 ;; busy) fin 3 ;; esac
start=$(awk '{sub(/.*\) /, ""); print $20}' /proc/$$/stat)
echo "$$ $start" >"$run/.$op.started" && mv "$run/.$op.started" "$run/$op.started"
case $mode in slow) sleep 1 ;; changed) fin 5 ;; stopped) fin 130 ;; fail) fin 1 ;; refused) fin 7 ;; esac
n=0
for p in $(cat "$root/tpackages"); do
  n=$((n + 1))
  [ "$mode" = closed ] && [ $n -gt 1 ] && exit 0
  case $recipe in
    omarchy-install-* | omarchy-pkg-add) echo "[2026-10-28T10:00:00+0000] [ALPM] installed $p (1-1)" >>"$root/pacman.log"; echo "$p 1-1" >>"$root/installed" ;;
    omarchy-pkg-aur-add) echo "[2026-10-28T10:00:00+0000] [ALPM] installed $p (9-1)" >>"$root/pacman.log"; echo "$p 9-1" >>"$root/installed" ;;
    *) echo "[2026-10-28T10:00:00+0000] [ALPM] removed $p (1-1)" >>"$root/pacman.log"; grep -v "^$p " "$root/installed" >"$root/i2"; mv "$root/i2" "$root/installed" ;;
  esac
done
[ "$mode" = closed ] && exit 0
fin 0)SH";

// flatpak's stand-in (b.3, step 3c): `install --user --noninteractive flathub <ref>` prints S24's lines and adds the app to
// the flatpaks file (fmode fail: flatpak's error; slow: it waits for SIGTERM after its first ref, S25), `uninstall` removes it
// and `--unused` the runtime, `list --user --app` answers from the file. Step 4: `update --user --noninteractive -- <ref>...`
// prints "Updating <ref>" and takes each ref out of the fupdates file, `remote-ls --user --updates` lists that file's refs
// (S31); fmode offline: the update says "Nothing to update." and exits 0, the listing fails (S31d); stale: the update exits 0
// and updates nothing. Each call is written to fcalls.
const QByteArray kFlatpak = R"SH(root=$(dirname "$0")
echo "$*" >>"$root/fcalls"
mode=$(cat "$root/fmode" 2>/dev/null)
case "$1" in
  install)
    id=$(echo "$5" | cut -d/ -f2)
    [ "$mode" = fail ] && { echo "error: While pulling app/$id/x86_64/stable from remote flathub: Could not connect"; exit 1; }
    echo "Looking for matches…"
    echo "Installing runtime/org.example.Platform/x86_64/1"
    if [ "$mode" = slow ]; then
      trap 'echo stopped >>"$root/fcalls"; kill $! 2>/dev/null; exit 1' TERM
      sleep 30 >/dev/null 2>&1 &
      wait
    fi
    echo "Installing app/$id/x86_64/stable"
    echo "$id" >>"$root/flatpaks"
    echo "Installation complete." ;;
  uninstall)
    if [ "$mode" = silent ]; then
      trap 'echo stopped >>"$root/fcalls"; kill $! 2>/dev/null; exit 1' TERM
      echo waiting >>"$root/fcalls"
      sleep 30 >/dev/null 2>&1 &
      wait
    fi
    if [ "$4" = --unused ]; then echo "Uninstalling runtime/org.example.Platform/x86_64/1"; exit 0; fi
    grep -vx "$5" "$root/flatpaks" >"$root/f2"; mv "$root/f2" "$root/flatpaks"
    echo "Uninstalling app/$5/x86_64/stable" ;;
  list) cat "$root/flatpaks" ;;
  update)
    [ "$mode" = fail ] && { echo "error: Could not connect"; exit 1; }
    if [ "$mode" = offline ] || [ "$mode" = stale ]; then echo; echo "Nothing to update."; exit 0; fi
    shift 3
    commit=
    case "$1" in --commit=*) commit=${1#--commit=}; shift ;; esac
    shift
    if [ "$mode" = slow ]; then
      trap 'echo stopped >>"$root/fcalls"; kill $! 2>/dev/null; exit 1' TERM
      echo waiting >>"$root/fcalls"
      echo "Looking for updates…"
      sleep 30 >/dev/null 2>&1 &
      wait
    fi
    for ref in "$@"; do
      [ "$ref" = "$(cat "$root/failref" 2>/dev/null)" ] && { echo "error: Server returned status 404"; exit 1; }
      echo "Updating $ref"
      [ -n "$commit" ] && echo "$ref $commit" >>"$root/fcommits"
      # newer: a newer commit was published meanwhile, so a pinned ref is still listed after its update (S32e)
      if [ -z "$commit" ] || [ "$mode" != newer ]; then grep -vx "$ref" "$root/fupdates" >"$root/u2"; mv "$root/u2" "$root/fupdates"; fi
    done ;;
  info)
    c=$(grep "^$5 " "$root/fcommits" 2>/dev/null | tail -1 | cut -d' ' -f2)
    [ -n "$c" ] || exit 1
    echo "$c" ;;
  remote-ls)
    [ "$mode" = offline ] && { echo "error: Unable to load summary from remote flathub" >&2; exit 1; }
    while read -r ref; do
      [ -n "$ref" ] && printf '%s\t%s\tflathub\t%s\n' "$(echo "$ref" | cut -d/ -f2)" "$(echo "$ref" | cut -d/ -f4)" "$ref"
    done <"$root/fupdates" ;;
  *) exit 2 ;;
esac)SH";

struct Fixture {
    QTemporaryDir dir;
    OperationsConfig config;
    Fixture()
    {
        storetest::ensureApp();
        const QString root = dir.path();
        QDir().mkpath(root + QStringLiteral("/run"));
        QDir().mkpath(root + QStringLiteral("/apps"));
        storetest::writeFile(root + QStringLiteral("/installed"), "bash 5.3-1\n");
        storetest::writeFile(root + QStringLiteral("/pacman.log"), "[2026-10-27T09:00:00+0000] [ALPM] installed old (1-1)\n");
        config.pkexec = storetest::script(root + QStringLiteral("/pkexec"), kPkexec);
        config.helper = QStringLiteral("/usr/lib/grassfield/grassfield-store-helper");
        config.statusDir = root + QStringLiteral("/run");
        config.updateLock = root + QStringLiteral("/omarchy-update.lock");
        config.dbLock = root + QStringLiteral("/db.lck");
        config.pacmanLog = root + QStringLiteral("/pacman.log");
        config.pacman = storetest::script(root + QStringLiteral("/pacman"), kPacman);
        config.stateFile = root + QStringLiteral("/state/store.json");
        config.applications = root + QStringLiteral("/apps");
        const QString installer = storetest::script(root + QStringLiteral("/installer"), kInstaller);
        storetest::script(root + QStringLiteral("/fakerun"), kFakeRun);
        config.run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
        config.runDir = root + QStringLiteral("/runstore");
        config.terminalStartMs = 1000;
        config.terminalGraceMs = 500;
        config.omarchy = [installer](const QString &command, const QStringList &args) { return QStringList{installer, command} + args; };
        config.flatpak = storetest::script(root + QStringLiteral("/flatpak"), kFlatpak);
        storetest::writeFile(root + QStringLiteral("/flatpaks"), "");
        storetest::writeFile(root + QStringLiteral("/fupdates"), "");
        config.pollMs = 20;
    }
    void mode(const QByteArray &m) { storetest::writeFile(dir.filePath(QStringLiteral("mode")), m); }
    void terminalMode(const QByteArray &m) { storetest::writeFile(dir.filePath(QStringLiteral("tmode")), m); }
    QByteArray read(const QString &name) const
    {
        QFile file(dir.filePath(name));
        return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
    }
    QJsonObject record() const { return readStoreState(config.stateFile).value(QStringLiteral("operation")).toObject(); }
};

OperationRecord helperRecord(const QString &app, const QString &kind, const QStringList &plan)
{
    OperationRecord r;
    r.id = newOperationId();
    r.kind = kind;
    r.path = QStringLiteral("helper");
    r.app = app;
    r.name = app;
    r.packages = plan; // the fake pkexec installs what it is given (pacman would add the dependencies itself)
    for (const QString &n : plan) {
        PlannedPackage p;
        p.name = n;
        p.version = QStringLiteral("1-1");
        r.plan.append(p);
    }
    return r;
}

// A setup's operation (b.2): its recipe with its arguments, its packages (the plan), the catalog's pins.
OperationRecord terminalRecord(const QString &app, const QString &kind, const QStringList &plan)
{
    OperationRecord r = helperRecord(app, kind, plan);
    r.path = QStringLiteral("terminal");
    r.recipe = (kind == QLatin1String("install") ? QStringLiteral("omarchy-install-") : QStringLiteral("omarchy-remove-")) + app;
    r.args = {QStringLiteral("one"), QStringLiteral("v2.0")};
    r.pins = {{QStringLiteral("bin/") + r.recipe, QString(64, QLatin1Char('a'))}, {QStringLiteral("install/x.sh"), QString(64, QLatin1Char('b'))}};
    return r;
}

// A Flatpak's operation (b.3): an install takes Flathub's ref and flatpak's own plan, a removal the app id.
OperationRecord flatpakRecord(const QString &app, const QString &kind)
{
    OperationRecord r;
    r.id = newOperationId();
    r.kind = kind;
    r.path = QStringLiteral("flatpak");
    r.app = app;
    r.name = app;
    r.flatpak = kind == QLatin1String("install") ? QStringLiteral("app/%1/x86_64/stable").arg(app) : app;
    for (const QString &n : {QStringLiteral("org.example.Platform"), app}) {
        PlannedPackage p;
        p.name = n;
        p.version = QStringLiteral("stable");
        r.plan.append(p);
    }
    return r;
}

// The apps whose operation ended, in order (Operations::finished).
struct Ended {
    QStringList apps;
    explicit Ended(Operations &ops)
    {
        QObject::connect(&ops, &Operations::finished, &ops, [this](const QString &app) { apps.append(app); });
    }
    int count() const { return int(apps.size()); }
};

// Runs the event loop until `done` or 10 s.
template<typename F>
bool waitFor(F done, int ms = 10000)
{
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    timeout.start(ms);
    while (!done() && timeout.isActive()) {
        QTimer::singleShot(10, &loop, &QEventLoop::quit);
        loop.exec();
    }
    return done();
}

} // namespace

TEST(Operations, RecordsAndIds)
{
    const QString id = newOperationId();
    EXPECT_TRUE(isOperationId(id));
    EXPECT_NE(id, newOperationId());
    EXPECT_FALSE(isOperationId(id.toUpper()));
    const OperationRecord r = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm"), QStringLiteral("libxaw")});
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->id, r.id);
    EXPECT_EQ(back->plan.size(), 2);
    QJsonObject bad = r.toJson();
    bad.insert(QStringLiteral("packages"), QJsonArray{QStringLiteral("-rf")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = r.toJson();
    bad.insert(QStringLiteral("kind"), QStringLiteral("upgrade"));
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    EXPECT_EQ(judge(0, 2, 2), Outcome::Done);
    EXPECT_EQ(judge(0, 1, 2), Outcome::Interrupted) << "an exit 0 with a part installed is not installed (S6)";
    EXPECT_EQ(judge(std::nullopt, 2, 2), Outcome::Interrupted) << "the state alone is not enough either";
    EXPECT_EQ(judge(1, 0, 2), Outcome::NotFinished);
    EXPECT_EQ(countLogged("[x] [ALPM] installed xterm (411-1)\n[x] [ALPM] installed other (1)\n[x] [ALPM] removed libxaw (1)\n",
                          QStringLiteral("installed"), {QStringLiteral("xterm"), QStringLiteral("libxaw")}), 1);
}

TEST(Operations, InstallThroughTheHelper)
{
    Fixture f;
    f.mode("ok");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm"), QStringLiteral("libxaw")}));
    EXPECT_TRUE(ops.running());
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(f.read(QStringLiteral("norecord")).isEmpty()) << "store.json had the record before the helper started (written off the click path)";
    EXPECT_TRUE(ops.results().isEmpty()) << "done: nothing to say";
    EXPECT_TRUE(waitFor([&] { return f.record().isEmpty(); })) << "the record goes once it ended";
    EXPECT_FALSE(ops.running());
}

// SU-03: pkexec's side of the helper ends while the run goes on in its transient system unit; the Store follows the unit by
// its files (the started file's process, then its exit file) and judges the operation by them, not by pkexec's end.
TEST(Operations, HelperFollowedInItsUnit)
{
    Fixture f;
    f.mode("unit");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm"), QStringLiteral("libxaw")}));
    ASSERT_TRUE(waitFor([&] { return !ops.items().isEmpty() && ops.items().constFirst().state == Operations::State::Running; }));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done in the unit: nothing to say (" << ops.results().value(QStringLiteral("xterm")).outcome.toStdString() << ")";
    EXPECT_TRUE(f.read(QStringLiteral("installed")).contains("libxaw 1-1"));
    EXPECT_TRUE(waitFor([&] { return f.record().isEmpty(); })); // cleared on the writer's thread
}

TEST(Operations, OutcomesFromCodeAndState)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    f.mode("cancel");
    ops.enqueue(helperRecord(QStringLiteral("a"), QStringLiteral("install"), {QStringLiteral("a")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("a")).outcome, QStringLiteral("cancelled"));

    f.mode("partial");
    ops.enqueue(helperRecord(QStringLiteral("b"), QStringLiteral("install"), {QStringLiteral("b"), QStringLiteral("b-dep")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    const Operations::Result r = ops.results().value(QStringLiteral("b"));
    EXPECT_EQ(r.outcome, QStringLiteral("interrupted"));
    EXPECT_EQ(r.present, 1);
    EXPECT_EQ(r.total, 2);
    EXPECT_TRUE(r.details.contains(QStringLiteral("conflicting files"))) << qPrintable(r.details);

    f.mode("refuse");
    ops.enqueue(helperRecord(QStringLiteral("c"), QStringLiteral("install"), {QStringLiteral("c")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("c")).outcome, QStringLiteral("unfinished"));
    ops.dismiss(QStringLiteral("c"));
    EXPECT_FALSE(ops.results().contains(QStringLiteral("c")));

    // Removed: each planned package gone.
    f.mode("ok");
    ops.enqueue(helperRecord(QStringLiteral("b"), QStringLiteral("remove"), {QStringLiteral("b")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
    EXPECT_FALSE(ops.results().contains(QStringLiteral("b")));

    // A planned file the mirror no longer has (the integrator's note on PR #36): the system is older than the mirror,
    // "outdated" (Software Update); pacman's lines stay in the details, not in the line. A mirror that does not answer
    // is a failure like any other.
    f.mode("gone");
    ops.enqueue(helperRecord(QStringLiteral("d"), QStringLiteral("install"), {QStringLiteral("d")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 5; }));
    const Operations::Result gone = ops.results().value(QStringLiteral("d"));
    EXPECT_EQ(gone.outcome, QStringLiteral("outdated"));
    EXPECT_TRUE(gone.details.contains(QStringLiteral("returned error: 404"))) << qPrintable(gone.details);
    f.mode("unreachable");
    ops.enqueue(helperRecord(QStringLiteral("e"), QStringLiteral("install"), {QStringLiteral("e")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 6; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("e")).outcome, QStringLiteral("failed"));
}

TEST(Operations, OneAtATimeAndTheLocks)
{
    Fixture f;
    f.mode("slow");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("one"), QStringLiteral("install"), {QStringLiteral("one")}));
    ops.enqueue(helperRecord(QStringLiteral("two"), QStringLiteral("install"), {QStringLiteral("two")}));
    ops.enqueue(helperRecord(QStringLiteral("three"), QStringLiteral("install"), {QStringLiteral("three")}));
    ASSERT_EQ(ops.items().size(), 3);
    EXPECT_EQ(ops.items().at(0).record.app, QStringLiteral("one"));
    EXPECT_EQ(ops.items().at(1).state, Operations::State::Waiting);
    // Omarchy's update lock is the Store's while the helper runs: another process cannot take it.
    EXPECT_TRUE(lockHeld(f.config.updateLock));
    EXPECT_TRUE(ops.removeWaiting(ops.items().at(2).record.id));
    EXPECT_FALSE(ops.removeWaiting(ops.items().at(0).record.id)) << "the running one stays";
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_EQ(finished.apps.at(0), QStringLiteral("one"));
    EXPECT_EQ(finished.apps.at(1), QStringLiteral("two"));
    EXPECT_FALSE(lockHeld(f.config.updateLock)) << "let go once it ended";

    // pacman's lock there: the next one waits (blocked) and starts when it goes.
    f.mode("ok");
    storetest::writeFile(f.config.dbLock, "");
    ops.enqueue(helperRecord(QStringLiteral("four"), QStringLiteral("install"), {QStringLiteral("four")}));
    EXPECT_FALSE(ops.running());
    ASSERT_EQ(ops.items().size(), 1);
    EXPECT_TRUE(ops.items().at(0).blocked);
    QFile::remove(f.config.dbLock);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_TRUE(ops.results().isEmpty());

    // Omarchy's update running (its lock held by another process): the same.
    QProcess holder;
    holder.start(QStringLiteral("flock"), {QStringLiteral("-o"), f.config.updateLock, QStringLiteral("sleep"), QStringLiteral("30")});
    ASSERT_TRUE(holder.waitForStarted());
    ASSERT_TRUE(waitFor([&] { return lockHeld(f.config.updateLock); }));
    ops.enqueue(helperRecord(QStringLiteral("five"), QStringLiteral("install"), {QStringLiteral("five")}));
    EXPECT_FALSE(ops.running());
    holder.kill();
    holder.waitForFinished();
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
}

TEST(Operations, AuthorizationTimesOut)
{
    Fixture f;
    f.mode("wait"); // the password never comes
    f.config.authorizationMs = 300;
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("slow"), QStringLiteral("install"), {QStringLiteral("slow")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("slow")).outcome, QStringLiteral("timedOut"));
}

TEST(Operations, WebApps)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.path = QStringLiteral("webapp");
    r.app = QStringLiteral("chat");
    r.name = QStringLiteral("Chat");
    r.webName = QStringLiteral("Chat Room");
    r.webUrl = QStringLiteral("https://chat.example.org/");
    r.webIcon = f.dir.filePath(QStringLiteral("chat.png"));
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(QFile::exists(f.dir.filePath(QStringLiteral("apps/Chat Room.desktop"))));
    EXPECT_TRUE(ops.results().isEmpty());
    r.id = newOperationId();
    r.kind = QStringLiteral("remove");
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("apps/Chat Room.desktop"))));
    EXPECT_TRUE(ops.results().isEmpty()) << "OMARCHY_REMOVE_NOTIFY=false reached the command";
    // A web app's command that fails with words like pacman's download error is a failure, never "update the system first":
    // only the helper's pacman downloads from the mirror (the integrator's review of ff2fd83: that condition's mutant).
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.webName = QStringLiteral("Gone");
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("chat")).outcome, QStringLiteral("failed"));
    EXPECT_TRUE(ops.results().value(QStringLiteral("chat")).details.contains(QStringLiteral("returned error: 404")));
}

TEST(Operations, RecoveryAtStart)
{
    Fixture f;
    // Done while the Store was away: its exit file 0 and every package there -> nothing said, the record gone.
    OperationRecord done = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm")});
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "xterm 1-1\n");
    storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + done.id + QStringLiteral(".exit")), "0\n");
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), done.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
        EXPECT_TRUE(waitFor([&] { return f.record().isEmpty(); })); // cleared on the writer's thread
    }
    // Interrupted: no exit file, no helper running, one of two packages there.
    OperationRecord cut = helperRecord(QStringLiteral("gimp"), QStringLiteral("install"), {QStringLiteral("gimp"), QStringLiteral("babl")});
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "babl 1-1\n");
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), cut.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        const Operations::Result r = ops.results().value(QStringLiteral("gimp"));
        EXPECT_EQ(r.outcome, QStringLiteral("interrupted"));
        EXPECT_EQ(r.present, 1);
        EXPECT_EQ(r.total, 2);
    }
    // Not finished: nothing there.
    OperationRecord none = helperRecord(QStringLiteral("blender"), QStringLiteral("install"), {QStringLiteral("blender")});
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), none.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("blender")).outcome, QStringLiteral("notFinished"));
    }
    // Still running (its started file names a live process with its start time): followed until its exit file comes.
    OperationRecord live = helperRecord(QStringLiteral("vlc"), QStringLiteral("install"), {QStringLiteral("vlc")});
    QProcess sleeper;
    sleeper.start(QStringLiteral("sleep"), {QStringLiteral("30")});
    ASSERT_TRUE(sleeper.waitForStarted());
    QFile stat(QStringLiteral("/proc/%1/stat").arg(sleeper.processId()));
    ASSERT_TRUE(stat.open(QIODevice::ReadOnly));
    const QByteArray line = stat.readAll();
    const QByteArray start = line.mid(line.lastIndexOf(") ") + 2).split(' ').at(19);
    storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + live.id + QStringLiteral(".started")), QByteArray::number(sleeper.processId()) + ' ' + start + '\n');
    EXPECT_TRUE(helperRunning(f.config.statusDir, live.id));
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), live.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        EXPECT_TRUE(ops.running());
        waitFor([] { return false; }, 200); // a while: it is still running
        EXPECT_EQ(finished.count(), 0);
        storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "vlc 1-1\n");
        storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + live.id + QStringLiteral(".exit")), "0\n");
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
    }
    sleeper.kill();
    sleeper.waitForFinished();
    EXPECT_FALSE(helperRunning(f.config.statusDir, live.id));
}

// A helper that has ended but is not yet reaped (a zombie: its /proc entry stays, with its pid and start time) is not running; a
// container's PID 1 that does not reap leaves orphans in this state for good.
TEST(Operations, AZombieIsNotARunningHelper)
{
    Fixture f;
    const OperationRecord rec = helperRecord(QStringLiteral("vlc"), QStringLiteral("install"), {QStringLiteral("vlc")});
    const pid_t child = ::fork();
    ASSERT_GE(child, 0);
    if (child == 0)
        ::_exit(0);
    QFile stat(QStringLiteral("/proc/%1/stat").arg(child));
    QByteArray line;
    ASSERT_TRUE(waitFor([&] {
        if (!stat.open(QIODevice::ReadOnly))
            return false;
        line = stat.readAll();
        stat.close();
        return line.mid(line.lastIndexOf(") ") + 2, 1) == "Z";
    })) << "the child ended and is waiting to be reaped";
    const QByteArray start = line.mid(line.lastIndexOf(") ") + 2).split(' ').at(19);
    storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + rec.id + QStringLiteral(".started")), QByteArray::number(child) + ' ' + start + '\n');
    EXPECT_FALSE(helperRunning(f.config.statusDir, rec.id)) << "a zombie has ended";
    ::waitpid(child, nullptr, 0);
}

TEST(Operations, TerminalRecordsAndCommand)
{
    const OperationRecord r = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")});
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->recipe, QStringLiteral("omarchy-install-game"));
    EXPECT_EQ(back->args, (QStringList{QStringLiteral("one"), QStringLiteral("v2.0")}));
    EXPECT_TRUE(back->pins.isEmpty()) << "the pins are not kept in store.json";
    QJsonObject bad = r.toJson();
    bad.insert(QStringLiteral("recipe"), QStringLiteral("omarchy-remove-game"));
    EXPECT_FALSE(OperationRecord::fromJson(bad)) << "an install runs an install recipe";
    bad = r.toJson();
    bad.insert(QStringLiteral("args"), QJsonArray{QStringLiteral("one;id")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = r.toJson();
    bad.insert(QStringLiteral("args"), QJsonArray{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"), QStringLiteral("d"), QStringLiteral("e")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));

    const QString run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
    const QString id = QString(32, QLatin1Char('c'));
    EXPECT_EQ(terminalCommand(run, id, 1793155826, QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox")}),
              run + QStringLiteral(" ") + id + QStringLiteral(" 1793155826 setup omarchy-install-browser firefox"));
    // Each token as e.5 allows it, or no command at all (the launcher hands it to bash -c).
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox;id")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("$(id)")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("-x")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser x"), {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-launch-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(run, QStringLiteral("cccc"), 1, QStringLiteral("omarchy-install-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 0, QStringLiteral("omarchy-install-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(QStringLiteral("/tmp/a b"), id, 1, QStringLiteral("omarchy-install-browser"), {}), QString());
}

// The AUR (step 3b2): its two commands through the same terminal path, kind "aur", one package's name; an AUR package is
// there at whatever version its build made; the script's 7 (its plan refused) is a refusal.
TEST(Operations, AurThroughTheTerminal)
{
    OperationRecord r = terminalRecord(QStringLiteral("aur:example-app-bin"), QStringLiteral("install"), {});
    r.recipe = kAurAdd;
    r.args = {QStringLiteral("example-app-bin")};
    r.packages = {QStringLiteral("example-app-bin")};
    r.plan.clear();
    for (const QString &name : {QStringLiteral("example-app-bin"), QStringLiteral("example-lib")}) {
        PlannedPackage p;
        p.name = name;
        p.repo = QStringLiteral("aur"); // no version: whichever the build makes
        r.plan.append(p);
    }
    r.pins = {{QStringLiteral("bin/omarchy-pkg-aur-add"), QString(64, QLatin1Char('a'))}};
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->recipe, kAurAdd);
    EXPECT_EQ(back->plan.at(1).version, QString());
    for (const auto &[key, value] : {std::pair{QStringLiteral("recipe"), QJsonValue(kAurDrop)},
                                     std::pair{QStringLiteral("recipe"), QJsonValue(QStringLiteral("omarchy-pkg-add"))},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{QStringLiteral("-rf")})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"),
                                                                                             QStringLiteral("d"), QStringLiteral("e")})}}) {
        QJsonObject bad = r.toJson();
        bad.insert(key, value);
        EXPECT_FALSE(OperationRecord::fromJson(bad)) << key.toStdString(); // an install runs the AUR's add, with 1 to 4 names
    }

    const QString run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
    const QString id = QString(32, QLatin1Char('c'));
    EXPECT_EQ(terminalKind(kAurAdd, {QStringLiteral("example-app-bin")}), QStringLiteral("aur"));
    EXPECT_EQ(terminalKind(QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox")}), QStringLiteral("setup"));
    EXPECT_EQ(terminalCommand(run, id, 1793155826, kAurAdd, {QStringLiteral("example-app-bin")}),
              run + QStringLiteral(" ") + id + QStringLiteral(" 1793155826 aur omarchy-pkg-aur-add example-app-bin"));
    EXPECT_EQ(terminalCommand(run, id, 1, kAurDrop, {QStringLiteral("lib32-gcc@x+")}).section(QLatin1Char(' '), 3),
              QStringLiteral("aur omarchy-pkg-drop lib32-gcc@x+"));
    for (const QString &bad : {QStringLiteral("-rf"), QStringLiteral("a;id"), QStringLiteral("$(id)"), QStringLiteral("A"), QString()})
        EXPECT_EQ(terminalCommand(run, id, 1, kAurAdd, {bad}), QString()) << bad.toStdString();
    EXPECT_EQ(terminalCommand(run, id, 1, kAurAdd, {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-pkg-add"), {QStringLiteral("gimp")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("a@b")}), QString())
        << "a setup's arguments keep their own pattern";

    Fixture f;
    f.terminalMode("ok");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "example-app-bin example-lib\n");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: exit 0, both there (at 9-1, the build's version)";
    EXPECT_TRUE(f.read(QStringLiteral("commands")).contains(" aur omarchy-pkg-aur-add example-app-bin\n"));

    OperationRecord drop = r;
    drop.id = newOperationId();
    drop.kind = QStringLiteral("remove");
    drop.recipe = kAurDrop;
    f.terminalMode("refused");
    ops.enqueue(drop);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_EQ(ops.results().value(r.app).outcome, QStringLiteral("refused")) << "exit 7: the script refused the plan";
    f.terminalMode("ok");
    drop.id = newOperationId();
    ops.enqueue(drop);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "removed: exit 0 and both gone";
    EXPECT_EQ(f.read(QStringLiteral("installed")), "bash 5.3-1\n");
}

// Get Flatpak… (step 3c part 3, SD24): omarchy-pkg-add flatpak through the same terminal path, kind "flatpak", an install
// of the flatpak package and nothing else; done once flatpak and what pacman added with it are there.
TEST(Operations, GetFlatpakThroughTheTerminal)
{
    OperationRecord r = terminalRecord(QStringLiteral("store:flatpak"), QStringLiteral("install"), {QStringLiteral("flatpak"), QStringLiteral("ostree")});
    r.recipe = kFlatpakAdd;
    r.args = {kFlatpakPackage};
    r.packages = {kFlatpakPackage};
    r.pins = {{QStringLiteral("bin/omarchy-pkg-add"), QString(64, QLatin1Char('a'))}, {QStringLiteral("bin/omarchy-pkg-missing"), QString(64, QLatin1Char('b'))}};
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->recipe, kFlatpakAdd);
    EXPECT_EQ(back->args, QStringList{kFlatpakPackage});
    for (const auto &[key, value] : {std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{QStringLiteral("gimp")})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{kFlatpakPackage, QStringLiteral("gimp")})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{})},
                                     std::pair{QStringLiteral("packages"), QJsonValue(QJsonArray{QStringLiteral("gimp")})},
                                     std::pair{QStringLiteral("packages"), QJsonValue(QJsonArray{kFlatpakPackage, QStringLiteral("gimp")})},
                                     std::pair{QStringLiteral("kind"), QJsonValue(QStringLiteral("remove"))},
                                     std::pair{QStringLiteral("recipe"), QJsonValue(QStringLiteral("omarchy-pkg-drop"))}}) {
        QJsonObject bad = r.toJson();
        bad.insert(key, value);
        EXPECT_FALSE(OperationRecord::fromJson(bad)) << key.toStdString() << " " << QJsonDocument(QJsonObject{{key, value}}).toJson().toStdString();
    }

    const QString run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
    const QString id = QString(32, QLatin1Char('c'));
    EXPECT_EQ(terminalKind(kFlatpakAdd, {kFlatpakPackage}), QStringLiteral("flatpak"));
    EXPECT_EQ(terminalCommand(run, id, 1793155826, kFlatpakAdd, {kFlatpakPackage}),
              run + QStringLiteral(" ") + id + QStringLiteral(" 1793155826 flatpak omarchy-pkg-add flatpak"));
    for (const QStringList &bad : {QStringList{}, QStringList{QStringLiteral("gimp")}, QStringList{kFlatpakPackage, kFlatpakPackage},
                                   QStringList{QStringLiteral("flatpak;id")}})
        EXPECT_EQ(terminalCommand(run, id, 1, kFlatpakAdd, bad), QString()) << bad.join(QLatin1Char(' ')).toStdString();

    Fixture f;
    f.terminalMode("ok");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "flatpak ostree\n");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: exit 0, flatpak and ostree there";
    EXPECT_TRUE(f.read(QStringLiteral("commands")).contains(" flatpak omarchy-pkg-add flatpak\n"));
    EXPECT_EQ(f.read(QStringLiteral("pins-seen")), QByteArray(QByteArray(64, 'a') + "  bin/omarchy-pkg-add\n" + QByteArray(64, 'b') + "  bin/omarchy-pkg-missing\n"));
    // The terminal refused it (5: the installed Omarchy differs): said as a setup's, by its source.
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "bash 5.3-1\n");
    f.terminalMode("changed");
    r.id = newOperationId();
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_EQ(ops.results().value(r.app).outcome, QStringLiteral("omarchyChanged"));
}

TEST(Operations, TerminalInstallAndRemove)
{
    Fixture f;
    f.terminalMode("slow");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game game-data\n");
    Operations ops(f.config);
    Ended finished(ops);
    const OperationRecord r = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game"), QStringLiteral("game-data")});
    const qint64 asked = QDateTime::currentSecsSinceEpoch();
    ops.enqueue(r);
    EXPECT_EQ(ops.items().at(0).state, Operations::State::Opening);
    EXPECT_EQ(ops.list().at(0).toMap().value(QStringLiteral("path")).toString(), QStringLiteral("terminal"));
    ASSERT_TRUE(waitFor([&] { return ops.running() && ops.items().at(0).state == Operations::State::Running; }));
    // The script takes Omarchy's lock itself (b.2): the Store does not hold it.
    EXPECT_FALSE(lockHeld(f.config.updateLock));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: exit 0 and both packages there";

    // The launcher got one argument: grassfield-store-run's command, its deadline the Store's 60 s (1 s here).
    const QList<QByteArray> words = f.read(QStringLiteral("commands")).trimmed().split(' ');
    ASSERT_EQ(words.size(), 7);
    EXPECT_EQ(words.at(0), "/usr/lib/grassfield/grassfield-store-run");
    EXPECT_EQ(words.at(1), r.id.toLatin1());
    EXPECT_GE(words.at(2).toLongLong(), asked + 1);
    EXPECT_LE(words.at(2).toLongLong(), asked + 2);
    EXPECT_EQ(words.mid(3), (QList<QByteArray>{"setup", "omarchy-install-game", "one", "v2.0"}));
    EXPECT_EQ(f.read(QStringLiteral("pins-seen")), QByteArray(64, 'a') + "  bin/omarchy-install-game\n" + QByteArray(64, 'b') + "  install/x.sh\n");
    EXPECT_EQ(f.read(QStringLiteral("modes")), "700\n600\n");
    EXPECT_TRUE(QDir(f.config.runDir).entryList(QDir::Files | QDir::Hidden).isEmpty()) << "its files go once it ended";

    f.terminalMode("ok");
    ops.enqueue(terminalRecord(QStringLiteral("game"), QStringLiteral("remove"), {QStringLiteral("game"), QStringLiteral("game-data")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "removed: exit 0 and both packages gone";
    EXPECT_EQ(f.read(QStringLiteral("installed")), "bash 5.3-1\n");
}

TEST(Operations, TerminalOutcomes)
{
    Fixture f;
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game game-data\n");
    Operations ops(f.config);
    Ended finished(ops);
    const auto outcome = [&](const QByteArray &mode, const QString &app) {
        f.terminalMode(mode);
        const int before = finished.count();
        ops.enqueue(terminalRecord(app, QStringLiteral("install"), {QStringLiteral("game"), QStringLiteral("game-data")}));
        if (!waitFor([&] { return finished.count() == before + 1; }))
            return QStringLiteral("(did not end)");
        return ops.results().value(app).outcome;
    };
    EXPECT_EQ(outcome("never", QStringLiteral("a")), QStringLiteral("terminalDidNotOpen")) << "no started file within 60 s (1 s here)";
    EXPECT_EQ(outcome("late", QStringLiteral("b")), QStringLiteral("terminalDidNotOpen")) << "exit 6: past its deadline";
    EXPECT_EQ(outcome("busy", QStringLiteral("c")), QStringLiteral("busy"));
    EXPECT_EQ(outcome("changed", QStringLiteral("d")), QStringLiteral("omarchyChanged")) << "exit 5: a pinned file differs";
    EXPECT_EQ(outcome("stopped", QStringLiteral("e")), QStringLiteral("cancelled")) << "Ctrl+C before anything was installed";
    EXPECT_EQ(outcome("fail", QStringLiteral("f")), QStringLiteral("failed"));
    EXPECT_EQ(outcome("closed", QStringLiteral("g")), QStringLiteral("interrupted")) << "the terminal closed: no exit file";
    EXPECT_EQ(ops.results().value(QStringLiteral("g")).present, 1);
    EXPECT_EQ(ops.results().value(QStringLiteral("g")).total, 2);

    // No folder for its files (no XDG_RUNTIME_DIR): it fails before anything starts, no command is run.
    f.config.runDir.clear();
    QFile::remove(f.dir.filePath(QStringLiteral("commands")));
    Operations without(f.config);
    Ended ended(without);
    without.enqueue(terminalRecord(QStringLiteral("h"), QStringLiteral("install"), {QStringLiteral("h")}));
    ASSERT_TRUE(waitFor([&] { return ended.count() == 1; }));
    EXPECT_EQ(without.results().value(QStringLiteral("h")).outcome, QStringLiteral("failed"));
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("commands"))));
}

TEST(Operations, TerminalWaitsForTheLocks)
{
    Fixture f;
    f.terminalMode("ok");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game\n");
    Operations ops(f.config);
    Ended finished(ops);
    // Omarchy's update running: the terminal is not asked for until its lock is free.
    QProcess holder;
    holder.start(QStringLiteral("flock"), {QStringLiteral("-o"), f.config.updateLock, QStringLiteral("sleep"), QStringLiteral("30")});
    ASSERT_TRUE(holder.waitForStarted());
    ASSERT_TRUE(waitFor([&] { return lockHeld(f.config.updateLock); }));
    ops.enqueue(terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")}));
    EXPECT_FALSE(ops.running());
    EXPECT_TRUE(ops.items().at(0).blocked);
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("commands"))));
    holder.kill();
    holder.waitForFinished();
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty());
}

TEST(Operations, TerminalRecovery)
{
    Fixture f;
    QDir().mkpath(f.config.runDir);
    // Still running (its started file names a live process): followed again until its exit file comes.
    OperationRecord live = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")});
    live.startedAt = QDateTime::currentDateTimeUtc().addSecs(-600);
    QProcess sleeper;
    sleeper.start(QStringLiteral("sleep"), {QStringLiteral("30")});
    ASSERT_TRUE(sleeper.waitForStarted());
    QFile stat(QStringLiteral("/proc/%1/stat").arg(sleeper.processId()));
    ASSERT_TRUE(stat.open(QIODevice::ReadOnly));
    const QByteArray line = stat.readAll();
    const QByteArray start = line.mid(line.lastIndexOf(") ") + 2).split(' ').at(19);
    storetest::writeFile(f.config.runDir + QLatin1Char('/') + live.id + QStringLiteral(".started"), QByteArray::number(sleeper.processId()) + ' ' + start + '\n');
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), live.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(ops.running());
        EXPECT_EQ(ops.items().at(0).state, Operations::State::Running);
        waitFor([] { return false; }, 200);
        EXPECT_EQ(finished.count(), 0);
        storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "game 1-1\n");
        storetest::writeFile(f.config.runDir + QLatin1Char('/') + live.id + QStringLiteral(".exit"), "0\n");
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
    }
    sleeper.kill();
    sleeper.waitForFinished();

    // Asked for long ago, never started: not finished; an old file of another operation is cleared.
    OperationRecord gone = terminalRecord(QStringLiteral("other"), QStringLiteral("install"), {QStringLiteral("other")});
    gone.startedAt = QDateTime::currentDateTimeUtc().addSecs(-600);
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), gone.toJson()); });
    const QString old = f.config.runDir + QLatin1Char('/') + QString(32, QLatin1Char('d')) + QStringLiteral(".exit");
    storetest::writeFile(old, "0\n");
    QFile oldFile(old);
    ASSERT_TRUE(oldFile.open(QIODevice::ReadWrite));
    ASSERT_TRUE(oldFile.setFileTime(QDateTime::currentDateTimeUtc().addDays(-1), QFileDevice::FileModificationTime));
    oldFile.close();
    const QString recent = f.config.runDir + QLatin1Char('/') + QString(32, QLatin1Char('e')) + QStringLiteral(".exit");
    storetest::writeFile(recent, "0\n");
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("other")).outcome, QStringLiteral("notFinished"));
    }
    EXPECT_FALSE(QFile::exists(old));
    EXPECT_TRUE(QFile::exists(recent)) << "within its 3 h it may still be followed";

    // Asked for moments ago: the terminal may still open, the Store waits for it.
    OperationRecord opening = terminalRecord(QStringLiteral("third"), QStringLiteral("install"), {QStringLiteral("third")});
    opening.startedAt = QDateTime::currentDateTimeUtc();
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), opening.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(ops.running());
        EXPECT_EQ(ops.items().at(0).state, Operations::State::Opening);
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("third")).outcome, QStringLiteral("terminalDidNotOpen"));
    }
}

TEST(Operations, FlatpakRecords)
{
    const OperationRecord install = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("install"));
    const auto back = OperationRecord::fromJson(install.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->flatpak, QStringLiteral("app/org.example.Notes/x86_64/stable"));
    EXPECT_EQ(back->plan.size(), 2);
    EXPECT_TRUE(OperationRecord::fromJson(flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("remove")).toJson()));
    QJsonObject bad = install.toJson();
    bad.insert(QStringLiteral("flatpak"), QStringLiteral("org.example.Notes")); // an install takes a ref
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = install.toJson();
    bad.insert(QStringLiteral("flatpak"), QStringLiteral("app/org.example.Notes/x86_64/stable --system"));
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("remove")).toJson();
    bad.insert(QStringLiteral("flatpak"), QStringLiteral("--unused"));
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = install.toJson();
    bad.insert(QStringLiteral("plan"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("not an id")}}});
    EXPECT_FALSE(OperationRecord::fromJson(bad));
}

// An install and a removal, as the Store's own child: flatpak's lines count the progress against its plan; success is the
// exit code AND the app there (or gone); a removal is followed by `--unused` (SD27); a failure keeps flatpak's words.
TEST(Operations, FlatpakInstallAndRemove)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    int done = 0;
    QObject::connect(&ops, &Operations::changed, &ops, [&] {
        for (const Operations::Item &i : ops.items())
            done = qMax(done, i.done);
    });
    ops.enqueue(flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("install")));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("org.example.Notes")).outcome.toStdString();
    EXPECT_EQ(done, 2);
    EXPECT_EQ(f.read(QStringLiteral("fcalls")),
              "install --user --noninteractive flathub app/org.example.Notes/x86_64/stable\nlist --user --app --columns=application\n");

    QFile::remove(f.dir.filePath(QStringLiteral("fcalls")));
    ops.enqueue(flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("remove")));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_TRUE(ops.results().isEmpty());
    EXPECT_EQ(f.read(QStringLiteral("fcalls")), "uninstall --user --noninteractive -- org.example.Notes\n"
                                                "uninstall --user --noninteractive --unused\nlist --user --app --columns=application\n");

    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "fail");
    ops.enqueue(flatpakRecord(QStringLiteral("org.example.Paint"), QStringLiteral("install")));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    const Operations::Result failed = ops.results().value(QStringLiteral("org.example.Paint"));
    EXPECT_EQ(failed.outcome, QStringLiteral("failed"));
    EXPECT_TRUE(failed.details.contains(QLatin1String("Could not connect"))) << failed.details.toStdString();

    // No flatpak (a dev session without its fake): nothing runs, and it says so.
    OperationsConfig none = f.config;
    none.flatpak.clear();
    Operations without(none);
    Ended ended(without);
    without.enqueue(flatpakRecord(QStringLiteral("org.example.Draw"), QStringLiteral("install")));
    ASSERT_TRUE(waitFor([&] { return ended.count() == 1; }));
    EXPECT_EQ(without.results().value(QStringLiteral("org.example.Draw")).outcome, QStringLiteral("notFinished"));
}

// A Flatpak's update (step 4): its refs (an app's, or the group's apps and runtimes), the app's own ref among them when it
// updates one app; only on the flatpak path.
OperationRecord flatpakUpdate(const QString &app, const QStringList &refs, const QString &appRef, const QStringList &commits = {})
{
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("update");
    r.path = QStringLiteral("flatpak");
    r.app = app;
    r.name = app;
    r.packages = refs;
    r.flatpak = appRef;
    r.commits = commits;
    while (r.commits.size() < refs.size())
        r.commits.append(QString());
    return r;
}

TEST(Operations, FlatpakUpdateRecords)
{
    const QString notes = QStringLiteral("app/org.example.Notes/x86_64/stable");
    const QString platform = QStringLiteral("runtime/org.example.Platform/x86_64/1");
    EXPECT_TRUE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes).toJson()));
    EXPECT_TRUE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {notes, platform}, QString()).toJson()));
    EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes, platform}, notes).toJson()))
        << "one app's update names its ref alone";
    EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, platform).toJson())) << "an app's ref";
    EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), {}, QString()).toJson())) << "no ref";
    for (const QString &bad : {QStringLiteral("--system"), QStringLiteral("app/org.example.Notes"), QStringLiteral("app/org.example.Notes/x86_64/../x"),
                               QStringLiteral("extension/org.example.X/x86_64/1")})
        EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), {notes, bad}, QString()).toJson())) << bad.toStdString();
    QJsonObject helper = flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes).toJson();
    helper.insert(QStringLiteral("path"), QStringLiteral("helper"));
    EXPECT_FALSE(OperationRecord::fromJson(helper)) << "only a Flatpak updates through the Store";
    // Not even with a package name the helper takes: the system updates as a whole, in Software Update (SD32).
    helper.insert(QStringLiteral("packages"), QJsonArray{QStringLiteral("example-notes")});
    helper.insert(QStringLiteral("flatpak"), QString());
    EXPECT_FALSE(OperationRecord::fromJson(helper)) << "a package's update through the helper";
    helper.insert(QStringLiteral("kind"), QStringLiteral("install"));
    helper.remove(QStringLiteral("commits")); // an update's
    EXPECT_TRUE(OperationRecord::fromJson(helper)) << "the same record as an install is the helper's";
    // As many refs as a check lists (Update All takes them all, one operation), no more.
    QStringList many;
    for (int i = 0; i < kMaxFlatpakUpdates; ++i)
        many.append(QStringLiteral("app/org.example.A%1/x86_64/stable").arg(i));
    EXPECT_TRUE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), many, QString()).toJson())) << "512";
    many.append(QStringLiteral("app/org.example.Last/x86_64/stable"));
    EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), many, QString()).toJson())) << "at most 512";

    // A commit for each ref (SD33, S32): 64 lowercase hex digits, or "" (unpinned); a pinned one only on an app's ref.
    const QString c1(64, QLatin1Char('a'));
    EXPECT_TRUE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes, {c1}).toJson()));
    EXPECT_TRUE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), {notes, platform}, QString(), {c1, QString()}).toJson()));
    EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("all"), {notes, platform}, QString(), {c1, c1}).toJson()))
        << "a runtime is not pinned";
    for (const QString &bad : {QStringLiteral("abc"), QString(64, QLatin1Char('A')), QString(63, QLatin1Char('a')), QStringLiteral("--system")})
        EXPECT_FALSE(OperationRecord::fromJson(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes, {bad}).toJson())) << bad.toStdString();
    QJsonObject shorter = flatpakUpdate(QStringLiteral("all"), {notes, platform}, QString()).toJson();
    shorter.insert(QStringLiteral("commits"), QJsonArray{c1});
    EXPECT_FALSE(OperationRecord::fromJson(shorter)) << "one commit per ref";
    QJsonObject install = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("install")).toJson();
    install.insert(QStringLiteral("commits"), QJsonArray{c1});
    EXPECT_FALSE(OperationRecord::fromJson(install)) << "commits are an update's";
    // The installed commit its plan read, for a pinned ref only (none at all from an older record).
    const QString c0(64, QLatin1Char('0'));
    OperationRecord from = flatpakUpdate(QStringLiteral("all"), {notes, platform}, QString(), {c1, QString()});
    from.fromCommits = {c0, QString()};
    EXPECT_TRUE(OperationRecord::fromJson(from.toJson()));
    from.fromCommits = {QString(), c0};
    EXPECT_FALSE(OperationRecord::fromJson(from.toJson())) << "no installed commit without a pin";
    from.fromCommits = {QStringLiteral("abc"), QString()};
    EXPECT_FALSE(OperationRecord::fromJson(from.toJson())) << "not a commit";
    from.fromCommits = {c0};
    EXPECT_FALSE(OperationRecord::fromJson(from.toJson())) << "one per ref";
    install.remove(QStringLiteral("commits"));
    install.insert(QStringLiteral("fromCommits"), QJsonArray{c0});
    EXPECT_FALSE(OperationRecord::fromJson(install)) << "an update's";

    // Its commands (S32d: --commit takes one ref): each pinned app alone, then the rest together.
    const QString paint = QStringLiteral("app/org.example.Paint/x86_64/stable");
    const QString c2(64, QLatin1Char('b'));
    const QStringList base{QStringLiteral("update"), QStringLiteral("--user"), QStringLiteral("--noninteractive")};
    EXPECT_EQ(flatpakUpdateCommands(flatpakUpdate(QStringLiteral("all"), {notes, platform, paint}, QString(), {c1, QString(), c2})),
              (QList<QStringList>{base + QStringList{QStringLiteral("--commit=") + c1, QStringLiteral("--"), notes},
                                  base + QStringList{QStringLiteral("--commit=") + c2, QStringLiteral("--"), paint},
                                  base + QStringList{QStringLiteral("--"), platform}}));
    EXPECT_EQ(flatpakUpdateCommands(flatpakUpdate(QStringLiteral("all"), {notes, platform}, QString())),
              (QList<QStringList>{base + QStringList{QStringLiteral("--"), notes, platform}}));
    // With each command, the ref it pins and the commit that ref must still have installed.
    OperationRecord guarded = flatpakUpdate(QStringLiteral("all"), {notes, platform, paint}, QString(), {c1, QString(), c2});
    guarded.fromCommits = {c0, QString(), QString()};
    EXPECT_EQ(flatpakUpdateGuards(guarded), (QList<std::pair<QString, QString>>{{notes, c0}, {paint, QString()}, {QString(), QString()}}));
}

// An update runs flatpak update with its refs; it is done when a new check no longer lists them, never on the exit code
// alone (offline flatpak exits 0 with "Nothing to update.", S31d).
TEST(Operations, FlatpakUpdate)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    const QString notes = QStringLiteral("app/org.example.Notes/x86_64/stable");
    const QString paint = QStringLiteral("app/org.example.Paint/x86_64/stable");
    const QString platform = QStringLiteral("runtime/org.example.Platform/x86_64/1");
    storetest::writeFile(f.dir.filePath(QStringLiteral("fupdates")), (notes + QLatin1Char('\n') + paint + QLatin1Char('\n') + platform + QLatin1Char('\n')).toUtf8());
    int total = 0;
    QObject::connect(&ops, &Operations::changed, &ops, [&] {
        for (const QVariant &v : ops.list())
            total = qMax(total, v.toMap().value(QStringLiteral("total")).toInt());
    });
    ops.enqueue(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("org.example.Notes")).outcome.toStdString();
    EXPECT_EQ(total, 1);
    EXPECT_EQ(f.read(QStringLiteral("fcalls")), "update --user --noninteractive -- " + notes.toUtf8()
                                                    + "\nremote-ls --user --updates --columns=application,branch,origin,ref\n");

    // Offline: flatpak says nothing was to update and exits 0; the check cannot answer: not finished, never done.
    QFile::remove(f.dir.filePath(QStringLiteral("fcalls")));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "offline");
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {paint, platform}, QString()));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    Operations::Result r = ops.results().value(QStringLiteral("store:flatpak-updates"));
    EXPECT_EQ(r.kind, QStringLiteral("update"));
    EXPECT_EQ(r.outcome, QStringLiteral("notFinished"));
    EXPECT_EQ(r.present, 0);
    EXPECT_EQ(r.total, 2);
    EXPECT_EQ(f.read(QStringLiteral("fcalls")), "update --user --noninteractive -- " + paint.toUtf8() + " " + platform.toUtf8()
                                                    + "\nremote-ls --user --updates --columns=application,branch,origin,ref\n");

    // Exit 0, the refs still listed: not finished either.
    ops.dismiss(QStringLiteral("store:flatpak-updates"));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "stale");
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {paint, platform}, QString()));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("store:flatpak-updates")).outcome, QStringLiteral("notFinished"));

    // flatpak's own failure keeps its words; then all of it, done.
    ops.dismiss(QStringLiteral("store:flatpak-updates"));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "fail");
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {paint, platform}, QString()));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
    r = ops.results().value(QStringLiteral("store:flatpak-updates"));
    EXPECT_EQ(r.outcome, QStringLiteral("failed"));
    EXPECT_TRUE(r.details.contains(QLatin1String("Could not connect")));
    ops.dismiss(QStringLiteral("store:flatpak-updates"));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "");
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {paint, platform}, QString()));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 5; }));
    EXPECT_TRUE(ops.results().isEmpty());
    EXPECT_EQ(f.read(QStringLiteral("fupdates")), "");
}

// A pinned update (SD33, S32): each app updated to the commit its plan checked, one command each, then the rest; a pinned
// ref is done when its installed commit is that one, even with a newer one listed already (S32e); a command that fails ends
// the update, and what it did is counted.
TEST(Operations, FlatpakUpdatePinned)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    const QString notes = QStringLiteral("app/org.example.Notes/x86_64/stable");
    const QString paint = QStringLiteral("app/org.example.Paint/x86_64/stable");
    const QString platform = QStringLiteral("runtime/org.example.Platform/x86_64/1");
    const QString c1(64, QLatin1Char('a')), c2(64, QLatin1Char('b'));
    const QByteArray listed = (notes + QLatin1Char('\n') + paint + QLatin1Char('\n') + platform + QLatin1Char('\n')).toUtf8();
    storetest::writeFile(f.dir.filePath(QStringLiteral("fupdates")), listed);
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "newer");
    int total = 0, done = 0;
    QObject::connect(&ops, &Operations::changed, &ops, [&] {
        for (const QVariant &v : ops.list()) {
            total = qMax(total, v.toMap().value(QStringLiteral("total")).toInt());
            done = qMax(done, v.toMap().value(QStringLiteral("done")).toInt());
        }
    });
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {notes, paint, platform}, QString(), {c1, c2, QString()}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("store:flatpak-updates")).outcome.toStdString();
    EXPECT_EQ(total, 3);
    EXPECT_EQ(done, 3) << "the Updating lines of the three commands";
    const QByteArray update = "update --user --noninteractive ";
    EXPECT_EQ(f.read(QStringLiteral("fcalls")), update + "--commit=" + c1.toUtf8() + " -- " + notes.toUtf8() + "\n"
                                                    + update + "--commit=" + c2.toUtf8() + " -- " + paint.toUtf8() + "\n"
                                                    + update + "-- " + platform.toUtf8() + "\n"
                                                    + "remote-ls --user --updates --columns=application,branch,origin,ref\n"
                                                    + "info --user --show-commit -- " + notes.toUtf8() + "\n"
                                                    + "info --user --show-commit -- " + paint.toUtf8() + "\n");
    EXPECT_EQ(f.read(QStringLiteral("fupdates")), (notes + QLatin1Char('\n') + paint + QLatin1Char('\n')).toUtf8())
        << "the newer commits are listed: a new plan asks about them";

    // The second command fails (its commit is gone from Flathub, S32d): the rest is not run; one of three was done.
    QFile::remove(f.dir.filePath(QStringLiteral("fcalls")));
    QFile::remove(f.dir.filePath(QStringLiteral("fcommits")));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fupdates")), listed);
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "");
    storetest::writeFile(f.dir.filePath(QStringLiteral("failref")), paint.toUtf8());
    ops.enqueue(flatpakUpdate(QStringLiteral("store:flatpak-updates"), {notes, paint, platform}, QString(), {c1, c2, QString()}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    const Operations::Result r = ops.results().value(QStringLiteral("store:flatpak-updates"));
    EXPECT_EQ(r.outcome, QStringLiteral("interrupted"));
    EXPECT_EQ(r.present, 1);
    EXPECT_EQ(r.total, 3);
    EXPECT_TRUE(r.details.contains(QLatin1String("status 404")));
    EXPECT_FALSE(f.read(QStringLiteral("fcalls")).contains("-- " + platform.toUtf8())) << "nothing after the failed command";

    // Updated outside the Store since its plan (another commit installed than the one its plan read): its pinned command is
    // not run, so it is never put back to an older commit; it counts as done, and the rest runs.
    ops.dismiss(QStringLiteral("store:flatpak-updates"));
    QFile::remove(f.dir.filePath(QStringLiteral("failref")));
    QFile::remove(f.dir.filePath(QStringLiteral("fcalls")));
    const QString c0(64, QLatin1Char('0')), c3(64, QLatin1Char('c'));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fcommits")),
                         (notes + QLatin1Char(' ') + c3 + QLatin1Char('\n') + paint + QLatin1Char(' ') + c0 + QLatin1Char('\n')).toUtf8());
    storetest::writeFile(f.dir.filePath(QStringLiteral("fupdates")), listed);
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "");
    OperationRecord outside = flatpakUpdate(QStringLiteral("store:flatpak-updates"), {notes, paint, platform}, QString(), {c1, c2, QString()});
    outside.fromCommits = {c0, c0, QString()};
    ops.enqueue(outside);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("store:flatpak-updates")).outcome.toStdString();
    const QByteArray outsideCalls = f.read(QStringLiteral("fcalls"));
    EXPECT_FALSE(outsideCalls.contains("--commit=" + c1.toUtf8())) << "Notes kept its newer commit";
    EXPECT_TRUE(outsideCalls.contains("--commit=" + c2.toUtf8() + " -- " + paint.toUtf8())) << "Paint still had its planned commit";
    EXPECT_TRUE(outsideCalls.contains(update + "-- " + platform.toUtf8()));
    EXPECT_TRUE(outsideCalls.startsWith("info --user --show-commit -- " + notes.toUtf8() + "\n")) << outsideCalls.constData();

    // Its installed commit is another one: not done.
    ops.dismiss(QStringLiteral("store:flatpak-updates"));
    QFile::remove(f.dir.filePath(QStringLiteral("failref")));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fcommits")), (notes + QLatin1Char(' ') + c2 + QLatin1Char('\n')).toUtf8());
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "stale");
    ops.enqueue(flatpakUpdate(QStringLiteral("org.example.Notes"), {notes}, notes, {c1}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("org.example.Notes")).outcome, QStringLiteral("notFinished"));
}

// Stopping an install (SD26): SIGTERM to flatpak, which ends at once (S25); the outcome says it was stopped, and only a
// running Flatpak install can be.
TEST(Operations, FlatpakStop)
{
    Fixture f;
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "slow");
    Operations ops(f.config);
    Ended finished(ops);
    OperationRecord r = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("install"));
    ops.enqueue(r);
    OperationRecord waiting = flatpakRecord(QStringLiteral("org.example.Paint"), QStringLiteral("install"));
    ops.enqueue(waiting);
    ASSERT_TRUE(waitFor([&] { return f.read(QStringLiteral("fcalls")).contains("install"); }));
    ASSERT_TRUE(waitFor([&] { return !ops.items().isEmpty() && ops.items().constFirst().done == 1; }));
    EXPECT_TRUE(ops.list().constFirst().toMap().value(QStringLiteral("stoppable")).toBool());
    EXPECT_FALSE(ops.list().at(1).toMap().value(QStringLiteral("stoppable")).toBool()) << "a waiting one is removed, not stopped";
    EXPECT_FALSE(ops.stop(waiting.id));
    EXPECT_TRUE(ops.removeWaiting(waiting.id));
    EXPECT_TRUE(ops.stop(r.id));
    EXPECT_FALSE(ops.stop(r.id)) << "once";
    EXPECT_FALSE(ops.list().constFirst().toMap().value(QStringLiteral("stoppable")).toBool());
    ASSERT_TRUE(waitFor([&] { return finished.count() >= 1; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("org.example.Notes")).outcome, QStringLiteral("stopped"));
    EXPECT_TRUE(f.read(QStringLiteral("fcalls")).contains("stopped")) << "flatpak had SIGTERM";
    EXPECT_FALSE(f.read(QStringLiteral("flatpaks")).contains("org.example.Notes"));

    // A removal and the other paths cannot be stopped.
    Fixture g;
    Operations other(g.config);
    Ended ended(other);
    g.mode("slow");
    const OperationRecord helper = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm")});
    other.enqueue(helper);
    EXPECT_FALSE(other.stop(helper.id));
    storetest::writeFile(g.dir.filePath(QStringLiteral("flatpaks")), "org.example.Notes\n");
    const OperationRecord removal = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("remove"));
    other.enqueue(removal);
    ASSERT_TRUE(waitFor([&] { return ended.count() == 1; }));
    EXPECT_FALSE(other.stop(removal.id));
    ASSERT_TRUE(waitFor([&] { return ended.count() == 2; }));
}

// SU-09: a Flatpak update can be stopped as an install can (the ring's square, the menu bar's Stop), its later commands not run;
// and any Flatpak operation that prints nothing past the idle limit (a stalled network) is stopped and ends "not finished",
// with the reason in Details, so the queue behind it moves on.
TEST(Operations, FlatpakUpdateStopAndIdleLimit)
{
    Fixture f;
    const QString notes = QStringLiteral("app/org.example.Notes/x86_64/stable");
    const QString platform = QStringLiteral("runtime/org.example.Platform/x86_64/1");
    storetest::writeFile(f.dir.filePath(QStringLiteral("fupdates")), (notes + QLatin1Char('\n') + platform + QLatin1Char('\n')).toUtf8());
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "slow");
    {
        Operations ops(f.config);
        Ended finished(ops);
        const OperationRecord update = flatpakUpdate(QStringLiteral("store:flatpak-updates"), {notes, platform}, QString());
        ops.enqueue(update);
        ASSERT_TRUE(waitFor([&] { return f.read(QStringLiteral("fcalls")).contains("waiting"); }));
        ASSERT_TRUE(waitFor([&] { return !ops.list().isEmpty() && ops.list().constFirst().toMap().value(QStringLiteral("stoppable")).toBool(); }));
        EXPECT_TRUE(ops.stop(update.id));
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(f.read(QStringLiteral("fcalls")).contains("stopped")) << "flatpak had SIGTERM";
        EXPECT_EQ(ops.results().value(QStringLiteral("store:flatpak-updates")).outcome, QStringLiteral("stopped"));
    }

    // The idle limit: a removal (which the user cannot stop) that prints nothing.
    QFile::remove(f.dir.filePath(QStringLiteral("fcalls")));
    storetest::writeFile(f.dir.filePath(QStringLiteral("fmode")), "silent");
    storetest::writeFile(f.dir.filePath(QStringLiteral("flatpaks")), "org.example.Notes\n");
    f.config.flatpakIdleMs = 600;
    Operations ops(f.config);
    Ended finished(ops);
    const OperationRecord removal = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("remove"));
    ops.enqueue(removal);
    const OperationRecord next = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm")});
    f.mode("ok");
    ops.enqueue(next);
    ASSERT_TRUE(waitFor([&] { return f.read(QStringLiteral("fcalls")).contains("uninstall"); }));
    EXPECT_FALSE(ops.stop(removal.id)) << "a removal is not stopped by the user";
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }, 15000)) << "stopped at the idle limit, not left hanging";
    EXPECT_TRUE(f.read(QStringLiteral("fcalls")).contains("stopped"));
    const Operations::Result r = ops.results().value(QStringLiteral("org.example.Notes"));
    EXPECT_EQ(r.outcome, QStringLiteral("notFinished"));
    EXPECT_TRUE(r.details.contains(QLatin1String("printed nothing"))) << r.details.toStdString();
    EXPECT_FALSE(f.read(QStringLiteral("fcalls")).contains("--unused")) << "nothing more runs after a stalled step";
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; })) << "the queue moved on";
}

// Recovery (f): the child died with the Store (SIGTERM), so a recorded Flatpak operation is judged by the app's state.
TEST(Operations, FlatpakRecovery)
{
    Fixture f;
    const OperationRecord there = flatpakRecord(QStringLiteral("org.example.Notes"), QStringLiteral("install"));
    storetest::writeFile(f.dir.filePath(QStringLiteral("flatpaks")), "org.example.Notes\n");
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), there.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty()) << "installed: done, nothing said";
    }
    const OperationRecord missing = flatpakRecord(QStringLiteral("org.example.Paint"), QStringLiteral("install"));
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), missing.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("org.example.Paint")).outcome, QStringLiteral("notFinished"));
        EXPECT_TRUE(waitFor([&] { return f.record().isEmpty(); })); // cleared on the writer's thread
    }
}
