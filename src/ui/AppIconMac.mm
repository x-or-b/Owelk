#include "AppIcon.h"

#include <QFile>
#import <AppKit/AppKit.h>

void AppIcon::setBundleIcon(const QString &bundle, const QString &image)
{
    @autoreleasepool {
        NSImage *icon = nil;
        if (!image.isEmpty()) {
            QFile file(image);
            if (!file.open(QIODevice::ReadOnly)) return;
            const auto bytes = file.readAll();
            icon = [[NSImage alloc] initWithData:[NSData dataWithBytes:bytes.constData()
                                                                length:NSUInteger(bytes.size())]];
            if (!icon) return;
        }
        [[NSWorkspace sharedWorkspace] setIcon:icon forFile:bundle.toNSString() options:0];
    }
}
