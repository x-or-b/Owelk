import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

// A thin track with an accent fill and a round knob.
T.Slider {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitHandleWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitHandleHeight + topPadding + bottomPadding)
    padding: 4
    hoverEnabled: true
    handle: Rectangle {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + (control.availableHeight - height) / 2
        implicitWidth: Theme.fontBody + 5
        implicitHeight: implicitWidth
        radius: width / 2
        color: "#ffffff"
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? Theme.focus : Theme.border
    }
    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + (control.availableHeight - height) / 2
        implicitWidth: 160
        implicitHeight: 4
        width: control.availableWidth
        height: implicitHeight
        radius: 2
        color: Theme.mix(Theme.control, Theme.text, .12)
        Rectangle {
            width: control.visualPosition * parent.width
            height: parent.height
            radius: 2
            color: control.enabled ? Theme.accent : Theme.textDisabled
        }
    }
}
