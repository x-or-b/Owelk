import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// Flat button for toolbars: no fill until hovered; checked uses the selection color.
T.ToolButton {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    padding: 3
    horizontalPadding: 8
    spacing: 4
    font.pixelSize: Theme.fontBody
    hoverEnabled: true
    icon.width: Theme.iconSize
    icon.height: Theme.iconSize
    contentItem: IconLabel {
        spacing: control.spacing
        mirrored: control.mirrored
        display: control.display
        icon: control.icon
        text: control.text
        font: control.font
        color: !control.enabled ? Theme.textDisabled : control.checked ? Theme.selectedText : control.palette.buttonText
    }
    background: Rectangle {
        implicitWidth: Theme.iconButton
        implicitHeight: Theme.iconButton
        radius: Theme.radiusSmall
        color: control.checked ? Theme.selected : control.down ? Theme.pressed : control.hovered ? Theme.hover : "transparent"
        border.width: control.visualFocus ? 2 : 0
        border.color: Theme.focus
    }
}
