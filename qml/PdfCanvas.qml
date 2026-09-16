import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import QtQuick.Shapes

Item {
    id: root
    property url source
    property real zoomFactor: 1
    property bool captureMode: false
    property int currentPage: 0
    property string selectedText: ""
    property var activeSelection: null
    property var lastPosition: ({page: 0, y: 0, x: 0, zoom: 1})
    property var pendingPosition: null
    property bool restoring: false
    property var highlight: null
    readonly property bool ready: pdfDocument.status === PdfDocument.Ready
    readonly property int pageCount: pdfDocument.pageCount
    readonly property string error: source.toString().length && pdfDocument.status === PdfDocument.Error ? pdfDocument.error : ""
    readonly property real pageScale: Math.max(0.1, (width - 40) / Math.max(1, firstPageWidth)) * zoomFactor
    readonly property real firstPageWidth: ready ? pdfDocument.pagePointSize(0).width : 595
    property alias searchString: search.searchString
    property int matchCount: 0
    readonly property int currentMatch: search.currentResult
    signal positionChanged()
    signal activated()
    signal regionSelected(int page, rect normalizedRegion)

    function openFile(url, position) {
        pendingPosition = position || {page: 0, y: 0, x: 0, zoom: 1}
        lastPosition = pendingPosition
        restoring = true
        captureMode = false
        selectedText = ""
        if (activeSelection) activeSelection.clear()
        activeSelection = null
        highlight = null
        search.searchString = ""
        if (source.toString() === url.toString() && ready) {
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
        const saved = position()
        restoring = true
        zoomFactor = Math.max(0.5, Math.min(4, zoomFactor * multiplier))
        Qt.callLater(function() { jump(saved.page, saved.y, saved.x) })
    }

    function fitWidth() {
        zoom(1 / zoomFactor)
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
        highlight = {page: page, rect: rect}
        jump(page, Math.max(0, rect.y - 0.08), 0)
        highlightTimer.restart()
    }

    function copySelection() {
        if (selectedText.length) researchStore.copyText(selectedText)
    }

    onWidthChanged: {
        if (ready && !restoring) {
            pendingPosition = lastPosition
            restoring = true
            restoreTimer.restart()
        }
    }

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
    Timer { id: highlightTimer; interval: 4000; onTriggered: root.highlight = null }

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
        cacheBuffer: height * 0.5
        onContentYChanged: if (!root.restoring) positionTimer.restart()
        onContentXChanged: if (!root.restoring) positionTimer.restart()
        onMovementEnded: root.updatePosition()
        ScrollBar.vertical: ScrollBar {}
        ScrollBar.horizontal: ScrollBar {}

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
                    cache: false
                    sourceSize.width: Math.min(4096, Math.ceil(paper.width * Screen.devicePixelRatio))
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
                    renderScale: root.pageScale
                    from: selectionDrag.centroid.pressPosition
                    to: selectionDrag.centroid.position
                    hold: !selectionDrag.active
                    onTextChanged: {
                        if (root.activeSelection === selection) root.selectedText = text
                    }
                }

                DragHandler {
                    id: selectionDrag
                    target: null
                    enabled: !root.captureMode
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                    onActiveChanged: {
                        if (active) {
                            if (!pageHolder.metricsReady) {
                                pageText.selectAll()
                                pageHolder.lineMetrics = selectionGeometry.lineRectangles(pageText.geometry)
                                pageHolder.metricsReady = true
                            }
                            root.activated()
                            if (root.activeSelection && root.activeSelection !== selection)
                                root.activeSelection.clear()
                            root.activeSelection = selection
                            root.selectedText = selection.text
                            selection.forceActiveFocus()
                        }
                    }
                }

                TapHandler {
                    enabled: !root.captureMode
                    onTapped: root.activated()
                }

                HoverHandler {
                    enabled: !root.captureMode
                    cursorShape: Qt.IBeamCursor
                }

                Repeater {
                    model: PdfLinkModel { document: pdfDocument; page: pageHolder.index }
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
                    property rect region: visible ? root.highlight.rect : Qt.rect(0, 0, 0, 0)
                    x: region.x * paper.width
                    y: region.y * paper.height
                    width: region.width * paper.width
                    height: region.height * paper.height
                    color: "#22555555"
                    border.color: "#555555"
                    border.width: 2
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
                }
            }
        }
    }

    PinchHandler {
        id: pinch
        property real finalScale: 1
        target: null
        enabled: root.ready
        onActiveScaleChanged: if (active) finalScale = activeScale
        onActiveChanged: {
            if (active) finalScale = 1
            else root.zoom(finalScale)
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
