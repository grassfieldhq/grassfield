#include "redaction.h"

#include <QVector>

#include <algorithm>
#include <cmath>

namespace screenshot {

namespace {

// splitmix64: a well-mixed 64-bit function of its argument (the noise is a function of the seed and the place, never of the source).
quint64 mix(quint64 x)
{
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

quint64 hashOf(quint64 seed, quint64 a, quint64 b, quint64 c)
{
    return mix(mix(mix(seed ^ a) ^ b) ^ c);
}

int floorDiv(int a, int b)
{
    int q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0)))
        --q;
    return q;
}

quint32 *row(QImage *image, int y)
{
    return reinterpret_cast<quint32 *>(image->scanLine(y));
}

bool usable(const QImage *image)
{
    return image && !image->isNull() && image->format() == QImage::Format_ARGB32_Premultiplied;
}

// The sizes of three box blurs that approximate a Gaussian of `sigma` (the standard construction), as radii.
void boxRadii(qreal sigma, int radii[3])
{
    const double ideal = std::sqrt(12.0 * sigma * sigma / 3 + 1);
    int lower = int(std::floor(ideal));
    if (lower % 2 == 0)
        --lower;
    lower = std::max(lower, 1);
    const int upper = lower + 2;
    const double m = std::round((12.0 * sigma * sigma - 3.0 * lower * lower - 12.0 * lower - 9) / (-4.0 * lower - 4));
    for (int i = 0; i < 3; ++i)
        radii[i] = ((i < m ? lower : upper) - 1) / 2;
}

// One box pass of radius `r` along a row or a column of `n` pixels (premultiplied, four channels), clamped at the ends.
void boxLine(const quint32 *src, quint32 *dst, int n, int r, int srcStep, int dstStep)
{
    const auto at = [&](int i) { return src[std::clamp(i, 0, n - 1) * srcStep]; };
    const int width = 2 * r + 1;
    qint64 sum[4] = {0, 0, 0, 0};
    for (int i = -r; i <= r; ++i) {
        const quint32 p = at(i);
        sum[0] += p >> 24;
        sum[1] += (p >> 16) & 0xff;
        sum[2] += (p >> 8) & 0xff;
        sum[3] += p & 0xff;
    }
    for (int i = 0; i < n; ++i) {
        quint32 out = 0;
        for (int c = 0; c < 4; ++c)
            out |= quint32((sum[c] + width / 2) / width) << (24 - 8 * c);
        dst[i * dstStep] = out;
        const quint32 gone = at(i - r), came = at(i + r + 1);
        sum[0] += qint64(came >> 24) - qint64(gone >> 24);
        sum[1] += qint64((came >> 16) & 0xff) - qint64((gone >> 16) & 0xff);
        sum[2] += qint64((came >> 8) & 0xff) - qint64((gone >> 8) & 0xff);
        sum[3] += qint64(came & 0xff) - qint64(gone & 0xff);
    }
}

} // namespace

void redactArea(QImage *image, const QRect &area, const QColor &fill, const QPoint &origin)
{
    if (!usable(image))
        return;
    const QRect part = area.translated(-origin).intersected(QRect(QPoint(), image->size()));
    // Opaque whatever the colour's alpha was: a redaction never lets the source show through.
    const quint32 value = 0xff000000u | (quint32(fill.red()) << 16) | (quint32(fill.green()) << 8) | quint32(fill.blue());
    for (int y = part.top(); y <= part.bottom(); ++y) {
        quint32 *line = row(image, y);
        std::fill(line + part.left(), line + part.right() + 1, value);
    }
}

QPoint pixelateOffset(quint64 seed, int block)
{
    block = std::max(block, kMinPixelateBlock);
    return QPoint(int(hashOf(seed, 1, 0, 0) % quint64(block)), int(hashOf(seed, 2, 0, 0) % quint64(block)));
}

void pixelateNoise(quint64 seed, int blockX, int blockY, int noise[3])
{
    const auto draw = [&](quint64 stream, int range) {
        return int(hashOf(seed, quint64(qint64(blockX)), quint64(qint64(blockY)), stream) % quint64(2 * range + 1)) - range;
    };
    // One term shared by the three channels (a brightness shift that averaging the channels of grey text cannot cancel) and one of each
    // channel's own; together at most kPixelateNoise.
    const int shared = draw(2, kPixelateLuma);
    for (int c = 0; c < 3; ++c)
        noise[c] = shared + draw(quint64(c + 3), kPixelateNoise - kPixelateLuma);
}

