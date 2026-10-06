import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A question before something that is hard to undo: Cancel, or the action (red when destructive).
Dialog {
    id: root
    property string message: ""
    property string actionText: "OK"
    property bool destructive: true
    signal confirmed()
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: 420
    modal: true
    Label { width: parent.width; wrapMode: Text.Wrap; color: Theme.textSecondary; text: root.message }
    footer: DialogButtonBox {
        Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
        Button {
            objectName: "confirmAction"
            text: root.actionText
            palette.buttonText: root.destructive ? Theme.danger : Theme.text
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }
    onAccepted: confirmed()
}
