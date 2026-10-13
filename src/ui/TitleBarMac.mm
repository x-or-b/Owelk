#include "TitleBar.h"

#include <QGuiApplication>
#include <QWindow>
#import <AppKit/AppKit.h>

void TitleBar::follow(QWindow *window, const QColor &color, bool dark)
{
    // Only real Cocoa windows (not the offscreen platform tests and smoke runs use).
    if (!window || QGuiApplication::platformName() != QLatin1String("cocoa")) return;
    @autoreleasepool {
        NSWindow *native = reinterpret_cast<NSView *>(window->winId()).window;
        if (!native) return;
        // A transparent title bar shows the window's background, which takes the theme's colour.
        native.titlebarAppearsTransparent = YES;
        native.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        const auto rgb = color.toRgb();
        native.backgroundColor = [NSColor colorWithSRGBRed:rgb.redF() green:rgb.greenF() blue:rgb.blueF() alpha:1];
    }
}
