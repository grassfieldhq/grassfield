// The Store window's backend (ADR-0037 step 2) in a dev session with the fixture plumbing of ADR-0019: a fake pacman
// (GRASSFIELD_STORE_FIXTURE/bin/pacman), Arch's AppStream from the fixture, a catalog URL on disk, a keyring folder without
// a key, and every XDG folder in a scratch directory. Nothing reads the system's package manager, keys or home.
#include "storebackend.h"
#include "storeenv.h"
#include "storetest.h"

#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QCryptographicHash>
#include <QTimer>

#include <functional>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

// The process environment of a dev session pointed at `root`, put back as it was afterwards.
class DevEnvironment
{
public:
    explicit DevEnvironment(const QString &root)
    {
        set("GRASSFIELD_DEV", "1");
        unset("GRASSFIELD_SESSION");
        set("GRASSFIELD_STORE_FIXTURE", root + QStringLiteral("/fixture"));
        set("GRASSFIELD_STORE_KEYRING", root + QStringLiteral("/keyring"));
        set("GRASSFIELD_STORE_CATALOG_URL", QUrl::fromLocalFile(root + QStringLiteral("/served/grassfield-catalog.v1.json")).toString());
        set("GRASSFIELD_CONFIG_HOME", root + QStringLiteral("/config"));
        set("GRASSFIELD_STATE_HOME", root + QStringLiteral("/state"));
        set("XDG_CACHE_HOME", root + QStringLiteral("/cache"));
        set("XDG_DATA_HOME", root + QStringLiteral("/data"));
        set("GRASSFIELD_LANG", "en_US");
    }
    ~DevEnvironment()
    {
        for (auto it = m_saved.cbegin(); it != m_saved.cend(); ++it) {
            if (it.value())
                qputenv(it.key().constData(), *it.value());
            else
                qunsetenv(it.key().constData());
        }
    }

    void set(const char *name, const QString &value)
    {
        save(name);
        qputenv(name, value.toUtf8());
    }
    void unset(const char *name)
    {
        save(name);
        qunsetenv(name);
    }

private:
    void save(const char *name)
    {
        if (!m_saved.contains(name))
            m_saved.insert(name, qEnvironmentVariableIsSet(name) ? std::optional<QByteArray>(qgetenv(name)) : std::nullopt);
    }
    QMap<QByteArray, std::optional<QByteArray>> m_saved;
};

// A fake pacman: the repositories' list, the explicit and foreign packages, the files of the foreign ones, one -Si.
const QByteArray kPacman = R"(case "$1" in
  -Sl) printf '%s\n' 'extra gimp 3.0.4-1 [installed]' 'extra sketch 2.1-1 [installed]' 'extra paint 1-1' 'extra cafe 1-1 [installed]' \
         'multilib steam 1.0-1' 'grassfield grassfield-desktop 1.0.0-1 [installed]' ;;
  -Qqe) printf '%s\n' gimp sketch yay grassfield-desktop ;;
  -Qqm) printf '%s\n' yay localapp grassfield-dev ;;
  -Ql) shift; [ "$1" = -- ] && shift
       for p in "$@"; do
         case $p in
           localapp) echo 'localapp /usr/share/applications/localapp.desktop' ;;
           yay) echo 'yay /usr/bin/yay' ;;
           grassfield-dev) echo 'grassfield-dev /usr/share/applications/dev.desktop' ;;
         esac
       done ;;
  -Si) [ "$3" = gimp ] || exit 1
       printf '%s\n' 'Repository      : extra' 'Name            : gimp' 'Version         : 3.0.4-1' 'Download Size   : 21.56 MiB' \
         'Installed Size  : 120.00 MiB' 'Build Date      : Thu Oct 15 08:27:03 2026' ;;
  *) exit 1 ;;
esac)";

struct Scratch {
    QTemporaryDir dir;
    std::unique_ptr<DevEnvironment> env;
    Scratch()
    {
        storetest::ensureApp();
        const QString root = dir.path();
        for (const char *sub : {"fixture/bin", "fixture/swcatalog/xml", "keyring", "served", "config", "state", "cache", "data/applications"})
            QDir().mkpath(root + QLatin1Char('/') + QLatin1String(sub));
        storetest::script(root + QStringLiteral("/fixture/bin/pacman"), kPacman);
        storetest::writeFile(root + QStringLiteral("/fixture/swcatalog/xml/extra.xml.gz"),
                             storetest::gzip(storetest::readFixture(QStringLiteral("appstream-extra.xml"))));
        storetest::writeFile(root + QStringLiteral("/fixture/swcatalog/xml/product.xml.gz"),
                             storetest::gzip(storetest::readFixture(QStringLiteral("appstream-product.xml"))));
        // Two web app launchers (Omarchy's), and a desktop entry of something else.
        storetest::writeFile(root + QStringLiteral("/data/applications/Mail.desktop"),
                             "[Desktop Entry]\nName=Mail\nExec=omarchy-launch-webapp \"https://mail.example.com/\"\nIcon=mail\n");
        storetest::writeFile(root + QStringLiteral("/data/applications/Chat.desktop"),
                             "[Desktop Entry]\nName=Chat\nExec=omarchy-launch-webapp https://chat.example.org\n");
        storetest::writeFile(root + QStringLiteral("/data/applications/editor.desktop"), "[Desktop Entry]\nName=Editor\nExec=vim\n");
        storetest::writeFile(root + QStringLiteral("/state/software-update.json"),
                             R"({"version":1,"state":"available","others":3,"grassfield":{"installed":"1.0.0-1","available":"1.0.1-1"},
                                 "otherPackages":[{"name":"gimp","installed":"3.0.4-1","available":"3.0.6-1"}]})");
        env = std::make_unique<DevEnvironment>(root);
    }
    QString path(const QString &rel) const { return dir.filePath(rel); }
};

// Waits until the backend has no job running (or 20 s passed).
bool settle(StoreBackend &backend)
{
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    QObject::connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
    timeout.start(20000);
    while (timeout.isActive() && (backend.loading() || backend.refreshing())) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    // A follow-up fetch may start right after the first load: let it run too.
    for (int i = 0; i < 25 && timeout.isActive(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
        if (backend.loading() || backend.refreshing())
            i = 0;
    }
    return timeout.isActive();
}

// The packageInfo answers, collected; wait() returns once there are `count` of them (or 10 s passed).
struct Answers {
    QList<std::pair<QString, QVariantMap>> list;
    explicit Answers(StoreBackend &backend)
    {
        QObject::connect(&backend, &StoreBackend::packageInfo, &backend,
                         [this](const QString &package, const QVariantMap &facts) { list.append({package, facts}); });
    }
    bool wait(int count)
    {
        QEventLoop loop;
        for (int i = 0; i < 500 && list.size() < count; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return list.size() >= count;
    }
};

QStringList ids(const QVariantList &list)
{
    QStringList out;
    for (const QVariant &v : list)
        out.append(v.toMap().value(QStringLiteral("id")).toString());
    return out;
}

} // namespace

// No catalog yet (none served, then one whose signature no key in the keyring makes): the built-in Discover and
// categories, AppStream's apps, the local search, a product page, Installed and the Updates list all work.
TEST(StoreBackend, WithoutACatalog)
{
    Scratch s;
    StoreBackend backend;
    EXPECT_TRUE(backend.devSession());
    EXPECT_EQ(backend.language(), QStringLiteral("en"));
    EXPECT_TRUE(backend.loading());
    backend.start();
    ASSERT_TRUE(settle(backend));
    EXPECT_FALSE(backend.loading());
    EXPECT_GE(backend.revision(), 1);

    const QVariantMap catalog = backend.catalogStatus();
    EXPECT_FALSE(catalog.value(QStringLiteral("inUse")).toBool());
    EXPECT_EQ(catalog.value(QStringLiteral("problem")), QStringLiteral("unavailable")); // nothing served
    // No VERSION in the fixture: only beta is safe (ADR-0033 O15b), whatever version this machine runs.
    EXPECT_EQ(catalog.value(QStringLiteral("channel")), QStringLiteral("beta"));
    EXPECT_EQ(backend.appDataStatus().value(QStringLiteral("origin")), QStringLiteral("installed"));

    // Discover is the built-in one: rows by category, GIMP (Graphics) among them.
    const QVariantList sections = backend.sections();
    ASSERT_EQ(ids(sections), QStringList{QStringLiteral("discover")});
    EXPECT_TRUE(sections.at(0).toMap().value(QStringLiteral("builtIn")).toBool());
    const QVariantList categories = backend.categories();
    EXPECT_TRUE(ids(categories).contains(QStringLiteral("graphics")));
    EXPECT_EQ(ids(backend.categoryApps(QStringLiteral("graphics"))),
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Paint")}));
    EXPECT_TRUE(backend.categoryApps(QStringLiteral("graphics"), QStringLiteral("webapp")).isEmpty());
    EXPECT_EQ(ids(backend.search(QStringLiteral("gimp"))).value(0), QStringLiteral("org.gimp.GIMP"));
    EXPECT_TRUE(backend.search(QStringLiteral("zzzz")).isEmpty());

    const QVariantMap sketch = backend.app(QStringLiteral("org.example.Sketch"));
    EXPECT_EQ(sketch.value(QStringLiteral("name")), QStringLiteral("Sketch Pad"));
    EXPECT_EQ(sketch.value(QStringLiteral("releases")).toList().size(), 3);
    EXPECT_TRUE(backend.app(QStringLiteral("org.example.Nothing")).isEmpty());

    // pacman -Si answers the Information list.
    Answers info(backend);
    backend.requestPackageInfo(QStringLiteral("gimp"));
    ASSERT_TRUE(info.wait(1));
    EXPECT_EQ(info.list.at(0).first, QStringLiteral("gimp"));
    EXPECT_EQ(info.list.at(0).second.value(QStringLiteral("version")), QStringLiteral("3.0.4-1"));
    EXPECT_EQ(info.list.at(0).second.value(QStringLiteral("buildDate")), QStringLiteral("October 15, 2026"));
    backend.requestPackageInfo(QStringLiteral("-rf")); // not a package name: no query
    backend.requestPackageInfo(QStringLiteral("cafe"));
    ASSERT_TRUE(info.wait(2));
    EXPECT_EQ(info.list.size(), 2);
    EXPECT_EQ(info.list.at(1).first, QStringLiteral("cafe"));
    EXPECT_TRUE(info.list.at(1).second.isEmpty()); // pacman knows nothing: no facts

    // Installed: explicit packages with metadata, then web apps, then packages no repository has that own an entry.
    const QVariantList installed = backend.installed();
    QStringList groups;
    for (const QVariant &g : installed)
        groups.append(g.toMap().value(QStringLiteral("group")).toString());
    EXPECT_EQ(groups, (QStringList{QStringLiteral("arch"), QStringLiteral("webapp"), QStringLiteral("foreign")}));
    EXPECT_EQ(ids(installed.at(0).toMap().value(QStringLiteral("apps")).toList()),
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Sketch")})); // cafe is not explicit
    EXPECT_EQ(ids(installed.at(1).toMap().value(QStringLiteral("apps")).toList()),
              (QStringList{QStringLiteral("webapp:Chat"), QStringLiteral("webapp:Mail")}));
    EXPECT_EQ(ids(installed.at(2).toMap().value(QStringLiteral("apps")).toList()), QStringList{QStringLiteral("package:localapp")});

    const QVariantMap updates = backend.updates();
    EXPECT_EQ(updates.value(QStringLiteral("state")), QStringLiteral("available"));
    EXPECT_EQ(ids(updates.value(QStringLiteral("apps")).toList()), QStringList{QStringLiteral("org.gimp.GIMP")});
    EXPECT_EQ(updates.value(QStringLiteral("otherCount")).toInt(), 2);

    // Links never open from a dev session; screenshots are https only.
    EXPECT_FALSE(backend.openLink(QStringLiteral("https://www.gimp.org/")));
    EXPECT_TRUE(backend.screenshotSource(QStringLiteral("http://example.com/a.png")).isEmpty());
    EXPECT_EQ(backend.screenshotSource(QStringLiteral("https://example.com/a b.png")), QString()); // a space: not an https URL
    if (backend.online()) {
        EXPECT_EQ(backend.screenshotSource(QStringLiteral("https://example.com/a.png")),
                  QStringLiteral("image://screenshot/https%3A%2F%2Fexample.com%2Fa.png"));
    }

    // A catalog served now, signed by no key the keyring trusts (it has none): fetched on Ctrl+R, refused, not used.
    storetest::writeFile(s.path(QStringLiteral("served/grassfield-catalog.v1.json")), storetest::readFixture(QStringLiteral("catalog-good.json")));
    storetest::writeFile(s.path(QStringLiteral("served/grassfield-catalog.v1.json.sig")), "not a signature");
    const int before = backend.revision();
    backend.refresh();
    EXPECT_TRUE(backend.refreshing());
    ASSERT_TRUE(settle(backend));
    EXPECT_GT(backend.revision(), before);
    EXPECT_FALSE(backend.catalogStatus().value(QStringLiteral("inUse")).toBool());
    EXPECT_EQ(backend.catalogStatus().value(QStringLiteral("problem")), QStringLiteral("untrusted"));
    EXPECT_TRUE(backend.sections().at(0).toMap().value(QStringLiteral("builtIn")).toBool());
}

// The owner's rc1-7 (the integrator's note on PR #36): no catalog host yet ("unconfigured", no dev plumbing URL) and Arch's
// app data installed: the Store works on Arch's data alone, its Discover the built-in one with rows of apps, never the page
// that says the Store isn't available.
TEST(StoreBackend, NoCatalogHostButArchsData)
{
    Scratch s;
    s.env->unset("GRASSFIELD_STORE_CATALOG_URL");
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));
    EXPECT_EQ(backend.catalogStatus().value(QStringLiteral("problem")), QStringLiteral("unconfigured"));
    EXPECT_EQ(backend.appDataStatus().value(QStringLiteral("origin")), QStringLiteral("installed"));
    const QVariantList sections = backend.sections();
    ASSERT_EQ(ids(sections), QStringList{QStringLiteral("discover")});
    const QVariantMap discover = sections.at(0).toMap();
    EXPECT_TRUE(discover.value(QStringLiteral("builtIn")).toBool());
    EXPECT_FALSE(discover.value(QStringLiteral("blocks")).toList().isEmpty()); // rows: the page has something to show
    EXPECT_EQ(ids(backend.search(QStringLiteral("gimp"))).value(0), QStringLiteral("org.gimp.GIMP"));
}

// ADR-0046 F1: a repository app the user installed that no catalog or AppStream data describes (Omarchy's repository has no
// AppStream data) is an app named by its package, with its entry, so that the launcher and Files can remove it; Omarchy's own
// optional preinstall (aether) is not "Part of Omarchy", one of its base list (btop) is.
TEST(StoreBackend, AnAppWithoutAppStreamDataIsRemovableByItsEntry)
{
    Scratch s;
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    const QByteArray b = base.toUtf8();
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "case \"$1\" in\n"
                      "  -Sl) " + b + " -Sl; echo 'omarchy aether 1.0-1 [installed]'; echo 'omarchy btop 1.0-1 [installed]'\n"
                      "       echo 'extra needed 1-1 [installed]'; echo 'extra taker 1-1 [installed]'; echo 'extra kcmx 1-1 [installed]' ;;\n"
                      "  -Qqe) " + b + " -Qqe; echo aether; echo btop; echo needed; echo taker; echo kcmx ;;\n"
                      "  -Qq) echo grassfield-desktop; echo gimp ;;\n"
                      "  -Qi) printf '%s\\n' 'Name            : grassfield-desktop' 'Optional Deps   : kcmx: a Grassfield option [installed]' ;;\n"
                      "  -Rs) case \"$*\" in\n"
                      "         *aether*) echo 'aether 1.0-1' ;;\n"
                      "         *needed*) echo \":: removing needed breaks dependency 'needed' required by other\"; exit 1 ;;\n"
                      "         *taker*) echo 'taker 1-1'; echo 'glibc 2-1' ;;\n"
                      "         *) exit 1 ;;\n"
                      "       esac ;;\n"
                      "  -Qu) exit 1 ;;\n"
                      "  -Qo) shift; [ \"$1\" = -- ] && shift\n"
                      "       for f in \"$@\"; do case $f in\n"
                      "         */aether.desktop) echo \"$f is owned by aether 1.0-1\" ;;\n"
                      "         */btop.desktop) echo \"$f is owned by btop 1.0-1\" ;;\n"
                      "         */needed.desktop) echo \"$f is owned by needed 1-1\" ;;\n"
                      "         */taker.desktop) echo \"$f is owned by taker 1-1\" ;;\n"
                      "         */kcmx.desktop) echo \"$f is owned by kcmx 1-1\" ;;\n"
                      "       esac; done ;;\n"
                      "  *) exec " + b + " \"$@\" ;;\nesac");
    QDir().mkpath(s.path(QStringLiteral("fixture/applications")));
    QDir().mkpath(s.path(QStringLiteral("fixture/omarchy/install")));
    for (const char *name : {"aether", "btop", "needed", "taker", "kcmx"})
        storetest::writeFile(s.path(QStringLiteral("fixture/applications/%1.desktop").arg(QLatin1String(name))),
                             QByteArray("[Desktop Entry]\nType=Application\nName=X\nExec=x\n"));
    storetest::writeFile(s.path(QStringLiteral("fixture/omarchy/install/omarchy-base.packages")), "aether\nbtop\n");
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));
    const QVariantMap byEntry = backend.removalByEntry();
    ASSERT_TRUE(byEntry.contains(QStringLiteral("aether.desktop"))) << "listed by its package";
    EXPECT_EQ(byEntry.value(QStringLiteral("aether.desktop")).toMap().value(QStringLiteral("app")).toString(), QStringLiteral("aether"));
    const QString aether = byEntry.value(QStringLiteral("aether.desktop")).toMap().value(QStringLiteral("block")).toString();
    EXPECT_TRUE(aether.isEmpty() || aether == QLatin1String("dev")) << qPrintable(aether) << ": removable (a dev session has no pkexec)";
    EXPECT_EQ(byEntry.value(QStringLiteral("btop.desktop")).toMap().value(QStringLiteral("block")).toString(), QStringLiteral("omarchy"));
    EXPECT_EQ(backend.appForEntry(QStringLiteral("aether")), QStringLiteral("aether"));
    EXPECT_EQ(backend.actions(QStringLiteral("aether")).value(QStringLiteral("uninstall")).toString(), aether);
    // Grassfield's own optional dependency (pacman -Qi grassfield-desktop lists kcmx): "Part of Grassfield", never offered.
    EXPECT_EQ(byEntry.value(QStringLiteral("kcmx.desktop")).toMap().value(QStringLiteral("block")).toString(), QStringLiteral("grassfield"));
}

