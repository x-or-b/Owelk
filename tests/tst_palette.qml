import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 800
    height: 700
    App.CommandPalette {
        id: palette
        recentDocuments: [
            {name: "Paper Alpha.pdf", url: "file:///tmp/Alpha.pdf"},
            {name: "Paper Beta.pdf", url: "file:///tmp/Beta.pdf"}
        ]
    }
    SignalSpy { id: chosen; target: palette; signalName: "documentChosen" }
    SignalSpy { id: command; target: palette; signalName: "commandChosen" }
    TestCase {
        name: "CommandPalette"
        when: windowShown
        function init() {
            chosen.clear()
            command.clear()
            palette.open()
            tryCompare(palette, "opened", true)
        }
        function cleanup() { palette.close(); tryCompare(palette, "visible", false) }
        function test_filterAndOpen() {
            const query = findChild(palette, "paletteQuery")
            query.text = "bEtA"
            compare(palette.results.length, 1)
            keyClick(Qt.Key_Return)
            tryCompare(chosen, "count", 1)
            compare(chosen.signalArguments[0][0].toString(), "file:///tmp/Beta.pdf")
        }
        function test_commandsAndArguments() {
            const query = findChild(palette, "paletteQuery")
            query.text = "/split"
            compare(palette.results.length, 3)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(command, "count", 1)
            compare(command.signalArguments[0][0], "/split off")
            palette.open()
            tryCompare(palette, "opened", true)
            query.text = "/open paper beta"
            compare(palette.results.length, 1)
            compare(palette.results[0].title, "Paper Beta.pdf")
        }
        function test_completeAndCancel() {
            const query = findChild(palette, "paletteQuery")
            query.text = "/op"
            keyClick(Qt.Key_Tab)
            compare(query.text, "/open paper ")
            compare(palette.results.length, 2)
            keyClick(Qt.Key_Escape)
            tryCompare(palette, "visible", false)
            compare(command.count, 0)
            compare(chosen.count, 0)
        }
        function test_noResults() {
            const query = findChild(palette, "paletteQuery")
            query.text = "unmatched"
            compare(palette.results.length, 0)
            keyClick(Qt.Key_Return)
            compare(chosen.count, 0)
            compare(palette.visible, true)
        }
        function test_captureListTypoAlias() {
            const query = findChild(palette, "paletteQuery")
            query.text = "/caputres"
            compare(palette.results.length, 1)
            compare(palette.results[0].command, "/captures")
            verify(palette.results[0].description.length > 0)
            keyClick(Qt.Key_Return)
            tryCompare(command, "count", 1)
            compare(command.signalArguments[0][0], "/captures")
        }
    }
}
