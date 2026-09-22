import QtQuick
import QtQuick.Controls
import "UiTheme.js" as Theme

UiControls.Popup {
    id: root
    property string selectedColor: "#426b9a"
    signal chosen(string color)
    function colorButton(index) {
        return swatches.itemAt(index);
    }
    width: 174
    height: 46
    padding: 7
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle {
        color: "#fafafa"
        border.color: "#bcbcbc"
    }
    Row {
        spacing: 4
        Repeater {
            id: swatches
            model: [
                {
                    name: "Blue",
                    value: "#426b9a"
                },
                {
                    name: "Yellow",
                    value: "#e0b83f"
                },
                {
                    name: "Green",
                    value: "#54a878"
                },
                {
                    name: "Pink",
                    value: "#d87797"
                },
                {
                    name: "Purple",
                    value: "#9274c3"
                }
            ]
            delegate: UiControls.ToolButton {
                required property var modelData
                objectName: "annotationColor-" + modelData.name
                width: 28
                height: 30
                hoverEnabled: true
                Accessible.name: modelData.name + " highlight"
                ToolTip.visible: hovered
                ToolTip.text: modelData.name
                background: Rectangle {
                    color: "transparent"
                    border.color: root.selectedColor === modelData.value ? Theme.accent : "transparent"
                }
                contentItem: Rectangle {
                    color: modelData.value
                    radius: 4
                }
                onClicked: {
                    root.close();
                    root.chosen(modelData.value);
                }
            }
        }
    }
}