// ADR-0046 D3: with `withPlans` (what `--removable` asks) a removable app whose -Rs plan would be refused is not offered: a package
// something needs ("dependency"), one whose plan takes a protected package ("protected"); a clean plan stays "".
TEST(StoreBackend, ABadgeNeverLeadsToARefusal)
{
    Scratch s;
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    const QByteArray b = base.toUtf8();
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "case \"$1\" in\n"
                      "  -Sl) " + b + " -Sl; echo 'extra aether 1.0-1 [installed]'; echo 'extra needed 1-1 [installed]'; echo 'extra taker 1-1 [installed]' ;;\n"
                      "  -Qqe) " + b + " -Qqe; echo aether; echo needed; echo taker ;;\n"
                      "  -Qo) shift; [ \"$1\" = -- ] && shift\n"
                      "       for f in \"$@\"; do case $f in\n"
                      "         */aether.desktop) echo \"$f is owned by aether 1.0-1\" ;;\n"
                      "         */needed.desktop) echo \"$f is owned by needed 1-1\" ;;\n"
                      "         */taker.desktop) echo \"$f is owned by taker 1-1\" ;;\n"
                      "       esac; done ;;\n"
                      "  -Rs) case \"$*\" in\n"
                      "         *aether*) echo 'aether 1.0-1' ;;\n"
                      "         *needed*) echo \":: removing needed breaks dependency 'needed' required by other\"; exit 1 ;;\n"
                      "         *taker*) echo 'taker 1-1'; echo 'glibc 2-1' ;;\n"
                      "         *) exit 1 ;;\n"
                      "       esac ;;\n"
                      "  -Qu) exit 1 ;;\n"
                      "  *) exec " + b + " \"$@\" ;;\nesac");
    QDir().mkpath(s.path(QStringLiteral("fixture/applications")));
    QDir().mkpath(s.path(QStringLiteral("fixture/omarchy/install")));
    for (const char *name : {"aether", "needed", "taker"})
        storetest::writeFile(s.path(QStringLiteral("fixture/applications/%1.desktop").arg(QLatin1String(name))),
                             QByteArray("[Desktop Entry]\nType=Application\nName=X\nExec=x\n"));
    storetest::writeFile(s.path(QStringLiteral("fixture/omarchy/install/omarchy-base.packages")), "btop\n");
    s.env->set("GRASSFIELD_STORE_PKEXEC", QStringLiteral("/usr/bin/true")); // a dev session with a pkexec: nothing is blocked by "dev"
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));
    const auto block = [](const QVariantMap &m, const char *entry) {
        return m.value(QLatin1String(entry)).toMap().value(QStringLiteral("block")).toString();
    };
    const QVariantMap plain = backend.removalByEntry();
    EXPECT_EQ(block(plain, "needed.desktop"), QString()) << "the pages do not run the plans";
    EXPECT_EQ(block(plain, "taker.desktop"), QString());
    const QVariantMap planned = backend.removalByEntry(true);
    EXPECT_EQ(block(planned, "aether.desktop"), QString()) << "a clean plan stays offered";
    EXPECT_EQ(block(planned, "needed.desktop"), QStringLiteral("dependency"));
    EXPECT_EQ(block(planned, "taker.desktop"), QStringLiteral("protected"));
}

// Arch's app data fetched from the mirror (archlinux-appstream-data not installed), each failure with its own reason (the
// integrator's note on PR #36): the package file the mirror no longer has and its .sig not served are "download" (the
// window then offers Software Update), a signature pacman's rule refuses is "unverified".
TEST(StoreBackend, ArchsAppDataProblems)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0")); // the refresh runs only online
    QDir(s.path(QStringLiteral("fixture/swcatalog"))).removeRecursively(); // not installed: fetched from the mirror
    // pacman: the fixture's, and -Sp naming the package file in served/ (a file:// mirror, dev plumbing).
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    const QString package = s.path(QStringLiteral("served/archlinux-appstream-data-20261017-1-any.pkg.tar.zst"));
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "[ \"$1\" = -Sp ] && { echo '" + QUrl::fromLocalFile(package).toString().toUtf8() + "'; exit 0; }\nexec '" + base.toUtf8() + "' \"$@\"");
    // gpg: a good signature by a packager pacman's keyring does not trust fully (S19).
    storetest::script(s.path(QStringLiteral("fixture/bin/gpg")),
                      "case \" $* \" in\n"
                      "*' --verify '*) printf '[GNUPG:] NEWSIG\\n[GNUPG:] GOODSIG 1 Packager\\n[GNUPG:] VALIDSIG AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                      " 2026-10-27 1 0 4 0 22 10 00 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n[GNUPG:] TRUST_UNDEFINED 0 pgp\\n' ;;\n"
                      "*' --list-keys '*) printf 'pub:f:255:22:1:1:::-:::scSC::::::23::0:\\nfpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\\n' ;;\n"
                      "esac");
    QDir().mkpath(s.path(QStringLiteral("fixture/gnupg")));
    storetest::writeFile(s.path(QStringLiteral("fixture/gnupg/pubring.gpg")), "keys");
    storetest::writeFile(s.path(QStringLiteral("fixture/gnupg/trustdb.gpg")), "trust");
    const auto problem = [] {
        StoreBackend backend;
        backend.start();
        settle(backend);
        return backend.appDataStatus();
    };
    // The mirror has moved on: no such package file.
    QVariantMap data = problem();
    EXPECT_EQ(data.value(QStringLiteral("origin")), QStringLiteral("none"));
    EXPECT_EQ(data.value(QStringLiteral("problem")), QStringLiteral("download"));
    // The file there, its signature not.
    storetest::writeFile(package, "package bytes");
    EXPECT_EQ(problem().value(QStringLiteral("problem")), QStringLiteral("download"));
    // Both there, the signature refused by pacman's rule: the only case called "unverified".
    storetest::writeFile(package + QStringLiteral(".sig"), "signature bytes");
    EXPECT_EQ(problem().value(QStringLiteral("problem")), QStringLiteral("unverified"));
}

