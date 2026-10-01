import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import "UiTheme.js" as Theme

UiControls.Dialog {
    id: root
    objectName: "relinkDialog"
    property url source
    property url candidate
    property string detail: ""
    title: "Locate original PDF"
    modal: true
    width: Math.min(560, parent ? parent.width - 32 : 560)
    anchors.centerIn: parent
    closePolicy: researchStore.relinking ? Popup.NoAutoClose : Popup.CloseOnEscape
    standardButtons: researchStore.relinking ? Dialog.NoButton : Dialog.Cancel
    function begin(url) { source = url; candidate = ""; detail = ""; open() }
    contentItem: ColumnLayout {
        spacing: 12
        Label { Layout.fillWidth: true; text: "Reconnect the exact same PDF at a new location. Tabs, reading positions and captures will be preserved."; wrapMode: Text.Wrap }
        Label { Layout.fillWidth: true; text: "Previous: " + root.source.toString(); textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere; font.pixelSize: 11; color: Theme.textMuted }
        Label { Layout.fillWidth: true; text: root.candidate.toString().length ? "Selected: " + root.candidate.toString() : "No replacement selected"; textFormat: Text.PlainText; wrapMode: Text.WrapAnywhere; font.pixelSize: 11; color: Theme.textSecondary }
        RowLayout {
            UiControls.Button { objectName: "chooseRelinkFile"; text: "Choose PDF…"; enabled: !researchStore.relinking; onClicked: picker.open() }
            Item { Layout.fillWidth: true }
            UiControls.Button { objectName: "verifyRelink"; text: researchStore.relinking ? "Verifying…" : "Verify and Relink"; enabled: !researchStore.relinking && root.candidate.toString().length > 0; onClicked: { root.detail = ""; researchStore.relinkSource(root.source, root.candidate) } }
        }
        Label { Layout.fillWidth: true; visible: root.detail.length > 0; text: root.detail; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: Theme.textSecondary }
        Label { Layout.fillWidth: true; text: "Different versions are not accepted. No original files will be moved, overwritten or deleted."; wrapMode: Text.Wrap; font.pixelSize: 11; color: Theme.textMuted }
    }
    Native.FileDialog {
        id: picker
        title: "Locate the original PDF"
        nameFilters: ["PDF documents (*.pdf)"]
        onAccepted: root.candidate = selectedFile
    }
    Connections {
        target: researchStore
        function onRelinkFinished(success, detail) {
            if (!root.visible) return
            if (success) root.close()
            else root.detail = detail
        }
    }
}
