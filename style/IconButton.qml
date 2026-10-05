import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

// Icon-only button. `description` is shown on hover and read by screen readers;
// a colored `swatch` bar under the glyph shows a tool's current ink.
ToolButton {
    id: root
    property string description: ""
    property color swatch: "transparent"
    // Glyph color; Theme.danger for destructive actions.
    property color tint: Theme.icon
    property int glyphSize: Theme.iconSize
    // The one main action of an area (Send): a round accent button.
    property bool primary: false
    implicitWidth: Theme.iconButton
    implicitHeight: Theme.iconButton
    padding: 0
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    Accessible.name: description
    T.ToolTip.visible: hovered && description.length > 0
    T.ToolTip.delay: 500
    T.ToolTip.text: description
    background: Rectangle {
        radius: root.primary ? height / 2 : Theme.radiusSmall
        color: root.primary ? (!root.enabled ? Theme.control : root.down || root.hovered ? Theme.accentHover : Theme.accent)
            : root.checked ? Theme.selected : root.down ? Theme.pressed : root.hovered ? Theme.hover : "transparent"
        border.width: root.visualFocus ? 2 : 0
        border.color: Theme.focus
    }
    contentItem: Item {
        Icon {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: root.swatch.a > 0 ? -1 : 0
            name: root.icon.name
            size: root.glyphSize
            color: !root.enabled ? Theme.textDisabled : root.primary ? Theme.onAccent : root.checked ? Theme.selectedText : root.tint
        }
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            anchors.horizontalCenter: parent.horizontalCenter
            width: 12; height: 2; radius: 1
            color: root.swatch
            visible: root.swatch.a > 0
        }
    }
}
