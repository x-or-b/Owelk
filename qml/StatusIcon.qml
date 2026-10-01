import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls

Item {
    id: root
    property string kind
    property string description
    property bool selected: false
    property string dockSide: ""
    signal triggered()
    signal dockSideChosen(string side)
    implicitWidth: 30
    implicitHeight: 28
    Accessible.role: Accessible.Button
    Accessible.name: description
    Accessible.onPressAction: triggered()
    activeFocusOnTab: true
    Keys.onReturnPressed: triggered()
    Keys.onSpacePressed: triggered()
    Keys.onMenuPressed: if (dockSide.length) dockMenu.popup()
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Theme.cornerRadius
        color: root.selected ? Theme.controlHover : pointer.containsMouse ? Theme.surfaceSelected : "transparent"
        border.color: root.activeFocus ? Theme.focusRing : "transparent"
    }
    Canvas {
        id: icon
        anchors.centerIn: parent
        width: 18
        height: 18
        onPaint: {
            const c = getContext("2d")
            c.reset()
            c.strokeStyle = Theme.icon
            c.lineWidth = 1.3
            c.lineJoin = "round"
            c.beginPath()
            if (root.kind === "files") {
                c.moveTo(2, 5); c.lineTo(2, 3); c.lineTo(7, 3); c.lineTo(9, 5); c.lineTo(16, 5)
                c.lineTo(16, 15); c.lineTo(2, 15); c.closePath()
            } else if (root.kind === "captures") {
                c.rect(3, 3, 12, 12); c.moveTo(4, 12); c.lineTo(8, 8); c.lineTo(11, 11); c.lineTo(14, 7)
                c.moveTo(7, 6); c.arc(6, 6, 1, 0, Math.PI * 2)
            } else if (root.kind === "document") {
                c.rect(3, 2, 12, 14)
                c.moveTo(6, 6); c.lineTo(12, 6); c.moveTo(6, 9); c.lineTo(12, 9); c.moveTo(6, 12); c.lineTo(10, 12)
            } else if (root.kind === "home") {
                c.moveTo(1, 8); c.lineTo(9, 2); c.lineTo(17, 8)
                c.moveTo(4, 6); c.lineTo(4, 16); c.lineTo(14, 16); c.lineTo(14, 6)
                c.moveTo(7, 16); c.lineTo(7, 10); c.lineTo(11, 10); c.lineTo(11, 16)
            } else if (root.kind === "split") {
                c.rect(2, 3, 14, 12); c.moveTo(9, 3); c.lineTo(9, 15)
            } else {
                c.arc(7, 7, 5, 0, Math.PI * 2); c.moveTo(11, 11); c.lineTo(16, 16)
            }
            c.stroke()
        }
    }
    onKindChanged: icon.requestPaint()
    MouseArea {
        id: pointer
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) { if (root.dockSide.length) dockMenu.popup() }
            else root.triggered()
        }
    }
    UiControls.Menu {
        id: dockMenu
        objectName: "dockMenu-" + root.kind
        UiControls.MenuItem { objectName: "leftDockOption"; text: "Left Dock"; checkable: true; checked: root.dockSide === "left"; onTriggered: root.dockSideChosen("left") }
        UiControls.MenuItem { objectName: "rightDockOption"; text: "Right Dock"; checkable: true; checked: root.dockSide === "right"; onTriggered: root.dockSideChosen("right") }
    }
    ToolTip.visible: pointer.containsMouse && !pointer.pressed
    ToolTip.delay: 450
    ToolTip.text: description
}
