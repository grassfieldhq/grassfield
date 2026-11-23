// Golden exports (slices B3 and B4): every shape tool, and a scene of all of them, exported at scale 1 and 1.25 and compared with
// the PNG files of tests/unit/screenshot/golden/ (see golden/README.md: tolerance, regeneration).
//
// A capture at scale 1.25 has 1.25 times the pixels of the same window at scale 1; the editor's tools give a new shape 1.25 times
// the width, and the layers keep device pixels. The test builds the same drawing for each scale by multiplying every coordinate
// and width, so that the two sets of goldens show that the exporter is exact at a fractional scale (the strokes fall between
// pixels, and the anti-aliasing is the point).
#include "annotations.h"
#include "exporter.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>

#include <gtest/gtest.h>

#include <cstdlib>

#ifndef GF_SCREENSHOT_GOLDEN_DIR
#error "GF_SCREENSHOT_GOLDEN_DIR names tests/unit/screenshot/golden (build-direct.sh and CMakeLists.txt define it)"
#endif

using namespace screenshot;

namespace {

// The tolerance of golden/README.md: a pixel differs when a channel is off by more than kChannelTolerance; the export fails when
// more than kPixelFraction of the pixels differ. Anti-aliasing is the only thing that may move between Qt versions, and it moves
// a few pixels along an edge by a few levels.
constexpr int kChannelTolerance = 8;
constexpr double kPixelFraction = 0.005;

constexpr const char *kRed = "#de3651";
constexpr const char *kBlue = "#0167fd";
constexpr const char *kGreenHalf = "#80195e3f";

// A picture with no font, theme or file behind it: 8-pixel checkers of two greys over a slow ramp, so that a drawing over it is
// seen against structure and a shifted edge is seen.
QImage basePicture(double scale)
{
    const int w = int(std::lround(160 * scale)), h = int(std::lround(100 * scale));
    QImage image(w, h, QImage::Format_RGB32);
    for (int y = 0; y < h; ++y) {
        auto *row = reinterpret_cast<QRgb *>(image.scanLine(y));
        for (int x = 0; x < w; ++x) {
            const bool odd = (int(x / scale) / 8 + int(y / scale) / 8) & 1; // 8 logical pixels
            const int grey = (odd ? 214 : 238) - (x * 24 / w);
            row[x] = qRgb(grey, grey, grey + 6);
        }
    }
    return image;
}

ShapeStyle style(double scale, const char *color, double width = 3, bool fill = false, const char *arrow = "straight")
{
    ShapeStyle s;
    s.color = QString::fromLatin1(color);
    s.width = width * scale;
    s.fill = fill;
    s.arrow = QString::fromLatin1(arrow);
    return s;
}

QPointF at(double scale, double x, double y)
{
    return QPointF(x * scale, y * scale);
}

struct Case {
    const char *name;
    Layers (*layers)(double scale);
};

Layers arrowStraight(double s) { return {makeShape(1, "arrow", at(s, 20, 80), at(s, 140, 20), style(s, kRed, 4))}; }
Layers arrowCurved(double s) { return {makeShape(1, "arrow", at(s, 20, 80), at(s, 140, 30), style(s, kRed, 4, false, "curved"))}; }
Layers arrowDouble(double s) { return {makeShape(1, "arrow", at(s, 20, 70), at(s, 140, 40), style(s, kRed, 4, false, "double"))}; }
Layers line(double s) { return {makeShape(1, "line", at(s, 15, 25), at(s, 145, 75), style(s, kBlue, 5))}; }
Layers rectangle(double s) { return {makeShape(1, "rectangle", at(s, 30, 20), at(s, 130, 80), style(s, kBlue, 4))}; }
Layers rectangleFilled(double s) { return {makeShape(1, "rectangle", at(s, 30, 20), at(s, 130, 80), style(s, kGreenHalf, 4, true))}; }
Layers ellipse(double s) { return {makeShape(1, "ellipse", at(s, 25, 15), at(s, 135, 85), style(s, kRed, 4))}; }
Layers ellipseFilled(double s) { return {makeShape(1, "ellipse", at(s, 25, 15), at(s, 135, 85), style(s, kBlue, 2, true))}; }

// Every tool in one picture, over each other: the back-to-front order is part of what is compared.
Layers scene(double s)
{
    Layers all;
    for (auto build : {rectangleFilled, ellipse, line, arrowCurved, arrowDouble, arrowStraight}) {
        Layers one = build(s);
        one[0].id = all.size() + 1;
        all.append(one);
    }
    return all;
}

const Case kCases[] = {
    {"arrow-straight", arrowStraight}, {"arrow-curved", arrowCurved},       {"arrow-double", arrowDouble},
    {"line", line},                    {"rectangle", rectangle},            {"rectangle-filled", rectangleFilled},
    {"ellipse", ellipse},              {"ellipse-filled", ellipseFilled},   {"scene", scene},
};

QString goldenPath(const char *name, const char *scaleName)
{
    return QDir(QStringLiteral(GF_SCREENSHOT_GOLDEN_DIR)).filePath(QStringLiteral("%1@%2.png").arg(QLatin1String(name), QLatin1String(scaleName)));
}

// Whether `actual` matches the golden (or writes it, with GF_UPDATE_GOLDENS=1).
void expectGolden(const char *name, const char *scaleName, const QImage &actual)
{
    const QString path = goldenPath(name, scaleName);
    if (qEnvironmentVariableIsSet("GF_UPDATE_GOLDENS")) {
        ASSERT_TRUE(QDir().mkpath(QFileInfo(path).absolutePath()));
        ASSERT_TRUE(actual.convertToFormat(QImage::Format_RGB32).save(path, "PNG", 9)) << path.toStdString();
        return;
    }
    ASSERT_TRUE(QFileInfo::exists(path)) << path.toStdString() << " is missing: tests/unit/screenshot/regenerate-goldens.sh writes it";
    const QImage golden = QImage(path).convertToFormat(QImage::Format_RGB32);
    ASSERT_FALSE(golden.isNull()) << path.toStdString();
    ASSERT_EQ(actual.size(), golden.size()) << path.toStdString();
    const QImage rgb = actual.convertToFormat(QImage::Format_RGB32);
    long differing = 0;
    int worst = 0;
    for (int y = 0; y < rgb.height(); ++y) {
        const auto *a = reinterpret_cast<const QRgb *>(rgb.constScanLine(y));
        const auto *g = reinterpret_cast<const QRgb *>(golden.constScanLine(y));
        for (int x = 0; x < rgb.width(); ++x) {
            const int d = std::max({std::abs(qRed(a[x]) - qRed(g[x])), std::abs(qGreen(a[x]) - qGreen(g[x])), std::abs(qBlue(a[x]) - qBlue(g[x]))});
            worst = std::max(worst, d);
            if (d > kChannelTolerance)
                ++differing;
        }
    }
    const double fraction = double(differing) / (double(rgb.width()) * rgb.height());
    if (fraction > kPixelFraction) {
        // The picture that came out, next to where the tests write, for a look (never inside the repository).
        const QString out = qEnvironmentVariable("GRASSFIELD_TEST_TMP", QDir::tempPath()) + QStringLiteral("/golden-actual-%1@%2.png").arg(QLatin1String(name), QLatin1String(scaleName));
        rgb.save(out, "PNG");
        ADD_FAILURE() << path.toStdString() << ": " << differing << " pixels differ by more than " << kChannelTolerance << " (" << fraction * 100
                      << "%, the most " << worst << " levels); the picture is in " << out.toStdString();
    }
}

} // namespace

