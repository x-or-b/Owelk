import QtQuick
import Owelk.Ui

// What opens a context menu: a right click, or a finger held still for a moment. (A touch has no buttons, so a
// plain right-button TapHandler would take every finger tap.) point.position: where, in the parent.
TapHandler {
    id: root
    signal requested(var point)
    acceptedButtons: Qt.RightButton
    longPressThreshold: 0.45
    onTapped: function(eventPoint, button) { if (button === Qt.RightButton) root.requested(eventPoint) }
    onLongPressed: {
        const at = {position: root.point.position}
        // The held finger is the menu's now: what else holds it (a button, a row) does not click when it lifts.
        if (root.point.device && root.point.device.type === PointerDevice.TouchScreen) Theme.cancelTouches()
        root.requested(at)
    }
}
