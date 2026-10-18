#import <AppKit/AppKit.h>

bool swipeTrackingEnabled()
{
    return [NSEvent isSwipeTrackingFromScrollEventsEnabled];
}
