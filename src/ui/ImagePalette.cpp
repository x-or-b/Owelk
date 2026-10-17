#include "ImagePalette.h"
#include <algorithm>
#include <array>
#include <cmath>

namespace {
struct Lab {
    double L, a, b;
};
double toLinear(double c)
{
    return c <= .04045 ? c / 12.92 : std::pow((c + .055) / 1.055, 2.4);
}
double fromLinear(double c)
{
    return c <= .0031308 ? c * 12.92 : 1.055 * std::pow(c, 1 / 2.4) - .055;
}
// OKLab (Björn Ottosson): lightness and hue as people see them, unlike HSL.
Lab oklab(const QColor &c)
{
    const double r = toLinear(c.redF()), g = toLinear(c.greenF()), b = toLinear(c.blueF());
    const double l = std::cbrt(.4122214708 * r + .5363325363 * g + .0514459929 * b);
    const double m = std::cbrt(.2119034982 * r + .6806995451 * g + .1073969566 * b);
    const double s = std::cbrt(.0883024619 * r + .2817188376 * g + .6299787005 * b);
    return {.2104542553 * l + .7936177850 * m - .0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + .4505937099 * s,
        .0259040371 * l + .7827717662 * m - .8086757660 * s};
}
// The sRGB channels of an OKLab color; false when it is outside what a screen shows.
bool rgb(const Lab &lab, double out[3])
{
    const double l = std::pow(lab.L + .3963377774 * lab.a + .2158037573 * lab.b, 3);
    const double m = std::pow(lab.L - .1055613458 * lab.a - .0638541728 * lab.b, 3);
    const double s = std::pow(lab.L - .0894841775 * lab.a - 1.2914855480 * lab.b, 3);
    const double linear[3] = {4.0767416621 * l - 3.3077115913 * m + .2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - .3413193965 * s, -.0041960863 * l - .7034186147 * m + 1.7076147010 * s};
    bool inside = true;
    for (int i = 0; i < 3; ++i) {
        inside = inside && linear[i] >= -1e-4 && linear[i] <= 1 + 1e-4;
        out[i] = fromLinear(std::clamp(linear[i], 0.0, 1.0));
    }
    return inside;
}
}

namespace ImagePalette {
Colors extract(const QImage &source)
{
    if (source.isNull()) return {};
    // A thumbnail is plenty for colors.
    const auto image = (source.width() > 128 || source.height() > 128
            ? source.scaled(128, 128, Qt::KeepAspectRatio, Qt::FastTransformation)
            : source)
                           .convertToFormat(QImage::Format_ARGB32);
    // Vivid pixels by hue, in 10° bins. Each counts by its perceived chroma, so a large vivid area wins
    // over a larger pale one (skin, paper) without a small saturated spot outweighing it.
    constexpr int bins = 36;
    struct Bin {
        double weight = 0, r = 0, g = 0, b = 0;
    };
    std::array<Bin, bins> hues{};
    double total = 0;
    for (int y = 0; y < image.height(); ++y) {
        const auto *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
        for (int x = 0; x < image.width(); ++x) {
            const QRgb px = line[x];
            if (qAlpha(px) < 200) continue; // the transparent cut-out around a character, its soft edge
            const QColor color = QColor::fromRgb(px);
            const auto lab = oklab(color);
            const double chroma = std::hypot(lab.a, lab.b);
            // Grays, black outlines and white are not colors of the picture.
            if (chroma < .04 || lab.L < .25 || lab.L > .97) continue;
            auto &bin = hues[std::min(bins - 1, int(color.hslHueF() * bins))];
            bin.weight += chroma;
            bin.r += color.redF() * chroma;
            bin.g += color.greenF() * chroma;
            bin.b += color.blueF() * chroma;
            total += chroma;
        }
    }
    if (total <= 0) return {};
    // Peaks of the hue histogram (half the neighbours added, so a broad area counts). A swatch is the
    // peak bin's own color, not mixed with the next hue, and its neighbours are then set aside so the
    // next swatch is a different color.
    Colors colors;
    while (colors.swatches.size() < 6) {
        int best = -1;
        double bestScore = 0;
        for (int i = 0; i < bins; ++i) {
            if (hues[i].weight <= 0) continue;
            const double score
                = hues[i].weight + (hues[(i + bins - 1) % bins].weight + hues[(i + 1) % bins].weight) / 2;
            if (score > bestScore) bestScore = score, best = i;
        }
        if (best < 0 || bestScore < total * .02) break;
        const auto &bin = hues[best];
        colors.swatches.append(QColor::fromRgbF(bin.r / bin.weight, bin.g / bin.weight, bin.b / bin.weight));
        for (int d = -1; d <= 1; ++d) hues[(best + d + bins) % bins] = Bin{};
    }
    if (!colors.swatches.isEmpty()) colors.main = colors.swatches.first();
    return colors;
}

QColor tint(const QColor &gray, const QColor &hueOf, qreal chroma)
{
    const auto base = oklab(gray), hue = oklab(hueOf);
    const double length = std::hypot(hue.a, hue.b);
    if (length < 1e-6 || chroma <= 0) return gray;
    double c = chroma, out[3];
    // Less chroma where the screen cannot show that much at this lightness (near white or black).
    for (int i = 0; i < 20 && !rgb({base.L, hue.a / length * c, hue.b / length * c}, out); ++i) c *= .8;
    return QColor::fromRgbF(out[0], out[1], out[2]);
}
}
