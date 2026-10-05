import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf

Item {
    id: root
    objectName: "pdfNavigationPanel"
    property var reader: null
    property int mode: 0
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
    readonly property string relatedSource: ready && mode === 3 ? reader.source.toString() : ""
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
            font.pixelSize: 12
            color: Theme.textSecondary
        }
        TabBar {
            objectName: "navigationMode"
            Layout.fillWidth: true
            currentIndex: root.mode
            UiControls.TabButton {
                id: outlineTab
                objectName: "outlineTab"
                text: "Outline"
                background: Rectangle { color: outlineTab.checked ? Theme.selected : Theme.window; border.color: Theme.border }
                onClicked: root.modeChosen(0)
            }
            UiControls.TabButton {
                id: thumbnailsTab
                objectName: "thumbnailsTab"
                text: "Thumbnails"
                background: Rectangle { color: thumbnailsTab.checked ? Theme.selected : Theme.window; border.color: Theme.border }
                onClicked: root.modeChosen(1)
            }
            UiControls.TabButton {
                id: linksTab
                objectName: "linksTab"
                text: "Links" + (root.backlinks.length ? " (" + root.backlinks.length + ")" : "")
                background: Rectangle { color: linksTab.checked ? Theme.selected : Theme.window; border.color: Theme.border }
                onClicked: root.modeChosen(2)
            }
            UiControls.TabButton {
                id: relatedTab
                objectName: "relatedTab"
                text: "Related"
                background: Rectangle { color: relatedTab.checked ? Theme.selected : Theme.window; border.color: Theme.border }
                onClicked: root.modeChosen(3)
            }
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
                Label { text: "Papers"; font.pixelSize: 11; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 4 }
                Repeater {
                    model: root.relatedPapers
                    delegate: UiControls.ItemDelegate {
                        required property var modelData
                        objectName: "relatedPaper-" + index
                        required property int index
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: 12
                        ToolTip.visible: hovered; ToolTip.delay: 450; ToolTip.text: researchStore.localPath(modelData.source)
                        onClicked: root.linkActivated("owelk://document/" + modelData.documentId)
                    }
                }
                Label {
                    visible: !root.relatedPapers.length
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                    text: root.relatedLoading ? "Looking for related papers…" : "No related papers in the library yet."
                }
                Label { text: "Notes"; font.pixelSize: 11; font.bold: true; color: Theme.textTertiary; Layout.topMargin: 10 }
                Repeater {
                    model: root.relatedNotes
                    delegate: UiControls.ItemDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.title
                        font.pixelSize: 12
                        onClicked: root.linkActivated("owelk://note/" + modelData.id)
                    }
                }
                Label {
                    visible: !root.relatedNotes.length && !root.relatedLoading
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                    text: "No notes share this paper's key words."
                }
            }
        }
        ListView {
            objectName: "backlinkList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 2 && root.ready
            clip: true
            model: root.backlinks
            delegate: UiControls.ItemDelegate {
                required property var modelData
                width: ListView.view.width
                text: modelData.title
                font.pixelSize: 12
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
            delegate: UiControls.ItemDelegate {
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
                    PdfPageImage {
                        id: preview
                        objectName: "thumbnailImage-" + thumb.index
                        readonly property size points: root.ready ? root.reader.pdfDocument.pagePointSize(thumb.index) : Qt.size(595, 842)
                        width: thumb.width - 12
                        height: Math.min(250, width * points.height / Math.max(1, points.width))
                        document: root.navigationDocument
                        currentFrame: thumb.index
                        asynchronous: true
                        cache: false
                        sourceSize.width: Math.min(440, Math.ceil(width * Screen.devicePixelRatio))
                        fillMode: Image.PreserveAspectFit
                    }
                    Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: thumb.index + 1; font.pixelSize: 11; color: Theme.textTertiary }
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
