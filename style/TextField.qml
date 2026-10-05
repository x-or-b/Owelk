import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

T.TextField {
    id: control
    implicitWidth: implicitBackgroundWidth + leftInset + rightInset || Math.max(contentWidth, placeholder.implicitWidth) + leftPadding + rightPadding
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, contentHeight + topPadding + bottomPadding, placeholder.implicitHeight + topPadding + bottomPadding)
    padding: 4
    leftPadding: 8
    rightPadding: 8
    font.pixelSize: Theme.fontBody
    color: control.enabled ? Theme.text : Theme.textDisabled
    selectionColor: Theme.mix(Theme.accent, Theme.field, .65)
    selectedTextColor: Theme.text
    placeholderTextColor: Theme.textTertiary
    verticalAlignment: TextInput.AlignVCenter
    selectByMouse: true
    PlaceholderText {
        id: placeholder
        x: control.leftPadding
        y: control.topPadding
        width: control.width - (control.leftPadding + control.rightPadding)
        height: control.height - (control.topPadding + control.bottomPadding)
        text: control.placeholderText
        font: control.font
        color: control.placeholderTextColor
        verticalAlignment: control.verticalAlignment
        visible: !control.length && !control.preeditText && (!control.activeFocus || control.horizontalAlignment !== Qt.AlignHCenter)
        elide: Text.ElideRight
        renderType: control.renderType
    }
    background: Rectangle {
        implicitWidth: 160
        implicitHeight: Theme.controlHeight
        radius: Theme.radius
        color: control.readOnly ? Theme.control : Theme.field
        border.width: control.activeFocus && !control.readOnly ? 2 : 1
        border.color: control.activeFocus && !control.readOnly ? Theme.focus : Theme.border
    }
}
