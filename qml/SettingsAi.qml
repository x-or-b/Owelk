import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "AiNames.js" as AiNames

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
    // The provider's models, as the AI panel offers them: [{id, name, efforts, defaultEffort}].
    property var models: []
    property bool modelsLoaded: false
    property bool otherModel: false
    readonly property string chatModel: (ai.providers, current.model || "")
    readonly property var chatInfo: models.find(function(m) { return m.id === root.chatModel }) || ({})
    readonly property string glossChoice: (ai.providers, ai.glossChoice(currentId))
    readonly property string glossEffort: (ai.providers, ai.glossEffort(currentId))
    readonly property var glossInfo: models.find(function(m) { return m.id === (root.glossChoice === "auto" ? root.ai.glossModel(root.currentId) : root.glossChoice) }) || ({})
    property int settingsRevision: 0
    Connections {
        target: root.ai
        function onConnectionTested(provider, ok, detail) { root.testOk = ok; root.testResult = detail }
        function onCodexAccountChanged(account) { root.codexAccount = account }
        function onModelsLoaded(provider, list) {
            if (provider !== root.currentId) return
            root.models = list; root.modelsLoaded = true
        }
    }
    Connections { target: researchStore; function onSettingsChanged() { root.settingsRevision++ } }
    // Re-read the account and the models when the provider changes, not when its details refresh.
    readonly property string currentId: current.id || ""
    onCurrentIdChanged: refreshProvider()
    function refreshProvider() {
        testResult = ""
        models = []; modelsLoaded = false; otherModel = false
        if (currentId === "codex") ai.refreshCodexAccount()
        if (currentId.length) ai.listModels(currentId)
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
            label: "Explanations"
            detail: "How every answer is written"
            ComboBox {
                objectName: "aiExplainLevelBox"
                Layout.preferredWidth: 200
                model: ["Easy, with examples", "Brief"]
                currentIndex: researchStore.setting("ai.explainLevel", "easy") === "brief" ? 1 : 0
                onActivated: function(index) { researchStore.setSetting("ai.explainLevel", index === 1 ? "brief" : "easy") }
            }
        }
        SettingsRow {
            label: "Instructions"
            detail: "Added to every question, for example: \"Put English terms in brackets\" or \"I know Kalman filters\""
            wide: true
            TextArea {
                objectName: "aiInstructions"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(60, implicitHeight)
                wrapMode: TextEdit.Wrap
                placeholderText: "Optional"
                text: researchStore.setting("ai.instructions")
                onEditingFinished: researchStore.setSetting("ai.instructions", text.trim().slice(0, 2000))
            }
        }
        SettingsRow {
            label: "Symbol hints"
            detail: "Once a paper's symbols are listed (Document panel › Symbols), pointing at one shows its meaning"
            Switch {
                objectName: "aiSymbolHints"
                checked: researchStore.setting("ai.symbolHints", "1") === "1"
                onToggled: researchStore.setSetting("ai.symbolHints", checked ? "1" : "0")
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
                onEditingFinished: { researchStore.setSetting("ai.baseUrl.ollama", text.trim()); root.ai.listModels("ollama") }
            }
        }
        // The model and reasoning effort the AI panel starts with (the same choice as its model menu).
        SettingsRow {
            label: "Model"
            ComboBox {
                id: modelBox
                objectName: "aiModelBox"
                Layout.preferredWidth: 220
                readonly property int at: root.models.findIndex(function(m) { return m.id === root.chatModel })
                readonly property var names: (root.models.length ? root.models.map(function(m) { return m.name }) : [root.modelsLoaded ? "Default model" : "Loading…"]).concat(["Other…"])
                // A model typed by name (not in the list) shows as Other….
                readonly property bool custom: root.otherModel || (root.models.length > 0 && at < 0 && root.chatModel.length > 0)
                model: names
                currentIndex: custom ? names.length - 1 : Math.max(0, at)
                onActivated: function(index) {
                    root.otherModel = index === names.length - 1
                    if (root.otherModel) { modelField.forceActiveFocus(); return }
                    root.ai.setModel(root.currentId, root.models.length ? root.models[index].id : "")
                }
            }
        }
        SettingsRow {
            visible: modelBox.custom
            label: "Model name"
            wide: true
            TextField {
                id: modelField
                objectName: "aiModelField"
                Layout.fillWidth: true
                text: root.chatModel
                placeholderText: root.current.defaultModel || "Model name"
                onEditingFinished: root.ai.setModel(root.currentId, text.trim())
            }
        }
        SettingsRow {
            visible: (root.chatInfo.efforts || []).length > 0
            label: "Reasoning"
            detail: "Higher thinks longer and costs more"
            ComboBox {
                objectName: "aiEffortBox"
                Layout.preferredWidth: 160
                readonly property var efforts: root.chatInfo.efforts || []
                readonly property string chosen: (root.settingsRevision, researchStore.setting("ai.effort." + root.currentId, ""))
                model: efforts.map(function(e) { return AiNames.effortName(e) })
                currentIndex: Math.max(0, efforts.indexOf(efforts.indexOf(chosen) >= 0 ? chosen : (root.chatInfo.defaultEffort || efforts[0])))
                onActivated: function(index) { researchStore.setSetting("ai.effort." + root.currentId, efforts[index]) }
            }
        }
        // Gloss (a word's meaning or a passage's translation beside the selection): quick by default.
        SettingsRow {
            label: "Gloss model"
            ComboBox {
                objectName: "aiGlossModelBox"
                Layout.preferredWidth: 220
                model: ["Fast (automatic)"].concat(root.models.map(function(m) { return m.name }))
                currentIndex: root.glossChoice === "auto" ? 0 : root.models.findIndex(function(m) { return m.id === root.glossChoice }) + 1
                onActivated: function(index) { root.ai.setGloss(root.currentId, index === 0 ? "" : root.models[index - 1].id, root.glossEffort) }
            }
        }
        SettingsRow {
            visible: (root.glossInfo.efforts || []).length > 0
            label: "Gloss reasoning"
            ComboBox {
                id: glossEffortBox
                objectName: "aiGlossEffortBox"
                Layout.preferredWidth: 160
                readonly property var efforts: root.glossInfo.efforts || []
                model: efforts.map(function(e) { return AiNames.effortName(e) })
                // Set after the list changes (a binding would fight the list resetting it).
                function sync() { currentIndex = Math.max(0, efforts.indexOf(root.glossEffort)) }
                onModelChanged: Qt.callLater(sync)
                Connections { target: root; function onGlossEffortChanged() { glossEffortBox.sync() } }
                onActivated: function(index) { root.ai.setGloss(root.currentId, root.glossChoice === "auto" ? "" : root.glossChoice, efforts[index]) }
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
