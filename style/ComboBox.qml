import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// A pop-up button: the current value and a chevron; the list opens as a rounded popover.
T.ComboBox {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)
    leftPadding: 10
    rightPadding: 10 + (indicator ? indicator.width + spacing : 0)
    spacing: 4
    font.pixelSize: Theme.fontBody
    hoverEnabled: true
    delegate: ItemDelegate {
        required property var model
        required property int index
        width: ListView.view.width
        text: model[control.textRole] !== undefined ? model[control.textRole] : model.modelData !== undefined ? model.modelData : ""
        highlighted: control.highlightedIndex === index
        hoverEnabled: control.hoverEnabled
    }
    indicator: Icon {
        x: control.mirrored ? control.padding : control.width - width - 8
        y: control.topPadding + (control.availableHeight - height) / 2
        name: "down"
        size: Theme.fontBody
        color: control.enabled ? Theme.textSecondary : Theme.textDisabled
    }
    contentItem: T.TextField {
        leftPadding: 0
        rightPadding: 0
        text: control.editable ? control.editText : control.displayText
        enabled: control.editable
        autoScroll: control.editable
        readOnly: control.down
        inputMethodHints: control.inputMethodHints
        validator: control.validator
        selectByMouse: control.selectTextByMouse
        color: control.enabled ? Theme.text : Theme.textDisabled
        selectionColor: Theme.mix(Theme.accent, Theme.field, .65)
        selectedTextColor: Theme.text
        verticalAlignment: Text.AlignVCenter
        font: control.font
    }
    background: Rectangle {
        implicitWidth: 140
        implicitHeight: Theme.controlHeight
        radius: Theme.radius
        color: control.editable ? Theme.field : Theme.control
        border.width: control.visualFocus || control.editable && control.activeFocus ? 2 : Theme.dark && !control.editable ? 0 : 1
        border.color: control.visualFocus || control.editable && control.activeFocus ? Theme.focus : Theme.separator
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            visible: !control.editable
            color: control.pressed ? Theme.pressed : control.hovered ? Theme.hover : "transparent"
        }
    }
    popup: T.Popup {
        y: control.height + 2
        width: Math.max(control.width, contentItem.implicitWidth + leftPadding + rightPadding)
        height: Math.min(contentItem.implicitHeight + topPadding + bottomPadding, control.Window.height - topMargin - bottomMargin)
        topMargin: 6
        bottomMargin: 6
        padding: 4
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            implicitWidth: {
                let widest = 0
                for (let i = 0; i < count; ++i) { const row = itemAtIndex(i); if (row) widest = Math.max(widest, row.implicitWidth) }
                return widest
            }
            model: control.delegateModel
            currentIndex: control.highlightedIndex
            highlightMoveDuration: 0
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle {
            radius: Theme.radiusLarge
            color: Theme.raised
            border.color: Theme.border
        }
    }
}
