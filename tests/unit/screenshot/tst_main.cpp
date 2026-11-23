// The Screenshot app's unit tests' main (ADR-0066 D-3): a QGuiApplication around the cases (QImage and the image plugins need
// one in the app's own process), always offscreen.
#include <QGuiApplication>

#include <gtest/gtest.h>

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
