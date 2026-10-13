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
    // Where the search results open (right under this field, as in a browser).
    readonly property alias searchField: search
    implicitHeight: Theme.barHeight
    color: Theme.window
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
    // Below the buttons, so it only takes the bar's empty space. The move starts on the press itself: macOS
    // follows a window move only when it is asked as the button goes down, not once the pointer has moved.
    MouseArea {
        anchors.fill: parent
        enabled: root.titleBar
        // The system move takes over the mouse, so a double-click is told from two quick presses.
        property real lastPress: 0
        onPressed: {
            const window = root.Window.window, now = Date.now()
            if (now - lastPress < Qt.styleHints.mouseDoubleClickInterval) {
                lastPress = 0
                if (window.visibility === Window.Maximized) window.showNormal(); else window.showMaximized()
                return
            }
            lastPress = now
            window.startSystemMove()
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
