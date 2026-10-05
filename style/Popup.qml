import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

T.Popup {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, contentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, contentHeight + topPadding + bottomPadding)
    padding: 8
    background: Rectangle {
        radius: Theme.radiusLarge
        color: Theme.raised
        border.color: Theme.border
    }
    T.Overlay.modal: Rectangle { color: Theme.overlay }
    T.Overlay.modeless: Rectangle { color: "transparent" }
}
