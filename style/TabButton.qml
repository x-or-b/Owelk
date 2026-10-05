import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// One segment. With `icon.name` and no text it shows the icon; ToolTip.text describes it.
T.TabButton {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    padding: 2
    horizontalPadding: 8
    font.pixelSize: Theme.fontSmall
    hoverEnabled: true
    T.ToolTip.visible: hovered && T.ToolTip.text.length > 0
    T.ToolTip.delay: 500
    contentItem: Item {
        implicitWidth: control.icon.name.length && !control.text.length ? glyph.implicitWidth : label.implicitWidth
        implicitHeight: Math.max(glyph.implicitHeight, label.implicitHeight)
        Icon {
            id: glyph
            anchors.centerIn: parent
            visible: control.icon.name.length > 0 && !control.text.length
            name: control.icon.name
            color: control.checked ? Theme.text : Theme.textSecondary
        }
        Text {
            id: label
            anchors.fill: parent
            visible: control.text.length > 0
            text: control.text
            font: control.font
            color: !control.enabled ? Theme.textDisabled : control.checked ? Theme.text : Theme.textSecondary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    background: Rectangle {
        implicitHeight: Theme.controlHeight - 4
        radius: Theme.radius - 2
        color: control.checked ? (Theme.dark ? Theme.mix(Theme.control, Theme.text, .16) : Theme.content) : control.hovered ? Theme.hover : "transparent"
        border.width: control.checked && !Theme.dark ? 1 : control.visualFocus ? 2 : 0
        border.color: control.visualFocus ? Theme.focus : Theme.separator
    }
}