// A system older than its mirror (the integrator's note on PR #36: the owner's rc1-7 failed mid-download on files the
// mirror no longer had; the review of ff2fd83: the owner's Software Update answers not-set-up): Get's plan says so before
// anything downloads, by Software Update's own answer (the real checker's file) when it came after pacman last synced, or by
// a file of the plan the mirror (on disk here) no longer has; the Store never syncs.
TEST(StoreBackend, SystemOlderThanTheMirror)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    s.env->set("GRASSFIELD_STORE_PKEXEC", s.path(QStringLiteral("fixture/bin/pkexec"))); // never run: no plan is accepted here
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    const QString mirror = QUrl::fromLocalFile(s.path(QStringLiteral("served"))).toString();
    // pacman: nothing unfinished, and Paint's plan: its package and one dependency, both on the mirror in served/.
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "case \"$1\" in\n"
                      "  -Qu) exit 1 ;;\n"
                      "  -Qq) printf '%s\\n' gimp sketch cafe ;;\n"
                      "  -S) printf '%s\\n' 'paint 1-1 extra 1000 " + mirror.toUtf8() + "/paint-1-1-x86_64.pkg.tar.zst' "
                      "'libpaint 2-1 extra 500 " + mirror.toUtf8() + "/libpaint-2-1-x86_64.pkg.tar.zst' ;;\n"
                      "  *) exec '" + base.toUtf8() + "' \"$@\" ;;\n"
                      "esac");
    // The owner's case: Grassfield's repository off (not-set-up), Omarchy 4.0.6 and others pending, checked after pacman
    // last wrote a database. That write is the file's ctime, now (it cannot be set back); its mtime is the mirror's
    // Last-Modified, 50 days before the check.
    QDir().mkpath(s.path(QStringLiteral("fixture/sync")));
    const QString dbPath = s.path(QStringLiteral("fixture/sync/extra.db"));
    storetest::writeFile(dbPath, "db");
    const QByteArray fixture = storetest::readFixture(QStringLiteral("software-update/software-update-not-set-up.json"));
    QFile db(dbPath);
    ASSERT_TRUE(db.open(QIODevice::ReadWrite)
                && db.setFileTime(QDateTime::fromString(QJsonDocument::fromJson(fixture).object().value(QStringLiteral("checkedAt")).toString(),
                                                        Qt::ISODate)
                                      .addDays(-50),
                                  QFileDevice::FileModificationTime));
    db.close();
    const QDateTime written = QFileInfo(dbPath).metadataChangeTime();
    ASSERT_TRUE(written.isValid());
    const auto answerCheckedAt = [&](const QDateTime &checked) {
        QJsonObject answer = QJsonDocument::fromJson(fixture).object();
        answer.insert(QStringLiteral("checkedAt"), checked.toUTC().toString(Qt::ISODate));
        storetest::writeFile(s.path(QStringLiteral("state/software-update.json")), QJsonDocument(answer).toJson());
    };
    answerCheckedAt(written.addSecs(60));
    StoreBackend backend;
    QList<QVariantMap> plans;
    QObject::connect(&backend, &StoreBackend::planReady, &backend, [&plans](const QString &, const QString &, const QVariantMap &p) { plans.append(p); });
    backend.start();
    ASSERT_TRUE(settle(backend));
    const auto planOf = [&](const char *id) {
        const qsizetype before = plans.size();
        backend.plan(QLatin1String(id), QStringLiteral("install"));
        QEventLoop loop;
        for (int i = 0; i < 500 && plans.size() == before; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return plans.size() > before ? plans.last() : QVariantMap();
    };
    // Software Update found updates after the last sync: Software Update first.
    QVariantMap plan = planOf("org.example.Paint");
    EXPECT_EQ(plan.value(QStringLiteral("refusal")), QStringLiteral("outdated"));
    EXPECT_TRUE(plan.value(QStringLiteral("detail")).toString().startsWith(QStringLiteral("Software Update (not-set-up), ")))
        << plan.value(QStringLiteral("detail")).toString().toStdString();
    EXPECT_FALSE(backend.install(QStringLiteral("org.example.Paint"))) << "no plan was accepted";

    // A sync after the check that wrote nothing (offline, or the mirror unchanged): pacman.log has its line, the database is
    // as it was (S27). Still Software Update first (the integrator's merge note on PR #54).
    const QByteArray at = written.addSecs(120).toOffsetFromUtc(3600).toString(QStringLiteral("yyyy-MM-dd'T'HH:mm:ss'+0100'")).toUtf8();
    storetest::writeFile(s.path(QStringLiteral("fixture/pacman.log")),
                         "[" + at + "] [PACMAN] Running 'pacman -Syu'\n[" + at + "] [PACMAN] synchronizing package lists\n");
    plan = planOf("org.example.Paint");
    EXPECT_EQ(plan.value(QStringLiteral("refusal")), QStringLiteral("outdated"));
    EXPECT_TRUE(plan.value(QStringLiteral("detail")).toString().startsWith(QStringLiteral("Software Update (not-set-up), ")));

    // Software Update checked before pacman last wrote a database: its answer no longer counts. Paint's dependency is gone
    // from the mirror (its package is there): refused, before anything downloads.
    answerCheckedAt(written.addSecs(-60));
    storetest::writeFile(s.path(QStringLiteral("served/paint-1-1-x86_64.pkg.tar.zst")), "package");
    plan = planOf("org.example.Paint");
    EXPECT_EQ(plan.value(QStringLiteral("refusal")), QStringLiteral("outdated"));
    EXPECT_TRUE(plan.value(QStringLiteral("detail")).toString().endsWith(QStringLiteral("libpaint-2-1-x86_64.pkg.tar.zst: HTTP 404")))
        << plan.value(QStringLiteral("detail")).toString().toStdString();
    // Both files there: the plan goes to its sheet.
    storetest::writeFile(s.path(QStringLiteral("served/libpaint-2-1-x86_64.pkg.tar.zst")), "package");
    plan = planOf("org.example.Paint");
    EXPECT_EQ(plan.value(QStringLiteral("refusal")), QString());
    EXPECT_EQ(plan.value(QStringLiteral("packages")).toList().size(), 2);
}

// French: the catalog's words come in French where the built-in categories have them.
// GRASSFIELD_STORE_OFFLINE is dev plumbing (ADR-0019): in a dev session the Store counts as offline, so screenshotSource
// gives nothing and the screenshot provider's gate is shut; a packaged session (GRASSFIELD_SESSION=1) ignores it.
TEST(StoreEnv, OfflineOnlyInADevSession)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("1"));
    {
        StoreBackend backend;
        EXPECT_TRUE(env::offlineForced());
        EXPECT_FALSE(backend.online());
        EXPECT_FALSE(backend.screenshotGate()->load());
        EXPECT_TRUE(backend.screenshotSource(QStringLiteral("https://example.org/shot.png")).isEmpty());
    }
    s.env->set("GRASSFIELD_SESSION", QStringLiteral("1"));
    EXPECT_FALSE(env::offlineForced());
    s.env->unset("GRASSFIELD_SESSION");
    s.env->unset("GRASSFIELD_DEV");
    EXPECT_FALSE(env::offlineForced());
}

// The Store's own keys of grassfield.json (SD20): read with the contract's rule (not a boolean: the default), followed while
// the Store runs, and the file read and written whole for the settings window's switches (Preferences.js sets the key).
TEST(StoreBackend, SourcesFromGrassfieldJson)
{
    Scratch s;
    const QString config = s.path(QStringLiteral("config/grassfield.json"));
    {
        StoreBackend backend;
        EXPECT_FALSE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_FALSE(backend.sources().value(QStringLiteral("flathub")).toBool());
        EXPECT_TRUE(backend.sources().value(QStringLiteral("screenshots")).toBool());
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("exists")).toBool());
    }
    storetest::writeFile(config, R"({"version":1,"store":{"sources":{"aur":true,"flathub":"yes"},"screenshots":false}})");
    {
        StoreBackend backend;
        EXPECT_TRUE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_FALSE(backend.sources().value(QStringLiteral("flathub")).toBool()); // a string: the default
        EXPECT_FALSE(backend.sources().value(QStringLiteral("screenshots")).toBool());
        EXPECT_FALSE(backend.screenshotGate()->load());
        EXPECT_TRUE(backend.screenshotSource(QStringLiteral("https://example.com/a.png")).isEmpty());

        // Written whole, then followed: the switch's key changes, the source goes.
        const QVariantMap read = backend.readConfig();
        ASSERT_TRUE(read.value(QStringLiteral("ok")).toBool());
        EXPECT_TRUE(read.value(QStringLiteral("text")).toString().contains(QLatin1String("\"aur\":true")));
        int changes = 0;
        QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
        EXPECT_EQ(backend.writeConfig(QStringLiteral("{\n  \"version\": 1,\n  \"store\": {\"sources\": {\"aur\": false}}\n}\n")), QString());
        QEventLoop loop;
        for (int i = 0; i < 250 && changes == 0; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        EXPECT_GE(changes, 1);
        EXPECT_FALSE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_TRUE(backend.sources().value(QStringLiteral("screenshots")).toBool());

        // Never more than 1 MiB, either way; a folder in the file's place is not read.
        EXPECT_EQ(backend.writeConfig(QString(1024 * 1024 + 1, QLatin1Char(' '))), QStringLiteral("too large"));
        storetest::writeFile(config, QByteArray(1024 * 1024 + 1, ' '));
        EXPECT_TRUE(backend.readConfig().value(QStringLiteral("exists")).toBool());
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("ok")).toBool());
        QFile::remove(config);
        ASSERT_TRUE(QDir().mkpath(config));
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("ok")).toBool());
    }
}

// The AUR (step 3b2) through the dev plumbing's folder of answers (GRASSFIELD_STORE_AUR_URL, tests/fixtures/store/aur), turned
// on in grassfield.json: a search after Return (the repositories' names left out), an AUR page and its info, the build
// script, Installed's "AUR" group; nothing of it while the switch is off, and nothing asked by itself on a metered
// connection. The Store counts as online here whatever the machine's network (GRASSFIELD_STORE_OFFLINE=0, dev plumbing):
// the AUR is asked only online.
TEST(StoreBackend, TheAur)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_AUR_URL", QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur")).toString());
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    // Whether the AUR was asked at all: its answers are cached (aur/ in the Store's cache), whoever asked.
    const auto aurCached = [&s](const QString &kind) {
        QDirIterator it(s.path(QStringLiteral("cache/grassfield/store/aur/")) + kind, QDir::Files, QDirIterator::Subdirectories);
        return it.hasNext();
    };
    // pacman: example-app-bin installed explicitly from outside the repositories; example-lib only as its dependency; gimp a
    // repository's package that is also an AUR result here.
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")), R"(case "$1" in
  -Sl) printf '%s\n' 'extra gimp 3.0.4-1 [installed]' 'extra example-lib 1.3-2' ;;
  -Qqe) printf '%s\n' gimp example-app-bin ;;
  -Qqm) printf '%s\n' example-app-bin example-tool-git localapp ;;
  -Ql) shift; [ "$1" = -- ] && shift; for p in "$@"; do [ "$p" = localapp ] && echo 'localapp /usr/share/applications/localapp.desktop'; done ;;
  *) exit 1 ;;
