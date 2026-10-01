import QtQuick
import QtQuick.Controls
import "UiTheme.js" as Theme

UiControls.Popup {
    id: root
    property string selectedColor: Theme.defaultInk
    signal chosen(string color)
    function colorButton(index) {
        return swatches.itemAt(index);
    }
    width: 174
    height: 46
    padding: 7
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Rectangle {
        color: Theme.surfacePanel
        border.color: Theme.borderPopup
    }
    Row {
        spacing: 4
        Repeater {
            id: swatches
            model: Theme.annotationInks
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
