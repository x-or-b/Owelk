#pragma once

#include <QColor>
#include <QImage>
#include <QList>

// The colors of a picture, for the picture theme. Works on a thumbnail, so any picture takes a few
// milliseconds.
namespace ImagePalette {
struct Colors {
    // The most prominent vivid color; invalid when the picture has none (grayscale, line art).
    QColor main;
    // Distinct vivid colors, most prominent first (main is the first).
    QList<QColor> swatches;
};
Colors extract(const QImage &image);
// gray's perceived lightness with chroma (OKLCH, about 0..0.37) in the hue of hueOf: a theme surface
// tinted toward a color without getting lighter or darker.
QColor tint(const QColor &gray, const QColor &hueOf, qreal chroma);
}
