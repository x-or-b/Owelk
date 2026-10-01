import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "captureShelf"
    color: Theme.surfacePanel
    property string deletingId: ""
    property var viewingCapture: ({})
    property bool showingTrash: false
    signal aiRequested(var spec)
    signal noteRequested(string id)
    function requestDelete(id) { deletingId = id; deleteDialog.open() }
    function viewText(capture) { viewingCapture = capture; textDialog.open() }
    UiControls.Dialog {
        id: textDialog
        objectName: "excerptDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Text excerpt"
        width: Math.min(600, parent.width - 32)
        height: Math.min(540, parent.height - 32)
        modal: true
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: (root.viewingCapture.name || "") + " · p. " + (Number(root.viewingCapture.page || 0) + 1)
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
                color: Theme.textTertiary
            }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                UiControls.TextArea {
                    objectName: "excerptText"
                    text: root.viewingCapture.text || ""
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    background: Rectangle { color: Theme.surfaceAlt; border.color: Theme.border }
                }
            }
            RowLayout {
                UiControls.Button { objectName: "copyExcerptButton"; text: "Copy text"; onClicked: researchStore.copyText(root.viewingCapture.text) }
                UiControls.Button {
                    text: "View source"
                    enabled: !root.showingTrash
                    onClicked: { textDialog.close(); researchStore.openCapture(root.viewingCapture.id) }
                }
            }
        }
    }
    UiControls.Dialog {
        id: deleteDialog
        objectName: "deleteCaptureDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Delete capture?"
        width: 370
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { width: 310; wrapMode: Text.Wrap; text: "This capture will be moved to local trash. The original PDF will be kept." }
        onAccepted: { const id = root.deletingId; Qt.callLater(function() { researchStore.deleteCapture(id) }) }
    }
    property string purgingId: ""
    LinkToNoteDialog { id: linkToNote }
    UiControls.Dialog {
        id: purgeDialog
        objectName: "purgeCaptureDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Delete permanently?"
        width: 370
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { width: 310; wrapMode: Text.Wrap; text: "This capture, its text and note cannot be recovered. The original PDF will be kept." }
        onAccepted: { const id = root.purgingId; Qt.callLater(function() { researchStore.purgeCapture(id) }) }
    }
    UiControls.Dialog {
        id: emptyDialog
        objectName: "emptyTrashDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Empty trash?"
        width: 370
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            width: 310; wrapMode: Text.Wrap
            text: researchStore.trashedCaptures.length + (researchStore.trashedCaptures.length === 1 ? " capture" : " captures")
                + " will be deleted permanently with their text and notes. The original PDFs will be kept."
        }
        onAccepted: Qt.callLater(function() { researchStore.emptyCaptureTrash() })
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 12
        TabBar {
            Layout.fillWidth: true
            currentIndex: root.showingTrash ? 1 : 0
            UiControls.TabButton {
                id: savedTab
                objectName: "savedCapturesTab"
                text: "Saved"
                background: Rectangle { color: savedTab.checked ? Theme.segmentChecked : Theme.surfaceAlt; border.color: Theme.borderSegment }
                onClicked: root.showingTrash = false
            }
            UiControls.TabButton {
                id: trashTab
                objectName: "captureTrashTab"
                text: "Trash (" + researchStore.trashedCaptures.length + ")"
                background: Rectangle { color: trashTab.checked ? Theme.segmentChecked : Theme.surfaceAlt; border.color: Theme.borderSegment }
                onClicked: root.showingTrash = true
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                text: root.showingTrash ? researchStore.trashedCaptures.length + " deleted" : researchStore.captures.length + " saved"
                elide: Text.ElideRight; font.pixelSize: 12; color: Theme.textTertiary
            }
            UiControls.ToolButton {
                objectName: "emptyTrashButton"
                visible: root.showingTrash
                enabled: researchStore.trashedCaptures.length > 0
                text: "Empty"
                palette.buttonText: Theme.danger
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: "Delete everything in trash permanently"
                onClicked: emptyDialog.open()
            }
        }
        Label {
            Layout.fillWidth: true
            visible: !root.showingTrash
            text: "Select a capture to return to its source."
            wrapMode: Text.Wrap
            color: Theme.textTertiary
            font.pixelSize: 11
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12
            clip: true
            model: root.showingTrash ? researchStore.trashedCaptures : researchStore.captures
            ScrollBar.vertical: ScrollBar {}
            delegate: UiControls.ItemDelegate {
                id: card
                required property var modelData
                objectName: (root.showingTrash ? "trashedCaptureCard-" : "captureCard-") + modelData.id
                width: list.width
                height: contentItem.implicitHeight + 20
                padding: 10
                onClicked: { if (!root.showingTrash) researchStore.openCapture(modelData.id) }
                // Trash cards stay compact; details appear on hover.
                ToolTip.visible: root.showingTrash && hovered
                ToolTip.delay: 450
                ToolTip.text: [modelData.name + " · p. " + (modelData.page + 1),
                    "Deleted " + Qt.formatDateTime(new Date(modelData.deletedAt), "yyyy-MM-dd hh:mm"),
                    modelData.note ? "Note: " + modelData.note.slice(0, 160) : "",
                    modelData.kind !== "text" && !modelData.imageAvailable ? "Image unavailable; kept for recovery." : ""
                ].filter(function(line) { return line.length > 0 }).join("\n")
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    enabled: !root.showingTrash
                    onClicked: function(mouse) { captureMenu.popup(card, mouse.x, mouse.y) }
                }
                UiControls.Menu {
                    id: captureMenu
                    objectName: "captureMenu-" + card.modelData.id
                    UiControls.MenuItem { objectName: "readExcerpt-" + card.modelData.id; text: "Read Excerpt…"; visible: card.modelData.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: root.viewText(card.modelData) }
                    UiControls.MenuItem { text: "Copy Text"; visible: card.modelData.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: researchStore.copyText(card.modelData.text) }
                    UiControls.MenuItem { text: card.modelData.note ? "Edit Note…" : "Add Note…"; onTriggered: root.noteRequested(card.modelData.id) }
                    UiControls.MenuItem {
                        objectName: "explainCapture-" + card.modelData.id
                        text: "Explain with AI"
                        onTriggered: root.aiRequested({action: card.modelData.kind === "text" ? "explain" : "figure", scope: "none",
                                                       captureId: card.modelData.id, source: card.modelData.kind === "web" ? "" : card.modelData.source, page: card.modelData.page})
                    }
                    UiControls.MenuItem { objectName: "linkCaptureToNote-" + card.modelData.id; text: "Link to Note…"; onTriggered: linkToNote.begin("capture", card.modelData.id) }
                    UiControls.MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(card.modelData.source) }
                    UiControls.MenuItem {
                        text: "Delete"
                        palette.text: Theme.danger
                        palette.windowText: Theme.danger
                        palette.highlightedText: Theme.danger
                        onTriggered: root.requestDelete(card.modelData.id)
                    }
                }
                UiControls.ToolButton {
                    id: captureActions
                    objectName: "captureActions-" + card.modelData.id
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    width: 28; height: 28; text: "…"
                    Accessible.name: "Capture actions"
                    visible: !root.showingTrash
                    onClicked: captureMenu.popup(captureActions, 0, captureActions.height)
                }
                background: Rectangle {
                    color: card.hovered ? Theme.surfaceChrome : "white"
                    border.color: Theme.border
                    radius: Theme.cornerRadius
                }
                contentItem: Column {
                    spacing: 7
                    Image {
                        id: preview
                        visible: card.modelData.kind !== "text"
                        width: parent.width
                        height: Math.min(root.showingTrash ? 96 : 155, width / Math.max(.4, implicitWidth / Math.max(1, implicitHeight)))
                        source: card.modelData.imageAvailable ? card.modelData.image : ""
                        sourceSize.width: 520
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                    }
                    Label {
                        objectName: "captureCaption-" + card.modelData.id
                        visible: card.modelData.kind !== "text" && !!card.modelData.caption
                        width: parent.width
                        text: card.modelData.caption || ""
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        maximumLineCount: root.showingTrash ? 1 : 2; elide: Text.ElideRight
                        font.pixelSize: 11; color: Theme.textSecondary
                    }
                    Label {
                        objectName: "excerptPreview"
                        visible: card.modelData.kind === "text"
                        width: parent.width
                        text: card.modelData.text || ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: root.showingTrash ? 3 : 6
                        elide: Text.ElideRight
                        font.pixelSize: 13
                        color: Theme.textBody
                    }
                    Label {
                        visible: !root.showingTrash
                        width: parent.width
                        text: card.modelData.name
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                        font.pixelSize: 11
                        color: Theme.textQuote
                    }
                    Label { visible: !root.showingTrash; text: (card.modelData.kind === "web" ? "Web page" : "p. " + (card.modelData.page + 1)) + "  ·  View source"; font.pixelSize: 11; color: Theme.textSecondary; width: parent.width; wrapMode: Text.Wrap }
                    Label {
                        visible: !root.showingTrash && !!card.modelData.note
                        width: parent.width
                        text: "Note · " + (card.modelData.note || "")
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        maximumLineCount: 3; elide: Text.ElideRight
                        font.pixelSize: 12; color: Theme.textSecondary
                    }
                    UiControls.ToolButton {
                        objectName: "captureNoteButton-" + card.modelData.id
                        visible: !root.showingTrash
                        text: card.modelData.note ? "Edit note" : "Add note"
                        height: 28
                        onClicked: root.noteRequested(card.modelData.id)
                    }
                    RowLayout {
                        objectName: "trashCardFooter-" + card.modelData.id
                        visible: root.showingTrash
                        width: parent.width
                        spacing: 2
                        Label {
                            Layout.fillWidth: true
                            text: card.modelData.name + " · p. " + (card.modelData.page + 1)
                            textFormat: Text.PlainText; elide: Text.ElideRight
                            font.pixelSize: 11; color: Theme.textTertiary
                        }
                        ReaderIconButton {
                            objectName: "restoreCapture-" + card.modelData.id
                            kind: "restore"; description: "Restore with note and workspace links"
                            onClicked: { const id = card.modelData.id; Qt.callLater(function() { researchStore.restoreCapture(id) }) }
                        }
                        ReaderIconButton {
                            objectName: "purgeCapture-" + card.modelData.id
                            kind: "trash"; tint: Theme.danger; description: "Delete permanently…"
                            onClicked: { root.purgingId = card.modelData.id; purgeDialog.open() }
                        }
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: list.count === 0
                text: root.showingTrash ? "Trash is empty." : "No saved captures.\nSelect text and Save excerpt,\nor use Capture region."
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                lineHeight: 1.5
                color: Theme.textMuted
            }
        }
    }
}
