import QtQuick
import QtQuick.Controls
import QtTest
import "../qml" as App

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    SignalSpy { id: saved; target: researchStore; signalName: "captureSaved" }
    TestCase {
        name: "TextCaptures"
        when: windowShown
        function cleanupTestCase() { workspace.visible = false }
        function test_excerptWorkflow() {
            workspace.documents.restore({}); workspace.homeVisible = true
            workspace.openDocument(fixtureSource, {page: 0, zoom: 1})
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader, "pdfCanvas0")
            tryCompare(c, "ready", true); tryCompare(c, "restoring", false)
            wait(150)
            const paper = findChild(c, "paperPage0")
            const bounds = fixtureTextBounds
            const from = paper.mapToItem(c, bounds.x * c.pageScale, (bounds.y + bounds.height / 2) * c.pageScale)
            testInput.pointerDrag(c, from, Qt.point(from.x + bounds.width * c.pageScale, from.y + 40 * c.pageScale), false)
            tryVerify(function() { return c.selectedText.indexOf("Research finding") >= 0 })
            const text = c.selectedText
            const palette = findChild(workspace, "commandPalette")
            palette.open(); tryCompare(palette, "opened", true)
            const query = findChild(palette, "paletteQuery")
            query.text = "save selected"
            compare(palette.results.length, 1)
            verify(palette.results[0].enabled)
            testInput.keyClick(query, Qt.Key_Return)
            tryCompare(saved, "count", 1, 10000)
            const id = saved.signalArguments[0][0]
            const capture = researchStore.captures.find(function(row) { return row.id === id })
            compare(capture.text, text)
            const shelf = findChild(workspace, "captureShelf")
            tryCompare(shelf, "visible", true)
            // Opening the dock changes reader width; a held selection must remain the same text.
            tryCompare(c, "restoring", false)
            compare(c.selectedText, text)
            const card = findChild(shelf, "captureCard-" + id)
            verify(card !== null)
            const preview = findChild(card, "excerptPreview")
            compare(preview.text, text); compare(preview.textFormat, Text.PlainText)
            verify(card.height > 60 && card.height < 260)
            mouseClick(findChild(card, "captureActions-" + id))
            tryCompare(findChild(card, "captureMenu-" + id), "opened", true)
            const read = findChild(card, "readExcerpt-" + id)
            tryCompare(read, "visible", true)
            verify(read.width > 0 && read.height > 0)
            waitForRendering(read)
            mouseClick(read, read.width / 2, read.height / 2)
            compare(shelf.viewingCapture.id, id)
            const dialog = findChild(shelf, "excerptDialog")
            tryCompare(dialog, "opened", true)
            const full = findChild(dialog, "excerptText")
            compare(full.text, text.replace(/\r\n/g, "\n")); compare(full.readOnly, true)
            mouseClick(findChild(dialog, "copyExcerptButton"))
            compare(testInput.clipboardText(), text)
            dialog.close(); tryCompare(dialog, "visible", false)
            c.jump(4, 0, 0); tryCompare(c, "restoring", false)
            mouseClick(card)
            tryCompare(c, "currentPage", 0)
            verify(c.highlight !== null)
            const search = findChild(workspace, "searchPalette")
            search.open(); tryCompare(search, "opened", true)
            findChild(search, "searchPaletteQuery").text = "occlusion"
            tryVerify(function() { return search.results.some(function(r) { return r.id === id && r.snippet.length > 0 }) })
            search.close()
            shelf.requestDelete(id)
            const deletion = findChild(shelf, "deleteCaptureDialog")
            tryCompare(deletion, "opened", true)
            deletion.accept()
            tryVerify(function() { return !researchStore.captures.some(function(r) { return r.id === id }) })
            verify(!researchStore.searchKnowledge("occlusion").some(function(r) { return r.id === id }))
            // Excerpts are literal evidence, never interpreted as rich text.
            shelf.viewText({name: "<b>paper</b>.pdf", page: 0, text: "<b>literal quote & symbols</b>"})
            tryCompare(dialog, "opened", true)
            compare(full.textFormat, TextEdit.PlainText)
            compare(full.text, "<b>literal quote & symbols</b>")
            dialog.close()
        }
    }
}
