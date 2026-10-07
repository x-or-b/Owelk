import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import QtQuick.Shapes
import Owelk.Ui
import "StrokePath.js" as Stroke
import "WorkspaceTree.js" as Tree
import "Platform.js" as Platform

Item {
    id: root
    property url source
    property alias document: pdfDocument
    property real zoomFactor: 1
    // "width" (the default: zoom 1 fills the width), "page" (a whole page fits) or "" after a manual zoom.
    property string fitMode: "width"
    property bool pinching: false
    property bool selecting: false
    // Background PDF work (text index, paper details) waits while the reader is busy, including the
    // redraw after a zoom: both use one PDF lock, and the redraw is what the reader is looking at.
    readonly property bool interacting: pinching || selecting || sourceScroll.running || (redrawing && (loadingPages > 0 || redrawGrace.running))
    property int loadingPages: 0
    property bool redrawing: false
    function holdForRedraw() { redrawing = true; redrawGrace.restart(); redrawCap.restart() }
    Timer { id: redrawGrace; interval: 150 }
    Timer { id: redrawCap; interval: 1500; onTriggered: root.redrawing = false }
    onLoadingPagesChanged: if (loadingPages === 0 && !redrawGrace.running) redrawing = false
    onInteractingChanged: researchStore.paperIndex.setReaderInteracting(root, interacting)
    property real pinchStartZoom: 1
    property var pinchAnchor: null
    readonly property real rasterScale: Math.max(0.1, (width - 56) / Math.max(1, firstPageWidth)) * (pinching ? pinchStartZoom : zoomFactor)
    property bool captureMode: false
    property int currentPage: 0
    property string selectedText: ""
    property var activeSelection: null
    property var selectedAnchor: null
    property string tool: ""
    // Highlight (also comments), drawing and text-box inks are separate and remembered; text starts navy.
    readonly property bool invertPages: Theme.invertPages && Theme.canInvertPages
    readonly property string defaultTextColor: "#1d3a5c"
    property string markColor: savedInk("highlightColor")
    property string drawColor: savedInk("drawColor")
    property string textColor: savedInk("textColor", defaultTextColor)
    function savedInk(key, fallback) {
        const value = researchStore.setting(key)
        return Theme.annotationInks.some(function(ink) { return ink.value === value }) ? value : (fallback || Theme.defaultInk)
    }
    Connections {
        target: researchStore
        function onSettingsChanged() {
            root.markColor = root.savedInk("highlightColor"); root.drawColor = root.savedInk("drawColor")
            root.textColor = root.savedInk("textColor", root.defaultTextColor)
        }
    }
    // A page's size in PDF points (text boxes fit their font to it).
    function pagePoints(page) { return pdfDocument.pagePointSize(page) }
    property string documentFingerprint: ""
    property var editingMark: null
    // A mark outlined on the page while its note is hovered in the margin.
    property string focusedMark: ""
    property point markMenuPosition: Qt.point(0, 0)
    signal contextRequested(point position, int page)
    signal externalLinkRequested(url url)
    signal editRequested(var record, var selection)
    signal annotationPlaced(int page, var rectangle, var points)
    readonly property point selectionEnd: {
        const cy = pages.contentY, cx = pages.contentX, scale = pageScale
        if (!selectedAnchor) return Qt.point(-100, -100)
        const page = pages.itemAtIndex(selectedAnchor.page)
        if (!page) return Qt.point(-100, -100)
        return page.mapToItem(root, (pages.contentWidth - page.pointSize.width * scale) / 2 + selectedAnchor.to.x * scale, selectedAnchor.to.y * scale)
    }
    property var lastPosition: ({page: 0, y: 0, x: 0, zoom: 1})
    property var pendingPosition: null
    property bool restoring: false
    property var highlight: null
    property var savedHighlights: []
    property int highlightRequest: -1
    property string highlightError: ""
    property string removingHighlight: ""
    property var pendingHighlightSelection: null
    function refreshHighlights() {
        savedHighlights = []; highlightError = ""
        highlightRequest = ready ? researchStore.loadHighlights(source) : -1
    }
    onReadyChanged: refreshHighlights()
    onSourceChanged: {
        savedHighlights = []; highlightRequest = -1; highlightError = ""; pendingHighlightSelection = null; documentFingerprint = ""; tool = ""
        backStack = []; forwardStack = []
        closeLinkPreview(); hoveredLink = null; restSpot = null
        // PdfDocument may become Ready synchronously before this handler resets the request.
        Qt.callLater(refreshHighlights)
    }
    Connections {
        target: researchStore
        function onHighlightsChanged() { root.refreshHighlights() }
        function onHighlightsLoaded(request, source, highlights, error, fingerprint) {
            if (request !== root.highlightRequest || !researchStore.sameSource(root.source, source)) return
            root.savedHighlights = highlights; root.highlightError = error; root.documentFingerprint = fingerprint
        }
        function onHighlightSaved(id, source) {
            if (researchStore.sameSource(root.source, source) && root.pendingHighlightSelection !== null
                && root.pendingHighlightSelection === root.selectedAnchor) root.clearSelection()
            root.pendingHighlightSelection = null
        }
    }
    Menu {
        id: highlightMenu
        objectName: "highlightMenu"
        MenuItem { text: "Edit / Comment…"; onTriggered: root.editRequested(root.editingMark, null) }
        MenuItem { objectName: "changeAnnotationColor"; text: "Change Color…"; onTriggered: markColors.open() }
        MenuItem { text: "Link to Note…"; onTriggered: linkToNote.begin("highlight", root.editingMark.id) }
        MenuItem {
            visible: !!root.editingMark && !!root.editingMark.text; height: visible ? implicitHeight : 0
            text: "Copy Text"; onTriggered: researchStore.copyText(root.editingMark.text)
        }
        MenuSeparator {}
        MenuItem {
            objectName: "removeHighlightAction"
            text: "Remove Annotation"
            palette.windowText: Theme.danger
            onTriggered: { const id = root.removingHighlight; Qt.callLater(function() { researchStore.removeHighlight(id) }) }
        }
    }
    LinkToNoteDialog { id: linkToNote }
    AnnotationColors {
        id: markColors
        objectName: "markColors"
        parent: root
        x: Math.max(4, Math.min(root.width - width - 4, root.markMenuPosition.x + 8))
        y: Math.max(4, Math.min(root.height - height - 4, root.markMenuPosition.y + 8))
        selectedColor: root.editingMark ? root.editingMark.color : root.markColor
        onChosen: function(color) { if (root.editingMark) researchStore.updateHighlight(root.editingMark.id, color, root.editingMark.body || "") }
    }
    function selectPage(page) {
        const item = pages.itemAtIndex(page)
        if (!item) return
        clearSelection(); item.selectWholePage()
    }
    property real spotlightOpacity: 0
    property real spotlightScale: .9
    property real targetScrollX: 0
    property real targetScrollY: 0
    property int sourceScrollDuration: 800
    readonly property bool ready: pdfDocument.status === PdfDocument.Ready
    readonly property int pageCount: pdfDocument.pageCount
    readonly property string error: source.toString().length && pdfDocument.status === PdfDocument.Error ? pdfDocument.error : ""
    readonly property real pageScale: Math.max(0.1, (width - 56) / Math.max(1, firstPageWidth)) * zoomFactor
    readonly property real firstPageWidth: ready ? pdfDocument.pagePointSize(0).width : 595
    property alias searchString: search.searchString
    property int matchCount: 0
    readonly property int currentMatch: search.currentResult
    signal positionChanged()
    signal activated()
    signal regionSelected(int page, rect normalizedRegion)

    // Previous and next page (Cmd+[ / Cmd+], the toolbar arrows and the mouse's side buttons).
    function previousPage() { if (ready && currentPage > 0) jump(currentPage - 1, 0, 0) }
    function nextPage() { if (ready && currentPage < pageCount - 1) jump(currentPage + 1, 0, 0) }
    // A password given before (this session, or remembered) is tried first, once per opening.
    function tryKnownPassword() {
        const known = researchStore.pdfPassword(source)
        if (!known.length || passwordDialog.autoTried === source.toString()) return false
        passwordDialog.autoTried = source.toString()
        pdfDocument.password = known
        return true
    }
    function openFile(url, position) {
        const otherFile = !researchStore.sameSource(source, url)
        if (otherFile) {
            // A password belongs to one file: unload the locked file first, so clearing the password
            // does not reload it, and the next file opens without it.
            if (pdfDocument.password.length) {
                source = ""
                pdfDocument.password = ""
            }
            passwordDialog.autoTried = ""
        }
        stopSourceMotion()
        spotlight.stop()
        if (pinching) cancelPinch()
        pendingPosition = position || {page: 0, y: 0, x: 0, zoom: 1}
        lastPosition = pendingPosition
        restoring = true
        captureMode = false
        selecting = false
        selectedText = ""
        if (activeSelection) activeSelection.clear()
        activeSelection = null
        selectedAnchor = null
        highlight = null
        search.searchString = ""
        if (researchStore.sameSource(source, url) && ready) {
            restoreTimer.restart()
        } else {
            // A password belongs to one file: clear it once the next file is the source, so the
            // locked file is not reloaded (and asked for again) on the way out.
            source = url
        }
        if (!url.toString().length) restoring = false
    }

    function position() {
        if (!ready || restoring) return lastPosition
        let index = pages.indexAt(10, pages.contentY + 28)
        if (index < 0) index = currentPage
        const item = pages.itemAtIndex(index)
        if (!item) return lastPosition
        return {page: index, y: Math.max(0, (pages.contentY - item.y) / Math.max(1, item.height)),
                x: Math.max(0, pages.contentX / Math.max(1, pages.contentWidth)), zoom: zoomFactor, fit: fitMode}
    }

    function updatePosition() {
        if (!ready || restoring) return
        lastPosition = position()
        currentPage = lastPosition.page
        positionChanged()
    }

    function jump(page, y, x) {
        stopSourceMotion()
        if (!ready || pageCount < 1) return
        restoring = true
        const target = Math.max(0, Math.min(pageCount - 1, page))
        pages.forceLayout()
        pages.positionViewAtIndex(target, ListView.Beginning)
        pages.forceLayout()
        const item = pages.itemAtIndex(target)
        if (item) pages.contentY = item.y + Math.max(0, y || 0) * item.height
        pages.contentX = Math.max(0, x || 0) * pages.contentWidth
        pages.returnToBounds()
        currentPage = target
        Qt.callLater(function() {
            restoring = false
            updatePosition()
        })
    }

    function zoom(multiplier) {
        if (!ready) return
        if (pinching) endPinch()
        const saved = position()
        restoring = true
        zoomFactor = Math.max(0.5, Math.min(4, zoomFactor * multiplier))
        fitMode = ""
        holdForRedraw()
        Qt.callLater(function() { jump(saved.page, saved.y, saved.x) })
    }

    function fitWidth() {
        zoom(1 / zoomFactor)
        fitMode = "width"
    }
    // The zoom at which the current page is wholly visible (never wider than the width).
    function fitPageZoom(page) {
        const size = pdfDocument.pagePointSize(page === undefined ? currentPage : page), widthScale = Math.max(0.1, (width - 56) / Math.max(1, firstPageWidth))
        return size.height > 0 ? Math.max(0.5, Math.min(1, (pages.height - 24) / (size.height * widthScale))) : 1
    }
    // Shows a whole page at a time; turning pages (Cmd+] / Cmd+[) then reads like a book.
    function fitPage() {
        if (!ready) return
        if (pinching) endPinch()
        restoring = true
        zoomFactor = fitPageZoom()
        fitMode = "page"
        holdForRedraw()
        const page = currentPage
        Qt.callLater(function() { jump(page, 0, 0) })
    }

    function anchorAt(point) {
        const y = pages.contentY + point.y
        let index = pages.indexAt(pages.contentWidth / 2, y)
        if (index < 0) index = pages.indexAt(pages.contentWidth / 2, y + pages.spacing)
        if (index < 0) index = currentPage
        const item = pages.itemAtIndex(index)
        if (!item) return null
        const left = (pages.contentWidth - item.pointSize.width * pageScale) / 2
        return {page: index, x: (pages.contentX + point.x - left) / pageScale, y: (y - item.y) / pageScale,
            viewportX: point.x, viewportY: point.y}
    }
    function placeAnchor(anchor, point) {
        pages.forceLayout()
        pages.positionViewAtIndex(anchor.page, ListView.Beginning)
        pages.forceLayout()
        const item = pages.itemAtIndex(anchor.page)
        if (!item) return
        const left = (pages.contentWidth - item.pointSize.width * pageScale) / 2
        pages.contentX = Math.max(0, Math.min(pages.contentWidth - pages.width, left + anchor.x * pageScale - point.x))
        const low = pages.originY - pages.topMargin
        const high = Math.max(low, pages.originY + pages.contentHeight - pages.height + pages.bottomMargin)
        pages.contentY = Math.max(low, Math.min(high, item.y + anchor.y * pageScale - point.y))
    }
    function beginPinch(point) {
        stopSourceMotion()
        if (!ready || restoring || pinching) return false
        pinchAnchor = anchorAt(point)
        if (!pinchAnchor) return false
        activated()
        positionTimer.stop()
        lastPosition = position()
        pinchStartZoom = zoomFactor
        pinching = true
        restoring = true
        return true
    }
    function updatePinch(scale, point) {
        if (!pinching || !Number.isFinite(scale) || scale <= 0) return
        zoomFactor = Math.max(.5, Math.min(4, pinchStartZoom * scale))
        // Scale existing rasters while keeping selection, links and page geometry aligned.
        // Rendering resolution stays frozen until the gesture ends.
        placeAnchor(pinchAnchor, point)
    }
    function endPinch() {
        if (!pinching) return
        if (zoomFactor !== pinchStartZoom) { fitMode = ""; holdForRedraw() }
        pinching = false
        pinchAnchor = null
        restoring = false
        updatePosition()
    }
    function cancelPinch() {
        if (!pinching) return
        zoomFactor = pinchStartZoom
        placeAnchor(pinchAnchor, Qt.point(pinchAnchor.viewportX, pinchAnchor.viewportY))
        endPinch()
    }

    function zoomByWheel(event) {
        const steps = event.angleDelta.y ? event.angleDelta.y / 120 : event.pixelDelta.y / 60
        if (!steps) { event.accepted = false; return }
        activated()
        zoom(Math.pow(1.15, Math.max(-4, Math.min(4, steps))))
        event.accepted = true
    }

    function nextMatch(direction) {
        if (matchCount > 0)
            search.currentResult = (search.currentResult + direction + matchCount) % matchCount
    }

    function showSource(page, rect) {
        stopSourceMotion()
        spotlight.stop()
        clearSelection()
        pages.cancelFlick()
        highlight = {page: page, rect: rect}
        spotlightOpacity = 0; spotlightScale = .9
        const oldX = pages.contentX, oldY = pages.contentY
        restoring = true
        pages.positionViewAtIndex(page, ListView.Beginning)
        pages.forceLayout()
        const item = pages.itemAtIndex(page)
        const desiredY = item ? item.y + Math.max(0, rect.y - .08) * item.height : pages.contentY
        targetScrollY = Math.max(pages.originY - pages.topMargin,
                                Math.min(desiredY, pages.originY + pages.contentHeight - pages.height + pages.bottomMargin))
        const pageWidth = pdfDocument.pagePointSize(page).width * pageScale
        const left = (pages.contentWidth - pageWidth) / 2 + rect.x * pageWidth
        // Keep the current horizontal position if the target is already visible; never trigger rebound.
        targetScrollX = rect.width * pageWidth <= pages.width && left >= oldX && left + rect.width * pageWidth <= oldX + pages.width
            ? oldX : Math.max(0, Math.min(left - 24, pages.contentWidth - pages.width))
        pages.contentX = oldX; pages.contentY = oldY
        // Give long jumps more time without making nearby captures feel sluggish.
        sourceScrollDuration = Math.round(Math.min(1500, 700 + Math.abs(targetScrollY - oldY) / Math.max(1, pages.height) * 90))
        sourceScroll.restart(); spotlight.restart()
    }

    function stopSourceMotion() {
        if (sourceScroll.running) {
            sourceScroll.stop()
            restoring = false
            updatePosition()
        }
    }
    ParallelAnimation {
        id: sourceScroll
        NumberAnimation { target: pages; property: "contentY"; to: root.targetScrollY; duration: root.sourceScrollDuration; easing.type: Easing.InOutSine }
        NumberAnimation { target: pages; property: "contentX"; to: root.targetScrollX; duration: root.sourceScrollDuration; easing.type: Easing.InOutSine }
        onFinished: { root.restoring = false; root.updatePosition() }
    }
    SequentialAnimation {
        id: spotlight
        PauseAnimation { duration: Math.max(0, root.sourceScrollDuration - 120) }
        ParallelAnimation {
            NumberAnimation { target: root; property: "spotlightOpacity"; to: 1; duration: 160 }
            NumberAnimation { target: root; property: "spotlightScale"; to: 1; duration: 230; easing.type: Easing.OutBack }
        }
        ParallelAnimation {
            objectName: "captureSpotlightFade"
            NumberAnimation { target: root; property: "spotlightOpacity"; to: 0; duration: Theme.captureFadeDuration; easing.type: Easing.InOutQuad }
        }
    }

    function copySelection() {
        if (selectedText.length) researchStore.copyText(selectedText)
    }

    function clearCrossSelection() {
        crossPages.forEach(function(index) { const holder = pages.itemAtIndex(index); if (holder) holder.clearExtension() })
        if (selectionOrigin) selectionOrigin.clearExtension()
        crossPages = []; selectionOrigin = null
    }
    function clearSelection() {
        clearCrossSelection()
        if (activeSelection) activeSelection.clear()
        activeSelection = null
        selectedText = ""
        selectedAnchor = null
    }

    TapHandler {
        enabled: root.ready && !root.captureMode && !root.pinching && (!root.tool.length || root.tool === "highlight")
        onTapped: { root.activated(); root.clearSelection() }
    }

    // Selections across pages: the page where the drag started (origin) keeps its press point; pages up to
    // the pointer are added in order. Each page keeps its own verified PDF selection.
    property var crossPages: []
    property var selectionOrigin: null
    property point selectionPointer: Qt.point(0, 0)
    property point selectionPress: Qt.point(0, 0)
    function trackSelectionDrag(origin, pointer, press) {
        selectionOrigin = origin; selectionPointer = pointer; selectionPress = press
        const target = anchorAt(pointer)
        const forward = target && target.page > origin.index
        crossPages.forEach(function(index) { const holder = pages.itemAtIndex(index); if (holder) holder.clearExtension() })
        if (!target || target.page === origin.index || Math.abs(target.page - origin.index) > 3) {
            origin.clearExtension()
            crossPages = []
            return
        }
        const scale = pageScale
        origin.extendSelection(press, forward ? origin.textEnd(scale) : origin.textStart(scale))
        const list = []
        for (let i = origin.index + (forward ? 1 : -1); forward ? i <= target.page : i >= target.page; i += forward ? 1 : -1) {
            const holder = pages.itemAtIndex(i)
            if (!holder) continue
            const begin = holder.textStart(scale), end = holder.textEnd(scale)
            const snapped = i === target.page ? holder.snapToText(Qt.point(target.x, target.y)) : Qt.point(0, 0)
            const at = Qt.point(snapped.x * scale, snapped.y * scale)
            if (i === target.page) holder.extendSelection(forward ? begin : at, forward ? at : end)
            else holder.extendSelection(begin, end)
            list.push(i)
        }
        crossPages = list
        refreshCrossText()
    }
    function crossSegments() {
        if (!selectionOrigin || !crossPages.length) return []
        const indexes = crossPages.concat([selectionOrigin.index]).sort(function(a, b) { return a - b })
        return indexes.map(function(index) {
            const holder = index === selectionOrigin.index ? selectionOrigin : pages.itemAtIndex(index)
            const selection = holder.pageSelection, scale = selection.renderScale
            return {page: index, text: selection.text,
                from: Qt.point(selection.from.x / scale, selection.from.y / scale), to: Qt.point(selection.to.x / scale, selection.to.y / scale)}
        }).filter(function(segment) { return segment.text.length > 0 })
    }
    function refreshCrossText() { selectedText = crossSegments().map(function(s) { return s.text }).join("\n") }
    // Scroll while a selection drag waits near the top or bottom edge.
    Timer {
        interval: 16; repeat: true
        running: root.selecting && root.selectionOrigin !== null && (root.selectionPointer.y < 24 || root.selectionPointer.y > root.height - 24)
        onTriggered: {
            const step = root.selectionPointer.y < 24 ? -Math.ceil((24 - root.selectionPointer.y) / 2) : Math.ceil((root.selectionPointer.y - root.height + 24) / 2)
            pages.contentY = Math.max(0, Math.min(pages.contentHeight - pages.height, pages.contentY + step))
            root.trackSelectionDrag(root.selectionOrigin, root.selectionPointer, root.selectionPress)
        }
    }
    function rememberSelection(selection) {
        if (crossPages.length) {
            const segments = crossSegments()
            if (!segments.length) { selectedAnchor = null; return }
            const last = segments[segments.length - 1]
            selectedText = segments.map(function(s) { return s.text }).join("\n")
            selectedAnchor = {page: last.page, text: selectedText, from: segments[0].from, to: last.to, segments: segments}
            return
        }
        // Freeze PDF-point endpoints before zoom, resizing or opening a dock changes the scale.
        selectedAnchor = selection.text.length ? {
            page: selection.page, text: selection.text,
            from: Qt.point(selection.from.x / selection.renderScale, selection.from.y / selection.renderScale),
            to: Qt.point(selection.to.x / selection.renderScale, selection.to.y / selection.renderScale)
        } : null
    }

    function captureSelection() {
        if (!selectedAnchor || selectedAnchor.text !== selectedText || selecting) return
        if (selectedAnchor.segments) { researchStore.captureTextSegments(source, selectedAnchor.segments); return }
        researchStore.captureText(source, selectedAnchor.page, selectedAnchor.from, selectedAnchor.to, selectedAnchor.text)
    }
    function highlightSelection() {
        if (!selectedAnchor || selectedAnchor.text !== selectedText || selecting || researchStore.busy) return
        pendingHighlightSelection = selectedAnchor
        if (selectedAnchor.segments) {
            // One highlight per page, each verified against its page.
            const color = markColor
            selectedAnchor.segments.forEach(function(s) { researchStore.highlightText(source, s.page, s.from, s.to, s.text, color) })
            return
        }
        researchStore.highlightText(source, selectedAnchor.page, selectedAnchor.from, selectedAnchor.to, selectedAnchor.text, markColor)
    }

    // A whole page stays fitted when the window or split changes height.
    onHeightChanged: if (fitMode === "page" && ready && !restoring) { pendingPosition = lastPosition; restoring = true; restoreTimer.restart() }
    onWidthChanged: {
        stopSourceMotion()
        if (pinching) cancelPinch()
        if (ready && !restoring) {
            pendingPosition = lastPosition
            restoring = true
            restoreTimer.restart()
        }
    }
    onVisibleChanged: if (!visible && pinching) endPinch()

    Timer {
        id: restoreTimer
        interval: 80
        onTriggered: {
            if (!root.ready) return
            const saved = root.pendingPosition || root.lastPosition
            root.fitMode = saved.fit !== undefined ? saved.fit : ((saved.zoom || 1) === 1 ? "width" : "")
            root.zoomFactor = root.fitMode === "page" ? root.fitPageZoom(saved.page || 0) : root.fitMode === "width" ? 1 : Math.max(0.5, Math.min(4, saved.zoom || 1))
            root.pendingPosition = null
            Qt.callLater(function() { root.jump(saved.page || 0, saved.y || 0, saved.x || 0) })
        }
    }
    Timer { id: positionTimer; interval: 180; onTriggered: root.updatePosition() }

    PdfDocument {
        id: pdfDocument
        source: root.source
        onStatusChanged: function(status) {
            // A locked file may also just fail to load; a known password is then tried once.
            if (status === PdfDocument.Error && !pdfDocument.password.length) root.tryKnownPassword()
            if (status === PdfDocument.Ready) {
                restoreTimer.restart()
                // A password that worked is shared with indexing, captures, printing and AI.
                if (passwordDialog.tried.length) researchStore.rememberPdfPassword(root.source, passwordDialog.tried, passwordDialog.keep)
                passwordDialog.tried = ""
            }
        }
        onPasswordRequired: if (!root.tryKnownPassword()) passwordDialog.open()
    }

    PdfSearchModel {
        id: search
        document: pdfDocument
        currentPage: root.currentPage
        onCurrentResultChanged: {
            if (currentResult >= 0 && root.matchCount > 0) {
                const link = currentResultLink
                const size = pdfDocument.pagePointSize(link.page)
                root.jump(link.page, Math.max(0, link.location.y / size.height - 0.1), 0)
            }
        }
    }

    Connections {
        target: search
        function updateCount() {
            root.matchCount = search.rowCount()
            if (root.matchCount > 0 && search.currentResult < 0) search.currentResult = 0
        }
        function onRowsInserted() { updateCount() }
        function onRowsRemoved() { updateCount() }
        function onModelReset() { updateCount() }
    }

    ListView {
        id: pages
        objectName: "pageList"
        anchors.fill: parent
        anchors.rightMargin: 16
        anchors.bottomMargin: 14
        clip: true
        spacing: 16
        topMargin: 16
        bottomMargin: 16
        model: root.ready ? pdfDocument.pageCount : 0
        contentWidth: Math.max(width, pdfDocument.maxPageWidth * root.pageScale + 40)
        // Mouse dragging selects text; scrolling uses the wheel, trackpad or scrollbar.
        acceptedButtons: Qt.NoButton
        flickableDirection: Flickable.AutoFlickDirection
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: Math.max(0, height * 0.5)
        onContentYChanged: { if (!root.restoring) positionTimer.restart(); if ((root.linkPreview || previewShow.running) && !root.restoring && Math.abs(contentY - root.previewContentY) > 24) root.closeLinkPreview() }
        onContentXChanged: if (!root.restoring) positionTimer.restart()
        onMovementEnded: root.updatePosition()
        onMovementStarted: root.stopSourceMotion()
        ScrollBar.vertical: ScrollBar {
            objectName: "pdfVerticalScrollBar"
            parent: root; z: 50
            x: root.width - width; y: 0; width: 16; height: pages.height
            policy: ScrollBar.AlwaysOn; interactive: true; minimumSize: .05; padding: 3
            onPressedChanged: if (pressed) root.stopSourceMotion()
            background: Item {}
            contentItem: Rectangle { implicitWidth: 8; implicitHeight: 36; radius: 4; color: parent.pressed ? Theme.scrollHandlePressed : parent.hovered ? Theme.scrollHandleHover : Theme.scrollHandle }
        }
        ScrollBar.horizontal: ScrollBar {
            objectName: "pdfHorizontalScrollBar"
            parent: root; z: 50
            x: 0; y: root.height - height; width: pages.width; height: 14
            policy: ScrollBar.AsNeeded; interactive: true; minimumSize: .05; padding: 3
            onPressedChanged: if (pressed) root.stopSourceMotion()
            background: Item {}
            contentItem: Rectangle { implicitWidth: 36; implicitHeight: 8; radius: 4; color: parent.pressed ? Theme.scrollHandlePressed : parent.hovered ? Theme.scrollHandleHover : Theme.scrollHandle }
        }
        WheelHandler {
            target: null
            enabled: root.ready
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            acceptedModifiers: Qt.ControlModifier
            onWheel: function(event) { root.zoomByWheel(event) }
        }
        WheelHandler {
            target: null
            enabled: root.ready && Qt.platform.os === "osx"
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            // Qt maps the physical macOS Control key to MetaModifier.
            acceptedModifiers: Qt.MetaModifier
            onWheel: function(event) { root.zoomByWheel(event) }
        }

        delegate: Item {
            id: pageHolder
            property real selectionScale: root.pageScale
            required property int index
            readonly property size pointSize: pdfDocument.pagePointSize(index)
            property var lineMetrics: []
            property bool metricsReady: false
            function ensureMetrics() {
                if (!metricsReady) {
                    pageText.selectAll()
                    lineMetrics = selectionGeometry.lineRectangles(pageText.geometry)
                    metricsReady = true
                }
            }
            function overText(x, y) {
                return lineMetrics.some(function(r) {
                    return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height
                })
            }
            // Part of a selection that started on another page: from/to are set by the canvas, not this page's drag.
            property bool extended: false
            property point extFrom: Qt.point(0, 0)
            property point extTo: Qt.point(0, 0)
            readonly property alias pageSelection: selection
            function extendSelection(from, to) {
                // Release hold before moving the endpoints; a held selection ignores new points.
                if (!extended) { selectionScale = root.pageScale; extended = true; selection.hold = false }
                extFrom = from; extTo = to
                selection.from = from; selection.to = to
            }
            // Selections are hit-tested to characters, so "page start/end" must be on text, not page corners.
            function textStart(scale) {
                ensureMetrics()
                const line = lineMetrics.length ? lineMetrics[0] : null
                return line ? Qt.point((line.x + .5) * scale, (line.y + line.height / 2) * scale) : Qt.point(0, 0)
            }
            function textEnd(scale) {
                ensureMetrics()
                const line = lineMetrics.length ? lineMetrics[lineMetrics.length - 1] : null
                return line ? Qt.point((line.x + line.width - .5) * scale, (line.y + line.height / 2) * scale)
                            : Qt.point(pointSize.width * scale, pointSize.height * scale)
            }
            // The nearest point on a text line (PDF points), so a drag ending in a margin still selects text.
            function snapToText(point) {
                ensureMetrics()
                let best = null, distance = Infinity
                // Vertical and horizontal distance, so a drag past a column's edge stays in that column.
                lineMetrics.forEach(function(line) {
                    const dy = point.y < line.y ? line.y - point.y : point.y > line.y + line.height ? point.y - line.y - line.height : 0
                    const dx = point.x < line.x ? line.x - point.x : point.x > line.x + line.width ? point.x - line.x - line.width : 0
                    const d = dy + dx * .5
                    if (d < distance) { distance = d; best = line }
                })
                if (!best) return point
                return Qt.point(Math.max(best.x + .5, Math.min(best.x + best.width - .5, point.x)), best.y + best.height / 2)
            }
            function clearExtension() {
                if (!extended) return
                extended = false
                if (!selectionDrag.active) selection.clear()
                selection.from = Qt.binding(function() { return selectionDrag.centroid.pressPosition })
                selection.to = Qt.binding(function() { return selectionDrag.centroid.position })
                selection.hold = Qt.binding(function() { return !selectionDrag.active })
            }
            function selectWholePage() {
                selection.selectAll(); root.activeSelection = selection; root.selectedText = selection.text
                root.selectedAnchor = {page:index,text:selection.text,from:Qt.point(0,0),to:Qt.point(pointSize.width,pointSize.height)}
            }
            PdfSelection {
                id: pageText
                visible: false
                document: pdfDocument
                page: pageHolder.index
            }
            width: pages.contentWidth
            height: pointSize.height * root.pageScale

            Rectangle {
                id: paper
                objectName: "paperPage" + pageHolder.index
                width: pageHolder.pointSize.width * root.pageScale
                height: pageHolder.height
                anchors.horizontalCenter: parent.horizontalCenter
                color: root.invertPages ? Theme.paperInverted : Theme.paper

                PdfPageImage {
                    id: pageImage
                    objectName: "pageImage" + pageHolder.index
                    anchors.fill: parent
                    document: pdfDocument
                    currentFrame: pageHolder.index
                    asynchronous: true
                    retainWhileLoading: true
                    cache: false
                    sourceSize.width: Math.min(4096, Math.ceil(pageHolder.pointSize.width * root.rasterScale * Screen.devicePixelRatio))
                    fillMode: Image.PreserveAspectFit
                    // Counted while drawing, so background work can wait for the pages on screen.
                    property bool counted: false
                    onStatusChanged: {
                        const loading = status === Image.Loading
                        if (loading !== counted) { counted = loading; root.loadingPages += loading ? 1 : -1 }
                    }
                    Component.onDestruction: if (counted) root.loadingPages--
                    // Dark pages (Settings → Appearance): only while the option is on, so it costs nothing otherwise.
                    layer.enabled: root.invertPages
                    layer.effect: ShaderEffect { objectName: "invertEffect"; fragmentShader: "qrc:/owelk/shaders/invert.frag.qsb" }
                }

                // Only for a page with nothing on it yet, and only when it is slow: a redraw after a zoom
                // keeps showing the previous image instead.
                Timer {
                    id: slowPage
                    property bool slow: false
                    interval: 300
                    running: pageImage.status === Image.Loading && pageImage.paintedWidth === 0
                    onRunningChanged: if (running) slow = false
                    onTriggered: slow = true
                }
                BusyIndicator {
                    objectName: "pageBusy" + pageHolder.index
                    anchors.centerIn: parent
                    running: slowPage.slow && pageImage.status === Image.Loading && pageImage.paintedWidth === 0
                    visible: running
                }

                Label {
                    anchors.centerIn: parent
                    visible: pageImage.status === Image.Error
                    text: "Cannot display this page. Please reopen the PDF."
                    width: parent.width - 32
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: Theme.textSecondary
                }

                Shape {
                    anchors.fill: parent
                    visible: pageImage.status === Image.Ready
                    ShapePath {
                        strokeWidth: -1
                        fillColor: Theme.searchMatch
                        scale: Qt.size(root.pageScale, root.pageScale)
                        PathMultiline {
                            id: matches
                            function refresh() { paths = search.boundingPolygonsOnPage(pageHolder.index) }
                            Component.onCompleted: refresh()
                        }
                    }
                    Connections {
                        target: search
                        function onCurrentPageBoundingPolygonsChanged() { matches.refresh() }
                        function onSearchStringChanged() { matches.refresh() }
                    }
                    Connections {
                        target: root
                        function onMatchCountChanged() { matches.refresh() }
                    }
                }

                MouseArea {
                    id: textHover
                    objectName: "textHover" + pageHolder.index
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: pageHolder.ensureMetrics()
                    onPositionChanged: function(mouse) {
                        const x = mouse.x / root.pageScale, y = mouse.y / root.pageScale
                        if (pageHolder.overText(x, y)) root.restOn(pageHolder.index, Qt.point(x, y), mapToItem(root, mouse.x, mouse.y))
                        else root.leaveRest()
                    }
                    onExited: root.leaveRest()
                    acceptedButtons: Qt.RightButton
                    cursorShape: !root.captureMode && (!root.tool.length || root.tool === "highlight")
                        && containsMouse && pageHolder.overText(mouseX / root.pageScale, mouseY / root.pageScale)
                        ? Qt.IBeamCursor : Qt.ArrowCursor
                    onClicked: function(mouse) { root.contextRequested(mapToItem(root, mouse.x, mouse.y), pageHolder.index) }
                }
                Repeater {
                    model: root.savedHighlights.filter(function(h) { return h.page === pageHolder.index })
                    delegate: Item {
                        id: persistentMark
                        required property var modelData
                        anchors.fill: parent
                        Repeater {
                            model: persistentMark.modelData.rectangles
                            delegate: Item {
                                required property var modelData
                                required property int index
                                objectName: "savedHighlight-" + persistentMark.modelData.id
                                x: modelData.x * paper.width; y: modelData.y * paper.height
                                width: modelData.width * paper.width; height: modelData.height * paper.height
                                // Highlights tint the text; comments (and notes beside the page) only outline their place.
                                Rectangle {
                                    objectName: "markShape-" + persistentMark.modelData.id
                                    readonly property bool outline: persistentMark.modelData.kind === "comment"
                                    readonly property color ink: persistentMark.modelData.color || Theme.accent
                                    anchors.fill: parent
                                    visible: persistentMark.modelData.kind === "highlight" || outline
                                    radius: outline ? 2 : 0
                                    color: outline ? "transparent" : Qt.rgba(ink.r, ink.g, ink.b, .28)
                                    border.width: outline ? 1.5 : 0
                                    border.color: ink
                                }
                                Rectangle {
                                    objectName: "focusedMark-" + persistentMark.modelData.id
                                    anchors.fill: parent; anchors.margins: -2
                                    visible: root.focusedMark === persistentMark.modelData.id
                                    color: "transparent"; radius: 2
                                    border.width: 2; border.color: Theme.accent
                                }
                                // A text box at its own size (PDF points; older boxes 14 pt). The editor grows the box to
                                // fit, so nothing is clipped.
                                Text {
                                    objectName: "textBox-" + persistentMark.modelData.id
                                    anchors.fill: parent
                                    visible: persistentMark.modelData.kind === "text"
                                    text: persistentMark.modelData.body || ""
                                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                                    color: persistentMark.modelData.color
                                    font.pixelSize: Math.max(1, (persistentMark.modelData.fontSize || 14) * root.pageScale)
                                }
                                Image { anchors.fill: parent; visible: persistentMark.modelData.kind === "image"; source: visible ? persistentMark.modelData.image : ""; fillMode: Image.Stretch; asynchronous: true }
                                Canvas {
                                    id: savedStroke
                                    objectName: "savedStroke-" + persistentMark.modelData.id
                                    // The stored rectangle bounds the stroke centre line; pad it so round caps and
                                    // line width are never cut at the box edge.
                                    readonly property real pad: root.pageScale + 3
                                    readonly property var points: persistentMark.modelData.drawing || []
                                    function mapX(p) { return (p.x - parent.modelData.x) * paper.width + pad }
                                    function mapY(p) { return (p.y - parent.modelData.y) * paper.height + pad }
                                    x: -pad; y: -pad; width: parent.width + 2 * pad; height: parent.height + 2 * pad
                                    visible: persistentMark.modelData.kind === "draw"
                                    onWidthChanged: requestPaint(); onHeightChanged: requestPaint()
                                    onPaint: {
                                        const c = getContext("2d"); c.reset()
                                        c.strokeStyle = persistentMark.modelData.color; c.lineWidth = 2 * root.pageScale
                                        c.lineJoin = "round"; c.lineCap = "round"; c.beginPath()
                                        Stroke.trace(c, points, mapX, mapY); c.stroke()
                                    }
                                }
                                MouseArea {
                                    anchors.fill: persistentMark.modelData.kind === "draw" ? savedStroke : parent
                                    acceptedButtons: Qt.RightButton
                                    enabled: !root.captureMode
                                    cursorShape: persistentMark.modelData.text ? Qt.IBeamCursor : Qt.ArrowCursor
                                    // Only the ink is a drawing's hit area; empty space inside its box keeps text actions.
                                    onPressed: function(mouse) {
                                        if (persistentMark.modelData.kind === "draw"
                                            && Stroke.distance(savedStroke.points, mouse.x, mouse.y, savedStroke.mapX, savedStroke.mapY)
                                               > Math.max(6, 2 * root.pageScale)) mouse.accepted = false
                                    }
                                    onClicked: function(mouse) {
                                        root.removingHighlight = persistentMark.modelData.id
                                        root.editingMark = persistentMark.modelData
                                        root.markMenuPosition = mapToItem(root, mouse.x, mouse.y)
                                        highlightMenu.popup(parent, mouse.x, mouse.y)
                                    }
                                }
                                IconButton {
                                    objectName: "commentMarker-" + persistentMark.modelData.id + "-" + index
                                    visible: index === 0 && (!!persistentMark.modelData.body && persistentMark.modelData.kind !== "text")
                                    icon.name: "comment"; description: persistentMark.modelData.body || ""
                                    anchors.right: parent.right; y: -height / 2
                                    onClicked: root.editRequested(persistentMark.modelData, null)
                                }
                            }
                        }
                    }
                }

                Item {
                    objectName: "selectionOverlay" + pageHolder.index
                    anchors.fill: parent
                    visible: pageImage.status === Image.Ready
                    readonly property var rectangles: selectionGeometry.stableRectangles(selection.geometry, pageHolder.lineMetrics)
                    Repeater {
                        model: parent.rectangles
                        delegate: Rectangle {
                            required property var modelData
                            x: modelData.x * root.pageScale
                            y: modelData.y * root.pageScale
                            width: modelData.width * root.pageScale
                            height: modelData.height * root.pageScale
                            color: Theme.pageSelection
                        }
                    }
                }

                PdfSelection {
                    id: selection
                    objectName: "pageSelection" + pageHolder.index
                    anchors.fill: parent
                    document: pdfDocument
                    page: pageHolder.index
                    renderScale: pageHolder.selectionScale
                    from: selectionDrag.centroid.pressPosition
                    to: selectionDrag.centroid.position
                    hold: !selectionDrag.active
                    onTextChanged: {
                        if (root.crossPages.length) root.refreshCrossText()
                        else if (root.activeSelection === selection) {
                            root.selectedText = text
                            if (selectionDrag.active) root.rememberSelection(selection)
                        }
                    }
                }

                DragHandler {
                    id: selectionDrag
                    target: null
                    enabled: !root.captureMode && !root.pinching && (!root.tool.length || root.tool === "highlight")
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                    onCentroidChanged: {
                        if (active) root.trackSelectionDrag(pageHolder, selection.mapToItem(root, centroid.position.x, centroid.position.y), centroid.pressPosition)
                    }
                    onActiveChanged: {
                        root.selecting = active
                        if (active) {
                            root.clearCrossSelection()
                            root.stopSourceMotion()
                            // Do not reinterpret held pixel endpoints at a new zoom/viewport scale.
                            pageHolder.selectionScale = root.pageScale
                            pageHolder.ensureMetrics()
                            root.activated()
                            if (root.activeSelection && root.activeSelection !== selection)
                                root.activeSelection.clear()
                            root.activeSelection = selection
                            root.selectedAnchor = null
                            root.selectedText = selection.text
                            selection.forceActiveFocus()
                        } else if (root.activeSelection === selection) {
                            root.rememberSelection(selection)
                            if (root.tool === "highlight") Qt.callLater(function() { root.highlightSelection() })
                        }
                    }
                }

                Repeater {
                    model: PdfLinkModel {
                        document: pdfDocument
                        // Delegates can outlive the old page count briefly when switching tabs.
                        page: root.ready && pageHolder.index < root.pageCount ? pageHolder.index : -1
                    }
                    delegate: PdfLinkDelegate {
                        objectName: "pdfLink-" + pageHolder.index + "-" + index
                        x: rectangle.x * root.pageScale
                        y: rectangle.y * root.pageScale
                        width: rectangle.width * root.pageScale
                        height: rectangle.height * root.pageScale
                        enabled: !root.captureMode
                        onTapped: function(link) {
                            root.closeLinkPreview()
                            root.activated()
                            if (link.page >= 0) {
                                const size = pdfDocument.pagePointSize(link.page)
                                root.jumpRemembering(link.page, link.location.y / size.height, 0)
                            } else if (/^https?:\/\//i.test(url.toString())) {
                                root.externalLinkRequested(url)
                            }
                        }
                        // Hovering a reference ([12], Fig. 3, Eq. 2) shows where it points, in place.
                        // A link scrolled away or closed while under the pointer never reports leaving.
                        Component.onDestruction: if (workingLinkHover.hovered) root.hoveredLink = null
                        HoverHandler {
                            id: workingLinkHover
                            enabled: parent.page >= 0 && !root.captureMode && root.tool === ""
                            onHoveredChanged: {
                                const linkItem = parent
                                // Its destination, for reading the reference entry there when the link's own
                                // text is not a recognisable reference (an author name, say).
                                root.hoveredLink = hovered ? {page: linkItem.page, location: linkItem.location} : null
                                if (hovered) {
                                    const size = pdfDocument.pagePointSize(linkItem.page)
                                    const at = linkItem.mapToItem(root, 0, 0)
                                    root.requestLinkPreview({page: linkItem.page, y: size.height > 0 ? linkItem.location.y / size.height : 0,
                                                             x: at.x, top: at.y, bottom: at.y + linkItem.height})
                                } else root.leaveLinkPreview()
                            }
                            // The link takes the hover from the text below, so it passes the pointer on for
                            // the text lookup ([12] → its reference entry) itself.
                            onPointChanged: if (hovered) {
                                const linkItem = parent, p = point.position
                                root.restOn(pageHolder.index, Qt.point((linkItem.x + p.x) / root.pageScale, (linkItem.y + p.y) / root.pageScale),
                                            linkItem.mapToItem(root, p.x, p.y))
                            }
                        }
                    }
                }

                Rectangle {
                    objectName: "captureSourceBorder" + pageHolder.index
                    visible: root.highlight !== null && root.highlight.page === pageHolder.index
                    opacity: root.spotlightOpacity
                    scale: root.spotlightScale
                    property rect region: visible ? root.highlight.rect : Qt.rect(0, 0, 0, 0)
                    x: region.x * paper.width
                    y: region.y * paper.height
                    width: region.width * paper.width
                    height: region.height * paper.height
                    color: "transparent"
                    radius: Theme.radius
                    border.color: Theme.captureBorder
                    border.width: 2
                }

                MouseArea {
                    id: annotationArea
                    objectName: "annotationArea" + pageHolder.index
                    anchors.fill: parent
                    enabled: ["comment", "text", "image", "draw"].indexOf(root.tool) >= 0
                    visible: enabled; cursorShape: Qt.CrossCursor; preventStealing: true
                    property point start
                    property point end
                    property var points: []
                    property point lastSample
                    onPressed: function(mouse) { root.activated(); root.clearSelection(); start=Qt.point(mouse.x,mouse.y); end=start; lastSample=start; points=[{x:start.x/width,y:start.y/height}]; liveStroke.requestPaint() }
                    onPositionChanged: function(mouse) {
                        if (!pressed) return
                        end=Qt.point(Math.max(0,Math.min(width,mouse.x)),Math.max(0,Math.min(height,mouse.y)))
                        // Skip sub-pixel jitter; it only adds kinks to the smoothed curve.
                        if(root.tool==="draw" && points.length<5000 && Math.hypot(end.x-lastSample.x,end.y-lastSample.y)>=1.5) {
                            points.push({x:end.x/width,y:end.y/height}); lastSample=end
                        }
                        liveStroke.requestPaint()
                    }
                    onReleased: {
                        let x=Math.min(start.x,end.x)/width,y=Math.min(start.y,end.y)/height,w=Math.abs(end.x-start.x)/width,h=Math.abs(end.y-start.y)/height
                        if(root.tool==="draw") {
                            if((end.x!==lastSample.x||end.y!==lastSample.y) && points.length<5000) points.push({x:end.x/width,y:end.y/height})
                            x=Math.min.apply(null,points.map(function(p){return p.x}));y=Math.min.apply(null,points.map(function(p){return p.y}))
                            w=Math.max.apply(null,points.map(function(p){return p.x}))-x;h=Math.max.apply(null,points.map(function(p){return p.y}))-y
                        }
                        if(w<.005)w=root.tool==="comment"?.035:root.tool==="draw"?.005:.3
                        if(h<.005)h=root.tool==="comment"?.025:root.tool==="draw"?.005:.12
                        root.annotationPlaced(pageHolder.index,{x:x,y:y,width:Math.min(w,1-x),height:Math.min(h,1-y)},points)
                        liveStroke.requestPaint()
                    }
                    Rectangle { visible: annotationArea.pressed && root.tool!=="draw"; x:Math.min(annotationArea.start.x,annotationArea.end.x);y:Math.min(annotationArea.start.y,annotationArea.end.y);width:Math.abs(annotationArea.end.x-annotationArea.start.x);height:Math.abs(annotationArea.end.y-annotationArea.start.y);color:"transparent";border.color:Theme.accent }
                    Canvas { id:liveStroke;anchors.fill:parent;visible:annotationArea.pressed&&root.tool==="draw";onPaint:{const c=getContext("2d");c.reset();c.strokeStyle=root.drawColor;c.lineWidth=2*root.pageScale;c.lineCap="round";c.lineJoin="round";c.beginPath();Stroke.trace(c,annotationArea.points,function(p){return p.x*width},function(p){return p.y*height});c.stroke()} }
                }

                MouseArea {
                    id: captureArea
                    objectName: "captureArea" + pageHolder.index
                    anchors.fill: parent
                    visible: root.captureMode
                    enabled: root.captureMode
                    cursorShape: Qt.CrossCursor
                    preventStealing: true
                    property point start
                    property point end
                    onPressed: function(mouse) {
                        root.activated()
                        start = Qt.point(mouse.x, mouse.y)
                        end = start
                    }
                    onPositionChanged: function(mouse) {
                        if (pressed)
                            end = Qt.point(Math.max(0, Math.min(width, mouse.x)),
                                           Math.max(0, Math.min(height, mouse.y)))
                    }
                    onReleased: {
                        if (selectionBox.width >= 4 && selectionBox.height >= 4)
                            root.regionSelected(pageHolder.index,
                                Qt.rect(selectionBox.x / width, selectionBox.y / height,
                                        selectionBox.width / width, selectionBox.height / height))
                    }
                    Rectangle {
                        id: selectionBox
                        visible: captureArea.pressed
                        x: Math.min(captureArea.start.x, captureArea.end.x)
                        y: Math.min(captureArea.start.y, captureArea.end.y)
                        width: Math.abs(captureArea.end.x - captureArea.start.x)
                        height: Math.abs(captureArea.end.y - captureArea.start.y)
                        color: Theme.overlay
                        border.color: Theme.overlayBorder
                        border.width: 2
                    }
                }
            }
            Component.onDestruction: {
                if (root.activeSelection === selection) {
                    root.activeSelection = null
                    root.selectedText = ""
                    root.selectedAnchor = null
                }
            }
        }
    }

    PinchHandler {
        id: pinch
        target: null
        enabled: root.ready
        acceptedDevices: PointerDevice.TouchPad | PointerDevice.TouchScreen
        rotationAxis.enabled: false
        onActiveScaleChanged: if (active) root.updatePinch(activeScale, centroid.position)
        onTranslationChanged: if (active) root.updatePinch(activeScale, centroid.position)
        onActiveChanged: {
            if (active) root.beginPinch(centroid.position)
            else root.endPinch()
        }
    }

    Dialog {
        id: passwordDialog
        objectName: "pdfPasswordDialog"
        anchors.centerIn: parent
        modal: true
        title: "PDF password"
        standardButtons: Dialog.Ok | Dialog.Cancel
        property string tried: ""
        property string autoTried: ""
        property bool keep: false
        onOpened: passwordField.forceActiveFocus()
        Column {
            spacing: 8
            TextField {
                id: passwordField
                objectName: "pdfPasswordField"
                width: 260
                placeholderText: "Enter password"
                echoMode: TextInput.Password
                onAccepted: passwordDialog.accept()
            }
            CheckBox { id: rememberPassword; objectName: "pdfPasswordRemember"; text: "Remember on this computer" }
        }
        onAccepted: {
            tried = passwordField.text; keep = rememberPassword.checked
            pdfDocument.password = passwordField.text
            passwordField.clear()
        }
        onRejected: passwordField.clear()
    }
    // --- Reference previews -------------------------------------------------------------------
    property var linkPreview: null
    property var pendingPreview: null
    // Where the pages were scrolled when the preview was asked for: reading on (not layout settling) closes it.
    property real previewContentY: 0
    function requestLinkPreview(spec) { pendingPreview = spec; previewContentY = pages.contentY; previewHide.stop(); previewShow.restart() }
    function leaveLinkPreview() { previewShow.stop(); if (!previewHover.hovered) previewHide.restart() }
    function closeLinkPreview() { previewShow.stop(); previewHide.stop(); linkPreview = null; pendingPreview = null }
    Timer { id: previewShow; interval: 350; onTriggered: root.linkPreview = root.pendingPreview }
    // A citation shows its reference entries as a list (one or several); figures, tables and
    // equations keep the page view.
    function citedEntries(target) {
        if (target.entries && target.entries.length) return target.entries
        if ((target.kind !== "citation" && target.kind !== "author") || !target.text) return []
        return [{label: target.label, text: target.text, page: target.page, top: target.top, current: false}]
    }
    function goToEntry(entry) {
        const page = entry.page, top = Math.max(0, entry.top - .03)
        closeLinkPreview()
        jumpRemembering(page, top, 0)
    }
    // --- Back to where you were ----------------------------------------------------------------
    // Following a link, a preview or the outline remembers the spot left; Back (the pill, or Alt+Left)
    // returns there and Forward goes again. Scrolling and page turns are not remembered.
    property var backStack: []
    property var forwardStack: []
    function jumpRemembering(page, y, x) {
        if (!ready) return
        backStack = backStack.concat([position()]).slice(-20)
        forwardStack = []
        jump(page, y, x || 0)
    }
    function goBack() {
        if (!backStack.length) return false
        const target = backStack[backStack.length - 1]
        forwardStack = forwardStack.concat([position()]).slice(-20)
        backStack = backStack.slice(0, -1)
        jump(target.page, target.y, target.x)
        return true
    }
    function goForward() {
        if (!forwardStack.length) return false
        const target = forwardStack[forwardStack.length - 1]
        backStack = backStack.concat([position()]).slice(-20)
        forwardStack = forwardStack.slice(0, -1)
        jump(target.page, target.y, target.x)
        return true
    }
    // The spot Back returns to, while the reader is more than half a page away from it.
    readonly property var backTarget: backStack.length ? backStack[backStack.length - 1] : null
    readonly property bool awayFromBack: !!backTarget && Math.abs(lastPosition.page + lastPosition.y - backTarget.page - backTarget.y) > .5
    Rectangle {
        id: backPill
        objectName: "jumpBackPill"
        visible: root.awayFromBack && !root.captureMode
        z: 55
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom; anchors.bottomMargin: 26
        width: backRow.implicitWidth + 8; height: Theme.controlHeight + 4
        radius: height / 2
        color: Theme.raised
        border.color: Theme.border
        Row {
            id: backRow
            anchors.centerIn: parent
            spacing: 2
            ToolButton {
                objectName: "jumpBackButton"
                height: Theme.controlHeight
                icon.name: "back"
                text: "Back to p. " + (root.backTarget ? root.backTarget.page + 1 : "")
                ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: "Back to where you were reading · " + Platform.keys("Alt+Left")
                onClicked: root.goBack()
            }
            IconButton {
                objectName: "jumpBackDismiss"
                anchors.verticalCenter: parent.verticalCenter
                icon.name: "close"; description: "Forget this spot"
                onClicked: root.backStack = []
            }
        }
    }
    // A cited paper: look it up (its DOI or arXiv page, or a search for the entry), in a web tab.
    function findPaper(entry) {
        const url = Tree.referenceUrl(entry, researchStore.setting("searchEngine", "https://scholar.google.com/scholar?q=%s"))
        closeLinkPreview()
        if (url.length) externalLinkRequested(url)
    }
    // Papers without working links (most publisher PDFs): resting the pointer on "[12]", "Fig. 3",
    // "Table II" or "Eq. (4)" finds the target from the text (ReferenceFinder). Nothing runs until the
    // pointer rests on text.
    property var restSpot: null
    property int referenceRequest: -1
    // A working link under the pointer: {page, location} of its destination.
    property var hoveredLink: null
    property bool referenceFallback: false
    function restOn(page, point, viewPoint) {
        if (!ready || captureMode || tool.length || selecting || pinching) { referenceRest.stop(); return }
        // Moving off the reference that opened the card lets it go (unless the pointer goes into the card).
        if (linkPreview && linkPreview.fromText && Math.abs(viewPoint.x - linkPreview.anchorX) + Math.abs(viewPoint.y - linkPreview.anchorY) > 18) leaveLinkPreview()
        restSpot = {page: page, x: point.x, y: point.y, viewX: viewPoint.x, viewY: viewPoint.y}
        referenceRest.restart()
    }
    function leaveRest() {
        referenceRest.stop()
        restSpot = null
        if (linkPreview && linkPreview.fromText) leaveLinkPreview()
    }
    function resolveReference(spot) {
        referenceFallback = false
        referenceRequest = researchStore.references.resolve(source, spot.page, Qt.point(spot.x, spot.y))
    }
    Timer { id: referenceRest; interval: 350; onTriggered: if (root.restSpot) root.resolveReference(root.restSpot) }
    Connections {
        target: researchStore.references
        function onResolved(request, target) {
            if (request !== root.referenceRequest || !root.restSpot) return
            const spot = root.restSpot
            const fallback = root.referenceFallback
            root.referenceFallback = false
            if (target.page === undefined) {
                // A link whose text is no reference: the entry at its destination, if it is one.
                if (!fallback && root.hoveredLink) {
                    root.referenceFallback = true
                    root.referenceRequest = researchStore.references.entryAt(root.source, root.hoveredLink.page, root.hoveredLink.location)
                }
                return
            }
            if (fallback) {
                // Keep the link's own destination; add what the entry says (for Find Paper and the outline).
                const shown = root.linkPreview || root.pendingPreview
                if (!shown || !root.hoveredLink) return
                previewShow.stop(); previewHide.stop()
                root.linkPreview = Object.assign({}, shown, {kind: target.kind, label: target.label, text: target.text || "", entries: root.citedEntries(target),
                                                             rect: Qt.rect(target.x, target.y, target.width, target.height)})
                return
            }
            const half = 8 * root.pageScale
            previewShow.stop(); previewHide.stop()
            root.previewContentY = pages.contentY
            root.linkPreview = {page: target.page, y: target.top, x: spot.viewX, kind: target.kind, top: spot.viewY - half, bottom: spot.viewY + half,
                                rect: Qt.rect(target.x, target.y, target.width, target.height), label: target.label, text: target.text || "", entries: root.citedEntries(target),
                                fromText: true, anchorX: spot.viewX, anchorY: spot.viewY}
        }
    }
    Timer { id: previewHide; interval: 250; onTriggered: if (!previewHover.hovered) root.linkPreview = null }
    Rectangle {
        id: previewCard
        objectName: "linkPreview"
        visible: root.linkPreview !== null
        z: 60
        readonly property var spec: root.linkPreview || ({page: 0, y: 0, x: 0, top: 0, bottom: 0})
        // Figures and tables get a taller card, zoomed to their column.
        readonly property bool showsFloat: spec.kind === "figure" || spec.kind === "table"
        // A citation ([5], [3, 5], [12–14], Vaswani et al.): its reference entries as a list instead of the page.
        readonly property bool showsList: !!spec.entries && spec.entries.length > 0
        width: Math.min(560, root.width - 32)
        height: showsList ? Math.min(entryList.contentHeight + 12, root.height * .45)
              : showsFloat ? Math.min(420, root.height * .62) : Math.min(240, root.height * .45)
        // Below the reference when there is room, otherwise above it.
        x: Math.max(8, Math.min(root.width - width - 8, spec.x - 40))
        y: spec.bottom + height + 12 < root.height ? spec.bottom + 6 : Math.max(8, spec.top - height - 6)
        radius: Theme.radiusLarge
        color: root.invertPages ? Theme.paperInverted : Theme.paper
        border.color: Theme.border
        clip: true
        // Created only while shown, so references cost nothing until hovered. The page scrolls inside
        // the card (wheel, trackpad or drag) to see more around the target.
        Loader {
            active: previewCard.visible && !previewCard.showsList
            anchors.fill: parent
            sourceComponent: Flickable {
                id: previewFlick
                objectName: "linkPreviewFlick"
                readonly property size points: pdfDocument.pagePointSize(previewCard.spec.page)
                readonly property rect area: previewCard.spec.rect || Qt.rect(0, 0, 0, 0)
                // A caption line is about as wide as its column: zoom so that column fills the card.
                readonly property real zoom: previewCard.showsFloat && area.width > 0 && points.width > 0
                    ? Math.max(1, Math.min(2.2, points.width / (Math.max(area.width, points.width * .42) + 28))) : 1
                readonly property real scale: width * zoom / Math.max(1, points.width)
                contentWidth: page.width; contentHeight: page.height
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                // Figures: caption at the bottom, the figure above it. Tables: caption at the top, the
                // table below. Anything else: the target a little below the top, with context above.
                function place() {
                    const s = scale, a = area
                    let x = previewCard.showsFloat && a.width > 0 ? a.x * s - 14 : 0
                    let y = previewCard.spec.kind === "figure" && a.height > 0 ? (a.y + a.height) * s + 18 - height
                          : previewCard.spec.kind === "table" && a.height > 0 ? a.y * s - 14
                          : previewCard.spec.y * page.height - 28
                    contentX = Math.max(0, Math.min(contentWidth - width, x))
                    contentY = Math.max(0, Math.min(contentHeight - height, y))
                }
                Component.onCompleted: place()
                Connections { target: previewCard; function onSpecChanged() { Qt.callLater(previewFlick.place) } }
                PdfPageImage {
                    id: page
                    objectName: "linkPreviewPage"
                    document: pdfDocument
                    currentFrame: previewCard.spec.page
                    width: previewFlick.width * previewFlick.zoom
                    height: previewFlick.points.width > 0 ? width * previewFlick.points.height / previewFlick.points.width : width
                    sourceSize.width: Math.ceil(width * Screen.devicePixelRatio)
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    layer.enabled: root.invertPages
                    layer.effect: ShaderEffect { fragmentShader: "qrc:/owelk/shaders/invert.frag.qsb" }
                    // The found entry, caption or equation, outlined.
                    Rectangle {
                        objectName: "linkPreviewTarget"
                        readonly property rect area: previewFlick.area
                        visible: area.width > 0
                        x: area.x * previewFlick.scale - 3; y: area.y * previewFlick.scale - 2
                        width: area.width * previewFlick.scale + 6; height: area.height * previewFlick.scale + 4
                        radius: Theme.radiusSmall
                        color: "transparent"
                        border.color: Theme.accent
                        border.width: 1.5
                    }
                    // Click: go to what the card shows.
                    TapHandler {
                        onTapped: root.goToEntry({page: previewCard.spec.page, top: previewFlick.contentY / Math.max(1, previewFlick.contentHeight) + .03})
                    }
                }
            }
        }
        ListView {
            id: entryList
            objectName: "linkPreviewList"
            visible: previewCard.showsList
            anchors.fill: parent; anchors.margins: 6
            clip: true
            spacing: 2
            model: previewCard.showsList ? previewCard.spec.entries : []
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                id: entryRow
                required property var modelData
                required property int index
                objectName: "linkPreviewEntry-" + index
                width: ListView.view.width
                height: entryText.implicitHeight + 12
                radius: Theme.radiusSmall
                color: entryHover.hovered ? Theme.hover : modelData.current ? Theme.selected : "transparent"
                HoverHandler { id: entryHover }
                // Click: go to that entry.
                TapHandler {
                    // Closing the card removes this row, so go there first.
                    onTapped: root.goToEntry(entryRow.modelData)
                }
                Label {
                    id: entryText
                    x: 8; y: 6
                    width: parent.width - 16 - findEntry.width
                    text: "<b>" + entryRow.modelData.label + "</b> " + entryRow.modelData.text.replace(/^\s*(\[\d+\]|\d{1,3}\.)\s*/, "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
                    textFormat: Text.StyledText
                    wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                    font.pixelSize: Theme.fontSmall; color: Theme.text
                }
                IconButton {
                    id: findEntry
                    objectName: "findPaperEntry-" + entryRow.index
                    anchors.right: parent.right; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                    icon.name: "search"
                    description: "Find this paper · its DOI or arXiv page, or a search"
                    onClicked: root.findPaper(entryRow.modelData.text)
                }
            }
        }
        Rectangle {
            visible: !previewCard.showsList
            anchors.bottom: parent.bottom; anchors.right: parent.right; anchors.margins: 6
            width: goLabel.implicitWidth + 12; height: goLabel.implicitHeight + 6
            radius: Theme.radiusSmall
            color: Theme.raised; border.color: Theme.separator
            Label { id: goLabel; anchors.centerIn: parent; text: (previewCard.spec.label ? previewCard.spec.label + " · " : "") + "p. " + (previewCard.spec.page + 1) + " · click to go"; font.pixelSize: Theme.fontCaption; color: Theme.textSecondary }
        }
        // A cited paper: look it up (its DOI or arXiv page, or a search for the entry), in a web tab.
        Button {
            objectName: "findPaperButton"
            visible: !previewCard.showsList && (previewCard.spec.kind === "citation" || previewCard.spec.kind === "author") && !!previewCard.spec.text
            anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.margins: 6
            text: "Find Paper"
            icon.name: "search"
            ToolTip.visible: hovered; ToolTip.delay: 500
            ToolTip.text: "Open its DOI or arXiv page, or search for it · then download the PDF into the Library"
            onClicked: root.findPaper(previewCard.spec.text)
        }
        HoverHandler { id: previewHover; onHoveredChanged: if (!hovered) previewHide.restart() }
    }
    // Mouse side buttons turn pages, like Cmd+[ / Cmd+].
    // A handler, not a MouseArea, so text and link cursors underneath are unaffected.
    TapHandler {
        acceptedButtons: Qt.BackButton | Qt.ForwardButton
        onTapped: function(point, button) { if (button === Qt.BackButton) root.previousPage(); else root.nextPage() }
    }
}
