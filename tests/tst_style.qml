import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui

Item {
    id: scene
    width: 800; height: 600
    Button { id: button; text: "Save" }
    ToolTip { id: tip }
    ToolButton { id: toolButton; y: 50; text: "Filters" }
    TextField { id: field; y: 90; text: "Query" }
    TextArea { id: area; y: 140; text: "Note" }
    ComboBox { id: combo; y: 190; model: ["Everything", "Notes"] }
    Menu { id: menu; MenuItem { text: "Delete" } MenuItem { objectName: "longItem"; text: "Export Annotations as Markdown…" } }
    Dialog { id: dialog; title: "Rounded dialog"; standardButtons: Dialog.Ok | Dialog.Cancel }
    ItemDelegate { id: row; y: 240; width: 200; text: "Paper" }
    Label { id: cut; y: 290; width: 60; text: "A long paper title that cannot fit"; elide: Text.ElideRight }
    SignalSpy { id: accepted; target: dialog; signalName: "accepted" }
    // An input with its own key handler (like the AI question box) still gets line delete.
    TextArea { id: composer; y: 330; width: 300; property int returns: 0; Keys.onPressed: function(event) { if (event.key === Qt.Key_Return) { ++returns; event.accepted = true } } }
    TextField { id: single; y: 400; width: 300 }
    TestCase {
        name: "OwelkStyle"
        when: windowShown
        function test_shapes() {
            for (const control of [button, field, area, combo]) compare(control.background.radius, Theme.radius)
            compare(toolButton.background.radius, Theme.radiusSmall)
            compare(row.background.radius, Theme.radiusSmall)
            compare(menu.background.radius, Theme.radiusLarge)
            compare(combo.popup.background.radius, Theme.radiusLarge)
            compare(dialog.background.radius, Theme.radiusLarge)
            compare(button.height, Theme.controlHeight)
        }
        function test_oneHoverAndOneSelection() {
            mouseMove(scene, 700, 500)
            mouseMove(toolButton, 5, 5)
            tryCompare(toolButton, "hovered", true)
            verify(Qt.colorEqual(toolButton.background.color, Theme.hover))
            mouseMove(row, 5, 5)
            tryCompare(row, "hovered", true)
            verify(Qt.colorEqual(row.background.color, Theme.hover))
            row.highlighted = true
            verify(Qt.colorEqual(row.background.color, Theme.selected))
            row.highlighted = false
            mouseMove(button, 5, 5)
            tryCompare(button, "hovered", true)
            verify(Qt.colorEqual(button.background.children[0].color, Theme.hover))
        }
        function test_dialogAcceptIsPrimary() {
            dialog.open(); tryCompare(dialog, "opened", true)
            const ok = dialog.standardButton(Dialog.Ok)
            verify(ok.accented)
            verify(!dialog.standardButton(Dialog.Cancel).accented)
            verify(Qt.colorEqual(ok.background.color, Theme.accent))
            mouseClick(ok)
            compare(accepted.count, 1)
            tryCompare(dialog, "visible", false)
        }
        function test_cutTextShowsInFullOnHover() {
            verify(cut.truncated)
            mouseMove(cut, 10, 5)
            tryCompare(cut.ToolTip, "visible", true, 2000)
            compare(cut.ToolTip.text, cut.text)
            mouseMove(scene, 700, 500)
        }
        function test_tooltipSetsTheShortcutApart() {
            tip.text = "New tab · ⌘T"
            compare(tip.keyed[1], "New tab"); compare(tip.keyed[2], "⌘T")
            compare(tip.contentItem.textFormat, Text.StyledText)
            tip.text = "Close search · Esc"
            compare(tip.keyed[2], "Esc")
            tip.text = "Draw"
            compare(tip.keyed, null)
            compare(tip.contentItem.textFormat, Text.PlainText)
            tip.text = "Ask · answers cite the pages"
            compare(tip.keyed, null)
        }
        function test_menuFitsItsLongestItem() {
            menu.popup(0, 0)
            tryCompare(menu, "opened", true)
            const item = menu.itemAt(1)
            verify(item.implicitWidth <= item.width + 1)
            menu.close()
            tryCompare(menu, "visible", false)
        }
        function test_deleteToLineStart() {
            const mods = Qt.platform.os === "osx" ? Qt.ControlModifier : Qt.ControlModifier | Qt.ShiftModifier
            composer.text = "first line\nsecond line"
            composer.forceActiveFocus(); composer.cursorPosition = composer.length
            keyClick(Qt.Key_Backspace, mods)
            compare(composer.text, "first line\n")
            keyClick(Qt.Key_Backspace, mods) // at a line start it joins with the line above
            compare(composer.text, "first line")
            keyClick(Qt.Key_Return)
            compare(composer.returns, 1, "the box's own keys still work")
            single.text = "a search query"
            single.forceActiveFocus(); single.cursorPosition = 2
            keyClick(Qt.Key_Delete, mods)
            compare(single.text, "a ")
            keyClick(Qt.Key_Backspace, mods)
            compare(single.text, "")
        }
        function test_rightClickTextMenuOffersOnlyWhatWorks() {
            single.text = "alpha beta"
            mouseClick(single, single.width - 20, single.height / 2, Qt.RightButton)
            let menu = null
            tryVerify(function() { menu = findChild(single, "textMenuCopy"); return menu !== null && menu.visible })
            verify(!findChild(single, "textMenuCut").enabled) // Nothing selected.
            verify(findChild(single, "textMenuSelectAll").enabled)
            findChild(single, "textMenuSelectAll").triggered()
            keyClick(Qt.Key_Escape)
            compare(single.selectedText, "alpha beta")
            // The selection survives the menu, so Cut works on it.
            mouseClick(single, 20, single.height / 2, Qt.RightButton)
            tryVerify(function() { return findChild(single, "textMenuCut").enabled })
            findChild(single, "textMenuCut").triggered()
            compare(single.text, "")
            keyClick(Qt.Key_Escape)
            single.readOnly = true
            mouseClick(single, 20, single.height / 2, Qt.RightButton)
            tryVerify(function() { return findChild(single, "textMenuPaste") !== null })
            verify(!findChild(single, "textMenuPaste").enabled)
            keyClick(Qt.Key_Escape)
            single.readOnly = false
        }
        function test_annotationInksMatchStoreValidation() {
            // UI swatches and C++ validation must accept exactly the same inks, in the same order.
            compare(Theme.annotationInks.map(function(ink) { return ink.value }), researchStore.annotationColors)
            compare(Theme.defaultInk, researchStore.annotationColors[0])
        }
    }
}
