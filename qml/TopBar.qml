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
    // The search field (the library and the web). Typing, a click or Cmd+K opens its results right under it
    // (SearchPalette attached to this field); while they show, its bottom corners square off to join them.
    property var palette: null
    readonly property bool expanded: !!palette && palette.opened
    readonly property alias searchField: field
    readonly property alias searchBox: search
    Item {
        id: search
        objectName: "topSearch"
        anchors.centerIn: parent
        // Room for long titles in the results without stretching across a wide window.
        width: Math.min(680, Math.max(320, root.width * .5))
        height: Theme.controlHeightSmall + 4
        // While the results show, the field's bottom (corners and edge) is cut off so its sides run straight
        // into the card's.
        Item {
            anchors.fill: parent
            clip: root.expanded
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                height: parent.height + (root.expanded ? radius : 0)
                radius: Theme.radius
                color: root.expanded || field.activeFocus ? Theme.field : hover.hovered ? Theme.hover : Theme.field
                border.color: root.expanded ? Theme.border : field.activeFocus ? Theme.accent : Theme.separator
            }
        }
        HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }
        Icon { x: 10; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: Theme.fontBody; color: Theme.textTertiary }
        TextField {
            id: field
            objectName: "topSearchField"
            // A click elsewhere takes the cursor out (Main.qml); its box and its results keep it.
            property bool releaseFocusOnOutsidePress: true
            property var keepFocusWithin: [search, root.palette && root.palette.contentItem ? root.palette.contentItem.parent : null]
            anchors.fill: parent
            leftPadding: 30; rightPadding: hint.visible ? hint.width + 16 : 10
            topPadding: 0; bottomPadding: 0
            verticalAlignment: TextInput.AlignVCenter
            font.pixelSize: Theme.fontSmall
            placeholderText: qsTr("Search")
            selectByMouse: true
            background: null
            // Results open on typing (with Korean being composed too) and on a click.
            onDisplayTextChanged: if (activeFocus && displayText.length && root.palette && !root.palette.opened) root.palette.open()
            TapHandler { onTapped: { field.forceActiveFocus(); if (root.palette && !root.palette.opened) root.palette.open() } }
            Keys.onPressed: function(event) { if (root.palette && root.palette.handleKey(event)) event.accepted = true }
        }
        Label {
            id: hint
            visible: !root.expanded && !field.activeFocus
            anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
            text: Platform.keys("Ctrl+K")
            font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
        }
    }
    IconButton {
        objectName: "appMenuButton"
        visible: !!root.appMenu
        anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
        icon.name: "menu"; description: qsTr("Menu")
        onClicked: root.appMenu.popup(this, width - root.appMenu.width, height)
    }
}
