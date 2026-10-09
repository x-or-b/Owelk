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
            TabButton {
                id: linksTab; objectName: "linksTab"; icon.name: "link"
                ToolTip.text: "Notes linking to this paper" + (root.backlinks.length ? " · " + root.backlinks.length : "")
                onClicked: root.modeChosen(2)
            }
            TabButton { id: relatedTab; objectName: "relatedTab"; icon.name: "related"; ToolTip.text: "Related papers and notes"; onClicked: root.modeChosen(3) }
            TabButton { id: citationsTab; objectName: "citationsTab"; icon.name: "citations"; ToolTip.text: "Citations: what this paper cites and what cites it"; onClicked: root.modeChosen(4) }
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
                Label {
                    visible: root.suggestedCollections.length > 0
                    text: "Add to collection"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 4
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
                            ToolTip.text: "Add this paper to " + modelData.name + " · similar papers are there"
                            onClicked: {
                                const url = root.reader.source, id = modelData.id
                                root.suggestedCollections = root.suggestedCollections.filter(function(c) { return c.id !== id })
                                researchStore.setDocumentCollection(url, id, true)
                            }
                        }
                    }
                }
                Label { text: "Papers"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 4 }
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
                Label { text: "Notes"; font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 10 }
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
                    description: "Ask Semantic Scholar again" + (root.citations && root.citations.cached ? " · showing saved results" : "")
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
        ListView {
            objectName: "backlinkList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 2 && root.ready
            clip: true
            model: root.backlinks
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                text: modelData.title
                font.pixelSize: Theme.fontSmall
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: modelData.via === "document" ? "Links to this paper" : "Links to an " + (modelData.via === "capture" ? "excerpt" : "annotation") + " in this paper"
                onClicked: root.linkActivated("owelk://" + modelData.kind + "/" + modelData.id)
            }
            Label {
                anchors.centerIn: parent; width: parent.width - 16
                visible: parent.count === 0
                text: "No notes link to this paper yet. Use Link to Note… on an excerpt or annotation, or [[ in a note."
                wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; color: Theme.textTertiary
            }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 0 && root.ready
        TreeView {
            id: outline
            objectName: "pdfOutline"
            anchors.fill: parent
            model: bookmarks
            clip: true
            columnWidthProvider: function(column) { return width }
            ScrollBar.vertical: ScrollBar {}
            delegate: TreeViewDelegate {
                required property string title
                required property int page
                required property point location
                implicitHeight: 34
                implicitWidth: outline.width
                text: title
                onClicked: root.go(page, location)
                ToolTip.visible: hovered
                ToolTip.text: title + " · Page " + (page + 1)
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
