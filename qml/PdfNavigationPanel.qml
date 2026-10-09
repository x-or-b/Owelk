import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf
import "WorkspaceTree.js" as Tree

// The Document panel: the paper in front, in four views (mode): 0 Contents (outline or pages), 1
// Annotations (notes about it, then its annotations), 2 Symbols, 3 Related (similar papers in the
// Library, what it cites, what cites it).
Item {
    id: root
    objectName: "pdfNavigationPanel"
    property var reader: null
    property int mode: 0
    // Contents shows the outline or the pages; remembered.
    property string contents: researchStore.setting("document.contents", "outline") === "pages" ? "pages" : "outline"
    function setContents(value) { contents = value; researchStore.setSetting("document.contents", value) }
    // Related: 0 in the Library, 1 papers it cites, 2 papers citing it.
    property int relatedSide: 0
    readonly property bool invertPages: Theme.invertPages && Theme.canInvertPages
    // Thumbnails are drawn for the panel width once a resize pauses (scaled meanwhile).
    property real drawnWidth: 0
    onWidthChanged: if (drawnWidth <= 0) drawnWidth = width; else drawnSettle.restart()
    Timer { id: drawnSettle; interval: 140; onTriggered: root.drawnWidth = root.width }
    signal modeChosen(int mode)
    signal linkActivated(string link)
    signal newNoteRequested(url source)
    // Notes that link to this paper or to its annotations.
    readonly property var linkedNotes: {
        const revision = linkRevision
        return mode === 1 && ready ? researchStore.backlinks("document", researchStore.documentLinkId(reader.source)).filter(function(b) { return b.kind === "note" }) : []
    }
    property int linkRevision: 0
    Connections {
        target: researchStore
        function onLinksChanged() { root.linkRevision++ }
        function onNotesChanged() { root.linkRevision++ }
    }
    readonly property bool ready: !!reader && reader.pdfReady
    // The reader writes new comments into the Annotations list while it shows this paper.
    readonly property var annotationList: annotationLoader.item
    property var listedReader: null
    function updateListing() {
        const next = annotationList && reader ? reader : null
        if (listedReader && listedReader !== next) listedReader.annotationList = null
        listedReader = next
        if (next) next.annotationList = annotationList
    }
    onAnnotationListChanged: updateListing()
    onReaderChanged: updateListing()
    Component.onDestruction: if (listedReader) listedReader.annotationList = null
    // Related papers and notes: asked for only while that view is showing.
    property var relatedPapers: []
    property var relatedNotes: []
    property int relatedRequest: -1
    property bool relatedLoading: false
    readonly property string relatedSource: ready && mode === 3 && relatedSide === 0 ? reader.source.toString() : ""
    onRelatedSourceChanged: {
        relatedPapers = []; relatedNotes = []
        if (!relatedSource.length) { relatedRequest = -1; relatedLoading = false; return }
        relatedLoading = true
        relatedRequest = researchStore.relatedTo(reader.source)
    }
    Connections {
        target: researchStore
        function onRelatedFound(request, papers, notes) {
            if (request !== root.relatedRequest) return
            root.relatedPapers = papers; root.relatedNotes = notes; root.relatedLoading = false
        }
    }
    // Citations (Semantic Scholar): shown from the cache when Related opens; fetched only on request.
    property var citations: null
    property int citationsRequest: -1
    property bool citationsLoading: false
    readonly property string citationsSource: ready && mode === 3 ? reader.source.toString() : ""
    onCitationsSourceChanged: {
        citations = null; citationsLoading = false; citationsRequest = -1
        if (citationsSource.length) citationsRequest = researchStore.loadCitations(reader.source, false, true)
    }
    function fetchCitations(refresh) {
        citationsLoading = true
        citationsRequest = researchStore.loadCitations(reader.source, refresh, false)
    }
    readonly property bool citationsLoaded: !!citations && !citations.notLoaded && !citations.error
    readonly property var citationRows: citations ? (relatedSide === 1 ? citations.references || [] : citations.citedBy || []) : []
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
            TabButton { objectName: "contentsTab"; icon.name: "outline"; ToolTip.text: "Contents"; onClicked: root.modeChosen(0) }
            TabButton { objectName: "annotationsTab"; icon.name: "annotations"; ToolTip.text: "Annotations"; onClicked: root.modeChosen(1) }
            TabButton { objectName: "symbolsTab"; icon.name: "symbols"; ToolTip.text: "Symbols"; onClicked: root.modeChosen(2) }
            TabButton { objectName: "relatedTab"; icon.name: "related"; ToolTip.text: "Related"; onClicked: root.modeChosen(3) }
        }
        // Each view's own choices, in the same small switch.
        TabBar {
            objectName: "contentsMode"
            visible: root.mode === 0 && root.ready
            Layout.fillWidth: true
            currentIndex: root.contents === "pages" ? 1 : 0
            TabButton { objectName: "outlineTab"; text: "Outline"; onClicked: root.setContents("outline") }
            TabButton { objectName: "pagesTab"; text: "Pages"; onClicked: root.setContents("pages") }
        }
        TabBar {
            objectName: "relatedMode"
            visible: root.mode === 3 && root.ready
            Layout.fillWidth: true
            currentIndex: root.relatedSide
            TabButton { objectName: "libraryRelatedTab"; text: "Library"; onClicked: root.relatedSide = 0 }
            TabButton { objectName: "citesTab"; text: "Cites" + (root.citationsLoaded ? " " + (root.citations.references || []).length : ""); onClicked: root.relatedSide = 1 }
            TabButton { objectName: "citedByTab"; text: "Cited by" + (root.citationsLoaded ? " " + (root.citations.citedBy || []).length : ""); onClicked: root.relatedSide = 2 }
        }
        ColumnLayout {
            objectName: "annotationsView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 1 && root.ready
            spacing: 2
            // Notes about this paper (linking to it or its annotations): open one, write a new one beside it.
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 4
                Label { Layout.fillWidth: true; text: "Notes"; font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary }
                IconButton {
                    objectName: "newPaperNote"
                    icon.name: "add"; description: "New note about this paper"
                    onClicked: root.newNoteRequested(root.reader.source)
                }
            }
            Repeater {
                model: root.linkedNotes
                delegate: ItemDelegate {
                    id: linkedNote
                    required property var modelData
                    required property int index
                    objectName: "linkedNote-" + index
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: Theme.fontSmall
                    icon.name: "note"
                    onClicked: root.linkActivated("owelk://note/" + modelData.id)
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: linkedNoteMenu.popup() }
                    Menu {
                        id: linkedNoteMenu
                        MenuItem { text: "Open"; onTriggered: root.linkActivated("owelk://note/" + linkedNote.modelData.id) }
                        MenuItem {
                            objectName: "unlinkNote"
                            text: "Unlink from This Paper"
                            onTriggered: { const id = linkedNote.modelData.id, paper = root.reader.source; Qt.callLater(function() { researchStore.unlinkNote(id, paper) }) }
                        }
                    }
                }
            }
            Label {
                visible: !root.linkedNotes.length
                Layout.fillWidth: true; Layout.leftMargin: 4
                wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                text: "No notes about this paper yet."
            }
            Rectangle { Layout.fillWidth: true; Layout.topMargin: 6; Layout.bottomMargin: 2; height: 1; color: Theme.separator }
            Loader {
                id: annotationLoader
                Layout.fillWidth: true
                Layout.fillHeight: true
                active: root.mode === 1 && root.ready
                sourceComponent: AnnotationList { canvas: root.reader.pdfCanvas; source: root.reader.source }
            }
        }
        Flickable {
            objectName: "relatedView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 3 && root.relatedSide === 0 && root.ready
            clip: true
            contentHeight: relatedColumn.implicitHeight
            ColumnLayout {
                id: relatedColumn
                width: parent.width
                spacing: 2
                Label { text: "Similar papers"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 4 }
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
                    model: root.relatedNotes
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
            }
        }
        ColumnLayout {
            objectName: "citationsView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 3 && root.relatedSide > 0 && root.ready
            spacing: 6
            readonly property bool loaded: root.citationsLoaded
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
                Label {
                    Layout.fillWidth: true
                    text: "From Semantic Scholar"; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
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
                    text: root.relatedSide === 1 ? "Semantic Scholar lists no references for this paper." : "No citing papers are known yet."
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
            visible: root.mode === 0 && root.contents === "outline" && root.ready
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
                text: "This PDF has no embedded outline.\nUse Pages to navigate."
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
            visible: root.mode === 0 && root.contents === "pages" && root.ready
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
            text: root.reader && root.reader.source.toString().length ? "PDF is unavailable or still loading." : "Open a PDF to see its contents, annotations and related papers."
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: Theme.textTertiary
        }
    }
}
