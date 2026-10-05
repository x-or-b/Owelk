import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

T.CheckBox {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)
    padding: 4
    spacing: 8
    font.pixelSize: Theme.fontBody
    hoverEnabled: true
    indicator: Rectangle {
        implicitWidth: Theme.fontBody + 3
        implicitHeight: Theme.fontBody + 3
        x: control.text ? (control.mirrored ? control.width - width - control.rightPadding : control.leftPadding) : control.leftPadding + (control.availableWidth - width) / 2
        y: control.topPadding + (control.availableHeight - height) / 2
        radius: 4
        color: control.checkState !== Qt.Unchecked ? (control.enabled ? Theme.accent : Theme.textDisabled) : Theme.field
        border.width: control.visualFocus ? 2 : control.checkState !== Qt.Unchecked ? 0 : 1
        border.color: control.visualFocus ? Theme.focus : Theme.border
        Icon {
            anchors.centerIn: parent
            visible: control.checkState !== Qt.Unchecked
            name: control.checkState === Qt.Checked ? "check" : "minus"
            size: Theme.fontSmall
            color: Theme.onAccent
        }
    }
    contentItem: CheckLabel {
        leftPadding: control.indicator && !control.mirrored ? control.indicator.width + control.spacing : 0
        rightPadding: control.indicator && control.mirrored ? control.indicator.width + control.spacing : 0
        text: control.text
        font: control.font
        color: control.enabled ? Theme.text : Theme.textDisabled
    }
}
