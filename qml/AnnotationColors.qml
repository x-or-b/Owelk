import QtQuick
import QtQuick.Controls
import Owelk.Ui

Popup {
    id: root
    property string selectedColor: Theme.defaultInk
    signal chosen(string color)
    function colorButton(index) {
        return swatches.itemAt(index);
    }
    // Round color wells; the current ink has a ring.
    padding: 8
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    Row {
        spacing: 6
        Repeater {
            id: swatches
            model: Theme.annotationInks
            delegate: ToolButton {
                required property var modelData
                objectName: "annotationColor-" + modelData.name
                width: Theme.iconButton
                height: Theme.iconButton
                padding: 3
                hoverEnabled: true
                Accessible.name: modelData.name + " ink"
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: modelData.name
                background: Rectangle {
                    radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: root.selectedColor === modelData.value ? Theme.text : parent.hovered ? Theme.border : "transparent"
                }
                contentItem: Rectangle {
                    color: modelData.value
                    radius: width / 2
                }
                onClicked: {
                    root.close();
                    root.chosen(modelData.value);
                }
            }
        }
    }
}
