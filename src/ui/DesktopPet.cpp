#include "DesktopPet.h"
#include "ResearchStore.h"
#include <QGuiApplication>
#include <QImage>
#include <QImageReader>
#include <QRect>
#include <QScreen>
#include <QSurfaceFormat>
#include <QWindow>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

#ifdef Q_OS_MACOS
// DesktopPetMac.mm
void desktopPetFloatEverywhere(QWindow *window);
bool desktopPetPassThrough(QWindow *window, const QRegion &region);
#endif

DesktopPet::DesktopPet(ResearchStore *store, QObject *parent) : QObject(parent), m_store(store)
{
    if (!m_store) return;
    m_enabled = m_store->setting("pet.enabled") == "1";
    if (const auto size = m_store->setting("pet.size"); size == "small" || size == "large") m_size = size;
    const auto minutes = m_store->setting("pet.breakMinutes", "50").toInt();
    if (minutes == 0 || minutes == 25 || minutes == 90) m_breakMinutes = minutes;
}

void DesktopPet::save(const QString &key, const QString &value)
{
    if (m_store) m_store->setSetting(key, value);
}

void DesktopPet::setEnabled(bool on)
{
    if (on == m_enabled) return;
    m_enabled = on;
    save("pet.enabled", on ? "1" : "0");
    emit changed();
}

void DesktopPet::setSize(const QString &size)
{
    if ((size != "small" && size != "medium" && size != "large") || size == m_size) return;
    m_size = size;
    save("pet.size", size);
    emit changed();
}

void DesktopPet::setBreakMinutes(int minutes)
{
    if ((minutes != 0 && minutes != 25 && minutes != 50 && minutes != 90) || minutes == m_breakMinutes) return;
    m_breakMinutes = minutes;
    save("pet.breakMinutes", QString::number(minutes));
    emit changed();
}

int DesktopPet::height() const
{
    return m_size == "small" ? 120 : m_size == "large" ? 220 : 160;
}

bool DesktopPet::supported()
{
    return !QGuiApplication::platformName().startsWith(QLatin1String("wayland"));
}

QPoint DesktopPet::place(int width, int height) const
{
    const auto saved = m_store ? m_store->setting("pet.position").split(',') : QStringList();
    if (saved.size() == 2) {
        const QRect rect(saved[0].toInt(), saved[1].toInt(), width, height);
        // Still on a screen (one may have been unplugged since).
        for (const auto *screen : QGuiApplication::screens())
            if (screen->availableGeometry().contains(rect.center())) return rect.topLeft();
    }
    const auto *screen = QGuiApplication::primaryScreen();
    const QRect area = screen ? screen->availableGeometry() : QRect(0, 0, 1280, 800);
    return {area.x() + area.width() - width - 24, area.y() + area.height() - height - 24};
}

void DesktopPet::remember(int x, int y)
{
    save("pet.position", QString("%1,%2").arg(x).arg(y));
}

void DesktopPet::prepare(QWindow *window)
{
    if (!window) return;
    auto format = window->requestedFormat();
    format.setAlphaBufferSize(8);
    window->setFormat(format);
    // Qt::Tool windows hide while another app is active on macOS unless asked not to.
    window->setProperty("_q_macAlwaysShowToolWindow", true);
    floatEverywhere(window);
}

void DesktopPet::floatEverywhere(QWindow *window)
{
#ifdef Q_OS_MACOS
    desktopPetFloatEverywhere(window);
#elif defined(Q_OS_WIN)
    if (window && QGuiApplication::platformName() == "windows")
        SetWindowDisplayAffinity(reinterpret_cast<HWND>(window->winId()), 0x00000011 /* WDA_EXCLUDEFROMCAPTURE */);
#else
    Q_UNUSED(window)
#endif
}

QRegion DesktopPet::pictureRegion(const QString &file, const QSize &area, int top, int rise)
{
    QImageReader reader(file);
    const auto fitted = reader.size().scaled(area, Qt::KeepAspectRatio);
    if (fitted.isEmpty()) return {};
    reader.setScaledSize(fitted);
    const auto read = reader.read();
    if (read.isNull() || !read.hasAlphaChannel()) return {};
    const auto image = read.convertToFormat(QImage::Format_ARGB32);
    const QPoint at((area.width() - image.width()) / 2, top + (area.height() - image.height()) / 2);
    // A few points around what is drawn, so its soft edge always takes the click.
    constexpr int margin = 3;
    QRegion region;
    for (int y = 0; y < image.height(); ++y) {
        const auto *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
        for (int x = 0; x < image.width();) {
            if (qAlpha(line[x]) < 16) {
                ++x;
                continue;
            }
            int end = x;
            while (end < image.width() && qAlpha(line[end]) >= 16) ++end;
            region
                += QRect(at.x() + x - margin, at.y() + y - margin - rise, end - x + 2 * margin, 1 + 2 * margin + rise);
            x = end;
        }
    }
    // Nothing drawn at all: the whole window, rather than one that cannot be clicked.
    return region;
}

void DesktopPet::letClicksThrough(QWindow *window, const QUrl &picture, const QSize &area, int top, int rise)
{
    letClicksThroughAll(window, {picture}, area, top, rise);
}

void DesktopPet::letClicksThroughAll(
    QWindow *window, const QVariantList &pictures, const QSize &area, int top, int rise)
{
    if (!window) return;
    QRegion region;
    for (const auto &picture : pictures) {
        const auto shape = pictureRegion(picture.toUrl().toLocalFile(), area, top, rise);
        // A face with no transparency takes clicks everywhere: so does the window.
        if (shape.isEmpty()) {
            region = {};
            break;
        }
        region += shape;
    }
#ifdef Q_OS_MACOS
    // A shape (mask) on macOS clips the drawing but still takes every click in the window's frame.
    if (desktopPetPassThrough(window, region)) return;
#endif
    window->setMask(region);
}
