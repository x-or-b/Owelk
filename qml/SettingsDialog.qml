import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native

// App preferences. Values are stored locally in the settings table and apply immediately.
UiControls.Dialog {
    id: root
    objectName: "settingsDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(560, parent ? parent.width - 32 : 560)
    height: Math.min(620, parent ? parent.height - 32 : 620)
    title: "Settings"
    modal: true
    standardButtons: Dialog.Close
    readonly property var engines: [
        {name: "Google Scholar", template: "https://scholar.google.com/scholar?q=%s"},
        {name: "Google", template: "https://www.google.com/search?q=%s"},
        {name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"},
        {name: "arXiv", template: "https://arxiv.org/search/?query=%s&searchtype=all"}
    ]
    readonly property var languages: [{name: "Korean", value: "ko"}, {name: "English", value: "en"}, {name: "Japanese", value: "ja"},
        {name: "Chinese (Simplified)", value: "zh"}, {name: "German", value: "de"}, {name: "French", value: "fr"},
        {name: "Spanish", value: "es"}, {name: "Same as the paper", value: "source"}]
    function refresh() {
        const folder = researchStore.setting("downloadFolder")
        folderField.text = folder.length ? folder : researchStore.downloadTarget("x").directory
        engineBox.currentIndex = Math.max(0, engines.findIndex(function(e) { return e.template === researchStore.setting("searchEngine", engines[0].template) }))
        pdfModeBox.currentIndex = researchStore.setting("webPdfMode", "reader") === "browser" ? 1 : 0
        languageBox.currentIndex = Math.max(0, languages.findIndex(function(l) { return l.value === researchStore.setting("aiLanguage", "ko") }))
    }
    onAboutToShow: refresh()
    Native.FolderDialog {
        id: folderDialog
        title: "Download folder for web PDFs"
        onAccepted: {
            const path = researchStore.localPath(selectedFolder)
            if (researchStore.setSetting("downloadFolder", path)) root.refresh()
        }
    }
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            id: sections
            width: parent.width
            spacing: 14
            Label { text: "Web"; font.bold: true; color: Theme.text }
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                Label { text: "PDF downloads"; color: Theme.textBody }
                RowLayout {
                    Layout.fillWidth: true
                    UiControls.TextField { id: folderField; objectName: "downloadFolderField"; Layout.fillWidth: true; readOnly: true }
                    UiControls.Button { text: "Choose…"; onClicked: folderDialog.open() }
                }
                Label { text: "PDF links"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: pdfModeBox; objectName: "webPdfModeBox"
                    Layout.fillWidth: true
                    model: ["Download and open in the reader", "Show in the web tab"]
                    onActivated: function(index) { researchStore.setSetting("webPdfMode", index === 1 ? "browser" : "reader") }
                }
                Label { text: "Search with"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: engineBox; objectName: "searchEngineBox"
                    Layout.fillWidth: true
                    model: root.engines.map(function(e) { return e.name })
                    onActivated: function(index) { researchStore.setSetting("searchEngine", root.engines[index].template) }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: "PDFs downloaded from web pages are saved here. Existing files are never overwritten. In the web tab, PDFs can also be read in place (More → Show PDFs in This Tab) and sent to the reader with Open in Reader; highlights, captures and notes work in the reader."
            }
            Label { text: "Search"; font.bold: true; color: Theme.text }
            // Meaning search: off by default; an engine embeds the library in the background.
            GridLayout {
                id: semanticSettings
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                readonly property var semantic: researchStore.semantic
                readonly property var engines: [{name: "Off", value: ""}, {name: "Ollama (this computer)", value: "ollama"}, {name: "OpenAI", value: "openai"}]
                property int stored: 0
                function refreshCount() { stored = semantic.storedCount() }
                Component.onCompleted: refreshCount()
                Connections { target: semanticSettings.semantic; function onChanged() { semanticSettings.refreshCount() } }
                Label { text: "Meaning search"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: semanticEngineBox; objectName: "semanticEngineBox"
                    Layout.fillWidth: true
                    model: semanticSettings.engines.map(function(e) { return e.name })
                    currentIndex: Math.max(0, semanticSettings.engines.findIndex(function(e) { return e.value === semanticSettings.semantic.engine }))
                    onActivated: function(index) {
                        const engine = semanticSettings.engines[index].value
                        // Sending the library's text to OpenAI is confirmed first.
                        if (engine === "openai" && researchStore.setting("semantic.consent.openai") !== "1") { semanticConsent.open(); currentIndex = Qt.binding(function() { return Math.max(0, semanticSettings.engines.findIndex(function(e) { return e.value === semanticSettings.semantic.engine })) }); return }
                        semanticSettings.semantic.configure(engine, "")
                    }
                }
                Label { visible: semanticSettings.semantic.enabled; text: "Model"; color: Theme.textBody }
                UiControls.TextField {
                    objectName: "semanticModelField"
                    visible: semanticSettings.semantic.enabled
                    Layout.fillWidth: true
                    text: semanticSettings.semantic.model
                    onEditingFinished: if (text.trim() !== semanticSettings.semantic.model) semanticSettings.semantic.configure(semanticSettings.semantic.engine, text)
                }
                Item { visible: semanticSettings.semantic.enabled || semanticSettings.stored > 0; width: 1; height: 1 }
                RowLayout {
                    visible: semanticSettings.semantic.enabled || semanticSettings.stored > 0
                    Layout.fillWidth: true
                    Label {
                        objectName: "semanticStatus"
                        Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12
                        color: semanticSettings.semantic.error.length ? Theme.danger : Theme.textSecondary
                        text: semanticSettings.semantic.progress.length ? semanticSettings.semantic.progress
                            : semanticSettings.stored + " passages indexed"
                    }
                    UiControls.Button { text: "Update"; visible: semanticSettings.semantic.enabled; enabled: !semanticSettings.semantic.busy; onClicked: semanticSettings.semantic.configure(semanticSettings.semantic.engine, semanticSettings.semantic.model) }
                    UiControls.Button { text: "Delete Vectors"; enabled: !semanticSettings.semantic.busy && semanticSettings.stored > 0; onClicked: { semanticSettings.semantic.clear(); semanticSettings.refreshCount() } }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: "Finds passages, notes and answers by meaning as well as by words; results appear under \"Similar meaning\". Keyword search always works without it. "
                    + "Ollama runs on this computer (install it, then `ollama pull nomic-embed-text`). OpenAI uses your OpenAI API key and is billed per use. "
                    + "Indexing runs in the background and pauses while you read."
            }
            // OCR for scanned pages, with the Tesseract the reader installed.
            GridLayout {
                id: ocrSettings
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                property var status: researchStore.ocrStatus()
                Connections { target: researchStore; function onOcrChanged() { ocrSettings.status = researchStore.ocrStatus() } }
                Label { text: "Scanned pages"; color: Theme.textBody }
                RowLayout {
                    Layout.fillWidth: true
                    CheckBox {
                        objectName: "ocrEnabled"
                        text: "Read text with OCR"
                        enabled: ocrSettings.status.found
                        checked: ocrSettings.status.found && ocrSettings.status.enabled
                        onToggled: researchStore.setOcr(checked, ocrLanguages.text)
                    }
                    UiControls.TextField {
                        id: ocrLanguages
                        objectName: "ocrLanguages"
                        visible: ocrSettings.status.found && ocrSettings.status.enabled
                        Layout.fillWidth: true
                        text: ocrSettings.status.languages
                        placeholderText: "eng+kor"
                        ToolTip.visible: hovered; ToolTip.delay: 450
                        ToolTip.text: "Tesseract languages joined with +. Installed: " + (ocrSettings.status.installed || []).join(", ")
                        onEditingFinished: if (text !== ocrSettings.status.languages) researchStore.setOcr(true, text)
                    }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: ocrSettings.status.found
                    ? "Pages without a text layer are read by Tesseract (" + ocrSettings.status.program + ") in the background and become searchable. OCR text is for search only; it cannot be selected on the page."
                    : "To search scanned PDFs, install Tesseract: macOS `brew install tesseract tesseract-lang`, Linux `sudo apt install tesseract-ocr tesseract-ocr-kor`, Windows the UB Mannheim installer. Owelk finds it on its next start."
            }
            UiControls.Dialog {
                id: semanticConsent
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
            Label { text: "AI"; font.bold: true; color: Theme.text }
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                Label { text: "Preferred language"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: languageBox; objectName: "aiLanguageBox"
                    Layout.fillWidth: true
                    model: root.languages.map(function(l) { return l.name })
                    onActivated: function(index) { researchStore.setSetting("aiLanguage", root.languages[index].value) }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: "Used for Explain, Summarize and other one-click actions, and as the Translate target. A question you type is answered in the language you wrote it in."
            }
            GridLayout {
                id: aiSettings
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                readonly property var ai: researchStore.ai
                readonly property var current: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
                property string testResult: ""
                property var codexAccount: ({})
                property var ollamaModels: []
                Connections {
                    target: aiSettings.ai
                    function onConnectionTested(provider, ok, detail) { aiSettings.testResult = (ok ? "✓ " : "✗ ") + detail }
                    function onCodexAccountChanged(account) { aiSettings.codexAccount = account }
                    function onOllamaModelsLoaded(models) { aiSettings.ollamaModels = models }
                }
                onCurrentChanged: {
                    testResult = ""
                    if (current.id === "codex") ai.refreshCodexAccount()
                    if (current.id === "ollama") ai.listOllamaModels()
                }
                Label { text: "Provider"; color: Theme.textBody }
                UiControls.ComboBox {
                    objectName: "aiSettingsProvider"
                    Layout.fillWidth: true
                    textRole: "name"
                    model: aiSettings.ai.providers
                    currentIndex: Math.max(0, aiSettings.ai.providers.findIndex(function(p) { return p.id === aiSettings.ai.provider }))
                    onActivated: function(index) { aiSettings.ai.provider = aiSettings.ai.providers[index].id }
                }
                readonly property string keyProvider: current.id
                readonly property bool needsKey: current.kind === "api"
                readonly property bool keyStored: (ai.providers, ai.hasApiKey(keyProvider))
                Label { visible: aiSettings.needsKey; text: "API key"; color: Theme.textBody }
                RowLayout {
                    visible: aiSettings.needsKey
                    Layout.fillWidth: true
                    UiControls.TextField {
                        id: keyField; objectName: "aiKeyField"
                        Layout.fillWidth: true
                        echoMode: TextInput.Password
                        placeholderText: aiSettings.keyStored ? "Stored securely" : "Paste your API key"
                    }
                    UiControls.Button {
                        objectName: "aiSaveKey"; text: "Save"; enabled: keyField.text.trim().length > 0
                        onClicked: { if (aiSettings.ai.setApiKey(aiSettings.keyProvider, keyField.text)) keyField.clear() }
                    }
                    UiControls.Button { text: "Remove"; enabled: aiSettings.keyStored; onClicked: aiSettings.ai.clearApiKey(aiSettings.keyProvider) }
                    UiControls.Button {
                        objectName: "aiGetKey"
                        visible: !aiSettings.keyStored && (aiSettings.keyProvider === "claude" || aiSettings.keyProvider === "openai")
                        text: "Get a Key…"
                        onClicked: Qt.openUrlExternally(aiSettings.keyProvider === "claude" ? "https://console.anthropic.com/settings/keys" : "https://platform.openai.com/api-keys")
                    }
                }
                Label { visible: aiSettings.current.id === "codex"; text: "Account"; color: Theme.textBody }
                RowLayout {
                    visible: aiSettings.current.id === "codex"
                    Layout.fillWidth: true
                    Label {
                        Layout.fillWidth: true; elide: Text.ElideRight; color: Theme.textSecondary
                        text: aiSettings.codexAccount.available === false ? "Codex CLI not found — install it to sign in"
                            : aiSettings.codexAccount.signedIn ? "Signed in" + (aiSettings.codexAccount.email ? " as " + aiSettings.codexAccount.email : "")
                            : "Not signed in"
                    }
                    UiControls.Button {
                        objectName: "codexSignIn"
                        text: aiSettings.codexAccount.signedIn ? "Sign Out" : "Sign in with ChatGPT"
                        enabled: aiSettings.codexAccount.available !== false
                        onClicked: aiSettings.codexAccount.signedIn ? aiSettings.ai.codexSignOut() : aiSettings.ai.codexSignIn()
                    }
                }
                Label { visible: aiSettings.current.id === "ollama"; text: "Host"; color: Theme.textBody }
                UiControls.TextField {
                    visible: aiSettings.current.id === "ollama"
                    Layout.fillWidth: true
                    text: researchStore.setting("ai.baseUrl.ollama", "http://127.0.0.1:11434/")
                    onEditingFinished: { researchStore.setSetting("ai.baseUrl.ollama", text.trim()); aiSettings.ai.listOllamaModels() }
                }
                Label { text: "Model"; color: Theme.textBody }
                RowLayout {
                    Layout.fillWidth: true
                    UiControls.TextField {
                        objectName: "aiModelField"
                        Layout.fillWidth: true
                        text: aiSettings.current.model || ""
                        placeholderText: aiSettings.current.id === "codex" ? "Account default" : aiSettings.current.defaultModel || "Model name"
                        onEditingFinished: aiSettings.ai.setModel(aiSettings.current.id, text)
                    }
                    UiControls.ComboBox {
                        visible: aiSettings.current.id === "ollama" && aiSettings.ollamaModels.length > 0
                        Layout.preferredWidth: 160
                        model: aiSettings.ollamaModels
                        onActivated: function(index) { aiSettings.ai.setModel("ollama", aiSettings.ollamaModels[index]) }
                    }
                }
                Item { width: 1; height: 1 }
                RowLayout {
                    Layout.fillWidth: true
                    UiControls.Button { objectName: "aiTestConnection"; text: "Test Connection"; onClicked: { aiSettings.testResult = "Testing…"; aiSettings.ai.testConnection(aiSettings.current.id) } }
                    Label { objectName: "aiTestResult"; Layout.fillWidth: true; text: aiSettings.testResult; elide: Text.ElideRight; color: Theme.textSecondary; font.pixelSize: 12 }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: "Keys are stored in " + researchStore.ai.keyStorage() + ". Before the first request to a provider, Owelk shows what will be sent. "
                      + "Claude is available with an API key; signing in with a Claude.ai account is not offered because Anthropic does not allow it for third-party apps."
            }
            Label { text: "Data"; font.bold: true; color: Theme.text }
            // Backups: a folder with the library database and images; restore is applied on next start.
            GridLayout {
                id: dataSettings
                objectName: "dataSettings"
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                property string result: ""
                Connections {
                    target: researchStore
                    function onBackupFinished(ok, path, message) { dataSettings.result = message }
                }
                Label { text: "Backup"; color: Theme.textBody }
                RowLayout {
                    Layout.fillWidth: true
                    UiControls.Button {
                        objectName: "backUpNow"
                        text: researchStore.backingUp ? "Backing Up…" : "Back Up Now…"
                        enabled: !researchStore.backingUp
                        onClicked: backupFolderDialog.open()
                    }
                    UiControls.Button { objectName: "restoreBackup"; text: "Restore…"; onClicked: restoreFolderDialog.open() }
                    UiControls.Button { objectName: "exportNotes"; text: "Export Notes…"; onClicked: notesFolderDialog.open() }
                    Item { Layout.fillWidth: true }
                }
                Item { width: 1; height: 1 }
                CheckBox {
                    objectName: "autoBackup"
                    text: "Back up automatically once a day (keeps the last 7)"
                    checked: researchStore.setting("backup.auto", "1") === "1"
                    onToggled: researchStore.setSetting("backup.auto", checked ? "1" : "0")
                }
            }
            Label {
                objectName: "backupResult"
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: dataSettings.result.length ? dataSettings.result
                    : "A backup copies the library (papers' details, captures, notes, annotations, AI threads, workspaces) and its images into a folder. Your PDFs stay where they are and are not copied. Automatic backups go to the data folder's backups/auto."
            }
        }
    }
    Native.FolderDialog {
        id: backupFolderDialog
        title: "Choose where to put the backup"
        onAccepted: { researchStore.setSetting("backup.folder", researchStore.localPath(selectedFolder)); researchStore.backUp(researchStore.localPath(selectedFolder)) }
    }
    Native.FolderDialog {
        id: notesFolderDialog
        title: "Export every note as Markdown to…"
        onAccepted: dataSettings.result = researchStore.exportNotesMarkdown(researchStore.localPath(selectedFolder)) + " notes exported."
    }
    Native.FolderDialog {
        id: restoreFolderDialog
        title: "Choose an Owelk backup folder"
        onAccepted: {
            const folder = researchStore.localPath(selectedFolder)
            const problem = researchStore.checkBackup(folder)
            if (problem.length) { dataSettings.result = problem; return }
            restoreConfirm.folder = folder
            restoreConfirm.open()
        }
    }
    UiControls.Dialog {
        id: restoreConfirm
        objectName: "restoreConfirm"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 420
        modal: true
        property string folder: ""
        title: "Restore this backup?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            width: parent.width; wrapMode: Text.Wrap
            text: "Owelk replaces its library with the backup the next time it starts. The current library is moved to the data folder's backups, not deleted. Your PDFs are not touched."
        }
        onAccepted: if (researchStore.scheduleRestore(folder)) dataSettings.result = "Quit and reopen Owelk to finish restoring."
    }
}
