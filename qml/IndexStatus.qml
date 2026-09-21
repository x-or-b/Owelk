import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

UiControls.ToolButton {
    id: root
    objectName: "indexStatus"
    readonly property var indexer: researchStore.paperIndex
    readonly property var records: indexer.documents
    readonly property int unavailable: records.filter(function(d) { return ["failed", "missing", "locked", "empty"].indexOf(d.state) >= 0 }).length
    text: indexer.paused ? "Text index paused" : indexer.busy ? indexer.progress || "Indexing PDFs…" : "Text index · " + records.filter(function(d) { return d.state === "ready" }).length + " searchable" + (unavailable ? " · " + unavailable + " unavailable" : "")
    font.pixelSize: 11
    implicitHeight: 28
    onClicked: details.open()
    ToolTip.visible: hovered
    ToolTip.text: "Local text index · Status, pause and retry"
    contentItem: Label { text: root.text; color: "#777777"; font: root.font; elide: Text.ElideMiddle }
    UiControls.Dialog {
        id: details
        objectName: "indexDetails"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(650, parent ? parent.width - 32 : 650)
        title: "PDF text index"
        modal: true
        standardButtons: Dialog.Close
        contentItem: ColumnLayout {
            spacing: 8
            Label { Layout.fillWidth: true; text: "Opened PDFs only · Stored locally · No OCR or password indexing"; wrapMode: Text.Wrap; color: "#777777" }
            RowLayout {
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: root.indexer.progress || (root.indexer.paused ? "Paused" : "Up to date"); elide: Text.ElideMiddle }
                UiControls.Button { objectName: "pauseIndex"; text: root.indexer.paused ? "Resume" : "Pause"; onClicked: root.indexer.setPaused(!root.indexer.paused) }
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: 320
                model: details.visible ? root.records : []
                clip: true
                ScrollBar.vertical: ScrollBar {}
                delegate: UiControls.ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    height: 76
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: modelData.title; textFormat: Text.PlainText; elide: Text.ElideMiddle }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.state === "ready" ? "Searchable · " + modelData.textPages + "/" + modelData.pages + " pages with text"
                                    : modelData.state === "empty" ? "No extractable text · OCR is not available"
                                    : modelData.error || modelData.state
                                textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; color: "#777777"; font.pixelSize: 11
                            }
                        }
                        UiControls.Button { text: "Retry"; visible: ["failed", "missing", "locked", "paused"].indexOf(modelData.state) >= 0; onClicked: root.indexer.retry(modelData.source) }
                        UiControls.Button { text: "Locate…"; onClicked: { const source = modelData.source; details.close(); researchStore.requestRelink(source) } }
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: modelData.source.toString()
                }
                Label { anchors.centerIn: parent; visible: root.records.length === 0; text: "Open a PDF to start indexing."; color: "#777777" }
            }
        }
    }
}
