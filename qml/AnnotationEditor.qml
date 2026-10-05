import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Owelk.Ui

Dialog {
    id: root
    objectName: "annotationEditor"
    property var readerCanvas
    property var record: ({})
    property var selection: null
    property url source
    property bool saving: false
    property string originalBody: ""
    property string chosenImage: ""
    property string selectedColor: Theme.defaultInk
    readonly property bool dirty: visible && (body.text !== originalBody || chosenImage.length > 0
                                              || geometryDirty || selectedColor !== (record.color
                                                                                     || Theme.defaultInk))
    property bool geometryDirty: false
    // Typed text survives a crash as a draft, offered when the same annotation is edited again.
    readonly property string draftKey: record.kind === "image" ? "" : "annotation:" + (record.id || "new")
    property string savedDraft: ""
    Timer { id: draftTimer; interval: 1000; onTriggered: if (root.visible && body.text !== root.originalBody) researchStore.saveDraft(root.draftKey, body.text) }
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(470, parent.width - 32)
    height: Math.min(520, parent.height - 32)
    modal: true
    closePolicy: Popup.NoAutoClose
    title: record.kind === "image" ? "Image annotation" : record.kind === "text" ? "Text box" : "Comment"
    function begin(canvas, data, anchor) {
        readerCanvas = canvas;
        source = canvas.source;
        record = data;
        selection = anchor || null;
        originalBody = data.body || "";
        body.text = originalBody;
        chosenImage = data.imageSource || "";
        selectedColor = data.color || Theme.defaultInk;
        const r = data.rectangles && data.rectangles.length ? data.rectangles[0] : {
                                                                  x: 0,
                                                                  y: 0,
                                                                  width: .3,
                                                                  height: .1
                                                              };
        left.text = (r.x * 100).toFixed(2);
        top.text = (r.y * 100).toFixed(2);
        span.text = (r.width * 100).toFixed(2);
        tall.text = (r.height * 100).toFixed(2);
        geometryDirty = false;
        saving = false;
        const kept = researchStore.draft(draftKey);
        savedDraft = kept.length && kept !== originalBody ? kept : "";
        open();
    }
    function requestClose() {
        if (saving)
            return;
        if (dirty)
            discard.open();
        else
            close();
    }
    function save() {
        if (saving || researchStore.busy)
            return;
        if (record.kind !== "image" && !body.text.trim().length)
            return;
        if (selection) {
            saving = true;
            researchStore.commentText(source, selection.page, selection.from, selection.to, selection.text,
                                      body.text, selectedColor);
        } else if (record.id && (record.kind === "highlight" || record.kind === "draw" || (record.kind
                                                                                           === "comment"
                                                                                           && record.text))) {
            if (researchStore.updateHighlight(record.id, selectedColor, body.text)) {
                researchStore.clearDraft(draftKey);
                close();
            }
        } else {
            const spec = Object.assign({}, record, {
                                           body: body.text,
                                           color: selectedColor,
                                           imageSource: chosenImage,
                                           sha256: readerCanvas.documentFingerprint,
                                           rectangles: [
                                               {
                                                   x: Number(left.text) / 100,
                                                   y: Number(top.text) / 100,
                                                   width: Number(span.text) / 100,
                                                   height: Number(tall.text) / 100
                                               }
                                           ]
                                       });
            saving = true;
            researchStore.saveAnnotation(source, record.page, spec);
        }
    }
    Connections {
        target: researchStore
        function onAnnotationFinished(success, id) {
            if (root.saving) {
                root.saving = false;
                if (success) {
                    researchStore.clearDraft(root.draftKey);
                    root.close();
                }
            }
        }
    }
    onOpened: body.forceActiveFocus()
    ColumnLayout {
        anchors.fill: parent
        spacing: 10
        Label {
            Layout.fillWidth: true
            visible: !!root.selection || !!root.record.text
            text: root.selection ? root.selection.text : root.record.text || ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            color: Theme.textTertiary
        }
        RowLayout {
            objectName: "annotationDraftBar"
            visible: root.savedDraft.length > 0
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; text: "Unsaved text from last time is kept."; color: Theme.textSecondary; font.pixelSize: 12 }
            Button { objectName: "restoreAnnotationDraft"; text: "Restore"; onClicked: { body.text = root.savedDraft; root.savedDraft = "" } }
            Button { text: "Discard"; onClicked: { researchStore.clearDraft(root.draftKey); root.savedDraft = "" } }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.record.kind !== "image"
            TextArea {
                id: body
                objectName: "annotationBody"
                placeholderText: root.record.kind === "text" ? "Enter text…" : "Write a comment…"
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                enabled: !root.saving
                onTextChanged: if (root.visible) draftTimer.restart()
            }
        }
        Image {
            objectName: "annotationImagePreview"
            visible: root.record.kind === "image"
            Layout.fillWidth: true
            Layout.fillHeight: true
            source: root.chosenImage ? researchStore.annotationPreviewUrl(root.chosenImage) : root.record.image || ""
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 500
        }
        Button {
            visible: root.record.kind === "image"
            text: "Choose / Replace Image…"
            enabled: !root.saving
            onClicked: imageDialog.open()
        }
        GridLayout {
            visible: !root.selection && !root.record.text && root.record.kind !== "draw"
            columns: 4
            Layout.fillWidth: true
            Label {
                text: "X %"
            }
            Label {
                text: "Y %"
            }
            Label {
                text: "Width %"
            }
            Label {
                text: "Height %"
            }
            TextField {
                id: left
                Layout.fillWidth: true
                validator: DoubleValidator {
                    bottom: 0
                    top: 100
                    locale: "C"
                }
                onTextEdited: root.geometryDirty = true
            }
            TextField {
                id: top
                Layout.fillWidth: true
                validator: DoubleValidator {
                    bottom: 0
                    top: 100
                    locale: "C"
                }
                onTextEdited: root.geometryDirty = true
            }
            TextField {
                id: span
                Layout.fillWidth: true
                validator: DoubleValidator {
                    bottom: .1
                    top: 100
                    locale: "C"
                }
                onTextEdited: root.geometryDirty = true
            }
            TextField {
                id: tall
                Layout.fillWidth: true
                validator: DoubleValidator {
                    bottom: .1
                    top: 100
                    locale: "C"
                }
                onTextEdited: root.geometryDirty = true
            }
        }
        RowLayout {
            Button {
                text: "Color…"
                onClicked: colors.open()
            }
            Rectangle {
                width: 16
                height: 16
                radius: 3
                color: root.selectedColor
            }
            Item {
                Layout.fillWidth: true
            }
            Button {
                objectName: "cancelAnnotation"
                text: "Cancel"
                enabled: !root.saving
                onClicked: root.requestClose()
            }
            Button {
                objectName: "saveAnnotation"
                text: root.saving ? "Saving…" : "Save"
                enabled: !root.saving && !researchStore.busy
                onClicked: root.save()
            }
        }
    }
    AnnotationColors {
        id: colors
        selectedColor: root.selectedColor
        onChosen: function (color) {
            root.selectedColor = color;
        }
    }
    FileDialog {
        id: imageDialog
        nameFilters: ["Images (*.png *.jpg *.jpeg *.webp *.heic *.heif *.HEIC *.HEIF)"]
        onAccepted: root.chosenImage = selectedFile.toString()
    }
    Dialog {
        id: discard
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Discard annotation edits?"
        modal: true
        standardButtons: Dialog.Discard | Dialog.Cancel
        onDiscarded: { researchStore.clearDraft(root.draftKey); root.close() }
    }
}
