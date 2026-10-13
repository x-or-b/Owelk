#include "TitleBar.h"

#include <QGuiApplication>
#include <QWindow>
#include <dwmapi.h>

// DWM window attributes (dwmapi.h of older SDKs lacks the names).
namespace {
constexpr DWORD useImmersiveDarkMode = 20; // Windows 10 20H1 and later
constexpr DWORD captionColor = 35; // Windows 11
constexpr DWORD textColor = 36; // Windows 11
}

void TitleBar::follow(QWindow *window, const QColor &color, bool dark)
{
    if (!window || QGuiApplication::platformName() != QLatin1String("windows")) return;
    const auto hwnd = reinterpret_cast<HWND>(window->winId());
    const BOOL darkMode = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, useImmersiveDarkMode, &darkMode, sizeof(darkMode));
    // Ignored before Windows 11, where the light or dark look above is what changes.
    const auto rgb = color.toRgb();
    const COLORREF caption = RGB(rgb.red(), rgb.green(), rgb.blue());
    DwmSetWindowAttribute(hwnd, captionColor, &caption, sizeof(caption));
    const COLORREF text = dark ? RGB(0xf2, 0xf2, 0xf2) : RGB(0x1d, 0x1d, 0x1f);
    DwmSetWindowAttribute(hwnd, textColor, &text, sizeof(text));
}
