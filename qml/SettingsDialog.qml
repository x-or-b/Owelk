import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// App preferences, by category (macOS System Settings layout). Changes apply at once and are
// stored locally. Only the shown page exists; pages are created when chosen.
Dialog {
    id: root
    objectName: "settingsDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(820, parent ? parent.width - 48 : 820)
    height: Math.min(600, parent ? parent.height - 48 : 600)
    modal: true
    padding: 0
    topPadding: 0
    header: null
    footer: null
    property string page: "appearance"
    readonly property var pages: [
        {id: "appearance", name: "Appearance", icon: "appearance"},
        {id: "web", name: "Web", icon: "globe"},
        {id: "search", name: "Search", icon: "search"},
        {id: "ai", name: "AI", icon: "ai"},
        {id: "shortcuts", name: "Shortcuts", icon: "keyboard"},
        {id: "data", name: "Data", icon: "data"}
    ]
    function openPage(id) { page = id; open() }
    contentItem: RowLayout {
        spacing: 0
        Rectangle {
            Layout.preferredWidth: 190
            Layout.fillHeight: true
            color: Theme.sidebar
            radius: Theme.radiusLarge
            // Square the right edge against the content.
            Rectangle { anchors.right: parent.right; width: Theme.radiusLarge; height: parent.height; color: parent.color }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.separator }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                anchors.topMargin: 14
                spacing: 2
                Label { text: "Settings"; leftPadding: 8; bottomPadding: 8; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold }
                Repeater {
                    model: root.pages
                    delegate: ItemDelegate {
                        required property var modelData
                        objectName: "settingsPage-" + modelData.id
                        Layout.fillWidth: true
                        height: Theme.rowHeight + 2
                        leftPadding: 34
                        text: modelData.name
                        highlighted: root.page === modelData.id
                        onClicked: root.page = modelData.id
                        Icon {
                            x: 10; anchors.verticalCenter: parent.verticalCenter
                            name: parent.modelData.icon
                            color: parent.highlighted ? Theme.selectedText : Theme.textSecondary
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            IconButton {
                objectName: "closeSettings"
                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
                z: 2
                icon.name: "close"; description: "Close · Esc"
                onClicked: root.close()
            }
            ScrollView {
                id: scroller
                anchors.fill: parent
                contentWidth: availableWidth
                clip: true
                Item {
                    width: scroller.availableWidth
                    implicitHeight: pageLoader.implicitHeight + 44
                    Loader {
                        id: pageLoader
                        objectName: "settingsPageLoader"
                        x: 24; y: 20
                        width: parent.width - 48
                        active: root.visible
                        sourceComponent: ({appearance: appearancePage, web: webPage, search: searchPage, ai: aiPage, shortcuts: shortcutsPage, data: dataPage})[root.page]
                    }
                }
            }
        }
    }
    Component { id: appearancePage; SettingsAppearance {} }
    Component { id: webPage; SettingsWeb {} }
    Component { id: searchPage; SettingsSearch {} }
    Component { id: aiPage; SettingsAi {} }
    Component { id: shortcutsPage; SettingsShortcuts {} }
    Component { id: dataPage; SettingsData {} }
}
