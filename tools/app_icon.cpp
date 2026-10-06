// Regenerates the application icons from the brush mark (resources/app/owelk-mark.png, transparent).
// The mark sits on a white rounded tile (macOS icon grid); small sizes get a slightly thicker stroke
// so the brush line stays visible at 16-32 px.
//
//   c++ -std=c++20 tools/app_icon.cpp $(pkg-config --cflags --libs Qt6Gui) -o /tmp/app_icon
//   (Homebrew: -F/opt/homebrew/lib -framework QtCore -framework QtGui
//    -I/opt/homebrew/lib/QtCore.framework/Headers -I/opt/homebrew/lib/QtGui.framework/Headers)
//   QT_QPA_PLATFORM=offscreen /tmp/app_icon resources/app
//   iconutil -c icns resources/app/owelk.iconset -o resources/app/owelk.icns && rm -r resources/app/owelk.iconset
//
// Writes owelk.iconset/ (macOS), owelk.ico (Windows, PNG entries), owelk.png (512 px, Linux and the
// window icon).
#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QtEndian>
#include <cstdio>

static QImage render(const QImage &mark, int size)
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
    paper.setColorAt(0, QColor("#ffffff"));
    paper.setColorAt(1, QColor("#f2f4f7"));
    p.fillPath(tilePath, paper);
    p.setPen(QPen(QColor(0, 0, 0, small ? 40 : 22), qMax(1.0, size / 512.0)));
    p.drawPath(tilePath);
    // The mark: its ink spans ~87% of the source square; scale it to ~72% of the tile (80% when small).
    const qreal markSize = tile * (small ? .80 : .72) / .87;
    const QRectF target(box.center().x() - markSize / 2, box.center().y() - markSize / 2, markSize, markSize);
    const QImage scaled = mark.scaled(qCeil(markSize), qCeil(markSize), Qt::KeepAspectRatio, Qt::SmoothTransformation);
    const qreal thicken = small ? qMax(.35, size / 64.0) : 0;
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
    const QImage mark(out.filePath("owelk-mark.png"));
    if (mark.isNull()) {
        fprintf(stderr, "missing owelk-mark.png\n");
        return 1;
    }
    out.mkpath("owelk.iconset");
    for (const int base : {16, 32, 128, 256, 512}) {
        render(mark, base).save(out.filePath(QString("owelk.iconset/icon_%1x%1.png").arg(base)));
        render(mark, base * 2).save(out.filePath(QString("owelk.iconset/icon_%1x%1@2x.png").arg(base)));
    }
    render(mark, 512).save(out.filePath("owelk.png"));
    // ICO with PNG entries (Windows Vista and later).
    const QList<int> sizes{16, 24, 32, 48, 64, 128, 256};
    QList<QByteArray> images;
    for (const int size : sizes) images << png(render(mark, size));
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
