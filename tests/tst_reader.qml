import QtQuick
import QtTest
import Owelk.Ui
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
        function test_selectionAcrossPagesExcerptAndHighlights() {
            canvas.zoom(0.6)
            tryCompare(canvas, "restoring", false)
            canvas.jump(0, .35, 0)
            tryCompare(canvas, "restoring", false)
            wait(200)
            const first = findChild(canvas, "paperPage0"), second = findChild(canvas, "paperPage1")
            tryVerify(function() { return first !== null && second !== null })
            const scale = canvas.pageScale
            // From the last finding line on page 1 into the first lines of page 2.
            const start = first.mapToItem(canvas, 50 * scale, 385 * scale), end = second.mapToItem(canvas, 420 * scale, 212 * scale)
            verify(end.y < canvas.height, "page 2 text must be on screen: " + end.y)
            testInput.pointerDrag(canvas, start, end, false)
            tryVerify(function() { return canvas.selectedAnchor && canvas.selectedAnchor.segments })
            compare(canvas.selectedAnchor.segments.length, 2)
            compare(canvas.selectedAnchor.segments[0].page, 0)
            compare(canvas.selectedAnchor.segments[1].page, 1)
            verify(canvas.selectedText.indexOf("1.11") >= 0, canvas.selectedText)
            verify(canvas.selectedText.indexOf("2.1") >= 0, canvas.selectedText)
            const before = researchStore.captures.length
            canvas.captureSelection()
            tryVerify(function() { return researchStore.captures.length === before + 1 }, 10000)
            const excerpt = researchStore.captures[0]
            compare(excerpt.kind, "text")
            verify(excerpt.text.indexOf("1.11") >= 0 && excerpt.text.indexOf("2.1") >= 0, excerpt.text)
            compare(excerpt.page, 0)
            // Highlights are stored per page.
            const marks = researchStore.searchKnowledge("Research finding 2.1").filter(function(r) { return r.kind === "highlight" }).length
            canvas.highlightSelection()
            tryVerify(function() { return canvas.savedHighlights.length >= 1 }, 10000)
            tryVerify(function() { return researchStore.searchKnowledge("Section 2").length >= 0 && canvas.savedHighlights.some(function(h) { return h.page === 1 }) && canvas.savedHighlights.some(function(h) { return h.page === 0 }) }, 10000)
            canvas.clearSelection()
            verify(!canvas.crossPages.length)
            canvas.zoom(1 / 0.6)
        }
        function test_lockedPdfAsksOnceThenOpensWithTheRememberedPassword() {
            const locked = testInput.dataFile("locked.pdf")
            canvas.openFile(locked, {page: 0, y: 0, x: 0, zoom: 1})
            const dialog = findChild(canvas, "pdfPasswordDialog")
            tryCompare(dialog, "opened", true, 10000)
            findChild(canvas, "pdfPasswordField").text = "owelk"
            dialog.accept()
            tryCompare(canvas, "ready", true, 10000)
            compare(researchStore.pdfPassword(locked), "owelk") // Shared with background work.
            // Opened again: the known password is used without asking.
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
            canvas.openFile(locked, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
            compare(dialog.opened, false)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function test_previousAndNextPage() {
            canvas.openFile(longSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            const back = findChild(reader, "previousPage"), next = findChild(reader, "nextPage")
            verify(!back.enabled, "no page before the first")
            // The arrow, Cmd+] and Cmd+[ turn one page at a time.
            mouseClick(next)
            tryCompare(canvas, "currentPage", 1)
            testInput.keyClick(canvas, Qt.Key_BracketRight, Qt.ControlModifier)
            tryCompare(canvas, "currentPage", 2)
            verify(canvas.position().y < .05, "a new page starts at its top")
            testInput.keyClick(canvas, Qt.Key_BracketLeft, Qt.ControlModifier)
            tryCompare(canvas, "currentPage", 1)
            mouseClick(back)
            tryCompare(canvas, "currentPage", 0)
            // On the last page there is no next one.
            canvas.jump(canvas.pageCount - 1, 0, 0); tryCompare(canvas, "restoring", false)
            verify(!next.enabled)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function test_fitPageShowsWholePagesAndIsKept() {
            canvas.openFile(longSource, {page: 1, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            compare(canvas.fitMode, "width")
            // The zoom readout offers both fits; Fit Page shows the whole page.
            mouseClick(findChild(reader, "zoomReadout"))
            const menu = findChild(reader, "fitMenu")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "fitPageItem"))
            tryCompare(canvas, "fitMode", "page"); tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 1)
            const page = findChild(canvas, "paperPage1")
            verify(page.height <= canvas.height, "the whole page fits: " + page.height + " vs " + canvas.height)
            compare(canvas.position().fit, "page")
            // Turning the page keeps a whole page in view; a manual zoom leaves the fit.
            testInput.keyClick(canvas, Qt.Key_BracketRight, Qt.ControlModifier)
            tryCompare(canvas, "currentPage", 2)
            compare(canvas.fitMode, "page")
            canvas.zoom(1.2); tryCompare(canvas, "restoring", false)
            compare(canvas.fitMode, "")
            // Reopening restores the fit, not a stale zoom.
            canvas.fitPage(); tryCompare(canvas, "restoring", false)
            const saved = canvas.position()
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            compare(canvas.fitMode, "width")
            canvas.openFile(longSource, saved)
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            compare(canvas.fitMode, "page")
            canvas.fitWidth(); tryCompare(canvas, "restoring", false)
            compare(canvas.zoomFactor, 1)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function test_internalLinkJumps() {
            canvas.openFile(linkSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            const link = tryFindLink()
            mouseClick(link, link.width / 2, link.height / 2)
            tryCompare(canvas, "currentPage", 2)
        }
        function test_hoveringAReferencePreviewsItsTarget() {
            canvas.openFile(linkSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            const link = tryFindLink(), card = findChild(canvas, "linkPreview")
            verify(!card.visible)
            // Resting on the reference shows its target page in place, without moving the reading position.
            mouseMove(link, link.width / 2, link.height / 2)
            tryCompare(card, "visible", true, 3000)
            compare(findChild(card, "linkPreviewPage").currentFrame, 2)
            compare(canvas.currentPage, 0)
            // Clicking the preview goes there.
            mouseClick(card, card.width / 2, card.height / 2)
            tryCompare(canvas, "currentPage", 2)
            verify(!card.visible)
            // Leaving the reference without entering the preview hides it.
            canvas.jump(0, 0, 0); tryCompare(canvas, "restoring", false)
            const again = tryFindLink()
            mouseMove(canvas, 4, canvas.height - 4)
            mouseMove(again, again.width / 2, again.height / 2)
            tryCompare(card, "visible", true, 3000)
            mouseMove(canvas, 4, canvas.height - 4)
            tryCompare(card, "visible", false, 3000)
            // Reading on (scrolling) closes it too.
            mouseMove(again, again.width / 2, again.height / 2)
            tryCompare(card, "visible", true, 3000)
            findChild(canvas, "pageList").contentY += 200
            tryCompare(card, "visible", false)
        }
        function test_aLinkWithALostTargetPreviewsFromItsText() {
            canvas.openFile(lostLinkSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            // Qt drops a link whose named destination is gone; the text "[3]" still leads to its entry.
            const paper = findChild(canvas, "paperPage0"), card = findChild(canvas, "linkPreview")
            const y = (792 - 610 - 6) * canvas.pageScale
            for (let x = 200; x <= 240 && !card.visible; x += 8) { mouseMove(paper, x * canvas.pageScale, y); wait(500) }
            tryCompare(card, "visible", true, 5000)
            compare(canvas.linkPreview.label, "[3]")
            compare(canvas.linkPreview.page, 2)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function test_figureAndTablePreviewsShowTheFloatAndScroll() {
            canvas.openFile(referenceSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            const card = findChild(canvas, "linkPreview"), paper = findChild(canvas, "paperPage0")
            function rest(rect) {
                const at = Qt.point((rect.x + rect.width / 2) * canvas.pageScale, (rect.y + rect.height / 2) * canvas.pageScale)
                mouseMove(paper, at.x - 5, at.y); mouseMove(paper, at.x, at.y)
                tryCompare(card, "visible", true, 5000)
                const flick = findChild(card, "linkPreviewFlick")
                tryVerify(function() { return flick.contentHeight > flick.height })
                wait(50)
                return {flick: flick, target: findChild(card, "linkPreviewTarget").mapToItem(card, 0, 0).y}
            }
            // A figure's caption sits at the bottom of the card, with the figure above it.
            let shown = rest(referenceFigure)
            compare(canvas.linkPreview.kind, "figure")
            verify(shown.target > card.height * .55, "caption low in the card: " + shown.target + " / " + card.height)
            // The card scrolls on its own; the page behind it does not move.
            const before = shown.flick.contentY, pageY = findChild(canvas, "pageList").contentY
            shown.flick.flick(0, -1500)
            tryVerify(function() { return shown.flick.contentY !== before })
            compare(findChild(canvas, "pageList").contentY, pageY)
            mouseMove(canvas, 4, canvas.height - 4)
            tryCompare(card, "visible", false, 3000)
            // A table's caption sits at the top, with the table below it.
            shown = rest(referenceTable)
            compare(canvas.linkPreview.kind, "table")
            verify(shown.target < card.height * .25, "caption high in the card: " + shown.target)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function test_referencesWithoutLinksPreviewFromTheText() {
            canvas.openFile(referenceSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000); tryCompare(canvas, "restoring", false, 10000)
            const card = findChild(canvas, "linkPreview"), paper = findChild(canvas, "paperPage0")
            const at = Qt.point((referenceCitation.x + referenceCitation.width / 2) * canvas.pageScale,
                                (referenceCitation.y + referenceCitation.height / 2) * canvas.pageScale)
            // Resting on "[2]" shows its entry under References, outlined, without moving.
            mouseMove(paper, at.x - 6, at.y)
            mouseMove(paper, at.x, at.y)
            tryCompare(card, "visible", true, 5000)
            compare(findChild(card, "linkPreviewPage").currentFrame, 2)
            verify(findChild(card, "linkPreviewTarget").visible)
            compare(canvas.linkPreview.label, "[2]")
            compare(canvas.currentPage, 0)
            // Moving away along the text lets it go; clicking it goes there.
            mouseMove(paper, at.x + 200, at.y)
            tryCompare(card, "visible", false, 3000)
            mouseMove(paper, at.x - 6, at.y)
            mouseMove(paper, at.x, at.y)
            tryCompare(card, "visible", true, 5000)
            mouseClick(card, card.width / 2, card.height / 2)
            tryCompare(canvas, "currentPage", 2)
            canvas.openFile(fixtureSource, {page: 0, y: 0, x: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
        }
        function tryFindLink() {
            let link = null
            tryVerify(function() { link = findChild(canvas, "pdfLink-0-0"); return link !== null && link.width > 0 }, 5000)
            return link
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
        function test_verificationAndTextHoverAfterSourceSwitch() {
            const next = testInput.relinkFixture(true).candidate
            canvas.openFile(next, {page:0,zoom:1})
            tryCompare(canvas, "ready", true)
            tryCompare(canvas, "restoring", false)
            tryVerify(function() { return canvas.documentFingerprint.length === 64 })
            const paper = findChild(canvas, "paperPage0"), bounds = fixtureTextBounds
            const hover = findChild(canvas, "textHover0")
            mouseMove(paper, (bounds.x + 8) * canvas.pageScale, (bounds.y + bounds.height / 2) * canvas.pageScale)
            tryCompare(hover, "cursorShape", Qt.IBeamCursor)
            tryVerify(function() { return testInput.cursorShape(paper) === Qt.IBeamCursor })
            mouseMove(paper, paper.width - 8, 8)
            tryCompare(hover, "cursorShape", Qt.ArrowCursor)
            tryVerify(function() { return testInput.cursorShape(paper) === Qt.ArrowCursor })
            canvas.openFile(fixtureSource, {page:0,zoom:1})
            tryVerify(function() { return canvas.documentFingerprint.length === 64 })
        }
        function test_persistentHighlightSelectionAndRemoval() {
            const paper = findChild(canvas, "paperPage0")
            const bounds = fixtureTextBounds
            const from = paper.mapToItem(canvas, bounds.x * canvas.pageScale, (bounds.y + bounds.height / 2) * canvas.pageScale)
            testInput.pointerDrag(canvas, from, Qt.point(from.x + bounds.width * canvas.pageScale, from.y + 20 * canvas.pageScale), false)
            tryVerify(function() { return canvas.selectedText.indexOf("Research finding") >= 0 })
            const button = findChild(reader, "highlightSelectionButton")
            tryCompare(button, "visible", true); waitForPolish(reader)
            mouseClick(button)
            const colors = findChild(reader, "selectionColors")
            tryCompare(colors, "opened", true)
            waitForPolish(colors.contentItem)
            verify(colors.colorButton(1) !== null)
            mouseClick(colors.colorButton(1))
            tryVerify(function() { return canvas.savedHighlights.length === 1 }, 10000)
            compare(canvas.savedHighlights[0].color, "#e0b83f")
            tryCompare(canvas, "selectedText", "")
            const id = canvas.savedHighlights[0].id
            let mark = findChild(canvas, "savedHighlight-" + id)
            verify(mark !== null)
            const beforeWidth = mark.width
            canvas.zoom(1.2); tryCompare(canvas, "restoring", false)
            mark = findChild(canvas, "savedHighlight-" + id)
            verify(Math.abs(mark.width / beforeWidth - 1.2) < .02)
            canvas.openFile(""); canvas.openFile(fixtureSource, {page: 0, zoom: 1})
            tryCompare(canvas, "ready", true); tryCompare(canvas, "restoring", false)
            tryVerify(function() { return canvas.savedHighlights.length === 1 }, 10000)
            mark = findChild(canvas, "savedHighlight-" + id)
            verify(mark !== null)
            waitForPolish(reader)
            mouseClick(mark, mark.width / 2, mark.height / 2, Qt.RightButton)
            const menu = findChild(canvas, "highlightMenu")
            tryCompare(menu, "opened", true)
            const expectedPosition = canvas.markMenuPosition
            mouseClick(findChild(menu, "changeAnnotationColor"))
            const palette = findChild(canvas, "markColors")
            tryCompare(palette, "opened", true)
            verify(Math.abs(palette.x - expectedPosition.x) < 180)
            verify(Math.abs(palette.y - expectedPosition.y) < 60)
            mouseClick(palette.colorButton(4))
            tryVerify(function() { return canvas.savedHighlights.length > 0 && canvas.savedHighlights[0].color === "#9274c3" })
            mark = findChild(canvas, "savedHighlight-" + id)
            mouseClick(mark, mark.width / 2, mark.height / 2, Qt.RightButton)
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "removeHighlightAction"))
            tryCompare(canvas, "savedHighlights", [], 10000)
        }
        function test_toolbarSeparateInksAndMenus() {
            verify(findChild(reader, "aiToolbarButton") === null, "AI lives in the panel and selection menu, not the toolbar")
            waitForPolish(reader)
            verify(findChild(reader, "drawInk") === null && findChild(reader, "highlightInk") === null)
            mouseClick(findChild(reader, "drawTool"), 10, 10, Qt.RightButton)
            const colors = findChild(reader, "selectionColors")
            tryCompare(colors, "opened", true)
            waitForPolish(colors.contentItem)
            mouseClick(colors.colorButton(2))
            tryCompare(canvas, "tool", "draw")
            compare(canvas.drawColor, "#54a878")
            compare(researchStore.setting("drawColor"), "#54a878")
            verify(canvas.markColor !== canvas.drawColor, "Drawing color must not change the highlight color")
            // The highlight tool turns on in its own color with one click.
            const highlight = canvas.markColor
            mouseClick(findChild(reader, "highlightTool"))
            tryCompare(canvas, "tool", "highlight")
            compare(canvas.markColor, highlight)
            mouseClick(findChild(reader, "highlightTool"))
            tryCompare(canvas, "tool", "")
            // The page menu is about the spot: no print or export there (they are in ⋯).
            const page = findChild(canvas, "paperPage0")
            mouseClick(page, page.width * .8, 100, Qt.RightButton)
            const context = findChild(reader, "selectionContextMenu")
            tryCompare(context, "opened", true)
            for (let i = 0; i < context.count; ++i) {
                const entry = context.itemAt(i)
                verify(!entry.text || !/Print|Export|Paper Details|Mark Paper/.test(entry.text), entry.text)
            }
            context.close()
            tryCompare(context, "visible", false)
            // Menus grow to their longest label instead of cutting it.
            mouseClick(findChild(reader, "readerMoreButton"))
            const more = findChild(reader, "readerMoreMenu")
            tryCompare(more, "opened", true)
            verify(more.width > 200, "the longest label needs more than the default width")
            for (let i = 0; i < more.count; ++i) {
                const item = more.itemAt(i)
                if (item.visible && item.text) verify(item.implicitWidth <= item.width + 1, item.text + " is cut off")
            }
            more.close()
            tryCompare(more, "visible", false)
            researchStore.setSetting("drawColor", ""); researchStore.setSetting("highlightColor", "")
        }
        function test_marginNotesLinkToThePageAndUndo() {
            const unique = testInput.relinkFixture(true).candidate
            canvas.openFile(unique, {page:0,zoom:1})
            tryCompare(canvas,"ready",true); tryCompare(canvas,"restoring",false)
            tryVerify(function(){return canvas.documentFingerprint.length>0})
            reader.setMarginNotes(true)
            const margin = findChild(reader, "marginNotes")
            tryCompare(margin, "visible", true)
            verify(canvas.width < reader.width - 200, "the page makes room for the notes")
            // A note on a selection is written beside the page.
            const paper=findChild(canvas,"paperPage0"),bounds=fixtureTextBounds
            const from=paper.mapToItem(canvas,bounds.x*canvas.pageScale,(bounds.y+bounds.height/2)*canvas.pageScale)
            testInput.pointerDrag(canvas,from,Qt.point(from.x+bounds.width*canvas.pageScale*.6,from.y),false)
            tryVerify(function(){return canvas.selectedText.length>0})
            reader.addComment()
            verify(margin.draft !== null)
            tryVerify(function() { const e = findChild(margin, "marginNoteEditor"); return e && e.activeFocus })
            const editor = findChild(margin, "marginNoteEditor")
            editor.text = "Why does this hold?"
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            tryVerify(function() { return margin.notes.length === 1 }, 10000)
            const note = margin.notes[0]
            compare(note.body, "Why does this hold?")
            verify(note.text.length > 0, "linked to the selected text")
            // Hovering the note outlines its place on the page.
            tryVerify(function() { return findChild(margin, "marginNote-" + note.id) !== null })
            const card = findChild(margin, "marginNote-" + note.id)
            waitForPolish(margin); wait(50)
            mouseMove(card, card.width / 2, card.height / 2)
            tryCompare(canvas, "focusedMark", note.id)
            // The page's comment marker opens the note in the margin, not a dialog.
            const marker = findChild(canvas, "commentMarker-" + note.id + "-0")
            mouseClick(marker)
            compare(margin.editingId, note.id)
            verify(!findChild(reader, "annotationEditor").visible)
            margin.editingId = ""
            // Cmd+Z removes the note, Cmd+Shift+Z brings it back.
            canvas.forceActiveFocus()
            keyClick(Qt.Key_Z, Qt.ControlModifier)
            tryVerify(function() { return margin.notes.length === 0 }, 10000)
            keyClick(Qt.Key_Z, Qt.ControlModifier | Qt.ShiftModifier)
            tryVerify(function() { return margin.notes.length === 1 }, 10000)
            // A drawing is undone the same way.
            reader.setTool("draw"); waitForPolish(reader)
            const area = findChild(canvas, "annotationArea0")
            const start = area.mapToItem(canvas, area.width * .6, area.height * .5)
            testInput.pointerDrag(canvas, start, Qt.point(start.x + 50, start.y + 20), false)
            tryVerify(function() { return canvas.savedHighlights.some(function(m) { return m.kind === "draw" }) }, 10000)
            canvas.tool = ""; canvas.forceActiveFocus()
            keyClick(Qt.Key_Z, Qt.ControlModifier)
            tryVerify(function() { return !canvas.savedHighlights.some(function(m) { return m.kind === "draw" }) }, 10000)
            // Pen comes first among the tools.
            const tools = findChild(reader, "annotationTools")
            compare(tools.children[0].objectName, "drawTool")
            compare(tools.children[1].objectName, "highlightTool")
            reader.setMarginNotes(false)
            for (const m of canvas.savedHighlights) researchStore.removeHighlight(m.id)
        }
        function test_selectionToolbarCommentsAndPageAnnotations() {
            const unique = testInput.relinkFixture(true).candidate
            canvas.openFile(unique, {page:0,zoom:1})
            tryCompare(canvas,"ready",true);tryCompare(canvas,"restoring",false)
            tryVerify(function(){return canvas.documentFingerprint.length>0})
            const paper=findChild(canvas,"paperPage0"),bounds=fixtureTextBounds
            const from=paper.mapToItem(canvas,bounds.x*canvas.pageScale,(bounds.y+bounds.height/2)*canvas.pageScale)
            testInput.pointerDrag(canvas,from,Qt.point(from.x+bounds.width*canvas.pageScale,from.y),false)
            tryVerify(function(){return canvas.selectedText.length>0})
            const toolbar=findChild(reader,"selectionToolbar")
            tryCompare(toolbar,"visible",true)
            verify(Math.abs(toolbar.y-canvas.selectionEnd.y)<60)
            verify(toolbar.x>=0 && toolbar.x+toolbar.width<=canvas.width)
            const quote=canvas.selectedText
            mouseClick(paper,paper.width*.8,100,Qt.RightButton)
            const context=findChild(reader,"selectionContextMenu")
            tryCompare(context,"opened",true)
            const copy=findChild(context,"selectionCopy")
            verify(copy.enabled);mouseClick(copy)
            compare(testInput.clipboardText(),quote)
            tryCompare(context,"visible",false)
            mouseClick(findChild(reader,"commentSelectionButton"))
            const editor=findChild(reader,"annotationEditor")
            tryCompare(editor,"opened",true)
            findChild(editor,"annotationBody").text="Question about this result"
            mouseClick(findChild(editor,"saveAnnotation"))
            tryCompare(editor,"visible",false)
            tryVerify(function(){return canvas.savedHighlights.length===1})
            compare(canvas.savedHighlights[0].kind,"comment")
            compare(canvas.savedHighlights[0].text,quote)
            const id=canvas.savedHighlights[0].id
            const marker=findChild(canvas,"commentMarker-"+id+"-0")
            verify(marker!==null);mouseClick(marker)
            tryCompare(editor,"opened",true)
            compare(findChild(editor,"annotationBody").text,"Question about this result")
            editor.close()
            reader.setTool("text");waitForPolish(reader)
            const area=findChild(canvas,"annotationArea0")
            mouseClick(area,area.width*.2,area.height*.4)
            tryCompare(editor,"opened",true)
            findChild(editor,"annotationBody").text="Visible text box"
            mouseClick(findChild(editor,"saveAnnotation"))
            tryCompare(editor,"visible",false)
            tryVerify(function(){return canvas.savedHighlights.some(function(m){return m.kind==="text"})})
            reader.setTool("draw");waitForPolish(reader)
            const start=area.mapToItem(canvas,area.width*.6,area.height*.5)
            testInput.pointerDrag(canvas,start,Qt.point(start.x+60,start.y+30),false)
            tryVerify(function(){return canvas.savedHighlights.some(function(m){return m.kind==="draw"})})
            const drawn=canvas.savedHighlights.filter(function(m){return m.kind==="draw"})[0]
            const stroke=findChild(canvas,"savedStroke-"+drawn.id)
            tryVerify(function(){return stroke!==null&&stroke.visible})
            waitForRendering(stroke)
            // Round caps sit outside the stored centre-line box and must still be painted.
            const ink=grabImage(stroke); let outside=0
            for(let y=0;y<ink.height;++y)for(let x=0;x<Math.floor(stroke.pad);++x)if(ink.alpha(x,y)>0)++outside
            verify(outside>0,"Stroke caps must not be clipped at the stored box edge")
            // Empty space inside the box is not part of the drawing; only the ink opens its menu.
            const menu=findChild(canvas,"highlightMenu")
            const empty={x:stroke.mapX({x:drawn.rectangles[0].x+drawn.rectangles[0].width}),y:stroke.mapY({y:drawn.rectangles[0].y})}
            mouseClick(stroke,empty.x-2,empty.y+2,Qt.RightButton)
            verify(!menu.visible)
            const middle=stroke.points[Math.floor(stroke.points.length/2)]
            mouseClick(stroke,stroke.mapX(middle),stroke.mapY(middle),Qt.RightButton)
            tryCompare(menu,"visible",true)
            menu.close()
            canvas.tool=""
            editor.begin(canvas, {kind:"image",page:0,imageSource:fixtureImage.toString(),rectangles:[{x:.2,y:.4,width:.3,height:.2}]}, null)
            tryCompare(editor, "opened", true)
            tryCompare(findChild(editor,"annotationImagePreview"), "status", Image.Ready, 10000)
            mouseClick(findChild(editor,"saveAnnotation"))
            tryCompare(editor,"visible",false)
            tryVerify(function(){return canvas.savedHighlights.some(function(m){return m.kind==="image"})})
            for(const m of canvas.savedHighlights)verify(researchStore.removeHighlight(m.id))
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
        function test_unmodifiedWheelScrolls_data() {
            return [{tag: "reading", capture: false}, {tag: "capture_mode", capture: true}]
        }
        function test_unmodifiedWheelScrolls(data) {
            canvas.captureMode = data.capture
            canvas.jump(1, .25, 0)
            tryCompare(canvas, "restoring", false)
            const list = findChild(canvas, "pageList")
            const y = list.contentY
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, -120, Qt.NoButton, Qt.NoModifier)
            tryVerify(function() { return Math.abs(list.contentY - y) > 1 })
            compare(canvas.zoomFactor, 1)
            wait(200)
            const down = list.contentY
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, 120, Qt.NoButton, Qt.NoModifier)
            tryVerify(function() { return list.contentY < down - 1 })
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
            verify(canvas.sourceScrollDuration >= 700 && canvas.sourceScrollDuration <= 1500)
            verify((middle - start) / (canvas.targetScrollY - start) < .15, "Navigation must ease in rather than jump at the start")
            tryCompare(canvas, "restoring", false)
            compare(canvas.currentPage, 3)
            tryVerify(function() { return canvas.spotlightOpacity > .95 })
            const border = findChild(canvas, "captureSourceBorder3")
            verify(border !== null)
            verify(Qt.colorEqual(border.border.color, Theme.captureBorder))
            compare(border.radius, Theme.radius)
            compare(border.children.length, 0, "Source spotlight must have no translucent outer border")
            tryVerify(function() { return canvas.spotlightOpacity > 0 && canvas.spotlightOpacity < .9 }, 2000)
            tryCompare(canvas, "spotlightOpacity", 0, 3000)
            canvas.openFile(fixtureSource)
            compare(canvas.highlight, null)
        }
        function test_wheelInterruptsCaptureMotion() {
            canvas.showSource(5, Qt.rect(.1, .4, .3, .1))
            wait(150)
            verify(canvas.restoring)
            mouseWheel(canvas, canvas.width / 2, canvas.height / 2, 0, -120, Qt.NoButton, Qt.NoModifier)
            tryCompare(canvas, "restoring", false, 500)
            const list = findChild(canvas, "pageList")
            wait(canvas.sourceScrollDuration)
            verify(Math.abs(list.contentY - canvas.targetScrollY) > 100, "User scrolling must cancel navigation")
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
