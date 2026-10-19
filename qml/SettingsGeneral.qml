import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform
import "Shortcuts.js" as Shortcuts
import "HomeLayout.js" as HomeLayout

// What Owelk does on launch, how tabs behave, and the interface language.
ColumnLayout {
    id: root
    objectName: "generalSettings"
    spacing: 22
    SettingsGroup {
        objectName: "settingsGroup-launch"
        title: qsTr("Launch")
        // What a new launch shows: Home (the tabs wait behind it) or the tabs as they were left.
        SettingsRow {
            objectName: "settingsRow-launch"
            label: qsTr("On launch")
            TabBar {
                id: startupBar
                objectName: "startupView"
                property string chosen: researchStore.setting("startup.view", "home")
                currentIndex: chosen === "tabs" ? 1 : 0
                TabButton { text: qsTr("Home"); width: 96; onClicked: { startupBar.chosen = "home"; researchStore.setSetting("startup.view", "home") } }
                TabButton { objectName: "startupTabsOption"; text: qsTr("Last Tabs"); width: 96; onClicked: { startupBar.chosen = "tabs"; researchStore.setSetting("startup.view", "tabs") } }
            }
        }
    }
    // Home: the sections below Continue Reading, each on or off, moved up and down; a sketch shows where they go
    // (HomeLayout.js). Kept on this computer: screens differ.
    SettingsGroup {
        id: homeGroup
        objectName: "settingsGroup-home"
        title: qsTr("Home")
        note: qsTr("What Home shows below Continue Reading, in this order. For You and Reading take a row each; the others sit two to a row from the left.")
        property string text: researchStore.setting("home.sections")
        readonly property var sections: HomeLayout.parse(text)
        readonly property var names: ({foryou: qsTr("For You"), reading: qsTr("Reading"), collections: qsTr("Collections"),
            recent: qsTr("Recent Papers"), notes: qsTr("Notes"), threads: qsTr("AI Conversations")})
        function save(list) {
            text = HomeLayout.format(list)
            researchStore.setSetting("home.sections", text)
        }
        Repeater {
            model: homeGroup.sections
            delegate: SettingsRow {
                id: sectionRow
                required property var modelData
                required property int index
                objectName: "homeSection-" + modelData.name
                label: homeGroup.names[modelData.name]
                IconButton {
                    objectName: "homeSectionUp-" + sectionRow.modelData.name
                    icon.name: "up"; description: qsTr("Move Up")
                    enabled: sectionRow.index > 0
                    onClicked: homeGroup.save(HomeLayout.move(homeGroup.sections, sectionRow.index, -1))
                }
                IconButton {
                    objectName: "homeSectionDown-" + sectionRow.modelData.name
                    icon.name: "down"; description: qsTr("Move Down")
                    enabled: sectionRow.index < homeGroup.sections.length - 1
                    onClicked: homeGroup.save(HomeLayout.move(homeGroup.sections, sectionRow.index, 1))
                }
                Switch {
                    objectName: "homeSectionSwitch-" + sectionRow.modelData.name
                    checked: sectionRow.modelData.on
                    onToggled: homeGroup.save(homeGroup.sections.map(function(s) {
                        return {name: s.name, on: s.name === sectionRow.modelData.name ? checked : s.on}
                    }))
                }
            }
        }
        // A sketch of Home's rows as they will be.
        SettingsRow {
            objectName: "settingsRow-homeLayout"
            label: qsTr("Layout")
            Column {
                objectName: "homeLayoutSketch"
                spacing: 3
                Repeater {
                    model: HomeLayout.preview(homeGroup.sections)
                    delegate: Row {
                        id: sketchRow
                        required property var modelData
                        spacing: 3
                        Repeater {
                            model: sketchRow.modelData
                            delegate: Rectangle {
                                required property string modelData
                                width: sketchRow.modelData.length > 1 ? 78 : 159; height: 18
                                radius: Theme.radiusSmall
                                color: Theme.control
                                border.color: Theme.separator
                                Label {
                                    anchors.fill: parent; anchors.leftMargin: 5; anchors.rightMargin: 5
                                    verticalAlignment: Text.AlignVCenter
                                    text: homeGroup.names[parent.modelData]
                                    elide: Text.ElideRight
                                    font.pixelSize: Theme.fontCaption; color: Theme.textSecondary
                                }
                            }
                        }
                    }
                }
            }
            Button {
                objectName: "homeSectionsReset"
                text: qsTr("Reset")
                enabled: HomeLayout.format(homeGroup.sections) !== HomeLayout.names.join(",")
                onClicked: homeGroup.save(HomeLayout.parse(""))
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-tabs"
        title: qsTr("Tabs")
        note: qsTr("Vertical tabs list every tab beside the window, with full titles; the panel opens and closes from its button at the top left (") + Platform.keys("Ctrl+Shift+B") + ")."
        SettingsRow {
            objectName: "settingsRow-tabLayout"
            label: qsTr("Tab layout")
            TabBar {
                objectName: "tabLayout"
                currentIndex: Theme.verticalTabs ? 1 : 0
                TabButton { text: qsTr("Horizontal"); width: 96; onClicked: Theme.verticalTabs = false }
                TabButton { objectName: "verticalTabsOption"; text: qsTr("Vertical"); width: 96; onClicked: Theme.verticalTabs = true }
            }
        }
        // Windows and Linux: the bar above the tabs (Back, Forward, search, ≡). Off (the default), the window has one
        // row fewer: the search field is Home's (Ctrl+K elsewhere) and the buttons sit at the ends of the tab strip.
        // macOS has none to choose: there the bar is the title bar.
        SettingsRow {
            id: topBarRow
            objectName: "settingsRow-topBar"
            visible: Qt.platform.os !== "osx" || Qt.platform.pluginName !== "cocoa"
            property string choice: researchStore.setting("appearance.topBar")
            readonly property bool shown: choice.length ? choice === "show" : Qt.platform.os === "osx"
            Connections { target: researchStore; function onSettingsChanged() { topBarRow.choice = researchStore.setting("appearance.topBar") } }
            label: qsTr("Top bar")
            detail: Theme.verticalTabs ? qsTr("Back, Forward, search and the menu above the window. It stays with vertical tabs.")
                                       : qsTr("Back, Forward, search and the menu above the tabs. Off, search is on Home (%1 elsewhere).").arg(Platform.keys("Ctrl+K"))
            Switch {
                objectName: "topBarSwitch"
                checked: topBarRow.shown
                onToggled: researchStore.setSetting("appearance.topBar", checked ? "show" : "hide")
            }
        }
        // Control+Tab: through the tabs in order, or back and forth between the last two used.
        SettingsRow {
            objectName: "settingsRow-controlTab"
            label: Qt.platform.os === "osx" ? "\u2303Tab" : "Ctrl+Tab"
            TabBar {
                id: controlTabBar
                objectName: "controlTabMode"
                property string chosen: researchStore.setting("tabs.controlTab", "next")
                currentIndex: chosen === "recent" ? 1 : 0
                TabButton { text: qsTr("Next Tab"); width: 96; onClicked: { controlTabBar.chosen = "next"; researchStore.setSetting("tabs.controlTab", "next") } }
                TabButton { objectName: "controlTabRecent"; text: qsTr("Last Used"); width: 96; onClicked: { controlTabBar.chosen = "recent"; researchStore.setSetting("tabs.controlTab", "recent") } }
            }
        }
    }
    // Focus mode: only the pages and the side panels; the window full screen too unless turned off here.
    SettingsGroup {
        objectName: "settingsGroup-focus"
        title: qsTr("Focus mode")
        note: qsTr("Hides the bars above the pages; the side panels still open, from their keys or the window's edges, and the top edge brings a bar back for a moment. %1 turns it on and off.").arg(Platform.keys(Shortcuts.keys("focusMode", Shortcuts.parse(researchStore.setting("shortcuts")), Qt.platform.os)))
        SettingsRow {
            id: focusRow
            objectName: "settingsRow-focusFullScreen"
            property bool fullScreen: researchStore.setting("focus.fullScreen", "1") === "1"
            label: qsTr("Full screen")
            Switch {
                objectName: "focusFullScreen"
                checked: focusRow.fullScreen
                onToggled: { researchStore.setSetting("focus.fullScreen", checked ? "1" : "0"); focusRow.fullScreen = checked }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-language"
        title: qsTr("Language")
        // English as written, or every word spelled out in Hangul. The choices keep their own names.
        SettingsRow {
            objectName: "settingsRow-language"
            visible: typeof uiLanguage !== "undefined" && uiLanguage.available
            label: qsTr("Language")
            TabBar {
                objectName: "interfaceLanguage"
                currentIndex: typeof uiLanguage !== "undefined" && uiLanguage.language === "hangul" ? 1 : 0
                TabButton { text: "English"; width: 96; onClicked: uiLanguage.choose("en") }
                TabButton { objectName: "hangulOption"; text: "\ud55c\uae00"; width: 96; onClicked: uiLanguage.choose("hangul") }
            }
        }
    }
}
