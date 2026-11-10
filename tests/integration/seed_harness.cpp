// The session start seed of the bundled apps (DefaultApps::seedBundledApps) as a program, for tests/integration/seed_real_xdg.sh.
#include "applicationslogic.h"
#include <QCoreApplication>
#include <QTextStream>
#include <cstdio>
// usage: harness configDir stateFile appsDir omarchyDir desktops(colon) dataDir
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    const QString config = QString::fromLocal8Bit(argv[1]);
    const QString state = QString::fromLocal8Bit(argv[2]);
    const QString apps = QString::fromLocal8Bit(argv[3]);
    const QString omarchy = QString::fromLocal8Bit(argv[4]);
    QStringList desktops;
    for (const QString &d : QString::fromLocal8Bit(argv[5]).split(':', Qt::SkipEmptyParts)) desktops << d.toLower();
    const QString data = QString::fromLocal8Bit(argv[6]);
    const QStringList lists = DefaultApps::lookupLists({config}, {data}, desktops);
    bool r = DefaultApps::seedBundledApps(config, state, {apps}, omarchy, lists);
    printf("seedBundledApps=%d\n", r ? 1 : 0);
    return 0;
}
