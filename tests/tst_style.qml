import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui

Item {
    id: scene
    width: 800; height: 600
    Button { id: button; text: "Save" }
    ToolButton { id: toolButton; y: 50; text: "Filters" }
    TextField { id: field; y: 90; text: "Query" }
    TextArea { id: area; y: 140; text: "Note" }
    ComboBox { id: combo; y: 190; model: ["Everything", "Captures"] }
    Menu { id: menu; MenuItem { text: "Delete" } MenuItem { objectName: "longItem"; text: "Export Highlights and Captures as Markdown…" } }
    Dialog { id: dialog; title: "Rounded dialog"; standardButtons: Dialog.Ok | Dialog.Cancel }
    ItemDelegate { id: row; y: 240; width: 200; text: "Paper" }
    Label { id: cut; y: 290; width: 60; text: "A long paper title that cannot fit"; elide: Text.ElideRight }
    SignalSpy { id: accepted; target: dialog; signalName: "accepted" }
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
        function test_menuFitsItsLongestItem() {
            menu.popup(0, 0)
            tryCompare(menu, "opened", true)
            const item = menu.itemAt(1)
            verify(item.implicitWidth <= item.width + 1)
            menu.close()
            tryCompare(menu, "visible", false)
        }
        function test_annotationInksMatchStoreValidation() {
            // UI swatches and C++ validation must accept exactly the same inks, in the same order.
            compare(Theme.annotationInks.map(function(ink) { return ink.value }), researchStore.annotationColors)
            compare(Theme.defaultInk, researchStore.annotationColors[0])
        }
    }
}
