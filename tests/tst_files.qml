import QtQuick
import QtTest
import "../qml" as App

Item {
    width: 260
    height: 720
    App.FilePanel { id: panel; anchors.fill: parent; folder: fixtureFolder }
    SignalSpy { id: opened; target: panel; signalName: "documentChosen" }
    TestCase {
        name: "FilePanel"
        when: windowShown
        function init() {
            opened.clear()
            panel.refresh()
            tryCompare(findChild(panel, "folderTree"), "count", 2)
        }
        function test_expandOpenCollapse() {
            const tree = findChild(panel, "folderTree")
            panel.toggle(0)
            tryCompare(tree, "count", 3)
            panel.toggle(1)
            compare(opened.count, 1)
            verify(opened.signalArguments[0][0].toString().endsWith("/Group/inside.pdf"))
            panel.toggle(0)
            compare(tree.count, 2)
        }
        function test_fastToggleDoesNotDuplicateRows() {
            const tree = findChild(panel, "folderTree")
            panel.toggle(0)
            panel.toggle(0)
            panel.toggle(0)
            tryCompare(tree, "count", 3)
            wait(100)
            compare(tree.count, 3)
        }
    }
}
