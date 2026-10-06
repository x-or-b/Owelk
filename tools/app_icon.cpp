// Regenerates the application icons from the brush mark (resources/app/owelk-mark.png, transparent).
// The mark is recoloured and thickened (the circle more than the smile), then set on a rounded tile
// (macOS icon grid); small sizes get a little more weight so the brush line stays visible at 16-32 px.
//
//   c++ -std=c++20 tools/app_icon.cpp $(pkg-config --cflags --libs Qt6Gui) -o /tmp/app_icon
//   (Homebrew: -F/opt/homebrew/lib -framework QtCore -framework QtGui
//    -I/opt/homebrew/lib/QtCore.framework/Headers -I/opt/homebrew/lib/QtGui.framework/Headers)
//   QT_QPA_PLATFORM=offscreen /tmp/app_icon resources/app
//   QT_QPA_PLATFORM=offscreen /tmp/app_icon resources/app --sheet /tmp/options.png   (colour options only)
//   iconutil -c icns resources/app/owelk.iconset -o resources/app/owelk.icns && rm -r resources/app/owelk.iconset
//
// Writes owelk.iconset/ (macOS), owelk.ico (Windows, PNG entries), owelk.png (512 px, Linux and the
// window icon) and owelk-<palette>.png for the other icon choices.
#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QtEndian>
#include <cstdio>

// Colours: the stroke and the tile (top to bottom). The first is the app's own icon; the others can
// be chosen in Settings → Appearance (owelk-<id>.png).
struct Palette {
    QString id, name;
    QColor stroke, top, bottom;
};
static const QList<Palette> palettes{
    {"paper", "Ink on paper", QColor("#1d3a5c"), QColor("#fbf8f2"), QColor("#f1ebdf")},
    {"white", "Navy on white", QColor("#0b2f55"), QColor("#ffffff"), QColor("#f2f4f7")},
    {"navy", "Paper on navy", QColor("#f4efe4"), QColor("#24476e"), QColor("#183353")},
};

// The mark's pixels grown by `radius` (drawn at offsets over a disk).
static QImage dilate(const QImage &image, int radius)
{
    QImage out(image.size(), QImage::Format_ARGB32_Premultiplied);
    out.fill(Qt::transparent);
    QPainter p(&out);
    p.drawImage(0, 0, image);
    for (int r = 1; r <= radius; ++r) {
        const int steps = 8 * r;
        for (int i = 0; i < steps; ++i) {
            const qreal angle = i * 2 * M_PI / steps;
            p.drawImage(QPointF(r * qCos(angle), r * qSin(angle)), image);
        }
    }
    return out;
}

// Recoloured, with the outer circle grown more than the smile inside it.
static QImage prepare(const QImage &source, const QColor &stroke)
{
    QImage mark = source.convertToFormat(QImage::Format_ARGB32);
    // Faint specks in the scan would grow into marks: keep only real ink.
    for (int y = 0; y < mark.height(); ++y) {
        auto *line = reinterpret_cast<QRgb *>(mark.scanLine(y));
        for (int x = 0; x < mark.width(); ++x)
            if (qAlpha(line[x]) < 70) line[x] = 0;
    }
    mark = mark.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    const QPointF centre(mark.width() / 2.0, mark.height() / 2.0);
    const qreal inner = mark.width() * .33;
    QImage ring = mark, smile = mark;
    {
        QPainter p(&ring);
        p.setCompositionMode(QPainter::CompositionMode_Clear);
        p.setRenderHint(QPainter::Antialiasing);
        p.drawEllipse(centre, inner, inner);
    }
    {
        QPainter p(&smile);
        p.setCompositionMode(QPainter::CompositionMode_DestinationIn);
        p.setRenderHint(QPainter::Antialiasing);
        p.setBrush(Qt::black);
        p.drawEllipse(centre, inner, inner);
    }
    const int unit = mark.width() / 1024 + 1;
    QImage grown(mark.size(), QImage::Format_ARGB32_Premultiplied);
    grown.fill(Qt::transparent);
    {
        QPainter p(&grown);
        p.drawImage(0, 0, dilate(ring, 12 * unit));
        p.drawImage(0, 0, dilate(smile, 3 * unit));
        p.setCompositionMode(QPainter::CompositionMode_SourceIn);
        p.fillRect(grown.rect(), stroke);
    }
    return grown;
}

