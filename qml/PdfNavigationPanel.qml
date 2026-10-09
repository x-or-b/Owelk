import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf
import "WorkspaceTree.js" as Tree

Item {
    id: root
    objectName: "pdfNavigationPanel"
    property var reader: null
    property int mode: 0
    readonly property bool invertPages: Theme.invertPages && Theme.canInvertPages
    // Thumbnails are drawn for the panel width once a resize pauses (scaled meanwhile).
    property real drawnWidth: 0
    onWidthChanged: if (drawnWidth <= 0) drawnWidth = width; else drawnSettle.restart()
    Timer { id: drawnSettle; interval: 140; onTriggered: root.drawnWidth = root.width }
    signal modeChosen(int mode)
    signal linkActivated(string link)
    // Notes that link to this paper or to its excerpts and annotations.
    readonly property var backlinks: {
        const revision = linkRevision
        return root.reader && root.reader.source.toString().length ? researchStore.backlinks("document", researchStore.documentLinkId(root.reader.source)) : []
    }
    property int linkRevision: 0
    Connections {
        target: researchStore
        function onLinksChanged() { root.linkRevision++ }
        function onNotesChanged() { root.linkRevision++ }
    }
    readonly property bool ready: !!reader && reader.pdfReady
    // Related papers and notes: asked for only while the Related tab is showing.
    property var relatedPapers: []
    property var relatedNotes: []
    property int relatedRequest: -1
    property bool relatedLoading: false
    // Collections this paper probably belongs in (from where similar papers are).
    property var suggestedCollections: []
    property int suggestRequest: -1
    readonly property string relatedSource: ready && mode === 3 ? reader.source.toString() : ""
    onRelatedSourceChanged: {
        relatedPapers = []; relatedNotes = []
        if (!relatedSource.length) { relatedRequest = -1; relatedLoading = false; return }
        relatedLoading = true
        relatedRequest = researchStore.relatedTo(reader.source)
        suggestedCollections = []
        suggestRequest = researchStore.suggestCollections(reader.source)
    }
    Connections {
        target: researchStore
        function onRelatedFound(request, papers, notes) {
            if (request !== root.relatedRequest) return
            root.relatedPapers = papers; root.relatedNotes = notes; root.relatedLoading = false
        }
        function onCollectionsSuggested(request, source, list) { if (request === root.suggestRequest) root.suggestedCollections = list }
    }
    // Citations (Semantic Scholar): shown from the cache when the tab opens; fetched only on request.
    property var citations: null
    property int citationsRequest: -1
    property bool citationsLoading: false
    property int citationsSide: 0
    readonly property string citationsSource: ready && mode === 4 ? reader.source.toString() : ""
    onCitationsSourceChanged: {
        citations = null; citationsLoading = false; citationsRequest = -1
        if (citationsSource.length) citationsRequest = researchStore.loadCitations(reader.source, false, true)
    }
    function fetchCitations(refresh) {
        citationsLoading = true
        citationsRequest = researchStore.loadCitations(reader.source, refresh, false)
    }
    readonly property var citationRows: citations ? (citationsSide === 0 ? citations.references || [] : citations.citedBy || []) : []
    function openCitation(row) {
        if (row.inLibrary) root.linkActivated("owelk://document/" + researchStore.documentLinkId(row.inLibrary))
        else if (row.url) root.linkActivated(row.url)
    }
    Connections {
        target: researchStore
        function onCitationsLoaded(request, source, result) {
            if (request !== root.citationsRequest) return
            root.citationsLoading = false
            root.citations = result
        }
    }
    // Symbols (AI): the paper's notation, asked for only on request and kept per paper.
    property var symbols: []
    property int symbolsRequest: -1
    property bool symbolsLoading: false
    property string symbolsError: ""
    readonly property string symbolsSource: ready && mode === 2 ? reader.source.toString() : ""
    onSymbolsSourceChanged: loadSymbols()
    function loadSymbols() {
        symbolsError = ""
        symbols = symbolsSource.length ? researchStore.ai.notation(reader.source) : []
    }
    readonly property var aiProvider: researchStore.ai.providers.find(function(p) { return p.id === researchStore.ai.provider }) || ({})
    function findSymbols() {
        symbolsError = ""
        if (!aiProvider.configured && researchStore.ai.provider !== "ollama") {
            symbolsError = researchStore.ai.provider === "codex" ? "Sign in with ChatGPT in Settings → AI." : "Add an API key in Settings → AI."
            return
        }
        // Pressing the button, under the note on what is sent, is the agreement.
        researchStore.ai.giveConsent(researchStore.ai.provider)
        symbolsLoading = true
        symbolsRequest = researchStore.ai.findSymbols(reader.source)
    }
    // Where a symbol is defined: that page, with its defining words lit (and Back to return).
    function goToSymbol(entry) {
        if (!entry.page) return
        let link = "owelk://document/" + researchStore.documentLinkId(reader.source) + "#page=" + entry.page
        if (entry.quote) link += "&q=" + encodeURIComponent(entry.quote)
        linkActivated(link)
    }
    Connections {
        target: researchStore.ai
        function onFinished(id) { if (id === root.symbolsRequest) { root.symbolsLoading = false; root.symbolsRequest = -1 } }
        function onFailed(id, message) {
            if (id !== root.symbolsRequest) return
            root.symbolsLoading = false; root.symbolsRequest = -1
            if (message !== "Stopped.") root.symbolsError = message
        }
        function onNotationChanged(paper) { if (root.symbolsSource.length && researchStore.sameSource(paper, root.reader.source)) root.loadSymbols() }
    }
    PdfDocument { id: emptyDocument }
    // A blank document also avoids passing null to an active Qt PDF image/model during tab removal.
    readonly property var navigationDocument: reader && reader.pdfDocument ? reader.pdfDocument : emptyDocument
    function go(page, location) {
        if (!ready || page < 0 || page >= reader.pageCount) return
        const size = reader.pdfDocument.pagePointSize(page)
        reader.jumpToPage(page, location ? Math.max(0, location.y / size.height) : 0)
    }
    PdfBookmarkModel { id: bookmarks; document: root.navigationDocument }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8
        Label {
            Layout.fillWidth: true
            text: root.reader && root.reader.source.toString().length ? (researchStore.documentsRevision, researchStore.displayName(root.reader.source)) : "No active PDF"
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.pixelSize: Theme.fontSmall
            color: Theme.textSecondary
        }
        TabBar {
            objectName: "navigationMode"
            Layout.fillWidth: true
            currentIndex: root.mode
            TabButton { id: outlineTab; objectName: "outlineTab"; icon.name: "outline"; ToolTip.text: "Outline"; onClicked: root.modeChosen(0) }
            TabButton { id: thumbnailsTab; objectName: "thumbnailsTab"; icon.name: "thumbnails"; ToolTip.text: "Thumbnails"; onClicked: root.modeChosen(1) }
            TabButton { id: symbolsTab; objectName: "symbolsTab"; icon.name: "symbols"; ToolTip.text: "Symbols"; onClicked: root.modeChosen(2) }
            TabButton { id: relatedTab; objectName: "relatedTab"; icon.name: "related"; ToolTip.text: "Related"; onClicked: root.modeChosen(3) }
            TabButton { id: citationsTab; objectName: "citationsTab"; icon.name: "citations"; ToolTip.text: "Citations"; onClicked: root.modeChosen(4) }
        }
        Flickable {
            objectName: "relatedView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 3 && root.ready
            clip: true
            contentHeight: relatedColumn.implicitHeight
            ColumnLayout {
                id: relatedColumn
                width: parent.width
                spacing: 2
                // Notes linking to this paper or to its excerpts and annotations.
                Label { visible: root.backlinks.length > 0; text: "Linked notes"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 4 }
                Repeater {
                    model: root.backlinks
                    delegate: ItemDelegate {
                        required property var modelData
                        required property int index
                        objectName: "backlink-" + index
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: Theme.fontSmall
                        onClicked: root.linkActivated("owelk://" + modelData.kind + "/" + modelData.id)
                    }
                }
                Label { text: "Similar papers"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: root.backlinks.length ? 10 : 4 }
                Repeater {
                    model: root.relatedPapers
                    delegate: ItemDelegate {
                        required property var modelData
                        objectName: "relatedPaper-" + index
                        required property int index
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: Theme.fontSmall
                        ToolTip.visible: hovered; ToolTip.delay: 450; ToolTip.text: researchStore.localPath(modelData.source)
                        onClicked: root.linkActivated("owelk://document/" + modelData.documentId)
                    }
                }
                Label {
                    visible: !root.relatedPapers.length
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                    text: root.relatedLoading ? "Looking for related papers…" : "No related papers in the library yet."
                }
                Label { text: "Similar notes"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 10 }
                Repeater {
                    // Notes linked above are not repeated.
                    model: root.relatedNotes.filter(function(n) { return !root.backlinks.some(function(b) { return b.kind === "note" && b.id === n.id }) })
                    delegate: ItemDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: Theme.fontSmall
                        onClicked: root.linkActivated("owelk://note/" + modelData.id)
                    }
                }
                Label {
                    visible: !root.relatedNotes.length && !root.relatedLoading
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                    text: "No notes share this paper's key words."
                }
                Label {
                    visible: root.suggestedCollections.length > 0
                    text: "Add to collection"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 10
                }
                Flow {
                    visible: root.suggestedCollections.length > 0
                    Layout.fillWidth: true; Layout.bottomMargin: 6
                    spacing: 4
                    Repeater {
                        model: root.suggestedCollections
                        delegate: Chip {
                            required property var modelData
                            objectName: "suggestedCollection-" + modelData.name
                            text: "+ " + modelData.name
                            ToolTip.text: "Add to " + modelData.name
                            onClicked: {
                                const url = root.reader.source, id = modelData.id
                                root.suggestedCollections = root.suggestedCollections.filter(function(c) { return c.id !== id })
                                researchStore.setDocumentCollection(url, id, true)
                            }
                        }
                    }
                }
            }
        }
        ColumnLayout {
            objectName: "citationsView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 4 && root.ready
            spacing: 6
            readonly property bool loaded: !!root.citations && !root.citations.notLoaded && !root.citations.error
            // Before anything is fetched: what the button sends.
            Label {
                visible: !parent.loaded && !root.citationsLoading
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall
                color: root.citations && root.citations.error ? Theme.danger : Theme.textTertiary
                text: root.citations && root.citations.error ? root.citations.error
                    : "Papers this one cites and papers citing it, from Semantic Scholar. Sends this paper's DOI, arXiv ID or title."
            }
            Button {
                objectName: "findCitations"
                visible: !parent.loaded && !root.citationsLoading
                text: root.citations && root.citations.error ? "Try Again" : "Find Citations"
                onClicked: root.fetchCitations(!!(root.citations && root.citations.error))
            }
            Label {
                visible: root.citationsLoading
                text: "Asking Semantic Scholar…"; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
            }
            RowLayout {
                visible: parent.loaded
                Layout.fillWidth: true
                TabBar {
                    objectName: "citationsSide"
                    Layout.fillWidth: true
                    currentIndex: root.citationsSide
                    TabButton { objectName: "citesTab"; text: "Cites " + (root.citations && root.citations.references ? root.citations.references.length : 0); onClicked: root.citationsSide = 0 }
                    TabButton { objectName: "citedByTab"; text: "Cited by " + (root.citations && root.citations.citedBy ? root.citations.citedBy.length : 0); onClicked: root.citationsSide = 1 }
                }
                IconButton {
                    objectName: "refreshCitations"
                    icon.name: "reload"
                    description: "Refresh"
                    onClicked: root.fetchCitations(true)
                }
            }
            ListView {
                id: citationList
                objectName: "citationList"
                visible: parent.loaded
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.citationRows
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id: citation
                    required property var modelData
                    required property int index
                    objectName: "citation-" + index
                    width: ListView.view.width
                    height: Theme.rowHeightTall
                    separator: index < citationList.count - 1
                    onClicked: root.openCitation(modelData)
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: { citationMenu.row = citation.modelData; citationMenu.popup() } }
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: modelData.inLibrary ? "In your Library · click to open" : "Open " + modelData.url
                    contentItem: ColumnLayout {
                        spacing: 1
                        Label {
                            Layout.fillWidth: true; elide: Text.ElideRight; textFormat: Text.PlainText
                            text: citation.modelData.title; font.pixelSize: Theme.fontSmall; color: Theme.text
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Label {
                                Layout.fillWidth: true; elide: Text.ElideRight; textFormat: Text.PlainText
                                font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                text: [citation.modelData.authors, citation.modelData.year,
                                       citation.modelData.citations ? citation.modelData.citations + " citations" : ""].filter(function(t) { return !!t }).join(" · ")
                            }
                            Label {
                                visible: !!citation.modelData.inLibrary
                                text: "In Library"; font.pixelSize: Theme.fontCaption; color: Theme.accent
                            }
                        }
                    }
                }
                Label {
                    anchors.centerIn: parent; width: parent.width - 16
                    visible: parent.count === 0
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                    text: root.citationsSide === 0 ? "Semantic Scholar lists no references for this paper." : "No citing papers are known yet."
                }
            }
            // Before the list exists, this takes the rest of the height so the panel keeps its layout.
            Item { Layout.fillHeight: true; Layout.fillWidth: true; visible: !parent.loaded }
            Menu {
                id: citationMenu
                property var row: ({})
                MenuItem { text: citationMenu.row.inLibrary ? "Open" : "Open Page"; onTriggered: root.openCitation(citationMenu.row) }
                MenuItem {
                    text: "Find Paper"
                    onTriggered: root.linkActivated(Tree.referenceUrl([citationMenu.row.authors, citationMenu.row.title, citationMenu.row.year].join(" "),
                                                                     researchStore.setting("searchEngine", "https://scholar.google.com/scholar?q=%s")))
                }
                MenuItem { text: "Copy Title"; onTriggered: researchStore.copyText(citationMenu.row.title) }
            }
        }
        ColumnLayout {
            objectName: "symbolsView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 2 && root.ready
            spacing: 6
            readonly property bool loaded: root.symbols.length > 0
            // Before anything is asked: what the button sends.
            Label {
                visible: !parent.loaded && !root.symbolsLoading
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                text: "The symbols this paper uses: what each means and where it is defined. Sends the paper's text to "
                      + (root.aiProvider.sends || root.aiProvider.name || "the AI provider") + "."
            }
            Button {
                objectName: "findSymbols"
                visible: !parent.loaded && !root.symbolsLoading
                text: root.symbolsError.length ? "Try Again" : "Find Symbols"
                onClicked: root.findSymbols()
            }
            RowLayout {
                visible: root.symbolsLoading
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: "Finding symbols…"; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                IconButton { objectName: "stopSymbols"; icon.name: "stop"; description: "Stop"; onClicked: researchStore.ai.cancel(root.symbolsRequest) }
            }
            Label {
                objectName: "symbolsError"
                visible: root.symbolsError.length > 0
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.danger
                text: root.symbolsError
            }
            RowLayout {
                visible: parent.loaded && !root.symbolsLoading
                Layout.fillWidth: true
                Label { Layout.fillWidth: true; text: root.symbols.length + " symbols"; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                IconButton { objectName: "refreshSymbols"; icon.name: "reload"; description: "Refresh"; onClicked: root.findSymbols() }
            }
            ListView {
                objectName: "symbolList"
                visible: parent.loaded
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: root.symbols
                ScrollBar.vertical: ScrollBar {}
                // A row: the symbol as typeset, what it means, and where it is defined (click: go there).
                delegate: ItemDelegate {
                    id: symbolRow
                    required property var modelData
                    required property int index
                    objectName: "symbolRow-" + index
                    width: ListView.view.width
                    height: Math.max(Theme.rowHeight, details.implicitHeight + 10)
                    enabled: modelData.page > 0
                    onClicked: root.goToSymbol(modelData)
                    contentItem: Item {
                        Text {
                            id: symbol
                            x: 2; width: 48
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.RichText
                            text: researchStore.markdownHtml("$" + symbolRow.modelData.symbol + "$", Theme.accent, Theme.text, Theme.fontBody)
                            color: Theme.text; font.pixelSize: Theme.fontSmall
                        }
                        Column {
                            id: details
                            x: symbol.x + symbol.width + 4
                            width: parent.width - x
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Label {
                                width: parent.width
                                text: symbolRow.modelData.meaning
                                wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.text
                            }
                            Label {
                                text: symbolRow.modelData.page > 0 ? "p. " + symbolRow.modelData.page : "Background"
                                font.pixelSize: Theme.fontCaption
                                color: symbolRow.modelData.page > 0 && symbolRow.hovered ? Theme.accent : Theme.textTertiary
                            }
                        }
                    }
                }
            }
            Item { Layout.fillHeight: true; Layout.fillWidth: true; visible: !parent.loaded }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 0 && root.ready
        TreeView {
            id: outline
            objectName: "pdfOutline"
            anchors.fill: parent
            anchors.leftMargin: 4; anchors.rightMargin: 4
            model: bookmarks
            clip: true
            columnWidthProvider: function(column) { return width }
            ScrollBar.vertical: ScrollBar {}
            // A list row like the Files panel: a chevron for sections with subsections, the page at the right.
            delegate: ItemDelegate {
                id: entry
                required property TreeView treeView
                required property bool expanded
                required property bool hasChildren
                required property int depth
                required property int row
                required property string title
                required property int page
                required property point location
                implicitWidth: outline.width
                implicitHeight: Theme.rowHeight
                leftPadding: 22 + depth * 12
                rightPadding: pageLabel.implicitWidth + 16
                text: title
                font.pixelSize: Theme.fontSmall
                font.weight: depth === 0 ? Font.Medium : Font.Normal
                palette.text: depth === 0 ? Theme.text : Theme.textSecondary
                onClicked: root.go(page, location)
                Item {
                    visible: entry.hasChildren
                    x: 2 + entry.depth * 12; width: 20; height: parent.height
                    Icon { anchors.centerIn: parent; name: entry.expanded ? "down" : "right"; size: Theme.fontSmall; color: Theme.textTertiary }
                    TapHandler { onTapped: entry.treeView.toggleExpanded(entry.row) }
                }
                Label {
                    id: pageLabel
                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    text: entry.page + 1
                    font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                }
            }
        }
            Label {
                objectName: "emptyOutlineMessage"
                anchors.centerIn: parent
                width: Math.max(0, parent.width - 24)
                visible: outline.rows === 0
                text: "This PDF has no embedded outline.\nUse Thumbnails to navigate."
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary
            }
        }
        ListView {
            id: thumbs
            objectName: "pdfThumbnails"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 1 && root.ready
            model: visible ? root.reader.pageCount : 0
            currentIndex: root.ready ? root.reader.currentPage : -1
            onCurrentIndexChanged: if (visible && currentIndex >= 0) Qt.callLater(function() { thumbs.positionViewAtIndex(thumbs.currentIndex, ListView.Contain) })
            onVisibleChanged: if (visible && currentIndex >= 0) Qt.callLater(function() { thumbs.positionViewAtIndex(thumbs.currentIndex, ListView.Contain) })
            clip: true
            cacheBuffer: 180
            reuseItems: true
            spacing: 10
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                id: thumb
                required property int index
                objectName: "thumbnail-" + index
                width: thumbs.width
                height: preview.height + 30
                padding: 6
                onClicked: root.go(index, null)
                background: Rectangle { color: Theme.window; border.color: root.reader && root.reader.currentPage === thumb.index ? Theme.accent : Theme.separator; radius: Theme.radius }
                contentItem: Column {
                    spacing: 4
                    // A page on paper, so text stays readable on a dark theme; Dark pages turn it dark too.
                    Rectangle {
                        id: preview
                        objectName: "thumbnailPaper-" + thumb.index
                        readonly property size points: root.ready ? root.reader.pdfDocument.pagePointSize(thumb.index) : Qt.size(595, 842)
                        width: thumb.width - 12
                        height: Math.min(250, width * points.height / Math.max(1, points.width))
                        color: root.invertPages ? Theme.paperInverted : Theme.paper
                        PdfPageImage {
                            objectName: "thumbnailImage-" + thumb.index
                            anchors.fill: parent
                            document: root.navigationDocument
                            currentFrame: thumb.index
                            asynchronous: true
                            cache: false
                            sourceSize.width: Math.min(440, Math.ceil((root.drawnWidth - 12) * Screen.devicePixelRatio))
                            fillMode: Image.PreserveAspectFit
                            layer.enabled: root.invertPages
                            layer.effect: ShaderEffect { objectName: "thumbnailInvert"; fragmentShader: "qrc:/owelk/shaders/invert.frag.qsb" }
                        }
                    }
                    Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: thumb.index + 1; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                }
            }
        }
        Label {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.ready
            text: root.reader && root.reader.source.toString().length ? "PDF is unavailable or still loading." : "Open a PDF to see its outline and pages."
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: Theme.textTertiary
        }
    }
}
