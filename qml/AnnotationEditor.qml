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
    // Text boxes: the font size in PDF points. A new box fits its font to the box (largest size that fits,
    // never below minimumFont); a box whose text does not fit even then grows downward instead of clipping.
    readonly property real minimumFont: 8
    readonly property real maximumFont: 24
    property bool fitText: true
    property real chosenFont: 14
    // Measures wrapped text at a size, in points (the page draws the same text scaled to the zoom).
    Text { id: measure; visible: false; wrapMode: Text.Wrap; textFormat: Text.PlainText }
    function textHeight(text, width, size) {
        measure.width = width; measure.font.pixelSize = size; measure.text = text
        return measure.contentHeight
    }
    function fittingFont(text, width, height) {
        for (let size = maximumFont; size > minimumFont; size -= .5)
            if (textHeight(text, width, size) <= height) return size
        return minimumFont
    }
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
        // New boxes fit their text; saved ones keep their size (older boxes were drawn at 14 pt).
        fitText = data.kind === "text" && !data.id;
        chosenFont = data.fontSize || 14;
        fontSpin.value = Math.round(chosenFont);
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
        // Korean/Japanese/Chinese input keeps the last character in composition until it is committed.
        Qt.inputMethod.commit();
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
            let rect = {x: Number(left.text) / 100, y: Number(top.text) / 100, width: Number(span.text) / 100, height: Number(tall.text) / 100}
            let fontSize = 0
            if (record.kind === "text") {
                const points = readerCanvas.pagePoints(record.page)
                const width = rect.width * points.width, height = rect.height * points.height
                fontSize = fitText ? fittingFont(body.text, width, height) : chosenFont
                // Still too tall at that size: the box grows down (within the page) rather than cut the text.
                const needed = textHeight(body.text, width, fontSize) / points.height
                if (needed > rect.height) rect.height = Math.min(needed, 1 - rect.y)
            }
            const spec = Object.assign({}, record, {
                                           fontSize: fontSize,
                                           body: body.text,
                                           color: selectedColor,
                                           imageSource: chosenImage,
                                           sha256: readerCanvas.documentFingerprint,
                                           rectangles: [rect]
                                       });
            saving = true;
            if (record.kind === "text") researchStore.setSetting("textColor", selectedColor);
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
            Label { Layout.fillWidth: true; text: "Unsaved text from last time is kept."; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
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
        // Text boxes: the font size, fitted to the box unless chosen.
        RowLayout {
            objectName: "textSizeRow"
            visible: root.record.kind === "text"
            Layout.fillWidth: true
            Label { text: "Size"; color: Theme.textSecondary }
            SpinBox {
                id: fontSpin
                objectName: "textFontSize"
                from: 6; to: 72
                enabled: !root.fitText
                onValueModified: { root.chosenFont = value; root.geometryDirty = true }
            }
            Label { text: "pt"; color: Theme.textTertiary }
            CheckBox {
                objectName: "textFitBox"
                text: "Fit to box"
                checked: root.fitText
                onToggled: { root.fitText = checked; root.geometryDirty = true }
            }
            Item { Layout.fillWidth: true }
        }
        RowLayout {
            // The ink: a round color well; click to choose another.
            ToolButton {
                objectName: "annotationColorWell"
                implicitWidth: Theme.iconButton; implicitHeight: Theme.iconButton
                padding: 4
                ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: "Color"
                Accessible.name: "Color"
                contentItem: Rectangle { radius: width / 2; color: root.selectedColor }
                onClicked: colors.open()
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
