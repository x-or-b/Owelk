#include <QGuiApplication>
#include <functional>
#import <AppKit/AppKit.h>
#include <objc/runtime.h>

// AppKit asks the application delegate (Qt's) whether to reopen each time Owelk's Dock icon is clicked or
// Owelk is opened again from Finder while it runs, with its window shown or not. Calls reopened first, then
// Qt's own answer. Only on a real Cocoa desktop, and only once.
void appInstanceWatchReopen(std::function<void()> reopened)
{
    static bool watching = false;
    if (watching || QGuiApplication::platformName() != QLatin1String("cocoa")) return;
    @autoreleasepool {
        id delegate = NSApp.delegate;
        if (!delegate) return;
        watching = true;
        const SEL selector = @selector(applicationShouldHandleReopen:hasVisibleWindows:);
        const Class owner = [delegate class];
        const Method method = class_getInstanceMethod(owner, selector);
        const IMP previous = method ? method_getImplementation(method) : nullptr;
        const IMP watched = imp_implementationWithBlock(^BOOL(id self, NSApplication *application, BOOL visible) {
            reopened();
            if (!previous) return YES;
            return reinterpret_cast<BOOL (*)(id, SEL, NSApplication *, BOOL)>(previous)(
                self, selector, application, visible);
        });
        if (method)
            method_setImplementation(method, watched);
        else
            class_addMethod(owner, selector, watched,
                protocol_getMethodDescription(@protocol(NSApplicationDelegate), selector, NO, YES).types);
    }
}
