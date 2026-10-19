import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "SettingsIndex.js" as SettingsIndex

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
        {id: "foryou", name: qsTr("For You"), icon: "forYou"},
        {id: "web", name: qsTr("Web"), icon: "globe"},
        {id: "search", name: qsTr("Search"), icon: "search", last: true},
        {id: "ai", name: qsTr("AI"), icon: "ai"},
        {id: "sync", name: qsTr("Sync & Backup"), icon: "data"}
    ]
    // A page, or a setting on it ("general#settingsGroup-home"), lit up as a search does.
    function openPage(id) {
        const parts = id.split("#")
        page = parts[0]
        open()
        if (parts.length > 1) reveal({page: parts[0], anchor: parts[1]})
    }
    function pageName(id) { const p = pages.find(function(x) { return x.id === id }); return p ? p.name : "" }
    // Search: settings whose name or related words hold what is typed; choosing one opens its page there.
    property string query: ""
    readonly property var results: query.trim().length ? SettingsIndex.find(query, qsTranslate, pageName) : []
    property string revealing: ""
    function reveal(entry) {
        revealing = entry.anchor
        page = entry.page
        revealTimer.restart()
    }
    function findAnchor(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        const children = item.children || []
        for (let i = 0; i < children.length; ++i) { const found = findAnchor(children[i], name); if (found) return found }
        return null
    }
    // Once the page is laid out: scroll the setting into view and light it up for a moment.
    Timer {
        id: revealTimer
        interval: 60
        onTriggered: {
            const target = root.findAnchor(pageLoader.item, root.revealing)
            root.revealing = ""
            if (!target || !target.visible) return
            const at = target.mapToItem(pageContent, 0, 0)
            const flick = scroller.contentItem
            flick.contentY = Math.max(0, Math.min(at.y - 16, flick.contentHeight - flick.height))
            flash.x = at.x - 4; flash.y = at.y - 4
            flash.width = target.width + 8; flash.height = target.height + 8
            flashFade.restart()
        }
    }
    onClosed: query = ""
    // Each page, and Settings itself, opens at the top (a search then scrolls to its setting).
    onPageChanged: scroller.contentItem.contentY = 0
    onAboutToShow: scroller.contentItem.contentY = 0
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
                TextField {
                    id: searchField
                    objectName: "settingsSearch"
                    Layout.fillWidth: true
                    Layout.bottomMargin: 8
                    implicitHeight: Theme.controlHeight
                    font.pixelSize: Theme.fontSmall
                    placeholderText: qsTr("Search")
                    text: root.query
                    onTextEdited: root.query = text
                    Keys.onEscapePressed: function(event) { if (text.length) { root.query = ""; event.accepted = true } else event.accepted = false }
                    Keys.onReturnPressed: if (root.results.length) root.reveal(root.results[0])
                }
                // While searching, the settings found take the place of the pages.
                Repeater {
                    model: root.results
                    delegate: ItemDelegate {
                        required property var modelData
                        required property int index
                        objectName: "settingsResult-" + index
                        Layout.fillWidth: true
                        implicitHeight: resultColumn.implicitHeight + 10
                        leftPadding: 10
                        onClicked: root.reveal(modelData)
                        contentItem: ColumnLayout {
                            id: resultColumn
                            spacing: 0
                            Label { Layout.fillWidth: true; text: modelData.shown; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                            Label { Layout.fillWidth: true; text: root.pageName(modelData.page); elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                        }
                    }
                }
                Label {
                    visible: root.query.trim().length > 0 && root.results.length === 0
                    leftPadding: 10
                    text: qsTr("No setting found.")
                    font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                }
                Repeater {
                    model: root.query.trim().length ? [] : root.pages
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
                    id: pageContent
                    width: scroller.availableWidth
                    implicitHeight: pageLoader.implicitHeight + 44
                    // The setting a search opened, lit for a moment.
                    Rectangle {
                        id: flash
                        objectName: "settingsFlash"
                        z: 5
                        radius: Theme.radius
                        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, .12)
                        border.color: Theme.accent; border.width: 2
                        opacity: 0
                        NumberAnimation on opacity { id: flashFade; running: false; from: 1; to: 0; duration: 1400; easing.type: Easing.InQuad }
                    }
                    Loader {
                        id: pageLoader
                        objectName: "settingsPageLoader"
                        x: 24; y: 20
                        width: parent.width - 48
                        active: root.visible
                        sourceComponent: ({general: generalPage, appearance: appearancePage, shortcuts: shortcutsPage, library: libraryPage, foryou: forYouPage,
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
    Component { id: forYouPage; SettingsForYou {} }
    Component { id: webPage; SettingsWeb {} }
    Component { id: searchPage; SettingsSearch {} }
    Component { id: aiPage; SettingsAi {} }
    Component { id: syncPage; SettingsSync {} }
}
