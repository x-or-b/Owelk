import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import "UiTheme.js" as Theme

Rectangle {
    id: root
    property int paneIndex: 0
    property bool isActive: false
    property bool managed: false
    property alias source: canvas.source
    property alias pdfDocument: canvas.document
    readonly property bool pdfReady: canvas.ready
    readonly property int currentPage: canvas.currentPage
    readonly property int pageCount: canvas.pageCount
    property alias selectedText: canvas.selectedText
    property var sourceToReveal: null
    property bool searchVisible: false
    readonly property bool annotationDirty: annotationEditor.visible || annotationEditor.saving
    property bool applyHighlightOnColor: false
    function chooseHighlightColor(item, apply) {
        applyHighlightOnColor = apply
        const p = item.mapToItem(root, 0, item.height)
        colors.x = Math.max(4, Math.min(root.width - colors.width - 4, p.x))
        colors.y = Math.max(4, Math.min(root.height - colors.height - 4, p.y))
        colors.open()
    }
    function setTool(tool) {
        activated(); canvas.captureMode = false
        if (tool === "comment" && canvas.selectedAnchor) { addComment(); return }
        canvas.tool = canvas.tool === tool ? "" : tool
        canvas.clearSelection()
    }
    function addComment() {
        if (!canvas.selectedAnchor) return
        activated(); annotationEditor.begin(canvas, {kind:"comment",page:canvas.selectedAnchor.page}, canvas.selectedAnchor)
    }
    function printDocument() { researchStore.printDocument(canvas.source, canvas.documentFingerprint, canvas.pageCount) }
    signal activated()
    signal changed()
    signal documentAboutToOpen()
    signal documentOpened()
    signal fileChosen(url source)
    color: "#e8e8e8"
    border.color: isActive ? "#888888" : "#d6d6d6"
    radius: Theme.cornerRadius

    function chooseFile() { fileDialog.open() }
    function cancelReveal() { revealTimer.stop(); sourceToReveal = null }
    function openFile(url, position) {
        if (!researchStore.rememberDocument(url)) return false
        cancelReveal()
        documentAboutToOpen()
        hideSearch()
        canvas.openFile(url, position || researchStore.readingPosition(url))
        activated()
        changed()
        documentOpened()
        return true
    }
    function restore(state) {
        cancelReveal()
        hideSearch()
        if (state && state.source) canvas.openFile(state.source, state.position)
        else canvas.openFile("", {page: 0, y: 0, x: 0, zoom: 1})
    }
    function state() {
        return {source: source.toString(), position: canvas.position()}
    }
    function find() {
        if (!canvas.ready) return
        activated()
        searchVisible = true
        Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
    }
    function hideSearch() {
        searchDelay.stop()
        searchField.clear()
        canvas.searchString = ""
        searchVisible = false
        canvas.forceActiveFocus()
    }
    function zoom(multiplier) { canvas.zoom(multiplier) }
    function fitWidth() { canvas.fitWidth() }
    function jumpToPage(page, y) { activated(); canvas.jump(page, y || 0, 0) }
    function copySelection() { canvas.copySelection() }
    function captureSelection() { canvas.captureSelection() }
    function highlightSelection() { canvas.highlightSelection() }
    function toggleCapture() { if (canvas.ready) canvas.captureMode = !canvas.captureMode }
    function reveal(url, page, region) {
        cancelReveal()
        if (!researchStore.sameSource(source, url)) {
            // Managed readers belong to a tab: never replace its PDF behind the controller's back.
            if (managed || !openFile(url, {page: page, y: Math.max(0, region.y - .08), x: 0, zoom: 1})) return
        }
        hideSearch()
        sourceToReveal = {source: url.toString(), page: page, region: region}
        revealTimer.restart()
    }

    Timer {
        id: revealTimer
        interval: 180
        repeat: true
        onTriggered: {
            if (!root.sourceToReveal || canvas.error.length
                || !researchStore.sameSource(root.sourceToReveal.source, canvas.source)) { root.cancelReveal(); return }
            if (canvas.ready && !canvas.restoring) {
                canvas.showSource(root.sourceToReveal.page, root.sourceToReveal.region)
                root.sourceToReveal = null
                stop()
            }
        }
    }

    FileDialog {
        id: fileDialog
        title: "Open PDF"
        nameFilters: ["PDF documents (*.pdf)"]
        onAccepted: { if (root.managed) root.fileChosen(selectedFile); else root.openFile(selectedFile) }
    }
    AnnotationColors {
        id: colors
        objectName: "selectionColors"
        parent: root
        selectedColor: canvas.markColor
        onChosen: function(color) {
            canvas.markColor = color
            if (root.applyHighlightOnColor) canvas.highlightSelection()
            else { canvas.captureMode = false; canvas.tool = "highlight" }
        }
    }
    AnnotationEditor { id: annotationEditor }
    UiControls.Menu {
        id: selectionMenu
        objectName: "selectionContextMenu"
        property int page: 0
        UiControls.MenuItem { objectName:"selectionCopy"; text:"Copy"; enabled:!!canvas.selectedText; onTriggered:canvas.copySelection() }
        UiControls.MenuItem { text:"Select All on Page"; onTriggered:canvas.selectPage(selectionMenu.page) }
        MenuSeparator {}
        UiControls.MenuItem { text:"Add Comment to Selection…"; enabled:!!canvas.selectedAnchor; onTriggered:root.addComment() }
        UiControls.MenuItem { text:"Highlight Selection…"; enabled:!!canvas.selectedAnchor; onTriggered:root.chooseHighlightColor(pageField,true) }
        UiControls.MenuItem { text:"Save Excerpt"; enabled:!!canvas.selectedAnchor; onTriggered:canvas.captureSelection() }
        MenuSeparator {}
        UiControls.MenuItem { text:"Capture a Region"; onTriggered:{canvas.tool="";canvas.captureMode=true} }
        UiControls.MenuItem { text:"Print PDF…"; onTriggered:root.printDocument() }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0

        Rectangle {
            visible: !root.managed
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 48 : 0
            color: "#ffffff"
            radius: Theme.cornerRadius
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 10
                spacing: 8
                Label {
                    text: root.paneIndex === 0 ? "A" : "B"
                    color: "#555555"
                    font.bold: true
                    font.pixelSize: 12
                }
                Label {
                    Layout.fillWidth: true
                    text: root.source.toString().length ? researchStore.fileName(root.source) : "No document"
                    elide: Text.ElideMiddle
                    color: "#242424"
                    font.weight: Font.Medium
                }
                UiControls.Button { text: "Open"; onClicked: root.chooseFile() }
            }
        }

        Rectangle {
            visible: canvas.ready
            Layout.fillWidth: true
            id: readerToolbar
            objectName: "readerToolbar"
            Layout.preferredHeight: visible ? 32 : 0
            color: "#f5f5f5"
            radius: Theme.cornerRadius
            RowLayout {
                anchors.left: parent.left; anchors.leftMargin: 4; anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                UiControls.TextField {
                    id: pageField
                    Layout.preferredWidth: 34; Layout.preferredHeight: 25
                    horizontalAlignment: Text.AlignHCenter
                    text: (canvas.currentPage + 1).toString()
                    onActiveFocusChanged: if (activeFocus) root.activated()
                    validator: IntValidator { bottom: 1; top: Math.max(1, canvas.pageCount) }
                    onAccepted: {
                        canvas.jump(Number(text) - 1, 0, 0)
                        focus = false
                    }
                }
                Label { text: "/ " + canvas.pageCount; color: "#666666" }
            }
            Row {
                anchors.centerIn: parent
                ReaderIconButton { kind:"minus"; description:"Zoom out"; onClicked:{root.activated();canvas.zoom(1/1.2)} }
                UiControls.ToolButton {
                    height:26; width:48; hoverEnabled:true
                    text: Math.round(canvas.zoomFactor * 100) + "%"
                    onClicked: { root.activated(); canvas.fitWidth() }
                    ToolTip.visible: hovered
                    ToolTip.text: "Click to fit width · Ctrl+wheel to zoom"
                }
                ReaderIconButton { kind:"plus"; description:"Zoom in"; onClicked:{root.activated();canvas.zoom(1.2)} }
            }
            Row {
                anchors.right:parent.right;anchors.rightMargin:4;anchors.verticalCenter:parent.verticalCenter
                visible: readerToolbar.width >= 510
                ReaderIconButton { kind:"comment";description:"Add comment · Select text, or click a page";checked:canvas.tool==="comment";onClicked:root.setTool("comment") }
                ReaderIconButton { kind:"highlight";description:"Highlight text · Choose a color, then drag over text";swatch:canvas.markColor;checked:canvas.tool==="highlight";onClicked:{if(canvas.tool==="highlight")canvas.tool="";else root.chooseHighlightColor(this,!!canvas.selectedAnchor)} }
                ReaderIconButton { kind:"text";description:"Add text box · Click or drag on a page";checked:canvas.tool==="text";onClicked:root.setTool("text") }
                ReaderIconButton { kind:"image";description:"Add image · Drag an area; right-click added images to edit";checked:canvas.tool==="image";onClicked:root.setTool("image") }
                ReaderIconButton { kind:"draw";description:"Draw · Drag on a page; Esc to finish";swatch:canvas.markColor;checked:canvas.tool==="draw";onClicked:root.setTool("draw") }
                ReaderIconButton { kind:"print";description:"Print PDF and annotations";onClicked:root.printDocument() }
            }
            ReaderIconButton {
                anchors.right:parent.right;anchors.rightMargin:4;anchors.verticalCenter:parent.verticalCenter
                visible:readerToolbar.width<510
                description:"Annotation and print tools";onClicked:toolsMenu.popup(this,0,height)
                UiControls.Menu {
                    id:toolsMenu
                    UiControls.MenuItem { text:"Add Comment";onTriggered:root.setTool("comment") }
                    UiControls.MenuItem { text:"Highlight…";onTriggered:root.chooseHighlightColor(pageField,!!canvas.selectedAnchor) }
                    UiControls.MenuItem { text:"Add Text Box";onTriggered:root.setTool("text") }
                    UiControls.MenuItem { text:"Add Image";onTriggered:root.setTool("image") }
                    UiControls.MenuItem { text:"Draw";onTriggered:root.setTool("draw") }
                    UiControls.MenuItem { text:"Capture a Region";onTriggered:{canvas.tool="";canvas.captureMode=true} }
                    UiControls.MenuItem { text:"Print PDF…";onTriggered:root.printDocument() }
                }
            }
        }

        RowLayout {
            objectName: "searchBar"
            visible: canvas.ready && root.searchVisible
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.topMargin: visible ? 6 : 0
            Layout.bottomMargin: visible ? 6 : 0
            spacing: 4
            UiControls.TextField {
                id: searchField
                objectName: "searchField"
                Layout.fillWidth: true
                placeholderText: "Find in document"
                selectByMouse: true
                onTextEdited: searchDelay.restart()
                onActiveFocusChanged: if (activeFocus) root.activated()
                onAccepted: {
                    searchDelay.stop()
                    if (canvas.searchString !== text) canvas.searchString = text
                    else canvas.nextMatch(1)
                }
                Keys.onEscapePressed: root.hideSearch()
            }
            Label {
                text: canvas.searchString.length ? (canvas.matchCount ? (canvas.currentMatch + 1) + "/" + canvas.matchCount : "0") : ""
                color: "#666666"
            }
            UiControls.ToolButton { text: "↑"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(-1) }
            UiControls.ToolButton { text: "↓"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(1) }
            UiControls.ToolButton {
                text: "×"
                onClicked: root.hideSearch()
                ToolTip.visible: hovered
                ToolTip.text: "Close search (Esc)"
                Accessible.name: "Close search"
            }
        }

        Label {
            visible: canvas.highlightError.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            text: canvas.highlightError
            textFormat: Text.PlainText; wrapMode: Text.Wrap; color: "#b42323"
        }
        Label {
            visible: canvas.captureMode || canvas.tool.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.bottomMargin: 6
            text: canvas.captureMode ? "Drag a region to capture · Esc to cancel" : canvas.tool === "highlight" ? "Drag over text to highlight · Esc to finish" : "Click or drag on a page to add " + canvas.tool + " · Esc to cancel"
            color: "#444444"
            font.pixelSize: 11
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            PdfCanvas {
                id: canvas
                objectName: "pdfCanvas" + root.paneIndex
                anchors.fill: parent
                onActivated: root.activated()
                onContextRequested: function(position,page) { root.activated(); selectionMenu.page=page; selectionMenu.popup(canvas,position.x,position.y) }
                onEditRequested: function(record,selection) { root.activated(); annotationEditor.begin(canvas,record,selection) }
                onAnnotationPlaced: function(page,rectangle,points) {
                    const kind=canvas.tool
                    const spec={kind:kind,page:page,rectangles:[rectangle],color:canvas.markColor,sha256:canvas.documentFingerprint,drawing:kind==="draw"?points:[]}
                    if(kind==="draw")researchStore.saveAnnotation(canvas.source,page,spec)
                    else {canvas.tool="";annotationEditor.begin(canvas,spec,null)}
                }
                onPositionChanged: root.changed()
                onRegionSelected: function(page, rect) {
                    researchStore.captureRegion(source, page, rect)
                    captureMode = false
                }
                onSourceChanged: {
                    searchDelay.stop()
                    searchField.clear()
                    root.searchVisible = false
                }
            }

            Rectangle {
                objectName: "selectionToolbar"
                z: 5
                visible: canvas.selectedText.length > 0 && !canvas.selecting && canvas.selectionEnd.y >= 0 && canvas.selectionEnd.y <= canvas.height && !annotationEditor.visible && !selectionMenu.visible
                x: Math.max(4,Math.min(parent.width-width-20,canvas.selectionEnd.x+8))
                y: Math.max(4,canvas.selectionEnd.y+height+12>parent.height?canvas.selectionEnd.y-height-8:canvas.selectionEnd.y+8)
                width: 108; height: 34
                color: "#fafafa"; border.color: "#bcbcbc"; radius: Theme.cornerRadius
                Row {
                    id: selectionActions
                    x: 8; y: 4; width: parent.width - 16; spacing: 4
                    ReaderIconButton {
                        objectName: "highlightSelectionButton"
                        kind: "highlight"; description:"Highlight selection · Choose a color"; swatch:canvas.markColor
                        enabled: canvas.selectedAnchor !== null && !researchStore.busy
                        onClicked: { root.activated(); root.chooseHighlightColor(this,true) }
                    }
                    ReaderIconButton { objectName:"commentSelectionButton";kind:"comment";description:"Add a comment attached to this selection";enabled:!!canvas.selectedAnchor&&!researchStore.busy;onClicked:root.addComment() }
                    ReaderIconButton {
                        objectName: "saveExcerptButton"
                        kind:"excerpt";description:"Save excerpt · Keep the selected text and its source in Captures"
                        enabled: canvas.selectedAnchor !== null && !researchStore.busy
                        onClicked: { root.activated(); canvas.captureSelection() }
                    }
                }
            }

            ColumnLayout {
                visible: !canvas.source.toString().length || canvas.error.length > 0
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 320)
                spacing: 14
                Label {
                    Layout.fillWidth: true
                    text: canvas.error.length ? "Cannot open document" : "Open PDF"
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 16
                    font.weight: Font.Medium
                    color: "#333333"
                }
                Label {
                    Layout.fillWidth: true
                    text: canvas.error.length ? canvas.error : (root.paneIndex === 0 ? "Drop a PDF here or choose a file." : "Open another PDF to compare.\nYou can open the same document twice.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: "#666666"
                    lineHeight: 1.4
                }
                UiControls.Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Open PDF"
                    onClicked: root.chooseFile()
                }
                UiControls.Button {
                    Layout.alignment: Qt.AlignHCenter
                    visible: canvas.error.length > 0 && root.source.toString().length > 0
                    text: "Locate Original PDF…"
                    onClicked: researchStore.requestRelink(root.source)
                }
            }

            DropArea {
                anchors.fill: parent
                onDropped: function(drop) {
                    if (drop.hasUrls && /\.pdf$/i.test(drop.urls[0].toString())) {
                        if (root.managed) root.fileChosen(drop.urls[0]); else root.openFile(drop.urls[0])
                        drop.acceptProposedAction()
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    visible: parent.containsDrag
                    color: "#22555555"
                    border.color: "#555555"
                    border.width: 2
                }
            }
        }
    }
    Timer { id: searchDelay; interval: 220; onTriggered: canvas.searchString = searchField.text }
    Shortcut {
        sequences: [StandardKey.Copy]
        enabled: root.isActive && canvas.selectedText.length > 0 && !searchField.activeFocus && !pageField.activeFocus
        onActivated: canvas.copySelection()
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.isActive && (canvas.captureMode || canvas.tool.length > 0)
        onActivated: {canvas.captureMode = false;canvas.tool=""}
    }
}
