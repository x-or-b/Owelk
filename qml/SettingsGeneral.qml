import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform

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
