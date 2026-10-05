import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// An on/off toggle: a pill track (accent when on) and a round knob.
T.Switch {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)
    padding: 4
    spacing: 8
    font.pixelSize: Theme.fontBody
    hoverEnabled: true
    indicator: Rectangle {
        implicitWidth: Math.round(Theme.fontBody * 2.4)
        implicitHeight: Theme.fontBody + 5
        x: control.text ? (control.mirrored ? control.leftPadding : control.width - width - control.rightPadding) : control.leftPadding + (control.availableWidth - width) / 2
        y: control.topPadding + (control.availableHeight - height) / 2
        radius: height / 2
        color: control.checked ? (control.enabled ? Theme.accent : Theme.textDisabled) : Theme.mix(Theme.control, Theme.text, .12)
        border.width: control.visualFocus ? 2 : 0
        border.color: Theme.focus
        Rectangle {
            width: parent.height - 4; height: width; radius: width / 2
            y: 2
            x: control.checked ? parent.width - width - 2 : 2
            color: "#ffffff"
            Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        }
    }
    // The label sits on the left, the toggle on the right (as in macOS settings).
    contentItem: CheckLabel {
        leftPadding: 0
        rightPadding: control.indicator ? control.indicator.width + control.spacing : 0
        text: control.text
        font: control.font
        color: control.enabled ? Theme.text : Theme.textDisabled
    }
}
