#include "MathRenderer.h"

#include "latex.h"
#include "platform/qt/graphic_qt.h"

#include <QCryptographicHash>
#include <QHash>
#include <QMutex>
#include <QPainter>
#include <list>

namespace {
// Images are drawn at this multiple of their shown size.
constexpr int scale = 2;
// About this many bytes of images are kept; the oldest go first.
constexpr qsizetype budget = 48 * 1024 * 1024;

QMutex mutex;
QHash<QString, QImage> images;
std::list<QString> order; // Oldest first.
qsizetype used = 0;
// Small and kept for the session (unlike the images): copying a formula needs its LaTeX.
QHash<QString, QString> sources;

void keep(const QString &key, const QImage &image)
{
    QMutexLocker lock(&mutex);
    if (images.contains(key)) return;
    images.insert(key, image);
    order.push_back(key);
    used += image.sizeInBytes();
    while (used > budget && order.size() > 1) {
        used -= images.take(order.front()).sizeInBytes();
        order.pop_front();
    }
}
} // namespace

namespace MathRenderer {
QString render(const QString &latex, bool display, int pixelSize, const QColor &color, QSize *size)
{
    const auto formula = latex.trimmed();
    if (formula.isEmpty() || formula.size() > 4000) return {};
    const auto key = QString::fromLatin1(QCryptographicHash::hash(
        (formula + QChar(0) + (display ? "d" : "i") + QString::number(pixelSize) + color.name(QColor::HexArgb))
            .toUtf8(),
        QCryptographicHash::Sha1)
            .toHex()
            .left(24));
    {
        QMutexLocker lock(&mutex);
        if (sources.size() < 50000) sources.insert(key, display ? "$$" + formula + "$$" : "$" + formula + "$");
        if (images.contains(key)) {
            const auto &image = images[key];
            *size = QSize(image.width() / scale, image.height() / scale);
            return key;
        }
    }
    static const bool ready = [] {
        // The fonts are Qt resources (":/res/fonts/..."), where MicroTeX looks when "res" is not on disk.
        tex::LaTeX::init("res");
        return true;
    }();
    Q_UNUSED(ready);
    try {
        // MicroTeX sizes in points on a 96 dpi image; TeX fonts read a little small beside UI text.
        const float points = pixelSize * 0.75f * (display ? 1.3f : 1.2f) * scale;
        const auto argb = color.rgba();
        std::unique_ptr<tex::TeXRender> laid(tex::LaTeX::parse(
            (display ? L"\\displaystyle " : L"") + formula.toStdWString(), 100000, points, points / 3.f, argb));
        if (!laid || laid->getWidth() <= 0 || laid->getHeight() <= 0) return {};
        const int pad = scale; // Room for antialiased edges.
        QImage image(laid->getWidth() + 2 * pad, laid->getHeight() + 2 * pad, QImage::Format_ARGB32_Premultiplied);
        image.fill(Qt::transparent);
        {
            QPainter painter(&image);
            painter.setRenderHints(QPainter::Antialiasing | QPainter::TextAntialiasing);
            tex::Graphics2D_qt graphics(&painter);
            laid->draw(graphics, pad, pad);
        }
        *size = QSize((image.width() + scale - 1) / scale, (image.height() + scale - 1) / scale);
        keep(key, image);
        return key;
    } catch (const std::exception &) {
        return {};
    }
}

QImage cached(const QString &key)
{
    QMutexLocker lock(&mutex);
    return images.value(key);
}

QString source(const QString &key)
{
    QMutexLocker lock(&mutex);
    return sources.value(key);
}
} // namespace MathRenderer
