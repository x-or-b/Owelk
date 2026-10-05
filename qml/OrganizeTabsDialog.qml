import Owelk.Ui
import "WorkspaceTree.js" as Tree
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AI tab organization: shows what will be sent, asks the chosen provider for named groups, and applies
// only the groups the reader keeps. Nothing about the tabs changes before Apply.
UiControls.Dialog {
    id: root
    objectName: "organizeTabsDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(520, parent ? parent.width - 48 : 520)
    height: Math.min(600, parent ? parent.height - 64 : 600)
    modal: true
    title: "Organize Tabs"
    required property var controller
    readonly property var ai: researchStore.ai
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    property string stripId: ""
    property var tabs: []
    property var suggestions: []
    property int request: -1
    property bool asking: false
    property string error: ""
    // Edits change objects inside suggestions; this counter lets bindings see them.
    property int revision: 0
    function begin(groupId) {
        stripId = groupId
        const strip = Tree.find(controller.tree, groupId)
        tabs = strip ? strip.tabs.filter(function(t) { return t.kind !== "home" }).map(function(t) {
            const details = !t.kind ? researchStore.documentDetails(t.source) : ({})
            return {id: t.id, title: t.kind === "note" ? (t.title || "Note") : t.kind === "web" ? (t.title || t.source) : t.kind === "library" ? "Library" : researchStore.displayName(t.source),
                    url: t.kind === "web" ? t.source : "", authors: details.authors || "", year: details.year || "",
                    opening: !t.kind ? researchStore.paperOpening(t.source, 400) : ""}
        }) : []
        suggestions = []; error = ""; asking = false; request = -1
        open()
    }
    function ask() {
        error = ""
        if (!providerInfo.configured && ai.provider !== "ollama") { error = "Set up an AI provider in Settings → AI."; return }
        // Pressing Ask is the reader's agreement to send what is listed above.
        ai.giveConsent(ai.provider)
        asking = true
        request = ai.organizeTabs(tabs)
    }
    function apply() {
        const chosen = suggestions.filter(function(g) { return g.keep }).map(function(g) { return {name: g.name, tabIds: g.tabIds} })
        controller.applyTabGroups(stripId, chosen)
        close()
    }
    Connections {
        target: root.ai
        function onTabsOrganized(id, groups, error) {
            if (id !== root.request) return
            root.asking = false
            root.error = error
            root.suggestions = groups.map(function(g) { return Object.assign({keep: true}, g) })
        }
    }
    footer: DialogButtonBox {
        UiControls.Button {
            objectName: "organizeAsk"
            text: root.asking ? "Asking…" : root.suggestions.length ? "Ask Again" : "Ask " + (root.providerInfo.name || "AI")
            enabled: !root.asking && root.tabs.length >= 2
            onClicked: root.ask()
        }
        UiControls.Button {
            objectName: "organizeApply"
            text: "Apply"
            highlighted: true
            enabled: (root.revision, root.suggestions.some(function(g) { return g.keep && g.name.trim().length }))
            onClicked: root.apply()
        }
        UiControls.Button { text: "Cancel"; onClicked: root.close() }
    }
    contentItem: ColumnLayout {
        spacing: 8
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
            visible: !root.suggestions.length
            text: root.tabs.length < 2 ? "Open at least two tabs in this strip to organize them."
                : "Sends the titles of these " + root.tabs.length + " tabs, web addresses, paper authors and years, and the first lines of each paper to "
                  + (root.providerInfo.sends || "the AI provider") + ". Your tabs change only when you press Apply."
        }
        Label {
            objectName: "organizeError"
            visible: root.error.length > 0
            Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.danger; font.pixelSize: 12
            text: root.error
        }
        ListView {
            objectName: "organizeSuggestions"
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 10
            model: root.suggestions
            delegate: ColumnLayout {
                id: suggestion
                required property var modelData
                required property int index
                width: ListView.view.width
                spacing: 2
                RowLayout {
                    Layout.fillWidth: true
                    CheckBox {
                        objectName: "organizeKeep-" + suggestion.index
                        checked: suggestion.modelData.keep
                        onToggled: { root.suggestions[suggestion.index].keep = checked; root.revision++ }
                    }
                    UiControls.TextField {
                        objectName: "organizeName-" + suggestion.index
                        Layout.fillWidth: true
                        text: suggestion.modelData.name
                        maximumLength: 120
                        onTextEdited: { root.suggestions[suggestion.index].name = text; root.revision++ }
                    }
                }
                Repeater {
                    model: suggestion.modelData.tabIds
                    delegate: Label {
                        required property string modelData
                        Layout.fillWidth: true; Layout.leftMargin: 34
                        elide: Text.ElideRight; font.pixelSize: 12; color: Theme.textSecondary
                        text: (root.tabs.find(function(t) { return t.id === modelData }) || {title: ""}).title
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                visible: root.asking
                text: "Asking " + (root.providerInfo.name || "AI") + "…"
                color: Theme.textTertiary
            }
        }
    }
}
