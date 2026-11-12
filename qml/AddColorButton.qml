import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A round button with + in it, beside color swatches: a color of one's own.
AbstractButton {
    id: control
    property string description
    implicitWidth: Theme.iconButton; implicitHeight: Theme.iconButton
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    ToolTip.visible: hovered && description.length > 0; ToolTip.delay: 500; ToolTip.text: description
    Accessible.name: description
    background: Rectangle {
        anchors.fill: parent; anchors.margins: 3
        radius: width / 2
        color: control.down ? Theme.pressed : control.hovered ? Theme.hover : "transparent"
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? Theme.focus : control.hovered ? Theme.border : Theme.separator
    }
    contentItem: Item { Icon { anchors.centerIn: parent; name: "add"; size: Theme.fontBody; color: Theme.icon } }
}
