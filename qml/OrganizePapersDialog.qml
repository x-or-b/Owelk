import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AI topic collections: shows what will be sent, asks the chosen provider to sort the papers by topic
// (reusing existing collection names where they fit), and changes the Library only on Apply. Papers
// are only added to collections; nothing is moved out of one or deleted.
Dialog {
    id: root
    objectName: "organizePapersDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(540, parent ? parent.width - 48 : 540)
    height: Math.min(620, parent ? parent.height - 64 : 620)
    modal: true
    title: qsTr("Organize Papers into Collections")
    readonly property var ai: researchStore.ai
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    readonly property int limit: 80
    // New collections go inside this one (the collection being shown), or at the top.
    property string parentCollection: ""
    property var papers: []
    property var existing: []
    property var suggestions: []
    property int request: -1
    property bool asking: false
    property string error: ""
    function begin(urls, parentId) {
        parentCollection = parentId || ""
        existing = researchStore.collections()
        papers = urls.slice(0, limit).map(function(url) {
            const details = researchStore.documentDetails(url)
            return {id: url.toString(), title: researchStore.displayName(url), authors: details.authors || "", year: details.year || "",
                    opening: researchStore.paperOpening(url, 300)}
        })
        suggestions = []; error = ""; asking = false; request = -1
        open()
    }
    // The collection a suggested name stands for: one inside the parent first, then any with that name.
    function match(name) {
        const key = name.trim().toLowerCase()
        const same = existing.filter(function(c) { return c.name.toLowerCase() === key })
        return same.find(function(c) { return (c.parentId || "") === parentCollection }) || same[0] || null
    }
    function ask() {
        error = ""
        if (!providerInfo.configured && ai.provider !== "ollama") { error = qsTr("Set up an AI provider in Settings → AI."); return }
        // Pressing Ask is the reader's agreement to send what is listed above.
        ai.giveConsent(ai.provider)
        asking = true
        const names = existing.map(function(c) { return c.name }).filter(function(n, i, all) { return all.indexOf(n) === i })
        request = ai.organizePapers(papers, names)
    }
    function apply() {
        suggestions.filter(function(g) { return g.keep && g.name.trim().length && g.ids.length }).forEach(function(g) {
            const found = match(g.name)
            const id = found ? found.id : researchStore.createCollection(g.name.trim(), parentCollection)
            if (id) researchStore.setDocumentsCollection(g.ids, id, true)
        })
        close()
    }
    Connections {
        target: root.ai
        function onPapersOrganized(id, groups, error) {
            if (id !== root.request) return
            root.asking = false
            root.error = error
            root.suggestions = groups.map(function(g) { return {name: g.name, keep: true, ids: g.paperIds.slice()} })
        }
    }
    footer: DialogButtonBox {
        Button {
            objectName: "organizePapersAsk"
            text: root.asking ? qsTr("Asking…") : root.suggestions.length ? qsTr("Ask Again") : qsTr("Ask ") + (root.providerInfo.name || qsTr("AI"))
            enabled: !root.asking && root.papers.length >= 2
            onClicked: root.ask()
        }
        Button {
            objectName: "organizePapersApply"
            text: qsTr("Apply")
            highlighted: true
            enabled: (editor.revision, root.suggestions.some(function(g) { return g.keep && g.name.trim().length && g.ids.length }))
            onClicked: root.apply()
        }
        Button { text: qsTr("Cancel"); onClicked: root.close() }
    }
    contentItem: ColumnLayout {
        spacing: 8
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
            visible: !root.suggestions.length
            text: root.papers.length < 2 ? qsTr("Choose at least two papers to organize.")
                : qsTr("Sends the titles, authors, years and first lines of these ") + root.papers.length + qsTr(" papers, and the names of your collections, to ")
                  + (root.providerInfo.name || qsTr("the AI provider")) + ". Papers are only added to collections, and only when you press Apply."
        }
        Label {
            objectName: "organizePapersError"
            visible: root.error.length > 0
            Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.danger; font.pixelSize: Theme.fontSmall
            text: root.error
        }
        // Rename, skip or regroup before applying: uncheck a paper, move it, or start a new collection.
        GroupEditor {
            id: editor
            objectName: "organizePapersSuggestions"
            Layout.fillWidth: true; Layout.fillHeight: true
            groups: root.suggestions
            items: root.papers
            // Whether Apply adds to a collection you have or makes a new one.
            badge: function(name) { return root.match(name) ? {text: qsTr("Existing")} : {text: qsTr("New"), emphasis: true} }
        }
        Label {
            Layout.alignment: Qt.AlignHCenter
            visible: root.asking
            text: qsTr("Asking ") + (root.providerInfo.name || qsTr("AI")) + "…"
            color: Theme.textTertiary
        }
    }
}
