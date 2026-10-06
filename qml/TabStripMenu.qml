import QtQuick
import QtQuick.Controls
import Owelk.Ui
import "Platform.js" as Platform

// Right-click on empty space in a tab bar or the vertical tab list: what applies to the tabs as a
// whole. Sorting keeps groups together; nothing here closes a tab without saying so.
Menu {
    id: root
    objectName: "tabStripMenu"
    required property var controller
    property string stripId: ""
    function show(strip) { stripId = strip; popup() }
    MenuItem { objectName: "stripNewTab"; text: "New Tab"; onTriggered: { root.controller.activateGroup(root.stripId); root.controller.newHomeTab() } }
    MenuItem { text: "Reopen Closed Tab"; enabled: root.controller.closedTabs.length > 0; onTriggered: root.controller.reopenClosedTab() }
    MenuSeparator {}
    MenuItem { objectName: "stripSortTitle"; text: "Sort Tabs by Title"; onTriggered: root.controller.sortTabs(root.stripId, "title") }
    MenuItem { text: "Sort Tabs by Type"; onTriggered: root.controller.sortTabs(root.stripId, "kind") }
    MenuItem { objectName: "stripCloseDuplicates"; text: "Close Duplicate Tabs"; onTriggered: root.controller.closeDuplicateTabs(root.stripId) }
    MenuItem { text: "Organize Tabs with AI…"; onTriggered: root.controller.organizeRequested(root.stripId) }
    MenuSeparator {}
    Menu {
        title: "Tab Layout"
        MenuItem { objectName: "stripHorizontal"; text: "Horizontal"; checkable: true; checked: !Theme.verticalTabs; onTriggered: Theme.verticalTabs = false }
        MenuItem { objectName: "stripVertical"; text: "Vertical"; checkable: true; checked: Theme.verticalTabs; onTriggered: Theme.verticalTabs = true }
    }
}
