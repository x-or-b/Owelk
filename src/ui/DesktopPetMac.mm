#include <QCursor>
#include <QGuiApplication>
#include <QHash>
#include <QPointer>
#include <QRegion>
#include <QWindow>
#import <AppKit/AppKit.h>
#include <objc/message.h>

void desktopPetFloatEverywhere(QWindow *window)
{
    // Only real Cocoa windows (not the offscreen platform tests use).
    if (!window || QGuiApplication::platformName() != QLatin1String("cocoa")) return;
    @autoreleasepool {
        NSWindow *native = reinterpret_cast<NSView *>(window->winId()).window;
        if (!native) return;
        native.collectionBehavior = (native.collectionBehavior & ~NSWindowCollectionBehaviorMoveToActiveSpace)
            | NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorIgnoresCycle;
        native.hidesOnDeactivate = NO;
        native.sharingType = NSWindowSharingNone;
        // A press on it (a drag to move it, too) leaves Owelk in the background: activating Owelk would take the
        // screen to the desktop its window is on. A panel made non-activating after it was created still
        // activates the app, so the window server is told directly as well (as ChatGPT's pet does), where the
        // system has that call.
        if ([native isKindOfClass:[NSPanel class]]) native.styleMask |= NSWindowStyleMaskNonactivatingPanel;
        const SEL prevents = NSSelectorFromString(@"_setPreventsActivation:");
        if ([native respondsToSelector:prevents])
            reinterpret_cast<void (*)(id, SEL, BOOL)>(objc_msgSend)(native, prevents, YES);
        // It stays when Owelk is hidden (Cmd+H).
        native.canHide = NO;
    }
}

namespace {
// Event monitors that let clicks through a pet window, and the part of it that takes them.
struct PassThrough {
    id global = nil, local = nil;
    QRegion region;
};
QHash<QWindow *, PassThrough> &passThroughs()
{
    static QHash<QWindow *, PassThrough> map;
    return map;
}
void stopPassingThrough(QWindow *window)
{
    const auto it = passThroughs().find(window);
    if (it == passThroughs().end()) return;
    // Built without ARC: the monitors were retained when added.
    for (id monitor : {it->global, it->local})
        if (monitor) {
            [NSEvent removeMonitor:monitor];
            [monitor release];
        }
    passThroughs().erase(it);
}
}

// Qt makes a window take every click in its frame, transparent or not, and a shape only clips its
// drawing. So the window ignores the mouse while the pointer is over a transparent part, and takes it
// again over the picture: decided on each mouse move (here or in another app), not by polling. False
// when this is not a Cocoa window (the caller shapes it instead).
bool desktopPetPassThrough(QWindow *window, const QRegion &region)
{
    if (!window || QGuiApplication::platformName() != QLatin1String("cocoa")) return false;
    @autoreleasepool {
        NSWindow *native = reinterpret_cast<NSView *>(window->winId()).window;
        if (!native) return false;
        const bool watched = passThroughs().contains(window);
        stopPassingThrough(window);
        native.ignoresMouseEvents = NO;
        if (region.isEmpty()) return true;
        if (!watched) QObject::connect(window, &QObject::destroyed, [window] { stopPassingThrough(window); });
        auto &entry = passThroughs()[window];
        entry.region = region;
        const QPointer<QWindow> guard(window);
        void (^update)(void) = ^{
            if (!guard) return;
            const auto it = passThroughs().constFind(guard.data());
            if (it == passThroughs().constEnd()) return;
            const bool over = it->region.contains(QCursor::pos() - guard->geometry().topLeft());
            NSWindow *shown = reinterpret_cast<NSView *>(guard->winId()).window;
            if (shown && shown.ignoresMouseEvents == over) shown.ignoresMouseEvents = !over;
        };
        const NSEventMask moves = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged;
        entry.global = [[NSEvent addGlobalMonitorForEventsMatchingMask:moves
                                                               handler:^(NSEvent *) {
                                                                   update();
                                                               }] retain];
        entry.local = [[NSEvent addLocalMonitorForEventsMatchingMask:moves
                                                             handler:^NSEvent *(NSEvent *event) {
                                                                 update();
                                                                 return event;
                                                             }] retain];
        update();
    }
    return true;
}
