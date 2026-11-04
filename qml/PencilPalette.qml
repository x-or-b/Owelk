import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// The Pencil's tools in one place, where the Pencil is (a squeeze of a Pencil Pro brings it): select, highlight,
// draw, erase, a text box or a comment, and the colours of the ink in use. A choice puts it away.
Popup {
    id: root
    objectName: "pencilPalette"
    property string tool: ""
    property string markColor: Theme.defaultInk
    property string drawColor: Theme.defaultInk
    signal toolChosen(string tool)
    signal inkChosen(string tool, string color)
    // The ink the colours are for: drawing's while drawing, highlighting's otherwise.
    readonly property string inkTool: tool === "draw" ? "draw" : "highlight"
    // Near point (in the parent), kept inside it.
    function showAt(point) {
        x = Math.max(8, Math.min(parent.width - width - 8, point.x - width / 2))
        y = Math.max(8, Math.min(parent.height - height - 8, point.y - height - 16))
        open()
    }
    padding: 8
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    contentItem: ColumnLayout {
        spacing: 6
        RowLayout {
            spacing: 2
            Button {
                objectName: "pencilSelect"
                text: qsTr("Select")
                flat: true
                checkable: true
                checked: root.tool === ""
                onClicked: { root.close(); root.toolChosen("") }
            }
            Repeater {
                model: [{tool: "highlight", name: qsTr("Highlight")}, {tool: "draw", name: qsTr("Draw")}, {tool: "erase", name: qsTr("Eraser")},
                        {tool: "text", name: qsTr("Text box")}, {tool: "comment", name: qsTr("Comment")}]
                delegate: IconButton {
                    required property var modelData
                    objectName: "pencil-" + modelData.tool
                    icon.name: modelData.tool
                    description: modelData.name
                    checked: root.tool === modelData.tool
                    swatch: modelData.tool === "highlight" ? root.markColor : modelData.tool === "draw" ? root.drawColor : "transparent"
                    onClicked: { root.close(); root.toolChosen(modelData.tool) }
                }
            }
        }
        Row {
            spacing: 6
            Repeater {
                model: Theme.annotationInks
                delegate: ToolButton {
                    required property var modelData
                    readonly property string current: root.inkTool === "draw" ? root.drawColor : root.markColor
                    objectName: "pencilInk-" + modelData.name
                    width: Theme.iconButton; height: Theme.iconButton
                    padding: 3
                    Accessible.name: qsTranslate("Owelk", modelData.name) + qsTr(" ink")
                    background: Rectangle {
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: parent.current === modelData.value ? Theme.text : "transparent"
                    }
                    contentItem: Rectangle { color: modelData.value; radius: width / 2 }
                    onClicked: { root.close(); root.inkChosen(root.inkTool, modelData.value) }
                }
            }
        }
    }
}
