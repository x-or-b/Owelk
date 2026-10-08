import QtQuick
import QtQuick.Controls.impl
import QtQuick.Templates as T
import Owelk.Ui

// A menu row: rounded hover inset in the menu, check mark and submenu chevron as icons.
// Destructive rows set palette.windowText (and text) to Theme.danger.
T.MenuItem {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding,
                             implicitIndicatorHeight + topPadding + bottomPadding)
    padding: 3
    leftPadding: 10
    rightPadding: 10
    spacing: 6
    font.pixelSize: Theme.fontBody
    icon.width: Theme.iconSize
    icon.height: Theme.iconSize
    contentItem: IconLabel {
        readonly property real arrowPadding: control.subMenu && control.arrow ? control.arrow.width + control.spacing : 0
        readonly property real indicatorPadding: control.checkable && control.indicator ? control.indicator.width + control.spacing : 0
        leftPadding: !control.mirrored ? indicatorPadding : arrowPadding
        rightPadding: control.mirrored ? indicatorPadding : arrowPadding
        spacing: control.spacing
        mirrored: control.mirrored
        display: control.display
        alignment: Qt.AlignLeft
        icon: control.icon
        text: control.text
        font: control.font
        color: control.enabled ? control.palette.windowText : Theme.textDisabled
        // Cut off (too narrow): the whole text on hover.
        HoverHandler { id: cutHover; enabled: control.text.length > 0 && control.implicitContentWidth > control.availableWidth + 1 }
        T.ToolTip.visible: cutHover.enabled && cutHover.hovered
        T.ToolTip.delay: 500
        T.ToolTip.text: control.text
    }
    indicator: Icon {
        x: control.mirrored ? control.width - width - control.rightPadding : control.leftPadding
        y: control.topPadding + (control.availableHeight - height) / 2
        width: Theme.iconSize
        visible: control.checkable
        name: control.checked ? "check" : ""
        size: Theme.fontBody
        color: control.enabled ? Theme.selectedText : Theme.textDisabled
    }
    arrow: Icon {
        x: control.mirrored ? control.leftPadding : control.width - width - control.rightPadding
        y: control.topPadding + (control.availableHeight - height) / 2
        visible: control.subMenu
        name: control.subMenu ? (control.mirrored ? "left" : "right") : ""
        size: Theme.fontBody
        color: Theme.textTertiary
    }
    background: Rectangle {
        implicitWidth: 180
        implicitHeight: Theme.controlHeight - 2
        x: 4; width: control.width - 8
        radius: Theme.radiusSmall
        color: control.down ? Theme.pressed : control.highlighted ? Theme.hover : "transparent"
    }
}
