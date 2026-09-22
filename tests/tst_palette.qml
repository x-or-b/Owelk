import QtQuick
import QtTest
import "../qml" as App
import "../qml/PaletteMatch.js" as Match

Item {
    id: scene
    width: 800; height: 700
    App.CommandPalette { id: palette; hasDocument: true }
    App.SearchPalette { id: search }
    SignalSpy { id: chosen; target: search; signalName: "resultChosen" }
    SignalSpy { id: command; target: palette; signalName: "commandChosen" }
    Component { id: resultComponent; App.SearchResultDelegate { width: 540; y: 400 } }
    TestCase {
        name: "CommandPalette"
        when: windowShown
        function init() {
            chosen.clear(); command.clear(); palette.hasDocument = true; palette.hasSelection = false
            palette.open(); tryCompare(palette, "opened", true)
        }
        function cleanup() { palette.close(); search.close(); tryCompare(palette, "visible", false) }
        function test_commandNamesAndPartialMatch() {
            const query = findChild(palette, "paletteQuery")
            query.text = "plicate right"
            compare(palette.results.length, 1)
            compare(palette.results[0].title, "Split: Duplicate Tab Right")
            keyClick(Qt.Key_Return)
            tryCompare(command, "count", 1)
            compare(command.signalArguments[0][0], "/split right")
        }
        function test_highlightSafeAndOverlapping() {
            compare(Match.highlight("sample command", "comma"), 'sample <font color="#426b9a"><b>comma</b></font>nd')
            verify(Match.matches("Split: Duplicate Tab Right", "RIGHT dup"))
            verify(!Match.matches("Split: Duplicate Tab Right", "left"))
            verify(Match.highlight("<b>& command", "<b>").indexOf("&lt;b&gt;") >= 0)
            compare(Match.highlight("<b>& command", "<b>"), '<font color="#426b9a"><b>&lt;b&gt;</b></font>&amp; command')
            compare((Match.highlight("command command", "comma").match(/<font/g) || []).length, 2)
            compare((Match.highlight("command", "com comma").match(/<font/g) || []).length, 1)
        }
        function test_recentPaperAndSearchHeadingStyles() {
            const result = createTemporaryObject(resultComponent, scene, {modelData: {kind: "paper", title: "Paper.pdf"}, queryText: ""})
            compare(result.heading, false)
            compare(findChild(result, "resultTitle").color.toString(), "#333333")
            result.queryText = "Paper"
            compare(result.heading, true)
            compare(result.background.color.toString(), "#767676")
            compare(findChild(result, "resultTitle").color.toString(), "#ffffff")
        }
        function test_selectionHasNoAccentRail() {
            const result = createTemporaryObject(resultComponent, scene, {
                modelData: {kind: "paper", title: "Paper.pdf"}, queryText: "", highlighted: true
            })
            compare(result.background.color.toString(), "#e9e9e9")
            compare(result.background.children.length, 0)
        }
        function bluePixels(item) {
            waitForRendering(scene, 100)
            wait(100)
            const pixels = grabImage(scene)
            const origin = item.mapToItem(scene, 0, 0)
            let count = 0
            for (let y = Math.max(0, Math.floor(origin.y)); y < Math.min(pixels.height, origin.y + item.height); ++y)
                for (let x = Math.max(0, Math.floor(origin.x)); x < Math.min(pixels.width, origin.x + item.width); ++x)
                    if (pixels.blue(x, y) > pixels.red(x, y) + 35 && pixels.alpha(x, y) > 100) ++count
            return count
        }
        function test_commandHighlightIsActuallyPainted() {
            findChild(palette, "paletteQuery").text = "capture"
            const list = findChild(palette, "paletteResults")
            tryVerify(function() { return list.itemAtIndex(0) !== null })
            const title = list.itemAtIndex(0).contentItem
            verify(bluePixels(title) > 15, "Matching command characters must be painted blue, not just contain markup")
        }
        function test_resultTitleAndSnippetArePainted_data() {
            return [{tag: "paper", kind: "paper"}, {tag: "text", kind: "text"},
                    {tag: "capture", kind: "capture"}, {tag: "workspace", kind: "workspace"}]
        }
        function test_resultTitleAndSnippetArePainted(data) {
            palette.close(); tryCompare(palette, "visible", false)
            const result = createTemporaryObject(resultComponent, scene, {
                modelData: {kind: data.kind, title: "occlusion <paper>.pdf", snippet: "The occlusion observation", page: 0},
                queryText: "occlu", highlighted: true
            })
            verify(result !== null)
            verify(bluePixels(findChild(result, "resultTitle")) > 15)
            verify(bluePixels(findChild(result, "resultSnippet")) > 15)
        }
        function test_disabledCommandsDoNotRun() {
            palette.hasDocument = false
            findChild(palette, "paletteQuery").text = "duplicate right"
            compare(palette.results.length, 1)
            compare(palette.results[0].enabled, false)
            keyClick(Qt.Key_Return); compare(command.count, 0); compare(palette.visible, true)
        }
        function test_excerptRequiresSelection() {
            findChild(palette, "paletteQuery").text = "save selected"
            compare(palette.results.length, 1)
            compare(palette.results[0].enabled, false)
            palette.hasSelection = true
            compare(palette.results[0].enabled, true)
            keyClick(Qt.Key_Return)
            tryCompare(command, "count", 1)
            compare(command.signalArguments[0][0], "/capture text")
        }
        function test_searchContainsNoCommands() {
            palette.close()
            researchStore.rememberDocument(fixtureSource)
            search.open(); tryCompare(search, "opened", true)
            const query = findChild(search, "searchPaletteQuery")
            query.text = "/split right"
            tryVerify(function() { return search.results.length === 0 })
            query.text = "fixture"
            tryVerify(function() { return search.results.length >= 1 })
            verify(search.results.every(function(r) { return r.kind !== "command" }))
            keyClick(Qt.Key_Return)
            tryCompare(chosen, "count", 1)
            compare(chosen.signalArguments[0][0].kind, "paper")
        }
        function test_noMatchAndEscape() {
            const query = findChild(palette, "paletteQuery")
            query.text = "unknown command xyz"
            compare(palette.results.length, 0)
            keyClick(Qt.Key_Return); compare(command.count, 0)
            keyClick(Qt.Key_Escape); tryCompare(palette, "visible", false)
        }
    }
}
