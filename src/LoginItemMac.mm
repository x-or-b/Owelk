#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

// Owelk's own bundle as a login item (macOS 13 and later): 1 on, 0 off, 2 asked for but waiting for the user to
// allow it in System Settings, -1 when it cannot be one (an older macOS, or a binary outside a bundle).
int loginItemState()
{
    if (@available(macOS 13.0, *)) {
        @autoreleasepool {
            if (!NSBundle.mainBundle.bundleIdentifier) return -1;
            switch (SMAppService.mainAppService.status) {
            case SMAppServiceStatusEnabled:
                return 1;
            case SMAppServiceStatusRequiresApproval:
                return 2;
            default:
                return 0;
            }
        }
    }
    return -1;
}

void loginItemSet(bool on)
{
    if (@available(macOS 13.0, *)) {
        @autoreleasepool {
            SMAppService *service = SMAppService.mainAppService;
            NSError *error = nil;
            if (on)
                [service registerAndReturnError:&error];
            else
                [service unregisterAndReturnError:&error];
            // Turned off in System Settings before: only the user can allow it again, there.
            if (on && service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
        }
    }
}
