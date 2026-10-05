import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

ColumnLayout {
    id: root
    spacing: 22
    readonly property var semantic: researchStore.semantic
    readonly property var engines: [{name: "Off", value: ""}, {name: "Ollama (this computer)", value: "ollama"}, {name: "OpenAI", value: "openai"}]
    property int stored: 0
    property var ocr: researchStore.ocrStatus()
    function refreshCount() { stored = semantic.storedCount() }
    Component.onCompleted: refreshCount()
    Connections { target: root.semantic; function onChanged() { root.refreshCount() } }
    Connections { target: researchStore; function onOcrChanged() { root.ocr = researchStore.ocrStatus() } }
    // Meaning search: off by default; an engine embeds the library in the background.
    SettingsGroup {
        title: "Meaning search"
        note: "Finds passages, notes and answers by meaning as well as by words; results appear under \"Similar meaning\". Keyword search always works without it. "
            + "Ollama runs on this computer (install it, then `ollama pull nomic-embed-text`). OpenAI uses your OpenAI API key and is billed per use. Indexing pauses while you read."
        SettingsRow {
            label: "Engine"
            ComboBox {
                objectName: "semanticEngineBox"
                Layout.preferredWidth: 220
                model: root.engines.map(function(e) { return e.name })
                currentIndex: Math.max(0, root.engines.findIndex(function(e) { return e.value === root.semantic.engine }))
                onActivated: function(index) {
                    const engine = root.engines[index].value
                    // Sending the library's text to OpenAI is confirmed first.
                    if (engine === "openai" && researchStore.setting("semantic.consent.openai") !== "1") {
                        consent.open()
                        currentIndex = Qt.binding(function() { return Math.max(0, root.engines.findIndex(function(e) { return e.value === root.semantic.engine })) })
                        return
                    }
                    root.semantic.configure(engine, "")
                }
            }
        }
        SettingsRow {
            visible: root.semantic.enabled
            label: "Model"
            wide: true
            TextField {
                objectName: "semanticModelField"
                Layout.fillWidth: true
                text: root.semantic.model
                onEditingFinished: if (text.trim() !== root.semantic.model) root.semantic.configure(root.semantic.engine, text)
            }
        }
        SettingsRow {
            visible: root.semantic.enabled || root.stored > 0
            label: "Index"
            detail: root.semantic.progress.length ? root.semantic.progress : root.stored + " passages indexed"
            Label { objectName: "semanticStatus"; visible: root.semantic.error.length > 0; text: root.semantic.error; color: Theme.danger; elide: Text.ElideRight; Layout.maximumWidth: 260 }
            IconButton { visible: root.semantic.enabled; enabled: !root.semantic.busy; icon.name: "reload"; description: "Update the index"; onClicked: root.semantic.configure(root.semantic.engine, root.semantic.model) }
            Button { text: "Delete Vectors"; palette.buttonText: Theme.danger; enabled: !root.semantic.busy && root.stored > 0; onClicked: { root.semantic.clear(); root.refreshCount() } }
        }
    }
    // OCR for scanned pages, with the Tesseract the reader installed.
    SettingsGroup {
        title: "Scanned pages"
        note: root.ocr.found
            ? "Pages without a text layer are read by Tesseract (" + root.ocr.program + ") in the background and become searchable. OCR text is for search only; it cannot be selected on the page."
            : "To search scanned PDFs, install Tesseract: macOS `brew install tesseract tesseract-lang`, Linux `sudo apt install tesseract-ocr tesseract-ocr-kor`, Windows the UB Mannheim installer. Owelk finds it on its next start."
        SettingsRow {
            label: "Read text with OCR"
            detail: root.ocr.found ? "" : "Tesseract not found"
            Switch {
                objectName: "ocrEnabled"
                enabled: root.ocr.found
                checked: root.ocr.found && root.ocr.enabled
                onToggled: researchStore.setOcr(checked, ocrLanguages.text)
            }
        }
        SettingsRow {
            visible: root.ocr.found && root.ocr.enabled
            label: "Languages"
            detail: "Installed: " + (root.ocr.installed || []).join(", ")
            TextField {
                id: ocrLanguages
                objectName: "ocrLanguages"
                Layout.preferredWidth: 160
                text: root.ocr.languages
                placeholderText: "eng+kor"
                onEditingFinished: if (text !== root.ocr.languages) researchStore.setOcr(true, text)
            }
        }
    }
    Dialog {
        id: consent
        objectName: "semanticConsent"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 420
        modal: true
        title: "Send library text to OpenAI?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            width: parent.width; wrapMode: Text.Wrap
            text: "To search by meaning with OpenAI, Owelk sends the text of your indexed papers, notes, annotations, captures and AI answers to OpenAI's embedding service, a little at a time, and again for new or changed items. PDF files themselves are not uploaded. Usage is billed to your OpenAI key."
        }
        onAccepted: { researchStore.setSetting("semantic.consent.openai", "1"); researchStore.semantic.configure("openai", "") }
    }
}
