#include "TitleBar.h"

#include <QGuiApplication>
#include <QHash>
#include <QRectF>
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
        // An empty compact toolbar makes the title bar a little taller and keeps the traffic lights centred in it.
        if (!native.toolbar) {
            // Built without ARC: the window keeps the toolbar, the pool lets go of this reference.
            NSToolbar *toolbar = [[[NSToolbar alloc] initWithIdentifier:@"OwelkTitleBar"] autorelease];
            toolbar.showsBaselineSeparator = NO;
            native.toolbar = toolbar;
            native.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
            native.titleVisibility = NSWindowTitleHidden;
        }
        native.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        const auto rgb = color.toRgb();
        native.backgroundColor = [NSColor colorWithSRGBRed:rgb.redF() green:rgb.greenF() blue:rgb.blueF() alpha:1];
    }
}


namespace {
struct DragArea {
    qreal height = 0;
    QList<QRectF> controls;
};
QHash<QWindow *, DragArea> &dragAreas()
{
    static QHash<QWindow *, DragArea> areas;
    return areas;
}
id dragMonitor = nil;

// A left press in a window with a drag area: moved (or zoomed) here and swallowed, or passed on to Qt.
NSEvent *titleBarPress(NSEvent *event)
{
    NSWindow *target = event.window;
    if (!target) return event;
    for (auto it = dragAreas().cbegin(); it != dragAreas().cend(); ++it) {
        NSView *view = reinterpret_cast<NSView *>(it.key()->winId());
        if (view.window != target) continue;
        if (target.styleMask & NSWindowStyleMaskFullScreen) return event;
        const NSPoint at = [view convertPoint:event.locationInWindow fromView:nil];
        const QPointF point(at.x, view.isFlipped ? at.y : view.bounds.size.height - at.y);
        if (point.y() < 0 || point.y() > it->height) return event;
        // The traffic lights and anything else AppKit draws over Owelk's own view keep their clicks.
        NSView *hit = [target.contentView.superview hitTest:event.locationInWindow];
        if (hit != view && ![hit isDescendantOf:view]) return event;
        for (const auto &control : it->controls)
            if (control.contains(point)) return event;
        // A click on the bar of a window behind others brings it forward, as a title bar does.
        if (!NSApp.isActive) {
            if (@available(macOS 14.0, *))
                [NSApp activate];
            else
                [NSApp activateIgnoringOtherApps:YES];
        }
        [target makeKeyAndOrderFront:nil];
        if (event.clickCount >= 2) {
            NSString *action = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleActionOnDoubleClick"];
            if ([action isEqualToString:@"Minimize"])
                [target performMiniaturize:nil];
            else if (![action isEqualToString:@"None"])
                [target performZoom:nil];
            return nil;
        }
        [target performWindowDragWithEvent:event];
        return nil;
    }
    return event;
}
}

void WindowChrome::setDragArea(QWindow *window, qreal height, const QVariantList &controls)
{
    if (!window || QGuiApplication::platformName() != QLatin1String("cocoa")) return;
    DragArea area;
    area.height = height;
    for (const auto &value : controls) {
        const auto rect = value.toMap();
        area.controls << QRectF(rect.value("x").toDouble(), rect.value("y").toDouble(), rect.value("width").toDouble(),
            rect.value("height").toDouble());
    }
    if (!dragAreas().contains(window))
        QObject::connect(window, &QObject::destroyed, [window] { dragAreas().remove(window); });
    dragAreas().insert(window, area);
    if (!dragMonitor)
        dragMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                                            handler:^NSEvent *(NSEvent *event) {
                                                                return titleBarPress(event);
                                                            }];
}
