import QtQuick
import QtQuick.Controls

Item {
    id: root
    property string kind
    property string description
    property bool selected: false
    property bool draggable: false
    signal triggered()
    signal dragProgress(string panel, real windowX, real windowY)
    signal dragEnded(string panel, real windowX, real windowY, bool cancelled)
    implicitWidth: 30
    implicitHeight: 28
    Accessible.role: Accessible.Button
    Accessible.name: description
    Accessible.onPressAction: triggered()
    activeFocusOnTab: true
    Keys.onReturnPressed: triggered()
    Keys.onSpacePressed: triggered()
    Keys.onEscapePressed: {
        pointer.cancelled = true
        pointer.moving = false
        dragEnded(kind, 0, 0, true)
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: 3
        color: root.selected ? "#dedede" : pointer.containsMouse ? "#e9e9e9" : "transparent"
        border.color: root.activeFocus ? "#999999" : "transparent"
    }
    Canvas {
        id: icon
        anchors.centerIn: parent
        width: 18
        height: 18
        onPaint: {
            const c = getContext("2d")
            c.reset()
            c.strokeStyle = "#555555"
            c.lineWidth = 1.3
            c.lineJoin = "round"
            c.beginPath()
            if (root.kind === "files") {
                c.moveTo(2, 5); c.lineTo(2, 3); c.lineTo(7, 3); c.lineTo(9, 5); c.lineTo(16, 5)
                c.lineTo(16, 15); c.lineTo(2, 15); c.closePath()
            } else if (root.kind === "captures") {
                c.rect(3, 3, 12, 12); c.moveTo(4, 12); c.lineTo(8, 8); c.lineTo(11, 11); c.lineTo(14, 7)
                c.moveTo(7, 6); c.arc(6, 6, 1, 0, Math.PI * 2)
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
        preventStealing: true
        cursorShape: moving ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        property point start
        property bool moving: false
        property bool cancelled: false
        onPressed: function(mouse) {
            start = mapToItem(null, mouse.x, mouse.y)
            moving = false
            cancelled = false
            root.forceActiveFocus()
        }
        onPositionChanged: function(mouse) {
            if (!pressed || cancelled || !root.draggable) return
            const point = mapToItem(null, mouse.x, mouse.y)
            if (Math.abs(point.x - start.x) + Math.abs(point.y - start.y) > 8) moving = true
            if (moving) root.dragProgress(root.kind, point.x, point.y)
        }
        onReleased: function(mouse) {
            if (cancelled) return
            const point = mapToItem(null, mouse.x, mouse.y)
            if (moving) root.dragEnded(root.kind, point.x, point.y, false)
            else root.triggered()
            moving = false
        }
        onCanceled: { moving = false; cancelled = true; root.dragEnded(root.kind, 0, 0, true) }
    }
    ToolTip.visible: pointer.containsMouse && !pointer.pressed
    ToolTip.delay: 450
    ToolTip.text: description
}