esac)");
    const auto wait = [](auto done) {
        QEventLoop loop;
        for (int i = 0; i < 500 && !done(); ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return done();
    };
    // Long enough for an answer the AUR's folder gives at once (a request that should not have been made) to come.
    const auto pause = [] {
        QEventLoop loop;
        for (int i = 0; i < 40; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
    };
    {
        StoreBackend backend; // the AUR off: nothing asked (a search, a page, a build script, the foreign names), no AUR page
        ASSERT_TRUE(backend.online());
        backend.start();
        ASSERT_TRUE(settle(backend));
        QString problem;
        QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&problem](const QString &, const QVariantList &, const QString &p) { problem = p; });
        int infos = 0, scripts = 0;
        bool scriptOk = true;
        QObject::connect(&backend, &StoreBackend::aurInfo, &backend, [&infos] { ++infos; });
        QObject::connect(&backend, &StoreBackend::buildScript, &backend, [&](const QString &, const QString &, bool ok) {
            ++scripts;
            scriptOk = ok;
        });
        backend.searchAur(QStringLiteral("example"));
        EXPECT_EQ(problem, QStringLiteral("off"));
        backend.requestAur(QStringLiteral("aur:example-app-bin"));
        backend.requestBuildScript(QStringLiteral("aur:example-app-bin"));
        wait([&scripts] { return scripts > 0; });
        pause();
        EXPECT_EQ(scripts, 1);
        EXPECT_FALSE(scriptOk) << "no build script while the AUR is off";
        EXPECT_EQ(infos, 0);
        EXPECT_FALSE(aurCached(QString())) << "the AUR was asked while it is off";
        EXPECT_TRUE(backend.app(QStringLiteral("aur:example-app-bin")).isEmpty());
        for (const QVariant &g : backend.installed())
            EXPECT_NE(g.toMap().value(QStringLiteral("group")), QStringLiteral("aur"));
    }
    storetest::writeFile(s.path(QStringLiteral("config/grassfield.json")), R"({"version":1,"store":{"sources":{"aur":true}}})");
    QDir().mkpath(s.path(QStringLiteral("fixture/omarchy/install")));
    storetest::writeFile(s.path(QStringLiteral("fixture/omarchy/install/omarchy-base.packages")), "btop\n");
    {
        // On a metered connection, the AUR on: nothing asked by itself (Installed's foreign names); a search after Return
        // is the user's and goes.
        s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("metered"));
        StoreBackend backend;
        backend.start();
        ASSERT_TRUE(settle(backend));
        pause();
        EXPECT_FALSE(aurCached(QStringLiteral("info"))) << "the foreign names were asked on a metered connection";
        for (const QVariant &g : backend.installed())
            EXPECT_NE(g.toMap().value(QStringLiteral("group")), QStringLiteral("aur"));
        int answers = 0;
        QVariantList results;
        QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&](const QString &, const QVariantList &list, const QString &) {
            results = list;
            ++answers;
        });
        backend.searchAur(QStringLiteral("example"));
        ASSERT_TRUE(wait([&answers] { return answers == 1; }));
        EXPECT_FALSE(results.isEmpty());
        s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    }
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));

    // Installed: example-app-bin (explicit, from outside the repositories, known to the AUR) under "AUR", with its page;
    // localapp (unknown to the AUR, with an entry) stays "Not from a repository".
    ASSERT_TRUE(wait([&backend] {
        for (const QVariant &g : backend.installed()) {
            if (g.toMap().value(QStringLiteral("group")) == QLatin1String("aur"))
                return true;
        }
        return false;
    }));
    QHash<QString, QStringList> groups;
    for (const QVariant &g : backend.installed())
        groups.insert(g.toMap().value(QStringLiteral("group")).toString(), ids(g.toMap().value(QStringLiteral("apps")).toList()));
    EXPECT_EQ(groups.value(QStringLiteral("aur")), QStringList{QStringLiteral("aur:example-app-bin")});
    EXPECT_EQ(groups.value(QStringLiteral("foreign")), QStringList{QStringLiteral("package:localapp")});

    // A search after Return: the AUR's results, a repository's name (example-lib) left out.
    QString term, problem;
    QVariantList results;
    int answers = 0;
    QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&](const QString &t, const QVariantList &list, const QString &p) {
        term = t;
        results = list;
        problem = p;
        ++answers;
    });
    backend.searchAur(QStringLiteral("example"));
    ASSERT_TRUE(wait([&answers] { return answers == 1; }));
    EXPECT_EQ(term, QStringLiteral("example"));
    EXPECT_EQ(problem, QString());
    EXPECT_EQ(ids(results), (QStringList{QStringLiteral("aur:example-app-bin"), QStringLiteral("aur:example-tool-git")}));
    EXPECT_EQ(results.at(0).toMap().value(QStringLiteral("votes")).toInt(), 120);
    EXPECT_EQ(results.at(0).toMap().value(QStringLiteral("kind")), QStringLiteral("aur"));
    EXPECT_TRUE(results.at(0).toMap().value(QStringLiteral("installed")).toBool());
    EXPECT_TRUE(results.at(1).toMap().value(QStringLiteral("outOfDate")).toBool());
    backend.searchAur(QStringLiteral("x"));
    ASSERT_TRUE(wait([&answers] { return answers == 2; }));
    EXPECT_EQ(problem, QStringLiteral("short"));

    // The page: a search's facts first, then its info answer's (its dependencies).
    QVariantMap tool = backend.app(QStringLiteral("aur:example-tool-git"));
    EXPECT_EQ(tool.value(QStringLiteral("name")), QStringLiteral("example-tool-git"));
    EXPECT_EQ(tool.value(QStringLiteral("summary")), QStringLiteral("A tool from the development branch"));
    EXPECT_FALSE(tool.value(QStringLiteral("aurRead")).toBool());
    EXPECT_EQ(tool.value(QStringLiteral("aur")).toMap().value(QStringLiteral("maintainer")), QStringLiteral("bob"));
    QStringList infos;
    QObject::connect(&backend, &StoreBackend::aurInfo, &backend, [&infos](const QString &id) { infos.append(id); });
    backend.requestAur(QStringLiteral("aur:example-tool-git"));
    ASSERT_TRUE(wait([&infos] { return infos.size() == 1; }));
    tool = backend.app(QStringLiteral("aur:example-tool-git"));
    EXPECT_TRUE(tool.value(QStringLiteral("aurRead")).toBool());
    EXPECT_EQ(tool.value(QStringLiteral("aur")).toMap().value(QStringLiteral("depends")).toStringList(),
              (QStringList{QStringLiteral("example-app-bin"), QStringLiteral("python")}));
    EXPECT_TRUE(tool.value(QStringLiteral("installed")).toBool()); // pacman -Qm lists it

    // Its build script, plain text.
    QString script;
    bool scriptOk = false;
    QObject::connect(&backend, &StoreBackend::buildScript, &backend, [&](const QString &, const QString &text, bool ok) {
        script = text;
        scriptOk = ok;
    });
    backend.requestBuildScript(QStringLiteral("aur:example-app-bin"));
    ASSERT_TRUE(wait([&scriptOk] { return scriptOk; }));
    EXPECT_TRUE(script.startsWith(QLatin1String("# Maintainer: alice")));

    // Get and Uninstall… go through Omarchy's terminal, which a dev session without its fake program never opens; an AUR name a
    // repository has is not offered from the AUR.
    const QVariantMap actions = backend.actions(QStringLiteral("aur:example-app-bin"));
    EXPECT_TRUE(actions.value(QStringLiteral("installed")).toBool());
    EXPECT_EQ(actions.value(QStringLiteral("get")), QStringLiteral("installed"));
    EXPECT_EQ(actions.value(QStringLiteral("uninstall")), QStringLiteral("dev"));
    backend.requestAur(QStringLiteral("aur:example-lib"));
    ASSERT_TRUE(wait([&infos] { return infos.size() == 2; }));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-lib")).value(QStringLiteral("get")), QStringLiteral("repository"));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-lib")).value(QStringLiteral("uninstall")), QStringLiteral("notInstalled"));
    // Installed from outside the repositories but only as another package's dependency (pacman -Qqm, not -Qqe): no
    // Uninstall… (a dependency), whatever else.
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-tool-git")).value(QStringLiteral("uninstall")), QStringLiteral("dependency"));
    // With Omarchy's terminal (the fake program) but no catalog to pin the AUR's commands: refused as unchecked, nothing run.
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-app-bin")).value(QStringLiteral("uninstall")), QStringLiteral("omarchyChanged"));

    // The switch turned off while the Store runs: its pages go (an id it remembers is no app any more).
    int changes = 0;
    QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
    ASSERT_EQ(backend.writeConfig(QStringLiteral("{\"version\":1,\"store\":{\"sources\":{\"aur\":false}}}\n")), QString());
    ASSERT_TRUE(wait([&changes] { return changes > 0; }));
    EXPECT_TRUE(backend.app(QStringLiteral("aur:example-app-bin")).isEmpty());
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-app-bin")).value(QStringLiteral("get")), QStringLiteral("source"));
}

namespace {

// A backend whose snapshot is the test's own (StoreBackend::apply).
class SnapshotBackend : public StoreBackend
{
public:
    using StoreBackend::apply;
};

} // namespace

// The AUR's Get and Uninstall… against a catalog, outside the container whose keys sign one (the integrator's note on PR
// #36: mutants C13 to C15 lived here): a catalog AUR app while the AUR is off (the snapshot built while it was on, in use
// for a moment); a catalog that does not pin the AUR's commands; a name of the deny list; Omarchy's lists unread; then
// offered (offline aside). Nothing runs: Omarchy's terminal is a dev session's stand-in.
TEST(StoreBackend, AurBlocksAgainstACatalog)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("1"));
    s.env->set("GRASSFIELD_STORE_AUR_URL", QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur")).toString());
    const QList<std::pair<QString, QString>> setupPins{{QStringLiteral("bin/omarchy-install-gaming-steam"), QString(64, QLatin1Char('a'))}};
    const QList<std::pair<QString, QString>> aurPins{{QStringLiteral("bin/omarchy-pkg-aur-add"), QString(64, QLatin1Char('b'))},
                                                    {QStringLiteral("bin/omarchy-pkg-drop"), QString(64, QLatin1Char('c'))},
                                                    {QStringLiteral("bin/omarchy-pkg-missing"), QString(64, QLatin1Char('d'))}};
    // aur-game not installed; aur-kept installed explicitly from the AUR; aur-omarchy-theme with Omarchy's prefix.
    const auto snapshot = [](const QList<std::pair<QString, QString>> &pins, const QSet<QString> &lists) {
        auto snap = std::make_shared<Snapshot>();
        Catalog catalog;
        catalog.omarchy = OmarchyPins{QStringLiteral("v4.0.4"), QString(40, QLatin1Char('0')), pins};
        snap->catalog = catalog;
        snap->deny.omarchy = lists;
        snap->explicitPackages = {QStringLiteral("example-kept")};
        snap->foreign = {QStringLiteral("example-kept")};
        for (const auto &[id, package] : {std::pair{QStringLiteral("aur-game"), QStringLiteral("example-game")},
                                          std::pair{QStringLiteral("aur-kept"), QStringLiteral("example-kept")},
                                          std::pair{QStringLiteral("aur-omarchy-theme"), QStringLiteral("omarchy-theme-example")}}) {
            StoreApp a;
            a.id = id;
            a.source = CatalogSource::Kind::Aur;
            a.package = package;
            a.installed = package == QLatin1String("example-kept");
            a.inCatalog = true;
            snap->index.insert(id, int(snap->apps.size()));
            snap->apps.append(a);
        }
        return std::shared_ptr<const Snapshot>(std::move(snap));
    };
    const auto get = [](const StoreBackend &b, const QString &id) { return b.actions(id).value(QStringLiteral("get")).toString(); };
    const auto uninstall = [](const StoreBackend &b, const QString &id) { return b.actions(id).value(QStringLiteral("uninstall")).toString(); };
    {
        SnapshotBackend backend; // the AUR off
        backend.apply(snapshot(setupPins + aurPins, {QStringLiteral("btop")}));
        EXPECT_EQ(get(backend, QStringLiteral("aur-game")), QStringLiteral("aurOff"));
        EXPECT_EQ(uninstall(backend, QStringLiteral("aur-kept")), QStringLiteral("aurOff"));
    }
    storetest::writeFile(s.path(QStringLiteral("config/grassfield.json")), R"({"version":1,"store":{"sources":{"aur":true}}})");
    SnapshotBackend backend;
    backend.apply(snapshot(setupPins, {QStringLiteral("btop")}));
    EXPECT_EQ(get(backend, QStringLiteral("aur-game")), QStringLiteral("aurUnchecked")) << "the catalog pins no AUR command";
    EXPECT_EQ(uninstall(backend, QStringLiteral("aur-kept")), QStringLiteral("aurUnchecked"));
    backend.apply(snapshot(setupPins + aurPins, {QStringLiteral("btop")}));
    EXPECT_EQ(get(backend, QStringLiteral("aur-game")), QStringLiteral("offline")) << "offered once online";
    EXPECT_EQ(uninstall(backend, QStringLiteral("aur-kept")), QString());
    EXPECT_EQ(get(backend, QStringLiteral("aur-omarchy-theme")), QStringLiteral("aurProtected")) << "the AUR is anyone's: never Omarchy's name";
    backend.apply(snapshot(setupPins + aurPins, {}));
    EXPECT_EQ(get(backend, QStringLiteral("aur-game")), QStringLiteral("listsMissing"));
    EXPECT_EQ(uninstall(backend, QStringLiteral("aur-kept")), QStringLiteral("listsMissing"));
}

// "Get Flatpak…" (step 3c part 3, SD24): offered while flatpak is missing, the terminal path is there and the catalog pins
// omarchy-pkg-add with the omarchy-pkg-missing it calls; its plan checked as a setup's (the pins against the installed
// Omarchy first); never an install without the plan its sheet showed.
TEST(StoreBackend, GetFlatpak)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("1"));
    const std::pair<QString, QString> add{QStringLiteral("bin/omarchy-pkg-add"), QString(64, QLatin1Char('a'))};
    const std::pair<QString, QString> missing{QStringLiteral("bin/omarchy-pkg-missing"), QString(64, QLatin1Char('b'))};
    const auto snapshot = [](const QList<std::pair<QString, QString>> &pins, bool withPins = true) {
        auto snap = std::make_shared<Snapshot>();
        Catalog catalog;
        if (withPins)
            catalog.omarchy = OmarchyPins{QStringLiteral("v4.0.4"), QString(40, QLatin1Char('0')), pins};
        snap->catalog = catalog;
        return std::shared_ptr<const Snapshot>(std::move(snap));
    };
    const auto block = [](const StoreBackend &b) { return b.sources().value(QStringLiteral("getFlatpak")).toString(); };
    SnapshotBackend backend;
    QList<std::pair<QString, QString>> plans;
    QObject::connect(&backend, &StoreBackend::planReady, &backend, [&plans](const QString &app, const QString &, const QVariantMap &plan) {
        plans.append({app, plan.value(QStringLiteral("refusal")).toString() + QLatin1Char('/') + plan.value(QStringLiteral("detail")).toString()});
    });
    int sourcesChanged = 0;
    QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&sourcesChanged] { ++sourcesChanged; });
    backend.apply(snapshot({add, missing}, false));
    EXPECT_EQ(block(backend), QStringLiteral("omarchyChanged")) << "a catalog without Omarchy's pins";
    EXPECT_EQ(sourcesChanged, 1) << "a snapshot applied says so to the settings";
    backend.apply(snapshot({add}));
    EXPECT_EQ(block(backend), QStringLiteral("flatpakUnchecked")) << "omarchy-pkg-missing not pinned";
    backend.apply(snapshot({missing}));
    EXPECT_EQ(block(backend), QStringLiteral("flatpakUnchecked")) << "omarchy-pkg-add not pinned";
    backend.plan(kGetFlatpakApp, QStringLiteral("install"));
    ASSERT_EQ(plans.size(), 1);
    EXPECT_EQ(plans.last(), (std::pair{kGetFlatpakApp, QStringLiteral("unavailable/flatpakUnchecked")}));
    backend.apply(snapshot({add, missing}));
    EXPECT_EQ(block(backend), QString());
    backend.plan(kGetFlatpakApp, QStringLiteral("remove"));
    ASSERT_EQ(plans.size(), 2);
    EXPECT_EQ(plans.last().second, QStringLiteral("unavailable/")) << "nothing to remove";
    // Its plan as a setup's: the pins against the installed Omarchy first (here none of it: refused, the file named).
    backend.plan(kGetFlatpakApp, QStringLiteral("install"));
    QEventLoop loop;
    for (int i = 0; i < 500 && plans.size() < 3; ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_EQ(plans.size(), 3);
    EXPECT_EQ(plans.last(), (std::pair{kGetFlatpakApp, QStringLiteral("omarchyChanged/bin/omarchy-pkg-add")}));
    EXPECT_FALSE(backend.install(kGetFlatpakApp)) << "no plan its sheet showed";
    EXPECT_TRUE(backend.operations().isEmpty());
    // flatpak there: nothing to get.
    storetest::script(s.path(QStringLiteral("fixture/bin/flatpak")), "exit 0");
    EXPECT_EQ(block(backend), QStringLiteral("installed"));
    EXPECT_TRUE(backend.sources().value(QStringLiteral("flatpak")).toBool());
}

