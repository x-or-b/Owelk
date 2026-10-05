import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

T.ToolTip {
    id: control
    x: parent ? (parent.width - implicitWidth) / 2 : 0
    y: -implicitHeight - 4
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitContentWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitContentHeight + topPadding + bottomPadding)
    margins: 6
    padding: 5
    horizontalPadding: 8
    closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutsideParent | T.Popup.CloseOnReleaseOutsideParent
    contentItem: Text {
        text: control.text
        font.pixelSize: Theme.fontSmall
        wrapMode: Text.Wrap
        color: Theme.text
        textFormat: Text.PlainText
    }
    // Long descriptions wrap instead of running off the window.
    contentWidth: Math.min(contentItem.implicitWidth, 360)
    background: Rectangle {
        radius: Theme.radiusSmall
        color: Theme.raised
        border.color: Theme.border
    }
}
