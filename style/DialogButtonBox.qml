import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

// Buttons in the dialog's bottom-right; the accepting button is the primary (accent) one.
T.DialogButtonBox {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, (control.count === 1 ? 72 : contentWidth) + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, contentHeight + topPadding + bottomPadding)
    spacing: 8
    padding: 16
    topPadding: 8
    alignment: Qt.AlignRight
    delegate: Button { width: implicitWidth }
    // The accepting standard button (OK, Save, Yes, Open, Apply) is the primary one.
    function markPrimary() {
        for (const kind of [T.DialogButtonBox.Ok, T.DialogButtonBox.Save, T.DialogButtonBox.Yes, T.DialogButtonBox.Open, T.DialogButtonBox.Apply]) {
            const button = standardButton(kind)
            if (button) { button.primary = true; return }
        }
    }
    onStandardButtonsChanged: Qt.callLater(markPrimary)
    Component.onCompleted: markPrimary()
    contentItem: ListView {
        implicitWidth: contentWidth
        model: control.contentModel
        spacing: control.spacing
        orientation: ListView.Horizontal
        boundsBehavior: Flickable.StopAtBounds
        snapMode: ListView.SnapToItem
    }
    background: Item { implicitHeight: Theme.controlHeight + 24 }
}
