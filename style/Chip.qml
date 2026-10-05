import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Owelk.Ui

// A small rounded choice: filters, pop-up values (model, effort) and tab groups.
// Checked uses the selection color; `trailingIcon` adds e.g. a chevron for pop-ups.
T.Button {
    id: control
    property string trailingIcon: ""
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    padding: 2
    leftPadding: 9
    rightPadding: trailingIcon.length ? 5 : 9
    font.pixelSize: Theme.fontSmall
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    T.ToolTip.visible: hovered && T.ToolTip.text.length > 0
    T.ToolTip.delay: 500
    contentItem: RowLayout {
        spacing: 2
        Text {
            Layout.fillWidth: true
            text: control.text
            font: control.font
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            color: !control.enabled ? Theme.textDisabled : control.checked ? Theme.selectedText : Theme.textSecondary
        }
        Icon {
            visible: control.trailingIcon.length > 0
            name: control.trailingIcon
            size: Theme.fontSmall
            color: control.checked ? Theme.selectedText : Theme.textTertiary
        }
    }
    background: Rectangle {
        implicitHeight: Theme.controlHeightSmall
        radius: Theme.radius
        color: control.checked ? Theme.selected : control.down ? Theme.pressed : control.hovered ? Theme.hover : "transparent"
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? Theme.focus : control.checked ? Theme.accentBorder : Theme.separator
    }
}
