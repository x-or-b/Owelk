import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

ColumnLayout {
    id: root
    spacing: 22
    readonly property var languages: [{name: "Korean", value: "ko"}, {name: "English", value: "en"}, {name: "Japanese", value: "ja"},
        {name: "Chinese (Simplified)", value: "zh"}, {name: "German", value: "de"}, {name: "French", value: "fr"},
        {name: "Spanish", value: "es"}, {name: "Same as the paper", value: "source"}]
    readonly property var ai: researchStore.ai
    readonly property var current: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    readonly property bool needsKey: current.kind === "api"
    readonly property bool keyStored: (ai.providers, ai.hasApiKey(current.id))
    property string testResult: ""
    property bool testOk: false
    property var codexAccount: ({})
    property var ollamaModels: []
    Connections {
        target: root.ai
        function onConnectionTested(provider, ok, detail) { root.testOk = ok; root.testResult = detail }
        function onCodexAccountChanged(account) { root.codexAccount = account }
        function onOllamaModelsLoaded(models) { root.ollamaModels = models }
    }
    // Re-read the account or local models when the provider changes, not when its details refresh.
    readonly property string currentId: current.id || ""
    onCurrentIdChanged: refreshProvider()
    function refreshProvider() {
        testResult = ""
        if (currentId === "codex") ai.refreshCodexAccount()
        if (currentId === "ollama") ai.listOllamaModels()
    }
    Component.onCompleted: refreshProvider()
    SettingsGroup {
        title: "Answers"
        note: "Used for Explain, Summarize and other one-click actions, and as the Translate target. A question you type is answered in the language you wrote it in."
        SettingsRow {
            label: "Preferred language"
            ComboBox {
                objectName: "aiLanguageBox"
                Layout.preferredWidth: 200
                model: root.languages.map(function(l) { return l.name })
                currentIndex: Math.max(0, root.languages.findIndex(function(l) { return l.value === researchStore.setting("aiLanguage", "ko") }))
                onActivated: function(index) { researchStore.setSetting("aiLanguage", root.languages[index].value) }
            }
        }
        SettingsRow {
            label: "Show thinking"
            detail: "A short summary of the model's reasoning, folded above each answer"
            Switch {
                objectName: "aiShowThinking"
                checked: researchStore.setting("ai.showThinking", "1") === "1"
                onToggled: researchStore.setSetting("ai.showThinking", checked ? "1" : "0")
            }
        }
    }
    SettingsGroup {
        title: "Provider"
        note: "Keys are stored in " + root.ai.keyStorage() + ". Before the first request to a provider, Owelk shows what will be sent. "
            + "Claude is available with an API key; signing in with a Claude.ai account is not offered because Anthropic does not allow it for third-party apps."
        SettingsRow {
            label: "Provider"
            ComboBox {
                objectName: "aiSettingsProvider"
                Layout.preferredWidth: 220
                textRole: "name"
                model: root.ai.providers
                currentIndex: Math.max(0, root.ai.providers.findIndex(function(p) { return p.id === root.ai.provider }))
                onActivated: function(index) { root.ai.provider = root.ai.providers[index].id }
            }
        }
        SettingsRow {
            visible: root.needsKey
            label: "API key"
            wide: true
            TextField {
                id: keyField
                objectName: "aiKeyField"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: root.keyStored ? "Stored securely" : "Paste your API key"
                onAccepted: if (text.trim().length && root.ai.setApiKey(root.current.id, text)) clear()
            }
            Button {
                objectName: "aiSaveKey"; text: "Save"; primary: keyField.text.trim().length > 0
                enabled: keyField.text.trim().length > 0
                onClicked: { if (root.ai.setApiKey(root.current.id, keyField.text)) keyField.clear() }
            }
            IconButton { visible: root.keyStored; icon.name: "trash"; tint: Theme.danger; description: "Remove the stored key"; onClicked: root.ai.clearApiKey(root.current.id) }
            IconButton {
                objectName: "aiGetKey"
                visible: !root.keyStored && (root.current.id === "claude" || root.current.id === "openai")
                icon.name: "external"; description: "Get a key…"
                onClicked: Qt.openUrlExternally(root.current.id === "claude" ? "https://console.anthropic.com/settings/keys" : "https://platform.openai.com/api-keys")
            }
        }
        SettingsRow {
            visible: root.current.id === "codex"
            label: "Account"
            detail: root.codexAccount.available === false ? "Codex CLI not found — install it to sign in"
                : root.codexAccount.signedIn ? "Signed in" + (root.codexAccount.email ? " as " + root.codexAccount.email : "") : "Not signed in"
            Button {
                objectName: "codexSignIn"
                text: root.codexAccount.signedIn ? "Sign Out" : "Sign in with ChatGPT"
                enabled: root.codexAccount.available !== false
                onClicked: root.codexAccount.signedIn ? root.ai.codexSignOut() : root.ai.codexSignIn()
            }
        }
        SettingsRow {
            visible: root.current.id === "ollama"
            label: "Host"
            wide: true
            TextField {
                Layout.fillWidth: true
                text: researchStore.setting("ai.baseUrl.ollama", "http://127.0.0.1:11434/")
                onEditingFinished: { researchStore.setSetting("ai.baseUrl.ollama", text.trim()); root.ai.listOllamaModels() }
            }
        }
        SettingsRow {
            label: "Model"
            wide: true
            TextField {
                id: modelField
                objectName: "aiModelField"
                Layout.fillWidth: true
                text: root.current.model || ""
                placeholderText: root.current.id === "codex" ? "Account default" : root.current.defaultModel || "Model name"
                onEditingFinished: root.ai.setModel(root.current.id, text)
            }
            ComboBox {
                visible: root.current.id === "ollama" && root.ollamaModels.length > 0
                Layout.preferredWidth: 160
                model: root.ollamaModels
                onActivated: function(index) { root.ai.setModel("ollama", root.ollamaModels[index]); modelField.text = root.ollamaModels[index] }
            }
        }
        SettingsRow {
            label: "Connection"
            detail: root.testResult
            Icon { visible: root.testResult.length > 0 && root.testResult !== "Testing…"; name: root.testOk ? "ok" : "alert"; color: root.testOk ? Theme.accent : Theme.danger }
            Label { objectName: "aiTestResult"; visible: false; text: root.testResult }
            Button { objectName: "aiTestConnection"; text: "Test"; onClicked: { root.testOk = false; root.testResult = "Testing…"; root.ai.testConnection(root.current.id) } }
        }
    }
}
