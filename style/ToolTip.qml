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
    // "Name · ⌘T": the name, then its shortcut set apart in a lighter colour.
    readonly property var keyed: /^(.+) · ((?:[⌘⌥⇧⌃]+|(?:(?:Ctrl|Alt|Shift|Meta)\+)+)\S{1,8}|Esc|↩|Return|\[\[)$/.exec(text)
    function escaped(value) { return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    contentItem: Text {
        text: control.keyed ? control.escaped(control.keyed[1]) + "&nbsp;&nbsp;<font color=\"" + Theme.textSecondary + "\">" + control.escaped(control.keyed[2]) + "</font>"
                            : control.text
        font.pixelSize: Theme.fontSmall
        wrapMode: Text.Wrap
        color: Theme.text
        textFormat: control.keyed ? Text.StyledText : Text.PlainText
    }
    // Long descriptions wrap instead of running off the window.
    contentWidth: Math.min(contentItem.implicitWidth, 360)
    background: Rectangle {
        radius: Theme.radiusSmall
        color: Theme.raised
        border.color: Theme.border
    }
}
