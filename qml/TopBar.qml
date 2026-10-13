import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform

// The bar above the tabs: back and forward on the left, the search box (Cmd+K: the library and the web)
// in the middle. On macOS it is the title bar as well: the traffic lights sit in `leading`, and its empty
// space moves the window (Main.qml reports controlRects() to the native side).
Rectangle {
    id: root
    objectName: "topBar"
    property bool titleBar: false
    property real leading: 0
    property bool canGoBack: false
    property bool canGoForward: false
    property string backKeys: ""
    property string forwardKeys: ""
    signal back()
    signal forward()
    signal searchRequested()
    // Where the search results open (right under this field, as in a browser).
    readonly property alias searchField: search
    implicitHeight: Theme.barHeight
    color: Theme.window
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    // The controls, in window coordinates: on macOS everything else in the bar moves the window.
    function controlRects() {
        return [arrows, search].map(function(item) {
            const at = item.mapToItem(null, 0, 0)
            return {x: at.x, y: at.y, width: item.width, height: item.height}
        })
    }
    Row {
        id: arrows
        anchors.left: parent.left; anchors.leftMargin: root.leading + 4; anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        IconButton {
            objectName: "topBack"; icon.name: "back"
            enabled: root.canGoBack
            description: qsTr("Back") + (root.backKeys.length ? " · " + root.backKeys : "")
            onClicked: root.back()
        }
        IconButton {
            objectName: "topForward"; icon.name: "forward"
            enabled: root.canGoForward
            description: qsTr("Forward") + (root.forwardKeys.length ? " · " + root.forwardKeys : "")
            onClicked: root.forward()
        }
    }
    // Looks like a search field; opens the search palette.
    ItemDelegate {
        id: search
        objectName: "topSearch"
        anchors.centerIn: parent
        width: Math.min(560, Math.max(260, root.width * .44))
        height: Theme.controlHeightSmall + 4
        padding: 0; leftPadding: 10; rightPadding: 10
        background: Rectangle {
            radius: Theme.radius
            color: search.hovered ? Theme.hover : Theme.field
            border.color: Theme.separator
        }
        contentItem: RowLayout {
            spacing: 6
            Icon { name: "search"; size: Theme.fontBody; color: Theme.textTertiary }
            Label { Layout.fillWidth: true; text: qsTr("Search"); elide: Text.ElideRight; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
            Label { text: Platform.keys("Ctrl+K"); font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
        }
        onClicked: root.searchRequested()
    }
}
