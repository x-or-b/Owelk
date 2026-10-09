import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Owelk.Ui
import "Platform.js" as Platform

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
    // Which ink the color popup changes: "highlight" or "draw".
    property string inkTarget: "highlight"
    function chooseHighlightColor(item, apply) { chooseInk(item, "highlight", apply) }
    function chooseInk(item, target, apply) {
        inkTarget = target
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
    // One click highlights the selection, or turns the highlight tool on, in the current color.
    function useHighlight() {
        activated(); canvas.captureMode = false
        if (canvas.tool === "highlight") canvas.tool = ""
        else if (canvas.selectedAnchor) canvas.highlightSelection()
        else { canvas.tool = "highlight"; canvas.clearSelection() }
    }
    function addComment() {
        if (!canvas.selectedAnchor) return
        activated()
        if (marginShown) margin.beginDraft({page: canvas.selectedAnchor.page, selection: canvas.selectedAnchor})
        else annotationEditor.begin(canvas, {kind:"comment",page:canvas.selectedAnchor.page}, canvas.selectedAnchor)
    }
    // Notes beside the page (remembered); shown when the pane has room for them.
    property bool marginNotes: researchStore.setting("reader.marginNotes") === "1"
    readonly property bool marginShown: marginNotes && canvas.ready && root.width >= 560
    function setMarginNotes(on) { marginNotes = on; researchStore.setSetting("reader.marginNotes", on ? "1" : "0") }
    function printDocument() { researchStore.printDocument(canvas.source, canvas.documentFingerprint, canvas.pageCount) }
    signal activated()
    signal changed()
    signal documentAboutToOpen()
    signal documentOpened()
    signal fileChosen(url source)
    color: Theme.pdfBackdrop

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
    function fitPage() { canvas.fitPage() }
    // From the outline, thumbnails and the like: Back returns to where the reader was.
    function jumpToPage(page, y) { activated(); canvas.jumpRemembering(page, y || 0, 0) }
    function goBack() { return canvas.goBack() }
    function goForward() { return canvas.goForward() }
    // Web links in a PDF open in an app tab when the pane belongs to a workspace.
    signal linkRequested(url url)
    // AI help about the selection, the current page or the whole paper; the composer is shared app-wide.
    signal aiRequested(var spec)
    function requestAi(action, scope) {
        activated()
        const anchor = canvas.selectedAnchor
        const spec = {action: action, scope: scope, source: source,
                      page: scope === "selection" && anchor ? (anchor.segments ? anchor.segments[0].page : anchor.page) : canvas.currentPage,
                      selection: scope === "selection" ? canvas.selectedText : ""}
        // A page translation stands alone (the next page follows from the AI panel).
        if (action === "translate" && scope === "page") { spec.fresh = true; spec.label = "Translate page " + (spec.page + 1) }
        aiRequested(spec)
    }
    function copySelection() { canvas.copySelection() }
    function captureSelection() { canvas.captureSelection() }
    function highlightSelection() { canvas.highlightSelection() }
    function toggleCapture() { if (canvas.ready) { canvas.tool = ""; canvas.captureMode = !canvas.captureMode } }
    function startCapture() { if (canvas.ready) { activated(); canvas.tool = ""; canvas.captureMode = true } }
    readonly property bool capturing: canvas.captureMode
    function reveal(url, page, region, passage) {
        cancelReveal()
        if (!researchStore.sameSource(source, url)) {
            // Managed readers belong to a tab: never replace its PDF behind the controller's back.
            if (managed || !openFile(url, {page: page, y: Math.max(0, region.y - .08), x: 0, zoom: 1})) return
        }
        hideSearch()
        sourceToReveal = {source: url.toString(), page: page, region: region, passage: !!passage}
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
                canvas.showSource(root.sourceToReveal.page, root.sourceToReveal.region, root.sourceToReveal.passage)
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
        selectedColor: root.inkTarget === "draw" ? canvas.drawColor : canvas.markColor
        onChosen: function(color) {
            canvas.captureMode = false
            if (root.inkTarget === "draw") {
                canvas.drawColor = color
                researchStore.setSetting("drawColor", color)
                canvas.tool = "draw"; canvas.clearSelection()
                return
            }
            canvas.markColor = color
            researchStore.setSetting("highlightColor", color)
            if (root.applyHighlightOnColor) canvas.highlightSelection()
            else canvas.tool = "highlight"
        }
    }
    AnnotationEditor { id: annotationEditor }
    Menu {
        id: selectionMenu
        objectName: "selectionContextMenu"
        property int page: 0
        MenuItem { objectName:"selectionCopy"; text:"Copy"; enabled:!!canvas.selectedText; onTriggered:canvas.copySelection() }
        MenuItem { text:"Select All on Page"; onTriggered:canvas.selectPage(selectionMenu.page) }
        MenuSeparator {}
        MenuItem { text:"Add Comment to Selection…"; enabled:!!canvas.selectedAnchor; onTriggered:root.addComment() }
        MenuItem { text:"Highlight Selection…"; enabled:!!canvas.selectedAnchor; onTriggered:root.chooseHighlightColor(pageField,true) }
        MenuItem { text:"Save Excerpt"; enabled:!!canvas.selectedAnchor; onTriggered:canvas.captureSelection() }
        MenuSeparator {}
        // With a selection they act on it; without one: a new thread to ask in, this page translated
        // (then the next, from the AI panel), the whole paper summarized.
        MenuItem { objectName:"menuExplainAi"; text:canvas.selectedText ? "Explain with AI" : "Explain with AI…"; onTriggered:canvas.selectedText ? root.requestAi("explain", "selection") : root.requestAi("ask", "none") }
        MenuItem { objectName:"menuTranslateAi"; text:canvas.selectedText ? "Translate with AI" : "Translate This Page with AI"; onTriggered:root.requestAi("translate", canvas.selectedText ? "selection" : "page") }
        MenuItem { objectName:"menuSummarizeAi"; text:canvas.selectedText ? "Summarize with AI" : "Summarize Paper with AI"; onTriggered:root.requestAi("summarize", canvas.selectedText ? "selection" : "paper") }
        MenuItem { text:canvas.selectedText ? "Ask AI about the Selection…" : "Ask AI about This Page…"; onTriggered:root.requestAi("ask", canvas.selectedText ? "selection" : "page") }
        MenuSeparator {}
        MenuItem { text:"Capture a Region"; onTriggered:root.startCapture() }
    }
    Loader { id: paperDetails; active: false; sourceComponent: PaperDetailsDialog {} }
    FileDialog {
        id: annotatedFile
        title: "Save a copy with annotations"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "pdf"
        nameFilters: ["PDF (*.pdf)"]
        currentFile: researchStore.fileUrl(researchStore.localPath(root.source).replace(/\.pdf$/i, "") + " (annotated).pdf")
        onAccepted: researchStore.exportAnnotatedPdf(root.source, canvas.documentFingerprint, researchStore.localPath(selectedFile))
    }
    FolderDialog {
        id: markdownFolder
        title: "Export highlights and captures as Markdown to…"
        onAccepted: researchStore.exportPaperMarkdown(root.source, researchStore.localPath(selectedFolder))
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            visible: !root.managed
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? Theme.barHeight + 8 : 0
            color: Theme.content
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 10
                spacing: 8
                Label {
                    text: root.paneIndex === 0 ? "A" : "B"
                    color: Theme.textSecondary
                    font.bold: true
                    font.pixelSize: Theme.fontSmall
                }
                Label {
                    Layout.fillWidth: true
                    text: root.source.toString().length ? (researchStore.documentsRevision, researchStore.displayName(root.source)) : "No document"
                    elide: Text.ElideMiddle
                    color: Theme.text
                    font.weight: Font.Medium
                }
                Button { text: "Open"; onClicked: root.chooseFile() }
            }
        }

        Rectangle {
            visible: canvas.ready
            Layout.fillWidth: true
            id: readerToolbar
            objectName: "readerToolbar"
            Layout.preferredHeight: visible ? Theme.barHeight : 0
            color: Theme.window
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            RowLayout {
                anchors.left: parent.left; anchors.leftMargin: 4; anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                IconButton {
                    objectName: "previousPage"; icon.name: "back"; implicitWidth: 24
                    description: "Previous page · " + Platform.keys("Ctrl+["); enabled: canvas.currentPage > 0
                    onClicked: { root.activated(); canvas.previousPage() }
                }
                IconButton {
                    objectName: "nextPage"; icon.name: "forward"; implicitWidth: 24
                    description: "Next page · " + Platform.keys("Ctrl+]"); enabled: canvas.currentPage < canvas.pageCount - 1
                    onClicked: { root.activated(); canvas.nextPage() }
                }
                TextField {
                    id: pageField
                    Layout.preferredWidth: Theme.fontBody * 3; Layout.preferredHeight: Theme.controlHeightSmall
                    horizontalAlignment: Text.AlignHCenter
                    text: (canvas.currentPage + 1).toString()
                    onActiveFocusChanged: if (activeFocus) root.activated()
                    validator: IntValidator { bottom: 1; top: Math.max(1, canvas.pageCount) }
                    onAccepted: {
                        canvas.jump(Number(text) - 1, 0, 0)
                        focus = false
                    }
                }
                Label { text: "/ " + canvas.pageCount; color: Theme.textTertiary }
            }
            Row {
                anchors.centerIn: parent
                IconButton { icon.name: "minus"; description:"Zoom out"; onClicked:{root.activated();canvas.zoom(1/1.2)} }
                // The zoom readout chooses how pages fit: the whole width or a whole page.
                ToolButton {
                    id: zoomReadout
                    objectName: "zoomReadout"
                    height:Theme.controlHeightSmall; width:Math.max(implicitWidth, Theme.fontBody * 4.5); hoverEnabled:true
                    text: canvas.fitMode === "page" ? "Page" : Math.round(canvas.zoomFactor * 100) + "%"
                    onClicked: { root.activated(); fitMenu.popup(zoomReadout, 0, zoomReadout.height) }
                    ToolTip.visible: hovered && !fitMenu.visible
                    ToolTip.text: "View · Ctrl+wheel to zoom"
                    Menu {
                        id: fitMenu
                        objectName: "fitMenu"
                        MenuItem { objectName: "fitWidthItem"; text: "Fit Width"; checkable: true; checked: canvas.fitMode === "width"; onTriggered: canvas.fitWidth() }
                        MenuItem { objectName: "fitPageItem"; text: "Fit Page"; checkable: true; checked: canvas.fitMode === "page"; onTriggered: canvas.fitPage() }
                    }
                }
                IconButton { icon.name: "add"; description:"Zoom in"; onClicked:{root.activated();canvas.zoom(1.2)} }
            }
            // Annotation tools, then capture, then everything else (find, print, export) behind ⋯.
            // Highlight and Draw keep their own colors; the narrow arrow next to each picks one.
            Row {
                anchors.right:parent.right;anchors.rightMargin:4;anchors.verticalCenter:parent.verticalCenter
                spacing: 2
                Row {
                    objectName: "annotationTools"
                    visible: readerToolbar.width >= 600
                    // Inks first (pen, highlight: right-click for color), then writing (comment, text), then image.
                    IconButton {
                        id: drawTool
                        objectName:"drawTool";icon.name: "draw";swatch:canvas.drawColor;checked:canvas.tool==="draw"
                        description:"Draw · Drag on a page · Right-click for color"
                        onClicked: root.setTool("draw")
                        TapHandler { acceptedButtons: Qt.RightButton; onTapped: root.chooseInk(drawTool, "draw", false) }
                    }
                    IconButton {
                        id: highlightTool
                        objectName:"highlightTool";icon.name: "highlight";swatch:canvas.markColor;checked:canvas.tool==="highlight"
                        description: (canvas.selectedAnchor ? "Highlight the selection" : "Highlight · Drag over text") + " · Right-click for color"
                        onClicked: root.useHighlight()
                        TapHandler { acceptedButtons: Qt.RightButton; onTapped: root.chooseInk(highlightTool, "highlight", !!canvas.selectedAnchor) }
                    }
                    IconButton { objectName:"commentTool";icon.name: "comment";checked:canvas.tool==="comment";description:"Comment · Select text, or click a page";onClicked:root.setTool("comment") }
                    IconButton { objectName:"textTool";icon.name: "text";checked:canvas.tool==="text";description:"Text box · Click or drag on a page";onClicked:root.setTool("text") }
                    IconButton { objectName:"imageTool";icon.name: "image";checked:canvas.tool==="image";description:"Image · Drag an area; right-click added images to edit";onClicked:root.setTool("image") }
                }
                Rectangle { visible: readerToolbar.width >= 600; width: 1; height: 16; anchors.verticalCenter: parent.verticalCenter; color: Theme.border }
                IconButton { objectName:"readerCaptureButton";icon.name: "capture";description:"Capture a region · " + Platform.keys("Ctrl+Shift+C");checked:canvas.captureMode;onClicked:root.toggleCapture() }
                IconButton { objectName:"marginNotesButton";icon.name: "margin";checked:root.marginNotes;description:"Annotations beside the page";onClicked:root.setMarginNotes(!root.marginNotes) }
                Rectangle { width: 1; height: 16; anchors.verticalCenter: parent.verticalCenter; color: Theme.border }
                IconButton { icon.name: "more";
                    objectName: "readerMoreButton"
                    description: "Find, print and export"
                    onClicked: moreMenu.popup(this, 0, height)
                    Menu {
                        id: moreMenu
                        objectName: "readerMoreMenu"
                        // Narrow panes: the annotation tools move here.
                        MenuItem { visible:readerToolbar.width<600;height:visible?implicitHeight:0;text:"Draw";onTriggered:root.setTool("draw") }
                        MenuItem { visible:readerToolbar.width<600;height:visible?implicitHeight:0;text:"Highlight";onTriggered:root.useHighlight() }
                        MenuItem { visible:readerToolbar.width<600;height:visible?implicitHeight:0;text:"Comment";onTriggered:root.setTool("comment") }
                        MenuItem { visible:readerToolbar.width<600;height:visible?implicitHeight:0;text:"Text Box";onTriggered:root.setTool("text") }
                        MenuItem { visible:readerToolbar.width<600;height:visible?implicitHeight:0;text:"Image";onTriggered:root.setTool("image") }
                        MenuSeparator { visible:readerToolbar.width<600;height:visible?implicitHeight:0 }
                        MenuItem { text:"Find in Document · " + Platform.keys("Ctrl+F");onTriggered:root.find() }
                        MenuItem { objectName:"printOption";text:"Print…";onTriggered:root.printDocument() }
                        MenuItem { objectName:"exportAnnotatedOption";text:"Export Annotated PDF…";visible:researchStore.canExportAnnotatedPdf();height:visible?implicitHeight:0;enabled:canvas.documentFingerprint.length>0;onTriggered:annotatedFile.open() }
                        MenuItem { objectName:"exportMarkdownOption";text:"Export Highlights and Captures…";onTriggered:markdownFolder.open() }
                        MenuSeparator {}
                        MenuItem { text:"Mark Paper as Read";onTriggered:researchStore.setReadingState(root.source, "read") }
                        MenuItem { objectName:"paperDetailsOption";text:"Paper Details…";onTriggered:{ paperDetails.active = true; paperDetails.item.begin(root.source) } }
                    }
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
            TextField {
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
                color: Theme.textTertiary
            }
            IconButton { icon.name: "up"; description: "Previous match"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(-1) }
            IconButton { icon.name: "down"; description: "Next match"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(1) }
            IconButton { icon.name: "close"; description: "Close search · Esc"; onClicked: root.hideSearch() }
        }

        Label {
            visible: canvas.highlightError.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            text: canvas.highlightError
            textFormat: Text.PlainText; wrapMode: Text.Wrap; color: Theme.danger
        }
        Label {
            visible: canvas.captureMode || canvas.tool.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.bottomMargin: 6
            text: canvas.captureMode ? "Drag a region to capture · Esc to cancel" : canvas.tool === "highlight" ? "Drag over text to highlight · Esc to finish" : "Click or drag on a page to add " + canvas.tool + " · Esc to cancel"
            color: Theme.textSecondary
            font.pixelSize: Theme.fontCaption
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            PdfCanvas {
                id: canvas
                objectName: "pdfCanvas" + root.paneIndex
                anchors.fill: parent
                anchors.rightMargin: root.marginShown ? margin.width : 0
                onActivated: root.activated()
                onExternalLinkRequested: function(url) { if (root.managed) root.linkRequested(url); else Qt.openUrlExternally(url) }
                onContextRequested: function(position,page) { root.activated(); selectionMenu.page=page; selectionMenu.popup(canvas,position.x,position.y) }
                onEditRequested: function(record,selection) {
                    root.activated()
                    // With the notes open, a comment or a highlight's note is written beside the page.
                    if (root.marginShown && !selection && (record.kind === "comment" || record.kind === "highlight")) margin.edit(record.id)
                    else annotationEditor.begin(canvas,record,selection)
                }
                onAnnotationPlaced: function(page,rectangle,points) {
                    const kind=canvas.tool
                    const spec={kind:kind,page:page,rectangles:[rectangle],color:kind==="draw"?canvas.drawColor:kind==="text"?canvas.textColor:canvas.markColor,sha256:canvas.documentFingerprint,drawing:kind==="draw"?points:[]}
                    if(kind==="draw")researchStore.saveAnnotation(canvas.source,page,spec)
                    else if(kind==="comment"&&root.marginShown){canvas.tool="";margin.beginDraft({page:page,rectangle:rectangle})}
                    else {canvas.tool="";annotationEditor.begin(canvas,spec,null)}
                }
                onPositionChanged: root.changed()
                onFigureAiRequested: function(page, rect) {
                    root.activated()
                    root.aiRequested({action: "figure", scope: "none", source: root.source, page: page, region: rect})
                }
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

            MarginNotes {
                id: margin
                visible: root.marginShown
                anchors.right: parent.right
                width: Math.min(300, Math.max(220, parent.width * .28)); height: parent.height
                canvas: canvas
                source: root.source
                z: 4
            }
            Rectangle {
                objectName: "selectionToolbar"
                z: 5
                visible: canvas.selectedText.length > 0 && !canvas.selecting && canvas.selectionEnd.y >= 0 && canvas.selectionEnd.y <= canvas.height && !annotationEditor.visible && !selectionMenu.visible
                x: Math.max(4,Math.min(canvas.width-width-20,canvas.selectionEnd.x+8))
                y: Math.max(4,canvas.selectionEnd.y+height+12>parent.height?canvas.selectionEnd.y-height-8:canvas.selectionEnd.y+8)
                width: 140; height: 34
                color: Theme.raised; border.color: Theme.border; radius: Theme.radiusLarge
                Row {
                    id: selectionActions
                    x: 8; y: 4; width: parent.width - 16; spacing: 4
                    IconButton {
                        objectName: "highlightSelectionButton"
                        icon.name: "highlight"; description:"Highlight selection · Choose a color"; swatch:canvas.markColor
                        enabled: canvas.selectedAnchor !== null && !researchStore.busy
                        onClicked: { root.activated(); root.chooseHighlightColor(this,true) }
                    }
                    IconButton { objectName:"commentSelectionButton";icon.name: "comment";description:"Add a comment attached to this selection";enabled:!!canvas.selectedAnchor&&!researchStore.busy;onClicked:root.addComment() }
                    IconButton {
                        objectName: "saveExcerptButton"
                        icon.name: "excerpt";description:"Save excerpt · Keep the selected text and its source in Captures"
                        enabled: canvas.selectedAnchor !== null && !researchStore.busy
                        onClicked: { root.activated(); canvas.captureSelection() }
                    }
                    IconButton {
                        objectName: "aiSelectionButton"
                        icon.name: "ai"; description: "AI · Explain, translate or ask about the selection"
                        onClicked: selectionAiMenu.popup(this, 0, height)
                        Menu {
                            id: selectionAiMenu
                            objectName: "selectionAiMenu"
                            MenuItem { objectName: "aiExplainSelection"; text: "Explain"; onTriggered: root.requestAi("explain", "selection") }
                            MenuItem { objectName: "aiTranslateSelection"; text: "Translate"; onTriggered: root.requestAi("translate", "selection") }
                            MenuItem { text: "Summarize"; onTriggered: root.requestAi("summarize", "selection") }
                            MenuItem { text: "Ask…"; onTriggered: root.requestAi("ask", "selection") }
                        }
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
                    font.pixelSize: Theme.fontHeadline
                    font.weight: Font.Medium
                    color: Theme.text
                }
                Label {
                    Layout.fillWidth: true
                    text: canvas.error.length ? canvas.error : (root.paneIndex === 0 ? "Drop a PDF here or choose a file." : "Open another PDF to compare.\nYou can open the same document twice.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: Theme.textTertiary
                    lineHeight: 1.4
                }
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Open PDF"
                    onClicked: root.chooseFile()
                }
                Button {
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
                    color: Theme.overlay
                    border.color: Theme.overlayBorder
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
    // Undo and redo annotation and capture changes in this paper. A focused text field keeps its own.
    Shortcut {
        objectName: "undoShortcut"
        sequences: [StandardKey.Undo]
        enabled: root.isActive && canvas.ready && (researchStore.historyRevision, researchStore.canUndo(root.source))
        onActivated: researchStore.undo(root.source)
    }
    Shortcut {
        objectName: "redoShortcut"
        sequences: [StandardKey.Redo]
        enabled: root.isActive && canvas.ready && (researchStore.historyRevision, researchStore.canRedo(root.source))
        onActivated: researchStore.redo(root.source)
    }
    Shortcut {
        objectName: "previousPageShortcut"
        sequence: "Ctrl+["
        enabled: root.isActive && canvas.ready
        onActivated: canvas.previousPage()
    }
    Shortcut {
        objectName: "nextPageShortcut"
        sequence: "Ctrl+]"
        enabled: root.isActive && canvas.ready
        onActivated: canvas.nextPage()
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.isActive && (canvas.captureMode || canvas.tool.length > 0 || canvas.selectedMarkId.length > 0)
        onActivated: {canvas.captureMode = false;canvas.tool="";canvas.selectedMarkId=""}
    }
    // A selected text box, picture, stroke or spot comment is removed with Delete (undo brings it back).
    Shortcut {
        objectName: "deleteSelectedMark"
        sequences: [StandardKey.Delete, "Backspace"]
        enabled: root.isActive && canvas.selectedMarkId.length > 0
        onActivated: canvas.removeSelectedMark()
    }
}
