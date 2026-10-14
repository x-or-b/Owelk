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
    property string page: "general"
    // In three groups: the app itself, papers and where they come from, then AI and keeping the library.
    readonly property var pages: [
        {id: "general", name: qsTr("General"), icon: "settings"},
        {id: "appearance", name: qsTr("Appearance"), icon: "appearance"},
        {id: "shortcuts", name: qsTr("Shortcuts"), icon: "keyboard", last: true},
        {id: "library", name: qsTr("Library"), icon: "library"},
        {id: "web", name: qsTr("Web"), icon: "globe"},
        {id: "search", name: qsTr("Search"), icon: "search", last: true},
        {id: "ai", name: qsTr("AI"), icon: "ai"},
        {id: "sync", name: qsTr("Sync & Backup"), icon: "data"}
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
                Label { text: qsTr("Settings"); leftPadding: 8; bottomPadding: 8; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold }
                Repeater {
                    model: root.pages
                    delegate: ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0
                        ItemDelegate {
                            objectName: "settingsPage-" + parent.modelData.id
                            Layout.fillWidth: true
                            implicitHeight: Theme.rowHeight + 2
                            leftPadding: 34
                            text: parent.modelData.name
                            highlighted: root.page === parent.modelData.id
                            onClicked: root.page = parent.modelData.id
                            Icon {
                                x: 10; anchors.verticalCenter: parent.verticalCenter
                                name: parent.parent.modelData.icon
                                color: parent.highlighted ? Theme.selectedText : Theme.textSecondary
                            }
                        }
                        // A quiet line closes each group.
                        Rectangle {
                            visible: !!parent.modelData.last
                            Layout.fillWidth: true; Layout.leftMargin: 8; Layout.rightMargin: 8
                            Layout.topMargin: 6; Layout.bottomMargin: 6
                            implicitHeight: 1
                            color: Theme.separator
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
                icon.name: "close"; description: qsTr("Close · Esc")
                onClicked: root.close()
            }
            // Inside the dialog's outline, so scrolled content passes under it rather than over it.
            ScrollView {
                id: scroller
                anchors.fill: parent
                anchors.topMargin: 1; anchors.rightMargin: 1; anchors.bottomMargin: 1
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
                        sourceComponent: ({general: generalPage, appearance: appearancePage, shortcuts: shortcutsPage, library: libraryPage,
                                           web: webPage, search: searchPage, ai: aiPage, sync: syncPage})[root.page] || generalPage
                    }
                }
            }
        }
    }
    Component { id: generalPage; SettingsGeneral {} }
    Component { id: appearancePage; SettingsAppearance {} }
    Component { id: shortcutsPage; SettingsShortcuts {} }
    Component { id: libraryPage; SettingsLibrary {} }
    Component { id: webPage; SettingsWeb {} }
    Component { id: searchPage; SettingsSearch {} }
    Component { id: aiPage; SettingsAi {} }
    Component { id: syncPage; SettingsSync {} }
}
