import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 820
    height: 720
    property var canvas: null
    App.ReaderPane {
        id: reader
        anchors.fill: parent
        paneIndex: 0
        isActive: true
    }
    SignalSpy { id: captureSpy; target: researchStore; signalName: "captureSaved" }
    SignalSpy { id: messageSpy; target: researchStore; signalName: "message" }

    TestCase {
        name: "PdfReader"
        when: windowShown
        function init() {
            canvas = findChild(reader, "pdfCanvas0")
            verify(canvas !== null)
            reader.hideSearch()
            canvas.captureMode = false
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
            tryCompare(canvas, "restoring", false, 10000)
            wait(150)
        }
        function test_searchAndNavigation() {
            compare(canvas.pageCount, 8)
            canvas.searchString = "occlusion"
            tryVerify(function() { return canvas.matchCount >= 8 }, 10000)
            canvas.nextMatch(1)
            verify(canvas.currentMatch >= 0)
            canvas.jump(5, .25, 0)
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 5)
            verify(Math.abs(canvas.position().y - .25) < .03)
        }
        function test_pageRendering() {
            const page = findChild(canvas, "pageImage0")
            verify(page !== null)
            verify(page.document !== null, "The page image must have a PDF document")
            tryCompare(page, "status", Image.Ready, 10000)
            verify(page.paintedWidth > 0)
            verify(page.paintedHeight > 0)
            // Inspect the offscreen test render, not the user's desktop.
            waitForRendering(page)
            const pixels = grabImage(page)
            let darkPixels = 0
            for (let y = 0; y < Math.min(pixels.height, 400); y += 4) {
                for (let x = 0; x < pixels.width; x += 4) {
                    if (pixels.alpha(x, y) > 0 && pixels.red(x, y) < 180)
                        darkPixels++
                }
            }
            verify(darkPixels > 20, "Rendered page must contain text, not just a white surface")
        }
        function test_zoomAndRestore() {
            canvas.jump(3, .35, 0)
            tryCompare(canvas, "restoring", false)
            canvas.zoom(1.4)
            tryCompare(canvas, "restoring", false)
            compare(canvas.zoomFactor, 1.4)
            compare(canvas.currentPage, 3)
            verify(Math.abs(canvas.position().y - .35) < .03)
            const saved = canvas.position()
            canvas.jump(0, 0, 0)
            tryCompare(canvas, "restoring", false)
            canvas.openFile(fixtureSource, saved)
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 3)
            verify(Math.abs(canvas.position().y - saved.y) < .03)
        }
        function test_continuousPinchAnchorsAndDefersRenders() {
            canvas.jump(2, .2, 0)
            tryCompare(canvas, "restoring", false)
            const point = Qt.point(canvas.width / 2, 220)
            const before = canvas.anchorAt(point)
            const image = findChild(canvas, "pageImage" + before.page)
            tryCompare(image, "status", Image.Ready, 10000)
            const resolution = image.sourceSize.width
            verify(canvas.beginPinch(point))
            for (let i = 1; i <= 12; ++i) {
                canvas.updatePinch(1 + i * .04, point)
                compare(image.sourceSize.width, resolution, "Pinching must not enqueue a raster per gesture update")
                compare(canvas.zoomFactor, 1 + i * .04)
                const current = canvas.anchorAt(point)
                compare(current.page, before.page)
                verify(Math.abs(current.x - before.x) < 1)
                verify(Math.abs(current.y - before.y) < 1)
            }
            canvas.endPinch()
            verify(image.sourceSize.width > resolution)
            compare(canvas.pinching, false)
            compare(canvas.restoring, false)
            const saved = canvas.position()
            canvas.openFile(fixtureSource, saved)
            tryCompare(canvas, "restoring", false)
            compare(canvas.zoomFactor, 1.48)
        }
        function test_pinchBoundsAndCancel() {
            const point = Qt.point(canvas.width / 2, 220)
            verify(canvas.beginPinch(point))
            canvas.updatePinch(100, point); compare(canvas.zoomFactor, 4)
            canvas.updatePinch(.01, point); compare(canvas.zoomFactor, .5)
            canvas.cancelPinch(); compare(canvas.zoomFactor, 1)
            compare(canvas.pinching, false)
        }
        function test_nativeTrackpadGesture() {
            const point = Qt.point(canvas.width / 2, 220)
            testInput.nativePinch(canvas, 0, 0, point)
            testInput.nativePinch(canvas, 1, .1, point)
            testInput.nativePinch(canvas, 1, .1, point)
            verify(canvas.pinching)
            verify(canvas.zoomFactor > 1)
            testInput.nativePinch(canvas, 2, 0, point)
            compare(canvas.pinching, false)
            compare(canvas.restoring, false)
        }
        function test_modifierWheelZoom_data() {
            const rows = [{tag: "ctrl_or_command", modifiers: Qt.ControlModifier}]
            if (Qt.platform.os === "osx") rows.push({tag: "mac_physical_control", modifiers: Qt.MetaModifier})
            return rows
        }
        function test_modifierWheelZoom(data) {
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, 120, Qt.NoButton, data.modifiers)
            tryVerify(function() { return Math.abs(canvas.zoomFactor - 1.15) < .001 })
            tryCompare(canvas, "restoring", false)
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, -120, Qt.NoButton, data.modifiers)
            tryVerify(function() { return Math.abs(canvas.zoomFactor - 1) < .001 })
        }
        function test_unmodifiedWheelScrolls() {
            canvas.jump(1, .25, 0)
            tryCompare(canvas, "restoring", false)
            const list = findChild(canvas, "pageList")
            const y = list.contentY
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, -120, Qt.NoButton, Qt.NoModifier)
            tryVerify(function() { return Math.abs(list.contentY - y) > 1 })
            compare(canvas.zoomFactor, 1)
        }
        function test_scrollBarDrag_data() {
            return [{tag: "left_edge", fraction: .1, capture: false}, {tag: "right_edge_capture_mode", fraction: .9, capture: true}]
        }
        function test_scrollBarDrag(data) {
            const bar = findChild(canvas, "pdfVerticalScrollBar")
            verify(bar.interactive && bar.visible)
            canvas.captureMode = data.capture
            const before = findChild(canvas, "pageList").contentY
            const thumb = bar.contentItem
            const from = bar.mapToItem(canvas, bar.width * data.fraction, thumb.y + thumb.height / 2)
            testInput.pointerDrag(canvas, from, Qt.point(from.x, from.y + 140), false)
            tryVerify(function() { return findChild(canvas, "pageList").contentY > before + 100 })
        }
        function test_captureMotionAndSpotlight() {
            const start = findChild(canvas, "pageList").contentY
            canvas.showSource(3, Qt.rect(.1, .4, .3, .1))
            compare(canvas.spotlightOpacity, 0)
            wait(100)
            const middle = findChild(canvas, "pageList").contentY
            verify(middle > start && middle < canvas.targetScrollY)
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 3)
            tryVerify(function() { return canvas.spotlightOpacity > .95 })
            tryVerify(function() { return canvas.spotlightGlow > .05 })
            tryVerify(function() { return canvas.spotlightGlow === 0 })
            canvas.openFile(fixtureSource)
            compare(canvas.highlight, null)
        }
        function test_findBarIsOptional() {
            const bar = findChild(reader, "searchBar")
            const field = findChild(reader, "searchField")
            compare(bar.visible, false)
            reader.find()
            compare(bar.visible, true)
            tryCompare(field, "activeFocus", true)
            field.text = "occlusion"
            keyClick(Qt.Key_Return)
            tryVerify(function() { return canvas.matchCount > 0 })
            keyClick(Qt.Key_Escape)
            compare(bar.visible, false)
            compare(canvas.searchString, "")
            compare(field.text, "")
            reader.find()
            tryCompare(field, "activeFocus", true)
            compare(bar.visible, true)
            reader.hideSearch()
        }
        function test_textSelection() {
            const paper = findChild(canvas, "paperPage0")
            verify(paper !== null)
            const bounds = fixtureTextBounds
            const selection = findChild(canvas, "pageSelection0")
            verify(selection.document !== null)
            const list = findChild(canvas, "pageList")
            const previousY = list.contentY
            const start = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                         (bounds.y + bounds.height / 2) * canvas.pageScale)
            mouseDrag(canvas, start.x, start.y, bounds.width * canvas.pageScale, 0, Qt.LeftButton, Qt.NoModifier, 40)
            tryVerify(function() { return canvas.selectedText.length > 4 }, 5000)
            verify(canvas.selectedText.indexOf("Research finding") >= 0)
            const overlay = findChild(canvas, "selectionOverlay0")
            compare(overlay.rectangles.length, 1, "A selected line should have one continuous rectangle")
            verify(overlay.rectangles[0].width > bounds.width * .8)
            verify(overlay.rectangles[0].height > bounds.height)
            compare(list.contentY, previousY, "Selecting text must not scroll the page")
        }
        function test_blankClickClearsSelection() {
            const paper = findChild(canvas, "paperPage0")
            const bounds = fixtureTextBounds
            const from = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                         (bounds.y + bounds.height / 2) * canvas.pageScale)
            testInput.pointerDrag(canvas, from, Qt.point(from.x + bounds.width * canvas.pageScale, from.y), false)
            verify(canvas.selectedText.length > 0)
            mouseClick(paper, paper.width - 20, 30)
            compare(canvas.selectedText, "")
            compare(canvas.selectedAnchor, null)
            compare(findChild(canvas, "selectionOverlay0").rectangles.length, 0)
        }
        function test_revealCancelledWhenReaderReused() {
            // A queued reveal must never survive reuse of this pane for another tab.
            reader.restore({})
            reader.reveal(fixtureSource, 5, Qt.rect(.1, .4, .3, .1))
            reader.restore({source: outlineSource, position: {page: 0, zoom: 1}})
            tryCompare(canvas, "ready", true)
            tryCompare(canvas, "restoring", false)
            wait(350)
            compare(canvas.source.toString(), outlineSource.toString())
            compare(canvas.currentPage, 0)
            compare(canvas.highlight, null)
            compare(reader.sourceToReveal, null)
        }
        function test_revealWaitsForExistingTabRestore() {
            canvas.openFile(fixtureSource, {page: 0, zoom: 1.2})
            reader.reveal(fixtureSource, 5, Qt.rect(.1, .4, .3, .1))
            tryCompare(canvas, "currentPage", 5)
            wait(350)
            compare(canvas.currentPage, 5)
            verify(Math.abs(canvas.position().y - .32) < .03)
            compare(reader.sourceToReveal, null)
        }
        function test_revealClearsFindAndReachesZoomedRegion() {
            canvas.zoom(3)
            tryCompare(canvas, "restoring", false)
            reader.find()
            canvas.searchString = "occlusion"
            tryVerify(function() { return canvas.matchCount > 0 })
            const region = Qt.rect(.7, .4, .15, .1)
            reader.reveal(fixtureSource, 4, region)
            tryCompare(canvas, "currentPage", 4)
            wait(350)
            compare(canvas.currentPage, 4)
            compare(canvas.searchString, "")
            compare(reader.searchVisible, false)
            const paper = findChild(canvas, "paperPage4")
            const point = paper.mapToItem(canvas, region.x * paper.width, region.y * paper.height)
            verify(point.x >= 0 && point.x < canvas.width)
            verify(point.y >= 0 && point.y < canvas.height)
        }
        function test_saveExcerpt_data() {
            return [{tag: "single_line", reverse: false, dy: 0, zoom: 1},
                    {tag: "reversed_multiline_after_zoom", reverse: true, dy: 40, zoom: 1.2},
                    {tag: "already_zoomed", reverse: false, dy: 40, zoom: 1, initialZoom: 1.4}]
        }
        function test_saveExcerpt(data) {
            captureSpy.clear()
            messageSpy.clear()
            if (data.initialZoom) {
                canvas.zoom(data.initialZoom)
                tryCompare(canvas, "restoring", false)
            }
            const paper = findChild(canvas, "paperPage0")
            const bounds = fixtureTextBounds
            const from = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                         (bounds.y + bounds.height / 2) * canvas.pageScale)
            const to = Qt.point(from.x + bounds.width * canvas.pageScale, from.y + data.dy * canvas.pageScale)
            testInput.pointerDrag(canvas, data.reverse ? to : from, data.reverse ? from : to, false)
            tryVerify(function() { return canvas.selectedText.indexOf("Research finding") >= 0 })
            const text = canvas.selectedText
            verify(canvas.selectedAnchor !== null)
            if (data.zoom !== 1) {
                canvas.zoom(data.zoom)
                tryCompare(canvas, "restoring", false)
            }
            const button = findChild(reader, "saveExcerptButton")
            verify(button.visible && button.enabled)
            compare(canvas.selectedAnchor.text, canvas.selectedText)
            compare(canvas.selecting, false)
            mouseClick(button)
            tryVerify(function() { return captureSpy.count > 0 || messageSpy.count > 0 }, 10000)
            compare(captureSpy.count, 1, JSON.stringify(messageSpy.signalArguments))
            const saved = researchStore.captures.filter(function(c) { return c.id === captureSpy.signalArguments[0][0] })[0]
            compare(saved.kind, "text")
            compare(saved.text, text)
            compare(saved.page, 0)
            verify(researchStore.searchKnowledge("Research finding").some(function(c) { return c.id === saved.id }))
            verify(researchStore.deleteCapture(saved.id))
            canvas.openFile(fixtureSource)
            compare(canvas.selectedAnchor, null)
            compare(button.visible, false)
        }
        function test_pointerDevices_data() {
            return [{tag: "mouse", trackpad: false}, {tag: "trackpad", trackpad: true}]
        }
        function test_selectionHeightStaysStable() {
            const paper = findChild(canvas, "paperPage0")
            function select(bounds) {
                const start = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                             (bounds.y + bounds.height / 2) * canvas.pageScale)
                mouseDrag(canvas, start.x, start.y, bounds.width * canvas.pageScale, 0, Qt.LeftButton, Qt.NoModifier, 40)
            }
            select(fixtureLowerBounds)
            const overlay = findChild(canvas, "selectionOverlay0")
            tryVerify(function() { return overlay.rectangles.length === 1 })
            const top = overlay.rectangles[0].y
            const height = overlay.rectangles[0].height
            select(fixtureMixedBounds)
            tryVerify(function() { return overlay.rectangles.length === 1 })
            compare(overlay.rectangles[0].y, top)
            compare(overlay.rectangles[0].height, height)
        }
        function test_multilineSelection() {
            const paper = findChild(canvas, "paperPage0")
            const bounds = fixtureTextBounds
            const start = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                         (bounds.y + bounds.height / 2) * canvas.pageScale)
            mouseDrag(canvas, start.x, start.y, bounds.width * canvas.pageScale, 40 * canvas.pageScale,
                      Qt.LeftButton, Qt.NoModifier, 40)
            const overlay = findChild(canvas, "selectionOverlay0")
            tryCompare(overlay.rectangles, "length", 3)
            verify(canvas.selectedText.indexOf("Research finding 1.2") >= 0)
            verify(overlay.rectangles[1].y > overlay.rectangles[0].y + overlay.rectangles[0].height)
        }
        function test_pointerDevices(data) {
            const paper = findChild(canvas, "paperPage0")
            const bounds = fixtureTextBounds
            const start = paper.mapToItem(canvas, bounds.x * canvas.pageScale,
                                         (bounds.y + bounds.height / 2) * canvas.pageScale)
            testInput.pointerDrag(canvas, start, Qt.point(start.x + bounds.width * canvas.pageScale, start.y), data.trackpad)
            tryVerify(function() { return canvas.selectedText.indexOf("Research finding") >= 0 }, 1000)
            reader.copySelection()
            compare(testInput.clipboardText(), canvas.selectedText)
        }
        function test_captureModeCursor() {
            const area = findChild(canvas, "captureArea0")
            verify(area !== null)
            compare(area.visible, false)
            canvas.captureMode = true
            compare(area.visible, true)
            compare(area.cursorShape, Qt.CrossCursor)
            canvas.openFile(fixtureSource)
            compare(canvas.captureMode, false)
            compare(area.visible, false)
        }
        function test_regionCapture() {
            captureSpy.clear()
            canvas.jump(1, .45, 0)
            tryCompare(canvas, "restoring", false)
            canvas.captureMode = true
            const paper = findChild(canvas, "paperPage1")
            verify(paper !== null)
            const start = paper.mapToItem(canvas, paper.width * .12, paper.height * .57)
            mouseDrag(canvas, start.x, start.y, paper.width * .5, paper.height * .12, Qt.LeftButton, Qt.NoModifier, 40)
            tryCompare(captureSpy, "count", 1, 15000)
            compare(researchStore.captures[0].page, 1)
        }
    }
}