// Get Flatpak… from its plan to its operation (PR #65's review: no test drove a successful install): the plan its sheet
// showed, the record with the catalog's pins, written for grassfield-store-run when it starts; refused while flatpak is
// there, and once queued.
TEST(StoreBackend, GetFlatpakInstalls)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    // Omarchy's two commands, as the catalog pins them.
    QDir().mkpath(s.path(QStringLiteral("fixture/omarchy/bin")));
    storetest::script(s.path(QStringLiteral("fixture/omarchy/bin/omarchy-pkg-add")), "omarchy-pkg-missing \"$@\" && sudo pacman -S --noconfirm --needed \"$@\"");
    storetest::script(s.path(QStringLiteral("fixture/omarchy/bin/omarchy-pkg-missing")), "exit 0");
    const auto sha = [&s](const char *rel) {
        QFile file(s.path(QStringLiteral("fixture/omarchy/")) + QLatin1String(rel));
        return file.open(QIODevice::ReadOnly) ? QString::fromLatin1(QCryptographicHash::hash(file.readAll(), QCryptographicHash::Sha256).toHex()) : QString();
    };
    const QList<std::pair<QString, QString>> pins{{QStringLiteral("bin/omarchy-pkg-add"), sha("bin/omarchy-pkg-add")},
                                                  {QStringLiteral("bin/omarchy-pkg-missing"), sha("bin/omarchy-pkg-missing")}};
    // pacman: nothing unfinished, and flatpak's plan with one dependency, both on the mirror in served/.
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    const QByteArray mirror = QUrl::fromLocalFile(s.path(QStringLiteral("served"))).toString().toUtf8();
    for (const char *file : {"flatpak-1:1.18.4-2-x86_64.pkg.tar.zst", "ostree-2025.7-1-x86_64.pkg.tar.zst"})
        storetest::writeFile(s.path(QStringLiteral("served/")) + QLatin1String(file), "pkg");
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "case \"$1\" in\n"
                      "  -Qu) exit 1 ;;\n"
                      "  -Qq) printf '%s\\n' gimp sketch cafe ;;\n"
                      "  -S) printf '%s\\n' 'flatpak 1:1.18.4-2 extra 2100000 " + mirror + "/flatpak-1:1.18.4-2-x86_64.pkg.tar.zst' "
                      "'ostree 2025.7-1 extra 1100000 " + mirror + "/ostree-2025.7-1-x86_64.pkg.tar.zst' ;;\n"
                      "  *) exec '" + base.toUtf8() + "' \"$@\" ;;\n"
                      "esac");
    auto snap = std::make_shared<Snapshot>();
    Catalog catalog;
    catalog.omarchy = OmarchyPins{QStringLiteral("v4.0.4"), QString(40, QLatin1Char('0')), pins};
    snap->catalog = catalog;
    snap->appstream.origin = AppStreamData::Origin::Installed; // online, nothing to fetch: no load replaces this snapshot
    SnapshotBackend backend;
    backend.apply(std::shared_ptr<const Snapshot>(std::move(snap)));
    ASSERT_EQ(backend.sources().value(QStringLiteral("getFlatpak")).toString(), QString());
    QVariantMap plan;
    QObject::connect(&backend, &StoreBackend::planReady, &backend, [&plan](const QString &, const QString &, const QVariantMap &p) { plan = p; });
    backend.plan(kGetFlatpakApp, QStringLiteral("install"));
    QEventLoop loop;
    for (int i = 0; i < 500 && plan.isEmpty(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_EQ(plan.value(QStringLiteral("refusal")).toString(), QString()) << plan.value(QStringLiteral("detail")).toString().toStdString();
    const QVariantList packages = plan.value(QStringLiteral("packages")).toList();
    ASSERT_EQ(packages.size(), 2);
    EXPECT_EQ(packages.at(0).toMap().value(QStringLiteral("name")).toString(), QStringLiteral("flatpak"));
    // flatpak there meanwhile (installed another way): nothing to get, the plan or not.
    storetest::script(s.path(QStringLiteral("fixture/bin/flatpak")), "exit 0");
    EXPECT_FALSE(backend.install(kGetFlatpakApp));
    QFile::remove(s.path(QStringLiteral("fixture/bin/flatpak")));
    ASSERT_TRUE(backend.install(kGetFlatpakApp));
    const QVariantList ops = backend.operations();
    ASSERT_EQ(ops.size(), 1);
    const QVariantMap op = ops.first().toMap();
    EXPECT_EQ(op.value(QStringLiteral("app")).toString(), kGetFlatpakApp);
    EXPECT_EQ(op.value(QStringLiteral("name")).toString(), QStringLiteral("Flatpak"));
    EXPECT_FALSE(backend.install(kGetFlatpakApp)) << "queued";
    // Planned again while it waits for Omarchy's terminal: still once at a time.
    plan.clear();
    backend.plan(kGetFlatpakApp, QStringLiteral("install"));
    for (int i = 0; i < 500 && plan.isEmpty(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    EXPECT_EQ(plan.value(QStringLiteral("refusal")).toString(), QString()) << plan.value(QStringLiteral("detail")).toString().toStdString();
    EXPECT_FALSE(backend.install(kGetFlatpakApp)) << "once at a time";
    // The catalog's pins, written for grassfield-store-run as it starts.
    const QString written = s.path(QStringLiteral("fixture/run/store/")) + op.value(QStringLiteral("id")).toString() + QStringLiteral(".pins");
    for (int i = 0; i < 250 && !QFile::exists(written); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    QFile file(written);
    ASSERT_TRUE(file.open(QIODevice::ReadOnly)) << written.toStdString();
    EXPECT_EQ(file.readAll(), (pins.at(0).second + QStringLiteral("  bin/omarchy-pkg-add\n") + pins.at(1).second + QStringLiteral("  bin/omarchy-pkg-missing\n")).toUtf8());
}

TEST(StoreBackend, FrenchSession)
{
    Scratch s;
    qputenv("GRASSFIELD_LANG", "fr_FR");
    StoreBackend backend;
    EXPECT_EQ(backend.language(), QStringLiteral("fr"));
    backend.start();
    ASSERT_TRUE(settle(backend));
    QStringList titles;
    for (const QVariant &c : backend.categories())
        titles.append(c.toMap().value(QStringLiteral("title")).toString());
    EXPECT_TRUE(titles.contains(QStringLiteral("Graphisme")));
}

// The real gpgv on the throwaway keys of tests/integration/store_catalog.sh (STORE_TEST_REAL_GPGV): the fixture catalog
// served with its good signature is accepted and used (its sections, Discover first, the hero's app and its tint field),
// then a copy signed by the revoked key is refused on Ctrl+R and the accepted one stays in use.
TEST(StoreBackend, RealSignedCatalog)
{
    const QString keys = qEnvironmentVariable("STORE_TEST_REAL_GPGV");
    if (keys.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    Scratch s;
    QDir(s.path(QStringLiteral("keyring"))).removeRecursively();
    QDir().mkpath(s.path(QStringLiteral("keyring")));
    for (const char *f : {"grassfield.gpg", "grassfield-trusted", "grassfield-revoked"})
        QFile::copy(keys + QLatin1Char('/') + QLatin1String(f), s.path(QStringLiteral("keyring/")) + QLatin1String(f));
    const QString served = s.path(QStringLiteral("served/grassfield-catalog.v1.json"));
    QFile::copy(keys + QStringLiteral("/catalog.json"), served);
    QFile::copy(keys + QStringLiteral("/good.sig"), served + QStringLiteral(".sig"));
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));
    const QVariantMap status = backend.catalogStatus();
    EXPECT_TRUE(status.value(QStringLiteral("inUse")).toBool()) << status.value(QStringLiteral("problem")).toString().toStdString();
    EXPECT_EQ(status.value(QStringLiteral("problem")), QString());
    EXPECT_EQ(status.value(QStringLiteral("date")), QStringLiteral("October 27"));
    const QVariantList sections = backend.sections();
    ASSERT_FALSE(sections.isEmpty());
    EXPECT_EQ(sections.at(0).toMap().value(QStringLiteral("id")), QStringLiteral("discover"));
    EXPECT_FALSE(sections.at(0).toMap().value(QStringLiteral("builtIn")).toBool());
    const QVariantMap hero = sections.at(0).toMap().value(QStringLiteral("blocks")).toList().at(0).toMap();
    EXPECT_EQ(hero.value(QStringLiteral("kind")), QStringLiteral("hero"));
    EXPECT_EQ(hero.value(QStringLiteral("items")).toList().at(0).toMap().value(QStringLiteral("app")).toMap().value(QStringLiteral("id")),
              QStringLiteral("org.gimp.GIMP"));
    // The catalog's categories now (graphics, games, music-audio).
    QStringList ids;
    for (const QVariant &c : backend.categories())
        ids.append(c.toMap().value(QStringLiteral("id")).toString());
    EXPECT_TRUE(ids.contains(QStringLiteral("graphics")));

    // A setup (b.2): no recipe in the installed Omarchy, hidden; with the files the catalog pins, offered (offline aside);
    // once one of them differs, refused until the catalog has checked the new one.
    const QString steam = QStringLiteral("com.valvesoftware.Steam.desktop");
    EXPECT_TRUE(backend.app(steam).isEmpty()) << "Omarchy has no such recipe here";
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    for (const QString &rel : {QStringLiteral("bin/omarchy-install-gaming-steam"), QStringLiteral("bin/omarchy-remove-gaming-steam"),
                               QStringLiteral("install/helpers/steam.sh")}) {
        const QString file = s.path(QStringLiteral("fixture/omarchy/")) + rel;
        QDir().mkpath(QFileInfo(file).path());
        storetest::script(file, "# made up for the Store's tests: " + rel.toUtf8());
    }
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    ASSERT_FALSE(backend.app(steam).isEmpty());
    const QString get = backend.actions(steam).value(QStringLiteral("get")).toString();
    EXPECT_TRUE(get.isEmpty() || get == QLatin1String("offline")) << qPrintable(get);
    EXPECT_EQ(backend.actions(steam).value(QStringLiteral("uninstall")).toString(), QStringLiteral("notInstalled"));
    // The catalog's AUR app (step 3b2): not in the Store while the AUR is off (the model leaves it out); once it is on, with
    // Omarchy's terminal there, its package lists and the pins matching, refused while the catalog does not pin the AUR's
    // command and the omarchy-pkg-missing it calls (this fixture pins only the Steam setup's files).
    const QString aurGame = QStringLiteral("aur-game");
    EXPECT_TRUE(backend.app(aurGame).isEmpty()) << "a catalog AUR app while the AUR is off";
    storetest::writeFile(s.path(QStringLiteral("fixture/omarchy/install/omarchy-base.packages")), "btop\n");
    s.env->set("GRASSFIELD_STORE_AUR_URL", QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur")).toString());
    int changes = 0;
    QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
    ASSERT_EQ(backend.writeConfig(QStringLiteral("{\"version\":1,\"store\":{\"sources\":{\"aur\":true}}}\n")), QString());
    QEventLoop loop;
    for (int i = 0; i < 250 && changes == 0; ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_GT(changes, 0);
    ASSERT_TRUE(settle(backend));
    ASSERT_FALSE(backend.app(aurGame).isEmpty());
    EXPECT_EQ(backend.actions(aurGame).value(QStringLiteral("get")).toString(), QStringLiteral("aurUnchecked"));
    storetest::script(s.path(QStringLiteral("fixture/omarchy/install/helpers/steam.sh")), "# changed by an Omarchy update");
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    EXPECT_EQ(backend.actions(steam).value(QStringLiteral("get")).toString(), QStringLiteral("omarchyChanged"));

    QFile::remove(served + QStringLiteral(".sig"));
    QFile::copy(keys + QStringLiteral("/revoked.sig"), served + QStringLiteral(".sig"));
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    EXPECT_EQ(backend.catalogStatus().value(QStringLiteral("problem")), QStringLiteral("refused"));
    EXPECT_TRUE(backend.catalogStatus().value(QStringLiteral("inUse")).toBool()); // the accepted copy stays in use
}

// flatpak's stand-in in the fixture (step 3c part 2), the user's installation under <fixture>/flatpak as the Store reads it:
// remotes, remote-add (it writes the remote), update --appstream (Flathub's AppStream fixture and an icon), list, info,
// remote-info, install on a terminal (flatpak's own questions, S23) and without one (--noninteractive), uninstall.
const QByteArray kFlatpak = R"SH(root=$(dirname "$0")/..
echo "$*" >>"$root/flatpak-calls"
active=$root/flatpak/appstream/flathub/$(uname -m)/active
case "$1" in
  remotes) [ -f "$root/flatpak/remote" ] && echo flathub; exit 0 ;;
  remote-add) mkdir -p "$root/flatpak" && echo "$6" >"$root/flatpak/remote" ;;
  update)
    if [ "$3" = --noninteractive ]; then  # step 4: each ref updated, out of fupdates (S31); pinned to its commit (S32)
      shift 3
      commit=
      case "$1" in --commit=*) commit=${1#--commit=}; shift ;; esac
      shift
      [ -f "$root/slowupdate" ] && sleep 2
      for ref; do
        echo "Updating $ref"; grep -v "	$ref\$" "$root/fupdates" >"$root/u2"; mv "$root/u2" "$root/fupdates"
        [ -n "$commit" ] && echo "$commit" >"$root/commit-$(echo "$ref" | cut -d/ -f2)"
      done
      exit 0
    fi
    mkdir -p "$active/icons/128x128" && cp "$root/../flathub.xml.gz" "$active/appstream.xml.gz" && echo png >"$active/icons/128x128/org.example.Notes.png" ;;
  remote-ls) [ -f "$root/offline" ] && exit 1; cat "$root/fupdates" 2>/dev/null ;;
  list) cat "$root/flatpaks" 2>/dev/null ;;
  info) for id; do :; done; id=${id#app/}; id=${id%%/*}; grep -qx "$id" "$root/flatpaks" 2>/dev/null || exit 1
        case "$3" in --show-metadata) printf '[Application]\nname=%s\n\n[Context]\nshared=network;\n' "$id" ;;
                     --show-commit) cat "$root/commit-$id" 2>/dev/null || exit 1 ;;
                     *) printf 'Ref: app/%s/x86_64/stable\nVersion: 1.2\nInstalled: 2.0 MB\n' "$id" ;; esac ;;
  remote-info)
    for last; do :; done; name=$(echo "$last" | cut -d/ -f2)
    case "$3" in --show-commit) [ -f "$root/nocommit" ] && exit 1
                                cat "$root/commit" 2>/dev/null || printf '%064d\n' 7 ;;
                 --show-metadata) [ -f "$root/slowmeta" ] && sleep 1
                                  [ -f "$root/nometa" ] && exit 1
                                  [ -f "$root/samemeta" ] && { printf '[Application]\nname=%s\n\n[Context]\nshared=network;\n' "$name"; exit 0; }
                                  printf '[Application]\nname=%s\n\n[Context]\nshared=network;\nfilesystems=home;\n' "$name" ;;
                 *) printf '           Ref: %s\n       Version: 1.2\n       License: MIT\n Download Size: 1.5 MB\nInstalled Size: 4.0 MB\n' "$4" ;; esac ;;
  install)
    if [ "$3" = --noninteractive ]; then
      id=$(echo "$5" | cut -d/ -f2)
      echo "Installing app/$id/x86_64/stable"; echo "$id" >>"$root/flatpaks"; exit 0
    fi
    [ -t 0 ] || exit 1
    echo 'Required runtime for org.example.Notes/x86_64/stable (runtime/org.gnome.Platform/x86_64/50) found in remote flathub'
    printf 'Do you want to install it? [Y/n]: '; read a
    printf '\n        ID                  Branch Op Remote  Download\n'
    printf ' 1.     org.gnome.Platform  50     i  flathub < 418.8 MB\n 2.     org.example.Notes   stable i  flathub < 1.5 MB\n\n'
    printf 'Proceed with these changes to the user installation? [Y/n]: '; read b; exit 1 ;;
  uninstall) [ "$4" = --unused ] && exit 0
             grep -vx "$5" "$root/flatpaks" >"$root/f2"; mv "$root/f2" "$root/flatpaks" ;;
  *) exit 2 ;;
