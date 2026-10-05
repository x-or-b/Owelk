import QtQuick
import QtQuick.Controls
import QtTest
import "../qml" as App
import Owelk.Ui

Item {
    id: scene
    width: 800; height: 600
    App.UiControls.Button { id: button; text: "Save" }
    App.UiControls.ToolButton { id: toolButton; y: 50; text: "Filters" }
    App.UiControls.TextField { id: field; y: 90; text: "Query" }
    App.UiControls.TextArea { id: area; y: 140; text: "Note" }
    App.UiControls.ComboBox { id: combo; y: 190; model: ["Everything", "Captures"] }
    App.UiControls.Menu { id: menu; App.UiControls.MenuItem { text: "Delete" } }
    App.UiControls.Dialog { id: dialog; title: "Rounded dialog"; standardButtons: Dialog.Ok | Dialog.Cancel }
    App.UiControls.ItemDelegate { id: row; y: 240; text: "Paper"; background: Rectangle { color: "#767676" } }
    SignalSpy { id: accepted; target: dialog; signalName: "accepted" }
    TestCase {
        name: "RoundedStyle"
        when: windowShown
        function test_sharedRadiusAndDialogButtons() {
            for (const control of [button, toolButton, field, area, combo, row, menu, dialog])
                compare(control.background.radius, Theme.radius)
            compare(combo.popup.background.radius, Theme.radius)
            dialog.open(); tryCompare(dialog, "opened", true)
            compare(dialog.header.background.radius, Theme.radius)
            const ok = dialog.standardButton(Dialog.Ok)
            compare(ok.background.radius, Theme.radius)
            mouseClick(ok)
            compare(accepted.count, 1)
            tryCompare(dialog, "visible", false)
        }
        function test_annotationInksMatchStoreValidation() {
            // UI swatches and C++ validation must accept exactly the same inks, in the same order.
            compare(Theme.annotationInks.map(function(ink) { return ink.value }), researchStore.annotationColors)
            compare(Theme.defaultInk, researchStore.annotationColors[0])
        }
    }
}
