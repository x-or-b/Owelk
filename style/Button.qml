import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// Push button. `primary` (or `highlighted`) is the main action (accent); `flat` fills only on hover.
// Destructive buttons set palette.buttonText: Theme.danger.
T.Button {
    id: control
    // Text being composed (Korean and the like) is committed before the button acts on it.
    onPressed: Qt.inputMethod.commit()
    property bool primary: false
    readonly property bool accented: primary || highlighted
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    padding: 4
    horizontalPadding: 12
    spacing: 6
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
        color: !control.enabled ? Theme.textDisabled : control.accented ? Theme.onAccent : control.palette.buttonText
        // Cut off (too narrow): the whole text on hover.
        HoverHandler { id: cutHover; enabled: control.text.length > 0 && control.implicitContentWidth > control.availableWidth + 1 }
        T.ToolTip.visible: cutHover.enabled && cutHover.hovered
        T.ToolTip.delay: 500
        T.ToolTip.text: control.text
    }
    background: Rectangle {
        implicitWidth: 64
        implicitHeight: Theme.controlHeight
        radius: Theme.radius
        color: control.accented ? (control.enabled && (control.down || control.hovered) ? Theme.accentHover : control.enabled ? Theme.accent : Theme.control)
            : control.flat ? "transparent" : Theme.control
        border.width: control.visualFocus ? 2 : control.accented || control.flat || Theme.dark ? 0 : 1
        border.color: control.visualFocus ? Theme.focus : Theme.separator
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: !control.accented
            color: control.down ? Theme.pressed : control.hovered || control.checked ? Theme.hover : "transparent"
        }
    }
}