esac)SH";

// Step 4 (SR24, SR25): the Updates page's data. The system's from software-update.json and the shell's check (Check Now:
// `qs ipc ... update check user`, ADR-0033 d.7; a refusal says so), the last system update unfinished (pacman -Qu, S12);
// Flathub's updates (remote-ls --updates, S31; another remote's left to the user), the sidebar's count; an app's Update and
// the group's Update All, each through its plan, which says what an update lets an app reach that it could not; the search
// by document type.
TEST(StoreBackend, Updates)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    QDir().mkpath(s.path(QStringLiteral("shell")));
    s.env->set("GRASSFIELD_SHELL_DIR", s.path(QStringLiteral("shell")));
    storetest::script(s.path(QStringLiteral("fixture/bin/flatpak")), kFlatpak);
    storetest::writeFile(s.path(QStringLiteral("flathub.xml.gz")), storetest::gzip(storetest::readFixture(QStringLiteral("appstream-flathub.xml"))));
    storetest::writeFile(s.path(QStringLiteral("fixture/flatpaks")), "org.example.Notes\n");
    const QString notesRef = QStringLiteral("app/org.example.Notes/x86_64/stable");
    const QString platformRef = QStringLiteral("runtime/org.gnome.Platform/x86_64/50");
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")),
                         "org.example.Notes\tstable\tflathub\tapp/org.example.Notes/x86_64/stable\n"
                         "org.gnome.Platform\t50\tflathub\truntime/org.gnome.Platform/x86_64/50\n"
                         "com.mine.App\tstable\tmine\tapp/com.mine.App/x86_64/stable\n");
    // The shell's stand-in: its check writes a new checkedAt (one per call), then it answers "ok" (or "refused"); with
    // qs-slow it answers at once and writes 2 s later, as the real shell's check runs after its IPC answered.
    const QByteArray state = s.path(QStringLiteral("state")).toUtf8();
    storetest::script(s.path(QStringLiteral("fixture/bin/qs")),
                      "echo \"$*\" >>'" + state + "/qs-calls'\n"
                      "n=$(wc -l <'" + state + "/qs-calls')\n"
                      "[ -f '" + state + "/qs-refuses' ] && { echo refused; exit 0; }\n"
                      "write() {\n"
                      "  printf '{\"version\":1,\"state\":\"%s\",\"checkedAt\":\"2026-11-01T10:%02d:00Z\",\"others\":3,"
                      "\"otherPackages\":[{\"name\":\"gimp\",\"installed\":\"3.0.4-1\",\"available\":\"3.0.6-1\"}]}' \"$1\" \"$n\" >'" + state + "/su.tmp'\n"
                      "  mv '" + state + "/su.tmp' '" + state + "/software-update.json'\n"
                      "}\n"
                      "if [ -f '" + state + "/qs-slow' ]; then (sleep 2; write up-to-date) >/dev/null 2>&1 & echo ok; exit 0; fi\n"
                      "write available\n"
                      "echo ok\n");
    storetest::writeFile(s.path(QStringLiteral("config/grassfield.json")), R"({"version":1,"store":{"sources":{"flathub":true}}})");
    StoreBackend backend;
    QList<std::pair<QString, QVariantMap>> plans;
    QObject::connect(&backend, &StoreBackend::planReady, &backend,
                     [&plans](const QString &app, const QString &kind, const QVariantMap &p) { if (kind == QLatin1String("update")) plans.append({app, p}); });
    backend.start();
    ASSERT_TRUE(settle(backend));
    QEventLoop loop;
    const auto waitFor = [&loop](const std::function<bool()> &done) {
        for (int i = 0; i < 500 && !done(); ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return done();
    };
    const auto flatpak = [&backend] { return backend.updates().value(QStringLiteral("flatpak")).toMap(); };
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("state")).toString().isEmpty() && !flatpak().value(QStringLiteral("apps")).toList().isEmpty(); }))
        << "checked when the Store opens";
    QVariantMap u = backend.updates();
    EXPECT_TRUE(flatpak().value(QStringLiteral("on")).toBool());
    const QVariantList apps = flatpak().value(QStringLiteral("apps")).toList();
    ASSERT_EQ(apps.size(), 1) << "Flathub's only";
    EXPECT_EQ(apps.first().toMap().value(QStringLiteral("ref")).toString(), notesRef);
    EXPECT_EQ(flatpak().value(QStringLiteral("runtimes")).toInt(), 1);
    EXPECT_EQ(u.value(QStringLiteral("apps")).toList().size(), 1) << "gimp updates with the system";
    EXPECT_EQ(u.value(QStringLiteral("count")).toInt(), 2) << "the sidebar's number, Flatpaks included";
    EXPECT_EQ(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("update")).toString(), QString());
    EXPECT_EQ(backend.actions(QStringLiteral("org.example.Paint")).value(QStringLiteral("update")).toString(), QStringLiteral("none"));
    EXPECT_EQ(backend.actions(QStringLiteral("org.gimp.GIMP")).value(QStringLiteral("update")).toString(), QStringLiteral("none"))
        << "a repository app updates with the system, never on its own";

    // The launcher's and Files' question (ADR-0046 D1): the installed apps by application entry, "" blocking nothing.
    const QVariantMap byEntry = backend.removalByEntry();
    ASSERT_TRUE(byEntry.contains(QStringLiteral("org.example.Notes.desktop"))) << "an installed Flatpak is listed by its entry";
    const QVariantMap notesEntry = byEntry.value(QStringLiteral("org.example.Notes.desktop")).toMap();
    EXPECT_EQ(notesEntry.value(QStringLiteral("app")).toString(), QStringLiteral("org.example.Notes"));
    EXPECT_EQ(notesEntry.value(QStringLiteral("block")).toString(), backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("uninstall")).toString())
        << "the same answer as the product page's menu";
    EXPECT_FALSE(byEntry.contains(QStringLiteral("org.example.Paint.desktop"))) << "an app that is not installed is not listed";
    EXPECT_EQ(backend.appForEntry(QStringLiteral("org.example.Notes")), QStringLiteral("org.example.Notes")) << "with or without .desktop";
    EXPECT_EQ(backend.appForEntry(QStringLiteral("org.example.Notes.desktop")), QStringLiteral("org.example.Notes"));
    EXPECT_EQ(backend.appForEntry(QStringLiteral("../etc/passwd")), QString());
    EXPECT_EQ(backend.appForEntry(QStringLiteral("nothing.desktop")), QString());

    // ADR-0049: after the check, the list says the update asks for more (Flathub's newer metadata reaches the home folder,
    // which the installed one does not), grant by grant.
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().first().toMap().contains(QStringLiteral("asksForMore")); }))
        << "reviewed after the check";
    const QVariantMap notes = flatpak().value(QStringLiteral("apps")).toList().first().toMap();
    EXPECT_TRUE(notes.value(QStringLiteral("asksForMore")).toBool());
    EXPECT_FALSE(notes.value(QStringLiteral("permissionsUnknown")).toBool());
    const auto changeKeys = [](const QVariantList &changes) {
        QStringList out;
        for (const QVariant &c : changes)
            out.append(c.toMap().value(QStringLiteral("change")).toString() + QLatin1Char(' ') + c.toMap().value(QStringLiteral("key")).toString());
        return out;
    };
    EXPECT_EQ(changeKeys(notes.value(QStringLiteral("permissionChanges")).toList()),
              (QStringList{QStringLiteral("added home"), QStringLiteral("added login"), QStringLiteral("added outside")}));
    // Update All leaves it out: only the runtime would update, and Notes waits for its own Update.
    backend.plan(kFlatpakUpdatesApp, QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == 1; }));
    QVariantMap plan = plans.last().second;
    EXPECT_EQ(plan.value(QStringLiteral("refusal")).toString(), QString());
    EXPECT_EQ(plan.value(QStringLiteral("refs")).toInt(), 1) << "the runtime alone";
    EXPECT_EQ(plan.value(QStringLiteral("held")).toStringList(), QStringList{QStringLiteral("Example Notes")});
    EXPECT_FALSE(plan.value(QStringLiteral("asks")).toBool()) << "Update All never asks: what asks for more is left out";
    plans.clear();

    // Its own plan: the same changes, and the sheet asks.
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == 1; }));
    plan = plans.last().second;
    EXPECT_EQ(plan.value(QStringLiteral("refusal")).toString(), QString());
    EXPECT_EQ(plan.value(QStringLiteral("refs")).toInt(), 1);
    EXPECT_TRUE(plan.value(QStringLiteral("asks")).toBool());
    EXPECT_TRUE(plan.value(QStringLiteral("held")).toStringList().isEmpty());
    const QVariantList changed = plan.value(QStringLiteral("changed")).toList();
    ASSERT_EQ(changed.size(), 1);
    EXPECT_EQ(changed.first().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("Example Notes"));
    EXPECT_TRUE(changed.first().toMap().value(QStringLiteral("asks")).toBool());
    EXPECT_EQ(changeKeys(changed.first().toMap().value(QStringLiteral("changes")).toList()),
              (QStringList{QStringLiteral("added home"), QStringLiteral("added login"), QStringLiteral("added outside")}));
    EXPECT_FALSE(backend.update(QStringLiteral("org.example.Paint"))) << "no plan for it";
    ASSERT_TRUE(backend.update(QStringLiteral("org.example.Notes")));
    EXPECT_FALSE(backend.update(QStringLiteral("org.example.Notes"))) << "its plan is used once";
    ASSERT_TRUE(waitFor([&] { return backend.operations().isEmpty(); }));
    EXPECT_TRUE(backend.results().isEmpty());
    QFile calls(s.path(QStringLiteral("fixture/flatpak-calls")));
    ASSERT_TRUE(calls.open(QIODevice::ReadOnly));
    // Pinned to the commit its plan read (S32): the one whose access the sheet said; done by that commit installed.
    const QByteArray pinned = QByteArray(62, '0') + "07";
    EXPECT_TRUE(calls.readAll().contains("update --user --noninteractive --commit=" + pinned + " -- " + notesRef.toUtf8() + "\n"));
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().isEmpty(); })) << "checked again after it";

    // Update All: the runtime left; nothing new to reach, so no sheet would show.
    storetest::writeFile(s.path(QStringLiteral("fixture/samemeta")), "");
    backend.plan(kFlatpakUpdatesApp, QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == 2; }));
    plan = plans.last().second;
    EXPECT_EQ(plan.value(QStringLiteral("refs")).toInt(), 1);
    EXPECT_TRUE(plan.value(QStringLiteral("changed")).toList().isEmpty());
    EXPECT_TRUE(plan.value(QStringLiteral("unknown")).toStringList().isEmpty());
    EXPECT_TRUE(plan.value(QStringLiteral("held")).toStringList().isEmpty());
    ASSERT_TRUE(backend.update(kFlatpakUpdatesApp));
    ASSERT_TRUE(waitFor([&] { return backend.operations().isEmpty(); }));
    EXPECT_TRUE(backend.results().isEmpty());
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("runtimes")).toInt() == 0; }));
    // Nothing left: refused with why.
    backend.plan(kFlatpakUpdatesApp, QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == 3; }));
    EXPECT_EQ(plans.last().second.value(QStringLiteral("refusal")).toString(), QStringLiteral("unavailable"));
    EXPECT_EQ(plans.last().second.value(QStringLiteral("detail")).toString(), QStringLiteral("none"));
    // An update a check found done since its plan (another Check Now, flatpak run by hand): nothing left to run.
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), "org.example.Notes\tstable\tflathub\tapp/org.example.Notes/x86_64/stable\n");
    backend.updatesShown(true);
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().size() == 1 && !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == 4; }));
    EXPECT_EQ(plans.last().second.value(QStringLiteral("refs")).toInt(), 1);
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), "");
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().isEmpty() && !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    EXPECT_FALSE(backend.update(QStringLiteral("org.example.Notes"))) << "its ref is no longer listed";

    // A plan says what it checks while it runs (the integrator's MINOR 5 on #97): the app's Update waits ("checking"), the
    // group's line counts the apps; asked again meanwhile, it is the same plan, answered once.
    const QByteArray notesLine = "org.example.Notes\tstable\tflathub\tapp/org.example.Notes/x86_64/stable\n";
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), notesLine);
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().size() == 1 && !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    storetest::writeFile(s.path(QStringLiteral("fixture/slowmeta")), "");
    int asked = int(plans.size());
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    EXPECT_EQ(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("update")).toString(), QStringLiteral("checking"));
    EXPECT_EQ(flatpak().value(QStringLiteral("planning")).toMap(), (QVariantMap{{QStringLiteral("done"), 0}, {QStringLiteral("total"), 1}}));
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == asked + 1; }));
    for (int i = 0; i < 25; ++i) { // the second ask never answers on its own
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    EXPECT_EQ(plans.size(), asked + 1);
    EXPECT_FALSE(flatpak().value(QStringLiteral("planning")).isValid());
    EXPECT_EQ(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("update")).toString(), QString());
    QFile::remove(s.path(QStringLiteral("fixture/slowmeta")));

    // SD33: an update whose commit or metadata could not be read is said, by the app's name (the sheet then asks); with no
    // commit read, the update is not pinned (the user agreed to it unchecked).
    storetest::writeFile(s.path(QStringLiteral("fixture/nometa")), "");
    asked = int(plans.size());
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == asked + 1; }));
    EXPECT_EQ(plans.last().second.value(QStringLiteral("unknown")).toStringList(), QStringList{QStringLiteral("Example Notes")});
    EXPECT_TRUE(plans.last().second.value(QStringLiteral("changed")).toList().isEmpty());
    EXPECT_TRUE(plans.last().second.value(QStringLiteral("asks")).toBool()) << "unread: never silent";
    QFile::remove(s.path(QStringLiteral("fixture/nometa")));
    storetest::writeFile(s.path(QStringLiteral("fixture/nocommit")), "");
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == asked + 2; }));
    EXPECT_EQ(plans.last().second.value(QStringLiteral("unknown")).toStringList(), QStringList{QStringLiteral("Example Notes")});
    QFile::remove(s.path(QStringLiteral("fixture/flatpak-calls")));
    QFile::remove(s.path(QStringLiteral("fixture/nocommit")));
    ASSERT_TRUE(backend.update(QStringLiteral("org.example.Notes")));
    ASSERT_TRUE(waitFor([&] { return backend.operations().isEmpty(); }));
    QFile unpinned(s.path(QStringLiteral("fixture/flatpak-calls")));
    ASSERT_TRUE(unpinned.open(QIODevice::ReadOnly));
    EXPECT_TRUE(unpinned.readAll().contains("update --user --noninteractive -- " + notesRef.toUtf8() + "\n"));
    EXPECT_TRUE(backend.results().isEmpty()) << "unpinned: done when a new check no longer lists it";

    // Ctrl+Q while an update runs, then the Store asked for again (SD35's hand-over; the integrator's MAJOR on #97): the
    // quit is off, and the update ends with the Store still there.
    // The check an operation's end starts is over first (else it may read the list before it is written).
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("state")).toString().isEmpty(); }));
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), notesLine);
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().size() == 1 && !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    asked = int(plans.size());
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == asked + 1; }));
    storetest::writeFile(s.path(QStringLiteral("fixture/slowupdate")), "");
    ASSERT_TRUE(backend.update(QStringLiteral("org.example.Notes")));
    ASSERT_TRUE(waitFor([&] {
        const QVariantList ops = backend.operations();
        return !ops.isEmpty() && ops.first().toMap().value(QStringLiteral("state")).toString() == QLatin1String("running");
    }));
    EXPECT_FALSE(backend.quitPending());
    backend.quitWhenIdle();
    EXPECT_TRUE(backend.quitPending()) << "it waits for the update";
    backend.reopened();
    EXPECT_FALSE(backend.quitPending()) << "asked for again: it stays";
    ASSERT_TRUE(waitFor([&] { return backend.operations().isEmpty(); }));
    EXPECT_FALSE(backend.quitPending());
    QFile::remove(s.path(QStringLiteral("fixture/slowupdate")));

    // Updated outside the Store between its plan and its update (#97's merge note): the plan read the installed commit, and
    // the pinned one (perhaps older) is not installed over the newer one; it counts as done.
    // The check an operation's end starts is over first (else it may read the list before it is written).
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("state")).toString().isEmpty(); }));
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), notesLine);
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return flatpak().value(QStringLiteral("apps")).toList().size() == 1 && !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    storetest::writeFile(s.path(QStringLiteral("fixture/commit-org.example.Notes")), QByteArray(64, '1') + "\n");
    asked = int(plans.size());
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("update"));
    ASSERT_TRUE(waitFor([&] { return plans.size() == asked + 1; }));
    storetest::writeFile(s.path(QStringLiteral("fixture/commit-org.example.Notes")), QByteArray(64, '2') + "\n");
    QFile::remove(s.path(QStringLiteral("fixture/flatpak-calls")));
    ASSERT_TRUE(backend.update(QStringLiteral("org.example.Notes")));
    ASSERT_TRUE(waitFor([&] { return backend.operations().isEmpty(); }));
    QFile outside(s.path(QStringLiteral("fixture/flatpak-calls")));
    ASSERT_TRUE(outside.open(QIODevice::ReadOnly));
    const QByteArray outsideCalls = outside.readAll();
    EXPECT_TRUE(outsideCalls.contains("info --user --show-commit -- " + notesRef.toUtf8() + "\n")) << outsideCalls.constData();
    EXPECT_FALSE(outsideCalls.contains("update --user --noninteractive")) << outsideCalls.constData();
    EXPECT_TRUE(backend.results().isEmpty());
    EXPECT_TRUE(backend.operations().isEmpty());

    // Check Now: the shell is asked; its answer is the file's new checkedAt.
    backend.updatesShown(true);
    backend.checkUpdates();
    EXPECT_TRUE(backend.updates().value(QStringLiteral("checking")).toBool() || QFile::exists(s.path(QStringLiteral("state/qs-calls"))));
    ASSERT_TRUE(waitFor([&] { return !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    QFile qs(s.path(QStringLiteral("state/qs-calls")));
    ASSERT_TRUE(qs.open(QIODevice::ReadOnly));
    EXPECT_TRUE(qs.readAll().contains("ipc -p " + s.path(QStringLiteral("shell")).toUtf8() + " call update check user\n"));
    EXPECT_FALSE(backend.updates().value(QStringLiteral("askFailed")).toBool());
    EXPECT_EQ(backend.updates().value(QStringLiteral("state")).toString(), QStringLiteral("available"));
    // The shell answers before its check ends: the page shows the check until the file has a new checkedAt, not at the
    // shell's answer nor at a look at the unchanged file (the state folder's own changes wake the Store).
    storetest::writeFile(s.path(QStringLiteral("state/qs-slow")), "");
    backend.checkUpdates();
    EXPECT_TRUE(backend.updates().value(QStringLiteral("checking")).toBool());
    for (int i = 0; i < 50; ++i) { // 1 s: the shell has answered, the file is unchanged
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    EXPECT_TRUE(backend.updates().value(QStringLiteral("checking")).toBool()) << "the file has not changed yet";
    ASSERT_TRUE(waitFor([&] { return !backend.updates().value(QStringLiteral("checking")).toBool(); }));
    EXPECT_EQ(backend.updates().value(QStringLiteral("state")).toString(), QStringLiteral("up-to-date")) << "the check's own answer";
    QFile::remove(s.path(QStringLiteral("state/qs-slow")));
    // A shell that refuses: said.
    storetest::writeFile(s.path(QStringLiteral("state/qs-refuses")), "");
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return backend.updates().value(QStringLiteral("askFailed")).toBool(); }));
    EXPECT_FALSE(backend.updates().value(QStringLiteral("checking")).toBool());

    // The last system update unfinished (pacman -Qu lists packages, S12).
    const QString base = s.path(QStringLiteral("fixture/bin/pacman-base"));
    QFile::rename(s.path(QStringLiteral("fixture/bin/pacman")), base);
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")),
                      "[ \"$1\" = -Qu ] && { echo 'gimp 3.0.4-1 -> 3.0.6-1'; echo 'held 1-1 -> 2-1 [ignored]'; exit 0; }\nexec '" + base.toUtf8() + "' \"$@\"");
    backend.checkUpdates();
    ASSERT_TRUE(waitFor([&] { return backend.updates().value(QStringLiteral("unfinished")).toInt() == 1; })) << "the [ignored] one is not";
    backend.updatesShown(false);

    // The search by document type (ADR-0035 5c-3): GIMP's AppStream says it opens PNG images.
    QVariantMap found = backend.typeSearch(QStringLiteral("IMAGE/PNG"));
    EXPECT_EQ(found.value(QStringLiteral("type")).toString(), QStringLiteral("image/png"));
    const QVariantList openers = found.value(QStringLiteral("apps")).toList();
    ASSERT_FALSE(openers.isEmpty());
    EXPECT_EQ(openers.first().toMap().value(QStringLiteral("id")).toString(), QStringLiteral("org.gimp.GIMP"));
    EXPECT_FALSE(found.value(QStringLiteral("description")).toString().isEmpty());
    EXPECT_TRUE(backend.typeSearch(QStringLiteral("application/x-nothing-opens-this")).value(QStringLiteral("apps")).toList().isEmpty());
    EXPECT_TRUE(backend.typeSearch(QStringLiteral("not a type")).isEmpty());
    EXPECT_TRUE(backend.typeSearch(QStringLiteral("image/png;x")).isEmpty());

    // Offline (dev plumbing): an update a check listed cannot run; its Update says why, and so does Update All.
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("1"));
    storetest::writeFile(s.path(QStringLiteral("fixture/fupdates")), "org.example.Notes\tstable\tflathub\tapp/org.example.Notes/x86_64/stable\n");
    StoreBackend offline;
    offline.start();
    ASSERT_TRUE(settle(offline));
    const auto offlineFlatpak = [&offline] { return offline.updates().value(QStringLiteral("flatpak")).toMap(); };
    ASSERT_TRUE(waitFor([&] { return offlineFlatpak().value(QStringLiteral("apps")).toList().size() == 1; }));
    const QString listed = offlineFlatpak().value(QStringLiteral("apps")).toList().first().toMap().value(QStringLiteral("id")).toString();
    EXPECT_EQ(offline.actions(listed).value(QStringLiteral("update")).toString(), QStringLiteral("offline")) << listed.toStdString();
    EXPECT_EQ(offlineFlatpak().value(QStringLiteral("block")).toString(), QStringLiteral("offline"));
}

