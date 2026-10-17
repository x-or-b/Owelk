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
    // Windows and Linux: the app's menus (File, View) live behind ≡ at the right end, not in a bar of their own.
    property Menu appMenu: null
    property bool canGoBack: false
    property bool canGoForward: false
    property string backKeys: ""
    property string forwardKeys: ""
    signal back()
    signal forward()
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
    // The search field (the library and the web), with its results right under it.
    property var palette: null
    readonly property bool expanded: search.expanded
    readonly property alias searchField: search.field
    readonly property alias searchBox: search
    SearchBox {
        id: search
        objectName: "topSearch"
        fieldName: "topSearchField"
        palette: root.palette
        anchors.centerIn: parent
        // Room for long titles in the results without stretching across a wide window.
        width: Math.min(680, Math.max(320, root.width * .5))
    }
    IconButton {
        objectName: "appMenuButton"
        visible: !!root.appMenu
        anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
        icon.name: "menu"; description: qsTr("Menu")
        onClicked: root.appMenu.popup(this, width - root.appMenu.width, height)
    }
}
