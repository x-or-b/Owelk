import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui
import "LineDelete.js" as LineDelete

T.TextArea {
    id: control
    implicitWidth: Math.max(contentWidth + leftPadding + rightPadding, implicitBackgroundWidth + leftInset + rightInset, placeholder.implicitWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(contentHeight + topPadding + bottomPadding, implicitBackgroundHeight + topInset + bottomInset, placeholder.implicitHeight + topPadding + bottomPadding)
    padding: 8
    font.pixelSize: Theme.fontBody
    color: control.enabled ? Theme.text : Theme.textDisabled
    selectionColor: Theme.mix(Theme.accent, Theme.field, .65)
    selectedTextColor: Theme.text
    placeholderTextColor: Theme.textTertiary
    selectByMouse: true
    Keys.onPressed: function(event) { if (!event.accepted && LineDelete.handle(control, event, true)) event.accepted = true }
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
        implicitWidth: 200
        implicitHeight: 40
        radius: Theme.radius
        color: control.readOnly ? Theme.control : Theme.field
        border.width: control.activeFocus && !control.readOnly ? 2 : 1
        border.color: control.activeFocus && !control.readOnly ? Theme.focus : Theme.border
    }
}
