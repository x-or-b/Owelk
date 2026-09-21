import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import QtQuick.Shapes

Item {
    id: root
    property url source
    property alias document: pdfDocument
    property real zoomFactor: 1
    property bool pinching: false
    property bool selecting: false
    readonly property bool interacting: pinching || selecting || sourceScroll.running
    onInteractingChanged: researchStore.paperIndex.setReaderInteracting(root, interacting)
    property real pinchStartZoom: 1
    property var pinchAnchor: null
    readonly property real rasterScale: Math.max(0.1, (width - 56) / Math.max(1, firstPageWidth)) * (pinching ? pinchStartZoom : zoomFactor)
    property bool captureMode: false
    property int currentPage: 0
    property string selectedText: ""
    property var activeSelection: null
    property var selectedAnchor: null
    property var lastPosition: ({page: 0, y: 0, x: 0, zoom: 1})
    property var pendingPosition: null
    property bool restoring: false
    property var highlight: null
    property real spotlightOpacity: 0
    property real spotlightScale: .9
    property real spotlightGlow: 0
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

    function openFile(url, position) {
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
                x: Math.max(0, pages.contentX / Math.max(1, pages.contentWidth)), zoom: zoomFactor}
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
        Qt.callLater(function() { jump(saved.page, saved.y, saved.x) })
    }

    function fitWidth() {
        zoom(1 / zoomFactor)
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
        spotlightOpacity = 0; spotlightScale = .9; spotlightGlow = 0
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
        NumberAnimation { target: root; property: "spotlightGlow"; to: 1; duration: 140; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "spotlightGlow"; to: 0; duration: 160; easing.type: Easing.InOutQuad }
        PauseAnimation { duration: 3200 }
        NumberAnimation { target: root; property: "spotlightOpacity"; to: .4; duration: 600 }
    }

    function copySelection() {
        if (selectedText.length) researchStore.copyText(selectedText)
    }

    function clearSelection() {
        if (activeSelection) activeSelection.clear()
        activeSelection = null
        selectedText = ""
        selectedAnchor = null
    }

    TapHandler {
        enabled: root.ready && !root.captureMode && !root.pinching
        onTapped: { root.activated(); root.clearSelection() }
    }

    function rememberSelection(selection) {
        // Freeze PDF-point endpoints before zoom, resizing or opening a dock changes the scale.
        selectedAnchor = selection.text.length ? {
            page: selection.page, text: selection.text,
            from: Qt.point(selection.from.x / selection.renderScale, selection.from.y / selection.renderScale),
            to: Qt.point(selection.to.x / selection.renderScale, selection.to.y / selection.renderScale)
        } : null
    }

    function captureSelection() {
        if (!selectedAnchor || selectedAnchor.text !== selectedText || selecting) return
        researchStore.captureText(source, selectedAnchor.page, selectedAnchor.from, selectedAnchor.to, selectedAnchor.text)
    }

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
            root.zoomFactor = Math.max(0.5, Math.min(4, saved.zoom || 1))
            root.pendingPosition = null
            Qt.callLater(function() { root.jump(saved.page || 0, saved.y || 0, saved.x || 0) })
        }
    }
    Timer { id: positionTimer; interval: 180; onTriggered: root.updatePosition() }

    PdfDocument {
        id: pdfDocument
        source: root.source
        onStatusChanged: function(status) {
            if (status === PdfDocument.Ready) restoreTimer.restart()
        }
        onPasswordRequired: passwordDialog.open()
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
        onContentYChanged: if (!root.restoring) positionTimer.restart()
        onContentXChanged: if (!root.restoring) positionTimer.restart()
        onMovementEnded: root.updatePosition()
        onMovementStarted: root.stopSourceMotion()
        ScrollBar.vertical: ScrollBar {
            objectName: "pdfVerticalScrollBar"
            parent: root; z: 50
            x: root.width - width; y: 0; width: 16; height: pages.height
            policy: ScrollBar.AlwaysOn; interactive: true; minimumSize: .05; padding: 3
            onPressedChanged: if (pressed) root.stopSourceMotion()
            background: Rectangle { color: "#eeeeee" }
            contentItem: Rectangle { implicitWidth: 10; implicitHeight: 36; radius: 5; color: parent.pressed ? "#777777" : parent.hovered ? "#999999" : "#b5b5b5" }
        }
        ScrollBar.horizontal: ScrollBar {
            objectName: "pdfHorizontalScrollBar"
            parent: root; z: 50
            x: 0; y: root.height - height; width: pages.width; height: 14
            policy: ScrollBar.AsNeeded; interactive: true; minimumSize: .05; padding: 3
            onPressedChanged: if (pressed) root.stopSourceMotion()
            contentItem: Rectangle { implicitWidth: 36; implicitHeight: 8; radius: 4; color: parent.pressed ? "#777777" : "#b5b5b5" }
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
                color: "white"

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
                }

                BusyIndicator {
                    anchors.centerIn: parent
                    running: pageImage.status === Image.Loading
                    visible: running
                }

                Label {
                    anchors.centerIn: parent
                    visible: pageImage.status === Image.Error
                    text: "Cannot display this page. Please reopen the PDF."
                    width: parent.width - 32
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: "#555555"
                }

                Shape {
                    anchors.fill: parent
                    visible: pageImage.status === Image.Ready
                    ShapePath {
                        strokeWidth: -1
                        fillColor: "#33777777"
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
                            color: "#66555555"
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
                        if (root.activeSelection === selection) {
                            root.selectedText = text
                            if (selectionDrag.active) root.rememberSelection(selection)
                        }
                    }
                }

                DragHandler {
                    id: selectionDrag
                    target: null
                    enabled: !root.captureMode && !root.pinching
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                    onActiveChanged: {
                        root.selecting = active
                        if (active) {
                            root.stopSourceMotion()
                            // Do not reinterpret held pixel endpoints at a new zoom/viewport scale.
                            pageHolder.selectionScale = root.pageScale
                            if (!pageHolder.metricsReady) {
                                pageText.selectAll()
                                pageHolder.lineMetrics = selectionGeometry.lineRectangles(pageText.geometry)
                                pageHolder.metricsReady = true
                            }
                            root.activated()
                            if (root.activeSelection && root.activeSelection !== selection)
                                root.activeSelection.clear()
                            root.activeSelection = selection
                            root.selectedAnchor = null
                            root.selectedText = selection.text
                            selection.forceActiveFocus()
                        } else if (root.activeSelection === selection) root.rememberSelection(selection)
                    }
                }

                HoverHandler {
                    enabled: !root.captureMode
                    cursorShape: Qt.IBeamCursor
                }

                Repeater {
                    model: PdfLinkModel {
                        document: pdfDocument
                        // Delegates can outlive the old page count briefly when switching tabs.
                        page: root.ready && pageHolder.index < root.pageCount ? pageHolder.index : -1
                    }
                    delegate: PdfLinkDelegate {
                        x: rectangle.x * root.pageScale
                        y: rectangle.y * root.pageScale
                        width: rectangle.width * root.pageScale
                        height: rectangle.height * root.pageScale
                        enabled: !root.captureMode
                        onTapped: function(link) {
                            root.activated()
                            if (link.page >= 0) {
                                const size = pdfDocument.pagePointSize(link.page)
                                root.jump(link.page, link.location.y / size.height, 0)
                            } else if (/^https?:\/\//i.test(url.toString())) {
                                Qt.openUrlExternally(url)
                            }
                        }
                    }
                }

                Rectangle {
                    visible: root.highlight !== null && root.highlight.page === pageHolder.index
                    opacity: root.spotlightOpacity
                    scale: root.spotlightScale
                    property rect region: visible ? root.highlight.rect : Qt.rect(0, 0, 0, 0)
                    x: region.x * paper.width
                    y: region.y * paper.height
                    width: region.width * paper.width
                    height: region.height * paper.height
                    color: "transparent"
                    border.color: Qt.rgba(.32 + root.spotlightGlow * .23, .32 + root.spotlightGlow * .23, .32 + root.spotlightGlow * .23, 1)
                    border.width: 2
                    Rectangle {
                        anchors.fill: parent; anchors.margins: -3
                        color: "transparent"; radius: 3
                        border.width: 4; border.color: "#999999"
                        opacity: root.spotlightGlow * .28
                    }
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
                        color: "#33555555"
                        border.color: "#555555"
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
        anchors.centerIn: parent
        modal: true
        title: "PDF password"
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField {
            id: passwordField
            placeholderText: "Enter password"
            echoMode: TextInput.Password
            onAccepted: passwordDialog.accept()
        }
        onAccepted: { pdfDocument.password = passwordField.text; passwordField.clear() }
        onRejected: passwordField.clear()
    }
}
