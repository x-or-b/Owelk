import QtQuick
import QtTest
import Owelk.Ui
import OwelkStyle

Item {
    width: 10; height: 10
    Icon { id: probe }
    TestCase {
        name: "Icons"
        property int found: 0
        when: windowShown
        // Every visible icon button says what it does on hover, and every icon name exists.
        function check(item, problems) {
            if (!item || !item.visible) return
            if (item.description !== undefined && item.icon !== undefined && item.swatch !== undefined) {
                ++found
                if (!item.description.length) problems.push("no description: " + (item.objectName || item.icon.name))
                probe.name = item.icon.name
                if (!probe.text.length) problems.push("unknown icon: " + item.icon.name)
            }
            for (let i = 0; i < item.children.length; ++i) check(item.children[i], problems)
        }
        function test_iconButtonsDescribeThemselves() {
            const c = Qt.createComponent("../qml/Main.qml")
            verify(c.status === Component.Ready, c.errorString())
            const win = c.createObject(null, {width: 1280, height: 800})
            tryCompare(win, "initialized", true, 10000)
            verify(Theme.iconFont.length > 0, "the icon font is loaded")
            const problems = []
            check(win.contentItem.parent, problems)
            win.documents.openDocument(fixtureSource)
            tryVerify(function() { return win.currentReader && win.currentReader.pdfReady }, 10000)
            // The AI panel (in its own dock) and the Document panel.
            win.aiVisible = true; win.documentVisible = true; win.aiSide = "left"
            wait(300)
            check(win.contentItem.parent, problems)
            findChild(win, "leftDock").activePanel = "ai"
            wait(300)
            check(win.contentItem.parent, problems)
            compare(problems.join("; "), "")
            verify(found > 15, "checked " + found + " icon buttons")
            win.close(); win.destroy()
        }
    }
}
