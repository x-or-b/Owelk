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
    readonly property var languages: [{name: "Korean", value: "ko"}, {name: "English", value: "en"}, {name: "Same as source", value: "source"}]
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
            const path = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
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
            Label { text: "AI"; font.bold: true; color: Theme.text }
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                Label { text: "Answer language"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: languageBox; objectName: "aiLanguageBox"
                    Layout.fillWidth: true
                    model: root.languages.map(function(l) { return l.name })
                    onActivated: function(index) { researchStore.setSetting("aiLanguage", root.languages[index].value) }
                }
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
                // Claude Agent runs on the Claude API key, so it is entered right here too.
                readonly property string keyProvider: current.id === "claude-agent" ? "claude" : current.id
                readonly property bool needsKey: current.kind === "api" || current.id === "claude-agent"
                readonly property bool keyStored: (ai.providers, ai.hasApiKey(keyProvider))
                Label { visible: aiSettings.needsKey; text: aiSettings.current.id === "claude-agent" ? "Claude API key" : "API key"; color: Theme.textBody }
                RowLayout {
                    visible: aiSettings.needsKey
                    Layout.fillWidth: true
                    UiControls.TextField {
                        id: keyField; objectName: "aiKeyField"
                        Layout.fillWidth: true
                        echoMode: TextInput.Password
                        placeholderText: aiSettings.keyStored ? "Stored in the Keychain" : "Paste your API key"
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
                // ACP agents: installed from npm into Owelk's data folder on request.
                readonly property bool agent: current.kind === "agent"
                readonly property var agentInfo: agent ? (ai.agents().find(function(a) { return a.id === current.id }) || ({})) : ({})
                property var agentStatus: ({})
                property string agentMessage: ""
                property bool installing: false
                Connections {
                    target: aiSettings.ai
                    function onAgentInstallFinished(id, ok, message) {
                        aiSettings.installing = false
                        aiSettings.agentMessage = message
                        if (ok && id === aiSettings.current.id) aiSettings.ai.refreshAgent(id)
                    }
                    function onAgentStatus(id, status) { if (id === aiSettings.current.id) aiSettings.agentStatus = status }
                }
                onAgentChanged: { agentStatus = ({}); agentMessage = ""; if (agent && current.installed) ai.refreshAgent(current.id) }
                Label { visible: aiSettings.agent; text: "Agent"; color: Theme.textBody }
                RowLayout {
                    visible: aiSettings.agent
                    Layout.fillWidth: true
                    Label {
                        objectName: "agentState"
                        Layout.fillWidth: true; elide: Text.ElideRight; color: Theme.textSecondary
                        text: aiSettings.installing ? "Installing…" : aiSettings.current.installed ? "Installed" : "Not installed"
                    }
                    UiControls.Button {
                        objectName: "agentInstall"
                        text: aiSettings.current.installed ? "Update" : "Install…"
                        enabled: !aiSettings.installing
                        onClicked: installConfirm.open()
                    }
                    UiControls.Button {
                        objectName: "agentRemove"; text: "Remove"
                        visible: !!aiSettings.current.installed; enabled: !aiSettings.installing
                        onClicked: aiSettings.ai.removeAgent(aiSettings.current.id)
                    }
                }
                Label { visible: aiSettings.agent && aiSettings.current.installed && aiSettings.current.id !== "claude-agent"; text: "Account"; color: Theme.textBody }
                Flow {
                    visible: aiSettings.agent && aiSettings.current.installed && aiSettings.current.id !== "claude-agent"
                    Layout.fillWidth: true
                    spacing: 6
                    Label {
                        text: aiSettings.agentStatus.ready ? "Signed in" : aiSettings.agentStatus.installed ? "Not signed in" : "Checking…"
                        color: Theme.textSecondary; height: 30; verticalAlignment: Text.AlignVCenter
                    }
                    Repeater {
                        model: aiSettings.agentStatus.ready ? [] : aiSettings.agentStatus.authMethods || []
                        delegate: UiControls.Button {
                            required property var modelData
                            objectName: "agentAuth-" + modelData.id
                            text: modelData.name
                            ToolTip.visible: hovered && !!modelData.description; ToolTip.delay: 450; ToolTip.text: modelData.description || ""
                            onClicked: aiSettings.ai.authenticateAgent(aiSettings.current.id, modelData.id)
                        }
                    }
                }
                Label {
                    visible: aiSettings.agent
                    Layout.columnSpan: 2; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                    text: (aiSettings.agentMessage.length ? aiSettings.agentMessage + "\n" : "")
                        + (aiSettings.current.id === "claude-agent"
                           ? (aiSettings.keyStored ? "Uses the Claude API key above (billed by Anthropic per request). " : "Needs a Claude API key from console.anthropic.com (billed per request, separate from a Claude Pro/Max plan). ")
                             + "Signing in with a Claude.ai subscription is not available in Owelk: Anthropic does not allow third-party apps to offer it without approval."
                           : "The agent signs in on its own page; Owelk never sees the password.")
                        + " Owelk runs agents read-only and declines every file, command and network request they make."
                }
                UiControls.Dialog {
                    id: installConfirm
                    objectName: "agentInstallConfirm"
                    parent: Overlay.overlay
                    anchors.centerIn: parent
                    width: 420
                    modal: true
                    title: (aiSettings.current.installed ? "Update " : "Install ") + (aiSettings.agentInfo.name || "agent") + "?"
                    standardButtons: Dialog.Ok | Dialog.Cancel
                    Label {
                        width: parent.width; wrapMode: Text.Wrap
                        text: aiSettings.agentInfo.npm === false
                              ? "Node.js is needed to install agents. Install it from nodejs.org or with Homebrew (brew install node), then try again."
                              : "Owelk downloads " + (aiSettings.agentInfo.package || "") + " from npm into its own data folder (a few hundred MB with its dependencies). Nothing outside that folder changes."
                    }
                    onAccepted: if (aiSettings.agentInfo.npm !== false && aiSettings.ai.installAgent(aiSettings.current.id)) { aiSettings.installing = true; aiSettings.agentMessage = "" }
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
                        placeholderText: aiSettings.current.id === "codex" || aiSettings.agent ? "Default" : aiSettings.current.defaultModel || "Model name"
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
                text: "Keys are stored in the macOS Keychain. Before the first request to a provider, Owelk shows what will be sent. "
                      + "Claude is available with an API key; signing in with a Claude.ai account is not offered because Anthropic does not allow it for third-party apps."
            }
        }
    }
}
