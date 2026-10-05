import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// A list row: rounded hover, accent-tinted when highlighted (selected or keyboard-current).
T.ItemDelegate {
    id: control
    // A hairline under the row, inset to the text (lists, as in macOS settings).
    property bool separator: false
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)
    padding: 4
    horizontalPadding: 10
    spacing: 8
    font.pixelSize: Theme.fontBody
    hoverEnabled: true
    icon.width: Theme.iconSize
    icon.height: Theme.iconSize
    contentItem: IconLabel {
        spacing: control.spacing
        mirrored: control.mirrored
        display: control.display
        alignment: control.display === IconLabel.IconOnly || control.display === IconLabel.TextUnderIcon ? Qt.AlignCenter : Qt.AlignLeft
        icon: control.icon
        text: control.text
        font: control.font
        color: !control.enabled ? Theme.textDisabled : control.highlighted ? Theme.selectedText : control.palette.text
    }
    background: Rectangle {
        implicitWidth: 100
        implicitHeight: Theme.rowHeight
        radius: Theme.radiusSmall
        color: control.highlighted ? Theme.selected : control.down ? Theme.pressed : control.hovered ? Theme.hover : "transparent"
        border.width: control.visualFocus ? 2 : 0
        border.color: Theme.focus
        Rectangle {
            visible: control.separator && !control.highlighted
            anchors.bottom: parent.bottom
            anchors.bottomMargin: -1
            x: control.leftPadding; width: parent.width - control.leftPadding - control.rightPadding
            height: 1
            color: Theme.separator
        }
    }
}