class GoldenTest : public ::testing::TestWithParam<Case>
{
};

TEST_P(GoldenTest, ExportAtScaleOne)
{
    const Case &c = GetParam();
    const QImage original = basePicture(1);
    const QImage out = exportLayers(original, c.layers(1));
    EXPECT_NE(out, original) << "the drawing changed nothing: the golden would prove nothing";
    expectGolden(c.name, "1", out);
}

TEST_P(GoldenTest, ExportAtScaleOnePointTwoFive)
{
    const Case &c = GetParam();
    const QImage original = basePicture(1.25);
    EXPECT_EQ(original.size(), QSize(200, 125));
    const QImage out = exportLayers(original, c.layers(1.25));
    EXPECT_NE(out, original);
    expectGolden(c.name, "1.25", out);
}

INSTANTIATE_TEST_SUITE_P(Tools, GoldenTest, ::testing::ValuesIn(kCases), [](const ::testing::TestParamInfo<Case> &info) {
    std::string name = info.param.name;
    for (char &c : name) {
        if (c == '-')
            c = '_';
    }
    return name;
});

// The export is deterministic: the same layers on the same picture, twice, are the same bytes (what the goldens rely on).
TEST(GoldenHarness, TheExportIsRepeatable)
{
    const QImage original = basePicture(1.25);
    EXPECT_EQ(exportLayers(original, scene(1.25)), exportLayers(original, scene(1.25)));
}

// At 1.25 the strokes are 1.25 times as wide: the same drawing is not a resampled one (a stroke is not 4 pixels at both).
TEST(GoldenHarness, TheStrokeScalesWithTheDisplay)
{
    const auto thickness = [](double scale) {
        const QImage out = exportLayers(basePicture(scale), line(scale));
        // Count the blue-ish pixels in the column of the picture's middle.
        const int x = out.width() / 2;
        double covered = 0;
        for (int y = 0; y < out.height(); ++y) {
            const QColor c = out.pixelColor(x, y);
            if (c.blue() > c.red() + 40)
                covered += 1;
        }
        return covered;
    };
    const double one = thickness(1), scaled = thickness(1.25);
    EXPECT_GT(one, 0);
    EXPECT_NEAR(scaled / one, 1.25, 0.25);
}
