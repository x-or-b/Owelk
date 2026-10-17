import QtQuick
import QtQuick.Controls
import Owelk.Ui
import "Platform.js" as Platform

// The search field (the library and the web), in the top bar or, without it, on Home. Typing, a click or Cmd+K
// opens its results right under it (the SearchPalette attached to it); while they show, its bottom corners square
// off to join them.
Item {
    id: box
    property var palette: null
    property string fieldName: ""
    property alias field: field
    readonly property bool expanded: !!palette && palette.opened && palette.inputField === field
    height: Theme.controlHeightSmall + 4
    Item {
        anchors.fill: parent
        clip: box.expanded
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: parent.height + (box.expanded ? radius : 0)
            radius: Theme.radius
            color: box.expanded || field.activeFocus ? Theme.field : hover.hovered ? Theme.hover : Theme.field
            border.color: box.expanded ? Theme.border : field.activeFocus ? Theme.accent : Theme.separator
        }
    }
    HoverHandler { id: hover; cursorShape: Qt.IBeamCursor }
    Icon { x: 10; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: Theme.fontBody; color: Theme.textTertiary }
    TextField {
        id: field
        objectName: box.fieldName
        // A click elsewhere takes the cursor out (Main.qml); its box and its results keep it.
        property bool releaseFocusOnOutsidePress: true
        property var keepFocusWithin: [box, box.palette && box.palette.contentItem ? box.palette.contentItem.parent : null]
        anchors.fill: parent
        leftPadding: 30; rightPadding: hint.visible ? hint.width + 16 : 10
        topPadding: 0; bottomPadding: 0
        verticalAlignment: TextInput.AlignVCenter
        font.pixelSize: Theme.fontSmall
        placeholderText: qsTr("Search")
        selectByMouse: true
        background: null
        // Results open on typing (with Korean being composed too) and on a click, under this field.
        onDisplayTextChanged: if (activeFocus && displayText.length && box.palette && box.palette.inputField === field && !box.palette.opened) box.palette.open()
        TapHandler { onTapped: { field.forceActiveFocus(); if (box.palette && box.palette.inputField === field && !box.palette.opened) box.palette.open() } }
        Keys.onPressed: function(event) { if (box.palette && box.palette.inputField === field && box.palette.handleKey(event)) event.accepted = true }
    }
    Label {
        id: hint
        visible: !box.expanded && !field.activeFocus
        anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
        text: Platform.keys("Ctrl+K")
        font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
    }
}
