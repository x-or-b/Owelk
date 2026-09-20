import QtQuick
import QtTest
import "../qml" as App
import "../qml/PaletteMatch.js" as Match

Item {
    width: 800; height: 700
    App.CommandPalette { id: palette; hasDocument: true }
    App.SearchPalette { id: search }
    SignalSpy { id: chosen; target: search; signalName: "resultChosen" }
    SignalSpy { id: command; target: palette; signalName: "commandChosen" }
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
            compare(Match.highlight("sample command", "comma"), 'sample <span style="color:#426b9a;font-weight:600">comma</span>nd')
            verify(Match.matches("Split: Duplicate Tab Right", "RIGHT dup"))
            verify(!Match.matches("Split: Duplicate Tab Right", "left"))
            verify(Match.highlight("<b>& command", "<b>").indexOf("&lt;b&gt;") >= 0)
            verify(Match.highlight("<b>& command", "<b>").indexOf("<b>") < 0)
            compare((Match.highlight("command command", "comma").match(/<span/g) || []).length, 2)
            compare((Match.highlight("command", "com comma").match(/<span/g) || []).length, 1)
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
