import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Compare papers with AI: a table (one row per paper, one column per aspect) and the main differences.
// Shows what will be sent first; the answer can be copied or saved as a note linking the papers.
Dialog {
    id: root
    objectName: "comparePapersDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(860, parent ? parent.width - 48 : 860)
    height: Math.min(680, parent ? parent.height - 64 : 680)
    modal: true
    title: "Compare Papers"
    readonly property var ai: researchStore.ai
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    readonly property int limit: 8
    readonly property string defaultAspects: "Problem, Method, Data, Results, Limitations"
    property var papers: []
    property string answer: ""
    property int request: -1
    property bool asking: false
    property string error: ""
    signal noteCreated(string id)
    function begin(urls) {
        papers = urls.slice(0, limit).map(function(url) {
            const details = researchStore.documentDetails(url), excerpt = researchStore.paperExcerpt(url, 5000, 2500)
            return {url: url.toString(), title: researchStore.displayName(url), authors: details.authors || "", year: details.year || "",
                    opening: excerpt.opening || "", closing: excerpt.closing || ""}
        })
        aspects.text = researchStore.setting("compare.aspects", defaultAspects)
        answer = ""; error = ""; asking = false; request = -1
        open()
    }
    function ask() {
        error = ""
        if (!providerInfo.configured && ai.provider !== "ollama") { error = "Set up an AI provider in Settings → AI."; return }
        // Pressing Ask is the reader's agreement to send what is listed above.
        ai.giveConsent(ai.provider)
        researchStore.setSetting("compare.aspects", aspects.text)
        answer = ""
        asking = true
        request = ai.comparePapers(papers, aspects.text.split(","))
    }
    // A note with links to each paper, then the comparison.
    function saveAsNote() {
        const links = papers.map(function(p) {
            const id = researchStore.documentLinkId(p.url)
            return "- " + (id.length ? researchStore.markdownLink("document", id) : p.title)
        })
        const id = researchStore.createNote("Comparison: " + papers.map(function(p) { return p.title }).join(" · ").slice(0, 120),
                                            "Papers:\n" + links.join("\n") + "\n\n" + answer + "\n")
        if (id.length) { noteCreated(id); close() }
    }
    Connections {
        target: root.ai
        function onComparisonDelta(id, text) { if (id === root.request) root.answer += text }
        function onPapersCompared(id, markdown, error) {
            if (id !== root.request) return
            root.asking = false
            root.error = error
            if (markdown.length) root.answer = markdown
        }
    }
    footer: DialogButtonBox {
        Button {
            objectName: "compareAsk"
            text: root.asking ? "Asking…" : root.answer.length ? "Ask Again" : "Ask " + (root.providerInfo.name || "AI")
            enabled: !root.asking && root.papers.length >= 2
            onClicked: root.ask()
        }
        Button {
            objectName: "compareCopy"
            text: "Copy"
            enabled: !root.asking && root.answer.length > 0
            onClicked: { researchStore.copyText(root.answer); researchStore.notify("Comparison copied.") }
        }
        Button {
            objectName: "compareSave"
            text: "Save as Note"
            highlighted: true
            enabled: !root.asking && root.answer.length > 0
            onClicked: root.saveAsNote()
        }
        Button { text: "Close"; onClicked: root.close() }
    }
    contentItem: ColumnLayout {
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Label { text: "Compare by"; color: Theme.textSecondary }
            TextField {
                id: aspects
                objectName: "compareAspects"
                Layout.fillWidth: true
                placeholderText: root.defaultAspects
                enabled: !root.asking
                ToolTip.visible: hovered; ToolTip.delay: 500
                ToolTip.text: "The table's columns, separated by commas"
            }
        }
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
            visible: !root.answer.length
            text: root.papers.length < 2 ? "Choose at least two papers to compare."
                : "Sends the titles, authors, years, beginnings (abstract and introduction) and conclusions of these "
                  + root.papers.length + " papers to " + (root.providerInfo.name || "the AI provider") + ": "
                  + root.papers.map(function(p) { return p.title }).join(" · ")
                  + (root.papers.some(function(p) { return !p.opening.length }) ? ". Papers not yet indexed are sent by title only." : "")
        }
        Label {
            objectName: "compareError"
            visible: root.error.length > 0
            Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.danger; font.pixelSize: Theme.fontSmall
            text: root.error
        }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.answer.length > 0 || root.asking
            clip: true
            TextArea {
                objectName: "compareResult"
                readOnly: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.MarkdownText
                text: root.answer.length ? root.answer : "Asking " + (root.providerInfo.name || "AI") + "…"
                selectByMouse: true
            }
        }
        Item { Layout.fillHeight: true; visible: !(root.answer.length > 0 || root.asking) }
    }
}
