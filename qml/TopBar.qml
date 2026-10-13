import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform

// The bar above the tabs: back and forward on the left, the search box (Cmd+K: the library and the web)
// in the middle. On macOS it is the title bar as well: the traffic lights sit in `leading`, and its empty
// space moves the window and zooms it on a double-click, as a title bar does.
Rectangle {
    id: root
    objectName: "topBar"
    property bool titleBar: false
    property real leading: 0
    property bool canGoBack: false
    property bool canGoForward: false
    signal back()
    signal forward()
    signal searchRequested()
    implicitHeight: Theme.barHeight
    color: Theme.window
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    // Below the buttons, so it only takes the bar's empty space.
    Item {
        anchors.fill: parent
        DragHandler { target: null; enabled: root.titleBar; onActiveChanged: if (active) root.Window.window.startSystemMove() }
        TapHandler {
            enabled: root.titleBar
            onDoubleTapped: {
                const window = root.Window.window
                if (window.visibility === Window.Maximized) window.showNormal(); else window.showMaximized()
            }
        }
    }
    Row {
        anchors.left: parent.left; anchors.leftMargin: root.leading + 4; anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        IconButton {
            objectName: "topBack"; icon.name: "back"
            enabled: root.canGoBack
            description: qsTr("Back · ") + Platform.keys("Ctrl+[")
            onClicked: root.back()
        }
        IconButton {
            objectName: "topForward"; icon.name: "forward"
            enabled: root.canGoForward
            description: qsTr("Forward · ") + Platform.keys("Ctrl+]")
            onClicked: root.forward()
        }
    }
    // Looks like a search field; opens the search palette.
    ItemDelegate {
        id: search
        objectName: "topSearch"
        anchors.centerIn: parent
        width: Math.min(440, Math.max(200, root.width * .36))
        height: Theme.controlHeightSmall + 2
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
