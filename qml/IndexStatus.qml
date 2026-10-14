import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

ToolButton {
    id: root
    objectName: "indexStatus"
    readonly property var indexer: researchStore.paperIndex
    readonly property var records: indexer.documents
    readonly property int unavailable: records.filter(function(d) { return ["failed", "missing", "locked", "empty"].indexOf(d.state) >= 0 }).length
    // Papers whose PDF is gone (deleted, or never arrived): they can leave the Library from here.
    readonly property var missing: records.filter(function(d) { return d.state === "missing" }).map(function(d) { return d.source })
    // Quiet: shown only while indexing, paused, or when some PDFs cannot be read.
    property bool quiet: false
    visible: !quiet || indexer.busy || indexer.paused || unavailable > 0
    text: indexer.paused ? qsTr("Text index paused") : indexer.busy ? indexer.progress || qsTr("Indexing PDFs…") : qsTr("Text index · ") + records.filter(function(d) { return d.state === "ready" }).length + qsTr(" searchable") + (unavailable ? " · " + unavailable + qsTr(" unavailable") : "")
    font.pixelSize: Theme.fontCaption
    implicitHeight: Theme.controlHeightSmall + 4
    onClicked: details.open()
    ToolTip.visible: hovered
    ToolTip.text: qsTr("Text index")
    contentItem: Label { text: root.text; color: Theme.textTertiary; font: root.font; elide: Text.ElideMiddle }
    Dialog {
        id: details
        objectName: "indexDetails"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(650, parent ? parent.width - 32 : 650)
        title: qsTr("PDF text index")
        modal: true
        standardButtons: Dialog.Close
        contentItem: ColumnLayout {
            spacing: 8
            Label { Layout.fillWidth: true; text: qsTr("Opened PDFs only · Stored locally · Locked PDFs are indexed after you open them with their password"); wrapMode: Text.Wrap; color: Theme.textTertiary }
            RowLayout {
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: root.indexer.progress || (root.indexer.paused ? qsTr("Paused") : "Up to date"); elide: Text.ElideMiddle }
                Button {
                    objectName: "removeMissingPdfs"
                    visible: root.missing.length > 1
                    flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                    palette.buttonText: Theme.danger
                    text: qsTr("Remove ") + root.missing.length + qsTr(" Missing")
                    onClicked: { const list = root.missing; Qt.callLater(function() { researchStore.removeFromLibrary(list) }) }
                }
                IconButton { objectName: "pauseIndex"; icon.name: root.indexer.paused ? "play" : "pause"; description: root.indexer.paused ? qsTr("Resume indexing") : qsTr("Pause indexing"); onClicked: root.indexer.setPaused(!root.indexer.paused) }
            }
            ListView {
                objectName: "indexDetailsList"
                Layout.fillWidth: true
                Layout.preferredHeight: 320
                model: details.visible ? root.records : []
                clip: true
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: 76
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true
                            Label { Layout.fillWidth: true; text: modelData.title; textFormat: Text.PlainText; elide: Text.ElideMiddle }
                            Label {
                                Layout.fillWidth: true
                                text: modelData.state === "ready" ? qsTr("Searchable · ") + modelData.textPages + "/" + modelData.pages + qsTr(" pages with text")
                                    : modelData.state === "empty" ? qsTr("No extractable text · OCR is not available")
                                    : modelData.error || modelData.state
                                textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
                            }
                        }
                        IconButton { icon.name: "reload"; description: qsTr("Retry"); visible: ["failed", "missing", "locked", "paused"].indexOf(modelData.state) >= 0; onClicked: root.indexer.retry(modelData.source) }
                        IconButton { icon.name: "locate"; description: qsTr("Locate the original PDF…"); onClicked: { const source = modelData.source; details.close(); researchStore.requestRelink(source) } }
                        // A PDF that is gone and not wanted: the paper leaves the Library (and this list).
                        IconButton {
                            objectName: "removeMissing-" + index
                            visible: modelData.state === "missing"
                            icon.name: "trash"; tint: Theme.danger; description: qsTr("Remove from the Library")
                            onClicked: { const source = modelData.source; Qt.callLater(function() { researchStore.removeFromLibrary([source]) }) }
                        }
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: modelData.source.toString()
                }
                Label { anchors.centerIn: parent; visible: root.records.length === 0; text: qsTr("Open a PDF to start indexing."); color: Theme.textTertiary }
            }
        }
    }
}