// Flathub turned on (step 3c part 2): added to the user's installation and its AppStream read, its apps offered with
// flatpak's own plan and what they can reach, installed and removed as the Store's own child, listed in Installed with the
// user's other Flatpaks, opened by their exported entry or `flatpak run`; nothing of it while Flathub is off.
TEST(StoreBackend, Flathub)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    const QString installer = storetest::script(s.path(QStringLiteral("installer")), "echo \"$*\" >>\"$(dirname \"$0\")/opened\"");
    s.env->set("GRASSFIELD_STORE_INSTALLER", installer);
    storetest::script(s.path(QStringLiteral("fixture/bin/flatpak")), kFlatpak);
    storetest::writeFile(s.path(QStringLiteral("flathub.xml.gz")), storetest::gzip(storetest::readFixture(QStringLiteral("appstream-flathub.xml"))));
    storetest::writeFile(s.path(QStringLiteral("fixture/flatpaks")), "com.other.App\n");
    const auto calls = [&s] {
        QFile f(s.path(QStringLiteral("fixture/flatpak-calls")));
        return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()) : QString();
    };
    {
        // Off: flatpak is not asked, no Flathub app.
        StoreBackend backend;
        backend.start();
        ASSERT_TRUE(settle(backend));
        EXPECT_TRUE(backend.sources().value(QStringLiteral("flatpak")).toBool());
        EXPECT_FALSE(backend.sources().value(QStringLiteral("flathubReady")).toBool());
        EXPECT_TRUE(backend.app(QStringLiteral("org.example.Notes")).isEmpty());
        EXPECT_TRUE(calls().isEmpty());
    }
    storetest::writeFile(s.path(QStringLiteral("config/grassfield.json")), R"({"version":1,"store":{"sources":{"flathub":true}}})");
    StoreBackend backend;
    QList<QVariantMap> plans;
    QObject::connect(&backend, &StoreBackend::planReady, &backend, [&plans](const QString &, const QString &, const QVariantMap &p) { plans.append(p); });
    QVariantMap facts;
    QObject::connect(&backend, &StoreBackend::flatpakInfo, &backend, [&facts](const QString &, const QVariantMap &f) { facts = f; });
    backend.start();
    ASSERT_TRUE(settle(backend));
    EXPECT_TRUE(calls().contains(QStringLiteral("remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo\n"
                                                "update --user --appstream flathub\n")))
        << calls().toStdString();
    EXPECT_TRUE(backend.sources().value(QStringLiteral("flathubReady")).toBool());
    EXPECT_EQ(backend.sources().value(QStringLiteral("flathubProblem")).toString(), QString());
    const QVariantMap notes = backend.app(QStringLiteral("org.example.Notes"));
    ASSERT_FALSE(notes.isEmpty());
    EXPECT_EQ(notes.value(QStringLiteral("kind")).toString(), QStringLiteral("flatpak"));
    EXPECT_EQ(notes.value(QStringLiteral("flatpakId")).toString(), QStringLiteral("org.example.Notes"));
    EXPECT_EQ(notes.value(QStringLiteral("runtime")).toString(), QStringLiteral("org.gnome.Platform 50"));
    EXPECT_TRUE(notes.value(QStringLiteral("verified")).toBool());
    EXPECT_TRUE(notes.value(QStringLiteral("icon")).toString().endsWith(QLatin1String("/icons/128x128/org.example.Notes.png")));
    EXPECT_EQ(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("get")).toString(), QString());
    const QVariantList found = backend.search(QStringLiteral("notes"));
    EXPECT_TRUE(std::any_of(found.cbegin(), found.cend(),
                            [](const QVariant &v) { return v.toMap().value(QStringLiteral("id")) == QLatin1String("org.example.Notes"); }));

    // Its facts before an install (remote-info), and its plan: flatpak's own, what it can reach.
    backend.requestFlatpakInfo(QStringLiteral("org.example.Notes"));
    QEventLoop loop;
    for (int i = 0; i < 500 && facts.isEmpty(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    EXPECT_EQ(facts.value(QStringLiteral("version")).toString(), QStringLiteral("1.2"));
    EXPECT_EQ(facts.value(QStringLiteral("license")).toString(), QStringLiteral("MIT"));
    EXPECT_EQ(facts.value(QStringLiteral("access")).toStringList(), (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("login"),
                                                                                    QStringLiteral("outside")}));
    EXPECT_FALSE(facts.value(QStringLiteral("download")).toString().isEmpty());
    // Its metadata unread: its facts without "access", so the page says nothing of what it can reach (PR #58).
    storetest::writeFile(s.path(QStringLiteral("fixture/nometa")), "");
    facts.clear();
    backend.requestFlatpakInfo(QStringLiteral("org.example.Notes"));
    for (int i = 0; i < 500 && facts.isEmpty(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    EXPECT_EQ(facts.value(QStringLiteral("version")).toString(), QStringLiteral("1.2"));
    EXPECT_FALSE(facts.contains(QStringLiteral("access")));
    QFile::remove(s.path(QStringLiteral("fixture/nometa")));
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("install"));
    for (int i = 0; i < 500 && plans.isEmpty(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_EQ(plans.size(), 1);
    EXPECT_EQ(plans.last().value(QStringLiteral("refusal")).toString(), QString()) << plans.last().value(QStringLiteral("detail")).toString().toStdString();
    const QVariantList refs = plans.last().value(QStringLiteral("packages")).toList();
    ASSERT_EQ(refs.size(), 2);
    EXPECT_EQ(refs.at(0).toMap().value(QStringLiteral("name")).toString(), QStringLiteral("org.gnome.Platform"));
    EXPECT_EQ(plans.last().value(QStringLiteral("access")).toStringList(), (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("login"),
                                                                                    QStringLiteral("outside")}));

    // Installed by the queue: then in Installed's Flatpak group, beside the user's other Flatpak.
    ASSERT_TRUE(backend.install(QStringLiteral("org.example.Notes")));
    for (int i = 0; i < 500 && !backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("installed")).toBool(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_TRUE(settle(backend));
    EXPECT_TRUE(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("installed")).toBool());
    EXPECT_TRUE(calls().contains(QStringLiteral("install --user --noninteractive flathub app/org.example.Notes/x86_64/stable\n")));
    QStringList group;
    for (const QVariant &g : backend.installed()) {
        if (g.toMap().value(QStringLiteral("group")) == QLatin1String("flatpak")) {
            for (const QVariant &a : g.toMap().value(QStringLiteral("apps")).toList())
                group.append(a.toMap().value(QStringLiteral("id")).toString());
        }
    }
    EXPECT_EQ(group, (QStringList{QStringLiteral("flatpak:com.other.App"), QStringLiteral("org.example.Notes")}));
    EXPECT_EQ(backend.actions(QStringLiteral("flatpak:com.other.App")).value(QStringLiteral("uninstall")).toString(), QString());

    // Open: `flatpak run` while the session does not see the export folder, its entry once it does (S20).
    EXPECT_TRUE(backend.open(QStringLiteral("org.example.Notes")));
    const QString exports = s.path(QStringLiteral("fixture/flatpak/exports/share"));
    QDir().mkpath(exports + QStringLiteral("/applications"));
    storetest::writeFile(exports + QStringLiteral("/applications/org.example.Notes.desktop"), "[Desktop Entry]\n");
    s.env->set("XDG_DATA_DIRS", exports + QStringLiteral(":/usr/share"));
    EXPECT_TRUE(backend.open(QStringLiteral("org.example.Notes")));
    EXPECT_TRUE(backend.open(QStringLiteral("flatpak:com.other.App")));
    // A web app the catalog does not list (no StoreApp behind it): Omarchy's launcher with its address, not a crash.
    EXPECT_TRUE(backend.open(QStringLiteral("webapp:Chat")));
    EXPECT_FALSE(backend.open(QStringLiteral("webapp:Nothing")));
    // Four detached programs, each writing its line: all four, whatever their order.
    const auto openedLines = [&s] {
        QFile f(s.path(QStringLiteral("opened")));
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
    };
    for (int i = 0; i < 500 && openedLines().count('\n') < 4; ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    const QByteArray lines = openedLines();
    EXPECT_TRUE(lines.contains("uwsm-app -- /usr/bin/flatpak run org.example.Notes\n")) << lines.toStdString();
    EXPECT_TRUE(lines.contains("uwsm-app -- org.example.Notes.desktop\n")) << lines.toStdString();
    EXPECT_TRUE(lines.contains("uwsm-app -- /usr/bin/flatpak run com.other.App\n")) << lines.toStdString();
    EXPECT_TRUE(lines.contains("omarchy-launch-webapp https://chat.example.org\n")) << lines.toStdString();

    // Removed: the app, then the runtimes no app needs (SD27).
    backend.plan(QStringLiteral("org.example.Notes"), QStringLiteral("remove"));
    for (int i = 0; i < 500 && plans.size() < 2; ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_EQ(plans.size(), 2);
    EXPECT_EQ(plans.last().value(QStringLiteral("refusal")).toString(), QString());
    ASSERT_TRUE(backend.uninstall(QStringLiteral("org.example.Notes")));
    for (int i = 0; i < 500 && backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("installed")).toBool(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_TRUE(settle(backend));
    EXPECT_FALSE(backend.actions(QStringLiteral("org.example.Notes")).value(QStringLiteral("installed")).toBool());
    EXPECT_TRUE(calls().contains(QStringLiteral("uninstall --user --noninteractive -- org.example.Notes\nuninstall --user --noninteractive --unused\n")));
    EXPECT_TRUE(backend.results().isEmpty()) << "done: nothing to say";
}

// ADR-0052: the running operation is the Store's one ongoing activity in the menu bar; a waiting queue shows nothing.
TEST(StoreOngoing, TheRunningOperationOnly)
{
    const QString id = QStringLiteral("0123456789abcdef0123456789abcdef");
    auto op = [&id](const QString &state, const QString &kind, int done, int total, bool stoppable) {
        return QVariantMap{{QStringLiteral("id"), id},           {QStringLiteral("app"), QStringLiteral("org.gimp.GIMP")},
                           {QStringLiteral("name"), QStringLiteral("GIMP")}, {QStringLiteral("kind"), kind},
                           {QStringLiteral("state"), state},     {QStringLiteral("done"), done},
                           {QStringLiteral("total"), total},     {QStringLiteral("stoppable"), stoppable}};
    };
    EXPECT_TRUE(StoreBackend::ongoingActivities({}).isEmpty());
    EXPECT_TRUE(StoreBackend::ongoingActivities({op(QStringLiteral("waiting"), QStringLiteral("install"), 0, 3, false)}).isEmpty());

    const auto running = StoreBackend::ongoingActivities({op(QStringLiteral("running"), QStringLiteral("install"), 1, 4, true)});
    ASSERT_EQ(running.size(), 1);
    const grassfield::apps::OngoingActivity a = running.value(QStringLiteral("op-") + id);
    EXPECT_EQ(a.kind, QStringLiteral("install"));
    EXPECT_EQ(a.title, QStringLiteral("Installing “GIMP”"));
    EXPECT_EQ(a.subtitle, QStringLiteral("1 of 4"));
    EXPECT_DOUBLE_EQ(a.progress, 0.25);
    ASSERT_EQ(a.actions.size(), 1);
    EXPECT_EQ(a.actions.first().id, QStringLiteral("stop"));

    const auto removing = StoreBackend::ongoingActivities({op(QStringLiteral("authorizing"), QStringLiteral("remove"), 0, 2, false)});
    const grassfield::apps::OngoingActivity r = removing.value(QStringLiteral("op-") + id);
    EXPECT_EQ(r.title, QStringLiteral("Uninstalling “GIMP”"));
    EXPECT_EQ(r.subtitle, QStringLiteral("Waiting for permission…"));
    EXPECT_LT(r.progress, 0.0) << "indeterminate until it runs";
    EXPECT_TRUE(r.actions.isEmpty());

    QVariantMap all = op(QStringLiteral("running"), QStringLiteral("update"), 0, 0, false);
    all.insert(QStringLiteral("name"), QString());
    EXPECT_EQ(StoreBackend::ongoingActivities({all}).value(QStringLiteral("op-") + id).title, QStringLiteral("Updating Apps"));
    // The id names the host's key: a malformed operation id gives nothing.
    QVariantMap bad = op(QStringLiteral("running"), QStringLiteral("install"), 0, 0, false);
    bad.insert(QStringLiteral("id"), QStringLiteral("../x"));
    EXPECT_TRUE(StoreBackend::ongoingActivities({bad}).isEmpty());
}
