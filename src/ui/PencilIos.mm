#include "Pencil.h"

#import <UIKit/UIKit.h>

namespace {
QString actionName(UIPencilPreferredAction action)
{
    switch (action) {
    case UIPencilPreferredActionSwitchPrevious:
        return QStringLiteral("previous");
    case UIPencilPreferredActionSwitchEraser:
        return QStringLiteral("eraser");
    case UIPencilPreferredActionShowColorPalette:
        return QStringLiteral("colors");
    case UIPencilPreferredActionShowInkAttributes:
        return QStringLiteral("ink");
    default:
        break;
    }
    if (@available(iOS 17.5, *)) {
        if (action == UIPencilPreferredActionShowContextualPalette) return QStringLiteral("palette");
        if (action == UIPencilPreferredActionRunSystemShortcut) return QStringLiteral("shortcut");
    }
    return QStringLiteral("ignore");
}
}

@interface OwelkPencilDelegate : NSObject <UIPencilInteractionDelegate>
@property (nonatomic, assign) Pencil *owner;
@end

@implementation OwelkPencilDelegate
- (void)report:(UIPencilHoverPose *)pose squeeze:(bool)squeeze API_AVAILABLE(ios(17.5))
{
    const bool hovering = pose != nil;
    const CGPoint at = hovering ? pose.location : CGPointZero;
    const QPointF position(at.x, at.y);
    if (squeeze)
        emit self.owner->squeezed(position, hovering);
    else
        emit self.owner->tapped(position, hovering);
}
- (void)pencilInteraction:(UIPencilInteraction *)interaction
            didReceiveTap:(UIPencilInteractionTap *)tap API_AVAILABLE(ios(17.5))
{
    [self report:tap.hoverPose squeeze:false];
}
- (void)pencilInteraction:(UIPencilInteraction *)interaction
        didReceiveSqueeze:(UIPencilInteractionSqueeze *)squeeze API_AVAILABLE(ios(17.5))
{
    // Once, when the squeeze lets go (as Apple's own apps do).
    if (squeeze.phase == UIPencilInteractionPhaseEnded) [self report:squeeze.hoverPose squeeze:true];
}
@end

// Owned here (manual reference counting, as the other Objective-C++ files).
struct PencilNative {
    UIPencilInteraction *interaction = nil;
    OwelkPencilDelegate *delegate = nil;
    id observer = nil;
};

Pencil::Pencil(QObject *parent) : QObject(parent) { }

Pencil::~Pencil()
{
    auto *native = static_cast<PencilNative *>(m_native);
    if (!native) return;
    if (native->interaction.view) [native->interaction.view removeInteraction:native->interaction];
    [native->interaction release];
    [native->delegate release];
    if (native->observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:native->observer];
        [native->observer release];
    }
    delete native;
}

void Pencil::attach(QWindow *window)
{
    m_window = window;
    if (!window || m_native) return;
    if (@available(iOS 17.5, *)) {
        UIView *view = reinterpret_cast<UIView *>(window->winId());
        if (!view) return;
        auto *native = new PencilNative;
        native->delegate = [[OwelkPencilDelegate alloc] init];
        native->delegate.owner = this;
        native->interaction = [[UIPencilInteraction alloc] initWithDelegate:native->delegate];
        [view addInteraction:native->interaction];
        // The reader may change what the gestures do while Owelk runs (Settings › Apple Pencil).
        native->observer =
            [[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                               object:nil
                                                                queue:[NSOperationQueue mainQueue]
                                                           usingBlock:^(NSNotification *) {
                                                               emit preferencesChanged();
                                                           }] retain];
        m_native = native;
    }
}

QString Pencil::tapAction() const
{
    return actionName(UIPencilInteraction.preferredTapAction);
}

QString Pencil::squeezeAction() const
{
    if (@available(iOS 17.5, *)) return actionName(UIPencilInteraction.preferredSqueezeAction);
    return QStringLiteral("ignore");
}
