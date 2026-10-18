import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A figure, table or equation pinned from its preview (PdfCanvas): it floats over the pages and stays while
// they scroll. Its bar moves it; its lower right corner resizes it, from 180 × 120 up to 80% of the reader (the
// size is kept for its kind); the page view zooms (pinch, Ctrl+wheel, − and +); a click on it goes there.
Rectangle {
    id: card
    objectName: "pinnedCard"
    property var spec: ({page: 0})
    property var document: null
    property bool inverted: false
    // The reader it stays within.
    property real areaWidth: 0
    property real areaHeight: 0
    signal closeRequested()
    signal goRequested(int page, real top)
    // Moved or resized by hand (to keep its place, and its size for its kind).
    signal moved()
    signal resized()
    readonly property bool hovered: cardHover.hovered
    readonly property real minWidth: 180
    readonly property real minHeight: 120
    readonly property real maxWidth: Math.max(minWidth, areaWidth * .8)
    readonly property real maxHeight: Math.max(minHeight, areaHeight * .8)
    function resize(w, h) {
        width = Math.round(Math.max(minWidth, Math.min(maxWidth, w)))
        height = Math.round(Math.max(minHeight, Math.min(maxHeight, h)))
        keepInside()
    }
    function keepInside() {
        x = Math.max(0, Math.min(areaWidth - width, x))
        y = Math.max(0, Math.min(areaHeight - height, y))
    }
    onAreaWidthChanged: if (areaWidth > 0) resize(width, height)
    onAreaHeightChanged: if (areaHeight > 0) resize(width, height)
    readonly property int inset: 4
    radius: Theme.radiusLarge
    color: inverted ? Theme.paperInverted : Theme.paper
    clip: true
    HoverHandler { id: cardHover }
    Rectangle {
        id: bar
        objectName: "pinnedCardBar"
        width: parent.width; height: Theme.iconButton + 6
        color: Theme.raised
        Label {
            anchors.left: parent.left; anchors.leftMargin: 10; anchors.right: tools.left; anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: (card.spec.label || (card.spec.kind === "table" ? qsTr("Table") : card.spec.kind === "equation" ? qsTr("Equation") : qsTr("Figure")))
                + qsTr(" · p. ") + (card.spec.page + 1)
            elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontCaption; color: Theme.textSecondary
        }
        Row {
            id: tools
            anchors.right: parent.right; anchors.rightMargin: 3; anchors.verticalCenter: parent.verticalCenter
            IconButton { objectName: "pinnedZoomOut"; icon.name: "minus"; description: qsTr("Zoom out"); onClicked: content.setZoom(content.zoom / 1.1) }
            IconButton { objectName: "pinnedZoomIn"; icon.name: "add"; description: qsTr("Zoom in"); onClicked: content.setZoom(content.zoom * 1.1) }
            IconButton { objectName: "pinnedClose"; icon.name: "close"; description: qsTr("Unpin"); onClicked: card.closeRequested() }
        }
        DragHandler {
            objectName: "pinnedMove"
            target: card
            xAxis.minimum: 0; xAxis.maximum: Math.max(0, card.areaWidth - card.width)
            yAxis.minimum: 0; yAxis.maximum: Math.max(0, card.areaHeight - card.height)
            onActiveChanged: if (!active) card.moved()
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    }
    PreviewContent {
        id: content
        objectName: "pinnedCardContent"
        anchors.fill: parent
        anchors.topMargin: bar.height + 1
        anchors.margins: card.inset
        document: card.document
        spec: card.spec
        inverted: card.inverted
        inset: card.inset
        onGoRequested: function(page, top) { card.goRequested(page, top) }
    }
    // The lower right corner: drag to resize.
    Item {
        id: grip
        objectName: "pinnedResize"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: 18; height: 18
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
        // A MouseArea that keeps the drag, so neither the page view under the corner nor the reader takes it.
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
            onReleased: card.resized()
        }
    }
    // The outline, over the page view.
    Rectangle {
        anchors.fill: parent
        radius: card.radius
        color: "transparent"
        border.color: Theme.border
    }
}