void pixelateArea(QImage *image, const QRect &area, int block, quint64 seed, const QPoint &origin)
{
    if (!usable(image))
        return;
    block = std::clamp(block, kMinPixelateBlock, kMaxPixelateBlock);
    const QRect bounds(origin, image->size());
    const QRect a = area.intersected(bounds);
    if (a.isEmpty())
        return;
    const QPoint offset = pixelateOffset(seed, block);
    const int bx0 = floorDiv(a.left() - offset.x(), block), bx1 = floorDiv(a.right() - offset.x(), block);
    const int by0 = floorDiv(a.top() - offset.y(), block), by1 = floorDiv(a.bottom() - offset.y(), block);
    for (int by = by0; by <= by1; ++by) {
        for (int bx = bx0; bx <= bx1; ++bx) {
            const QRect cell(offset.x() + bx * block, offset.y() + by * block, block, block);
            // The mean of the whole block, the part outside the area included (but only as far as the image goes).
            const QRect src = cell.intersected(bounds);
            quint64 sum[3] = {0, 0, 0};
            for (int y = src.top(); y <= src.bottom(); ++y) {
                const quint32 *line = row(image, y - origin.y());
                for (int x = src.left(); x <= src.right(); ++x) {
                    const quint32 p = line[x - origin.x()];
                    sum[0] += (p >> 16) & 0xff;
                    sum[1] += (p >> 8) & 0xff;
                    sum[2] += p & 0xff;
                }
            }
            const quint64 count = quint64(src.width()) * quint64(src.height());
            int noise[3];
            pixelateNoise(seed, bx, by, noise);
            quint32 value = 0xff000000u;
            for (int c = 0; c < 3; ++c) {
                const int mean = int((sum[c] + count / 2) / count);
                value |= quint32(std::clamp(mean + noise[c], 0, 255)) << (16 - 8 * c);
            }
            const QRect out = cell.intersected(a);
            for (int y = out.top(); y <= out.bottom(); ++y) {
                quint32 *line = row(image, y - origin.y());
                std::fill(line + (out.left() - origin.x()), line + (out.right() - origin.x()) + 1, value);
            }
        }
    }
}

namespace {

int blurMargin(qreal sigma)
{
    int radii[3];
    boxRadii(std::clamp(sigma, kMinBlurRadius, kMaxBlurRadius), radii);
    return radii[0] + radii[1] + radii[2];
}

} // namespace

void blurArea(QImage *image, const QRect &area, qreal sigma, const QPoint &origin)
{
    if (!usable(image))
        return;
    sigma = std::clamp(sigma, kMinBlurRadius, kMaxBlurRadius);
    const QRect bounds(origin, image->size());
    const QRect a = area.intersected(bounds);
    if (a.isEmpty())
        return;
    const int margin = blurMargin(sigma);
    // The part of the picture the blur reads, as its own image (the clamped ends are the picture's own edges).
    const QRect read = a.adjusted(-margin, -margin, margin, margin).intersected(bounds);
    QImage work = image->copy(read.translated(-origin));
    QImage temp(work.size(), QImage::Format_ARGB32_Premultiplied);
    int radii[3];
    boxRadii(sigma, radii);
    const int w = work.width(), h = work.height();
    for (int pass = 0; pass < 3; ++pass) {
        for (int y = 0; y < h; ++y)
            boxLine(row(&work, y), row(&temp, y), w, radii[pass], 1, 1);
        for (int x = 0; x < w; ++x)
            boxLine(row(&temp, 0) + x, row(&work, 0) + x, h, radii[pass], w, w);
    }
    for (int y = a.top(); y <= a.bottom(); ++y) {
        const quint32 *from = row(&work, y - read.top()) + (a.left() - read.left());
        std::copy(from, from + a.width(), row(image, y - origin.y()) + (a.left() - origin.x()));
    }
}

QRect regionContext(const ShapeGeometry &g, const QRect &picture)
{
    const QRect a = g.area.intersected(picture);
    if (a.isEmpty())
        return {};
    if (g.kind == ShapeGeometry::Pixelate) {
        const int block = std::clamp(g.block, kMinPixelateBlock, kMaxPixelateBlock);
        const QPoint offset = pixelateOffset(g.seed, block);
        const int x0 = offset.x() + floorDiv(a.left() - offset.x(), block) * block;
        const int y0 = offset.y() + floorDiv(a.top() - offset.y(), block) * block;
        const int x1 = offset.x() + (floorDiv(a.right() - offset.x(), block) + 1) * block - 1;
        const int y1 = offset.y() + (floorDiv(a.bottom() - offset.y(), block) + 1) * block - 1;
        return QRect(QPoint(x0, y0), QPoint(x1, y1)).intersected(picture);
    }
    if (g.kind == ShapeGeometry::Blur) {
        const int margin = blurMargin(g.radius);
        return a.adjusted(-margin, -margin, margin, margin).intersected(picture);
    }
    return a;
}

bool applyRegion(QImage *image, const ShapeGeometry &g, const QPoint &origin)
{
    switch (g.kind) {
    case ShapeGeometry::Redact:
        redactArea(image, g.area, g.color, origin);
        return true;
    case ShapeGeometry::Pixelate:
        pixelateArea(image, g.area, g.block, g.seed, origin);
        return true;
    case ShapeGeometry::Blur:
        blurArea(image, g.area, g.radius, origin);
        return true;
    default:
        return false;
    }
}

} // namespace screenshot
