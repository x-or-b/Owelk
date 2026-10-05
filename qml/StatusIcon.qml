import QtQuick
import QtQuick.Controls
import Owelk.Ui

// A status-bar button for a panel or a window action. Panels can move docks by right-click.
IconButton {
    id: root
    property string kind
    property bool selected: false
    property string dockSide: ""
    signal triggered()
    signal dockSideChosen(string side)
    icon.name: ({files: "folder", captures: "capture", document: "document", ai: "ai", split: "split", search: "search"})[kind] || kind
    checked: selected
    checkable: false
    onClicked: triggered()
    Keys.onMenuPressed: if (dockSide.length) dockMenu.popup()
    TapHandler { acceptedButtons: Qt.RightButton; enabled: root.dockSide.length > 0; onTapped: dockMenu.popup() }
    Menu {
        id: dockMenu
        objectName: "dockMenu-" + root.kind
        MenuItem { objectName: "leftDockOption"; text: "Left Dock"; checkable: true; checked: root.dockSide === "left"; onTriggered: root.dockSideChosen("left") }
        MenuItem { objectName: "rightDockOption"; text: "Right Dock"; checkable: true; checked: root.dockSide === "right"; onTriggered: root.dockSideChosen("right") }
    }
}
