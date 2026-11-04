import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A panel floating over the pages, as a pinned figure does (PinnedCard): its bar moves it, its lower right corner
// resizes it, and it stays while the pages scroll or are tapped. An upright iPad keeps the AI chat this way
// (Main.qml).
Rectangle {
    id: card
    property string title: ""
    // The area it stays within.
    property real areaWidth: 0
    property real areaHeight: 0
    default property alias content: body.data
    signal closeRequested()
    // Moved or resized by hand.
    signal placed()
    readonly property real minWidth: 280
    readonly property real minHeight: 240
    function resize(w, h) {
        width = Math.round(Math.max(minWidth, Math.min(Math.max(minWidth, areaWidth), w)))
        height = Math.round(Math.max(minHeight, Math.min(Math.max(minHeight, areaHeight), h)))
        keepInside()
    }
    function keepInside() {
        x = Math.max(0, Math.min(areaWidth - width, x))
        y = Math.max(0, Math.min(areaHeight - height, y))
    }
    onAreaWidthChanged: if (areaWidth > 0) resize(width, height)
    onAreaHeightChanged: if (areaHeight > 0) resize(width, height)
    radius: Theme.radiusLarge
    color: Theme.sidebar
    clip: true
    // What lands on it stays with it: nothing reaches the pages, or the press beside a side panel that closes it.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }
    Rectangle {
        id: bar
        objectName: "floatingPanelBar"
        width: parent.width; height: Theme.iconButton + 6
        color: Theme.raised
        Label {
            anchors.left: parent.left; anchors.leftMargin: 10; anchors.right: closeButton.left; anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: card.title
            elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontCaption; color: Theme.textSecondary
        }
        IconButton {
            id: closeButton
            objectName: "floatingPanelClose"
            anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter
            icon.name: "close"; description: qsTr("Close")
            onClicked: card.closeRequested()
        }
        DragHandler {
            objectName: "floatingPanelMove"
            target: card
            xAxis.minimum: 0; xAxis.maximum: Math.max(0, card.areaWidth - card.width)
            yAxis.minimum: 0; yAxis.maximum: Math.max(0, card.areaHeight - card.height)
            onActiveChanged: if (!active) card.placed()
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    }
    Item {
        id: body
        anchors.fill: parent
        anchors.topMargin: bar.height
        anchors.bottomMargin: grip.height
    }
    // The lower right corner, in a strip of its own below the content (whose own buttons sit in its corners): drag
    // to resize. A fingertip's size on a touch screen.
    Item {
        id: grip
        objectName: "floatingPanelResize"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: Theme.touch ? 32 : 18; height: Theme.touch ? 20 : 12
        Repeater {
            model: 2
            Rectangle {
                required property int index
                width: 8 - index * 4; height: 1.5; radius: 1
                color: Theme.textTertiary
                rotation: -45
                x: grip.width - width - 3 - index * 1.5; y: grip.height - 5 - index * 3
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SizeFDiagCursor
            preventStealing: true
            property size start
            property point from
            onPressed: function(mouse) { start = Qt.size(card.width, card.height); from = mapToItem(null, mouse.x, mouse.y) }
            onPositionChanged: function(mouse) {
                const at = mapToItem(null, mouse.x, mouse.y)
                card.resize(start.width + at.x - from.x, start.height + at.y - from.y)
            }
            onReleased: card.placed()
        }
    }
    // The outline, over the content.
    Rectangle {
        anchors.fill: parent
        radius: card.radius
        color: "transparent"
        border.color: Theme.border
    }
}