static QImage render(const QImage &mark, int size, const Palette &palette)
{
    QImage icon(size, size, QImage::Format_ARGB32_Premultiplied);
    icon.fill(Qt::transparent);
    QPainter p(&icon);
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::SmoothPixmapTransform);
    const bool small = size <= 64;
    // macOS grid: an 824/1024 tile with a soft shadow; small sizes use nearly the whole square.
    const qreal inset = small ? size * .04 : size * 100.0 / 1024, tile = size - 2 * inset;
    const QRectF box(inset, small ? inset : inset - size * 6.0 / 1024, tile, tile);
    const qreal radius = tile * .225;
    if (!small) {
        for (int i = 6; i >= 1; --i) {
            const qreal spread = size * i * 2.5 / 1024;
            QPainterPath shadow;
            shadow.addRoundedRect(
                box.adjusted(-spread, -spread + size * 8.0 / 1024, spread, spread + size * 10.0 / 1024),
                radius + spread, radius + spread);
            p.fillPath(shadow, QColor(0, 0, 0, 7));
        }
    }
    QPainterPath tilePath;
    tilePath.addRoundedRect(box, radius, radius);
    QLinearGradient paper(box.topLeft(), box.bottomLeft());
    paper.setColorAt(0, palette.top);
    paper.setColorAt(1, palette.bottom);
    p.fillPath(tilePath, paper);
    p.setPen(QPen(QColor(0, 0, 0, small ? 40 : 22), qMax(1.0, size / 512.0)));
    p.drawPath(tilePath);
    // The mark: its ink spans ~87% of the source square; scale it to ~72% of the tile (80% when small).
    const qreal markSize = tile * (small ? .80 : .72) / .87;
    const QRectF target(box.center().x() - markSize / 2, box.center().y() - markSize / 2, markSize, markSize);
    const QImage scaled = mark.scaled(qCeil(markSize), qCeil(markSize), Qt::KeepAspectRatio, Qt::SmoothTransformation);
    const qreal thicken = small ? qMax(.2, size / 128.0) : 0;
    const int steps = thicken > 0 ? 8 : 1;
    for (int i = 0; i < steps; ++i) {
        const qreal angle = i * 2 * M_PI / steps;
        p.drawImage(target.topLeft() + QPointF(thicken * qCos(angle), thicken * qSin(angle)), scaled);
    }
    return icon;
}

static QByteArray png(const QImage &image)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "usage: app_icon <resources/app>\n");
        return 1;
    }
    const QDir out(argv[1]);
    const QImage source(out.filePath("owelk-mark.png"));
    if (source.isNull()) {
        fprintf(stderr, "missing owelk-mark.png\n");
        return 1;
    }
    if (argc > 3 && QString(argv[2]) == "--mark") return prepare(source, palettes[0].stroke).save(argv[3]) ? 0 : 1;
    if (argc > 3 && QString(argv[2]) == "--sheet") {
        // Every palette at 256 px and 32 px, side by side, for choosing.
        QImage sheet(palettes.size() * 300 + 20, 340, QImage::Format_ARGB32_Premultiplied);
        sheet.fill(QColor("#e4e6ea"));
        QPainter p(&sheet);
        p.setRenderHint(QPainter::Antialiasing);
        for (qsizetype i = 0; i < palettes.size(); ++i) {
            const auto mark = prepare(source, palettes[i].stroke);
            p.drawImage(QPointF(20 + i * 300, 10), render(mark, 256, palettes[i]));
            p.drawImage(QPointF(20 + i * 300 + 112, 270), render(mark, 32, palettes[i]));
            p.setPen(QColor("#333"));
            p.drawText(QRectF(20 + i * 300, 310, 256, 24), Qt::AlignCenter,
                QString("%1. %2").arg(i + 1).arg(palettes[i].name));
        }
        return sheet.save(argv[3]) ? 0 : 1;
    }
    const auto &palette = palettes[0];
    const auto mark = prepare(source, palette.stroke);
    out.mkpath("owelk.iconset");
    for (const int base : {16, 32, 128, 256, 512}) {
        render(mark, base, palette).save(out.filePath(QString("owelk.iconset/icon_%1x%1.png").arg(base)));
        render(mark, base * 2, palette).save(out.filePath(QString("owelk.iconset/icon_%1x%1@2x.png").arg(base)));
    }
    render(mark, 512, palette).save(out.filePath("owelk.png"));
    for (qsizetype i = 1; i < palettes.size(); ++i)
        render(prepare(source, palettes[i].stroke), 512, palettes[i]).save(out.filePath("owelk-" + palettes[i].id + ".png"));
    // ICO with PNG entries (Windows Vista and later).
    const QList<int> sizes{16, 24, 32, 48, 64, 128, 256};
    QList<QByteArray> images;
    for (const int size : sizes) images << png(render(mark, size, palette));
    QByteArray ico(6, 0);
    qToLittleEndian<quint16>(1, ico.data() + 2);
    qToLittleEndian<quint16>(sizes.size(), ico.data() + 4);
    quint32 offset = 6 + 16 * sizes.size();
    for (qsizetype i = 0; i < sizes.size(); ++i) {
        QByteArray entry(16, 0);
        entry[0] = char(sizes[i] >= 256 ? 0 : sizes[i]);
        entry[1] = char(sizes[i] >= 256 ? 0 : sizes[i]);
        qToLittleEndian<quint16>(1, entry.data() + 4);
        qToLittleEndian<quint16>(32, entry.data() + 6);
        qToLittleEndian<quint32>(images[i].size(), entry.data() + 8);
        qToLittleEndian<quint32>(offset, entry.data() + 12);
        offset += images[i].size();
        ico += entry;
    }
    for (const auto &image : images) ico += image;
    QFile file(out.filePath("owelk.ico"));
    return file.open(QIODevice::WriteOnly) && file.write(ico) == ico.size() ? 0 : 1;
}
