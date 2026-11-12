import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Shortcuts.js" as Shortcuts
import "Platform.js" as Platform

// Reading a paper: how its pages look, focus mode, and what pointing at a symbol shows.
ColumnLayout {
    id: root
    objectName: "readingSettings"
    spacing: 22
    SettingsGroup {
        visible: Theme.canInvertPages
        objectName: "settingsGroup-pdfPages"
        title: qsTr("PDF pages")
        note: qsTr("Dark pages invert lightness and keep hues, so figures stay recognizable. Exports and printing use the original colors.")
        SettingsRow {
            objectName: "settingsRow-darkPages"
            label: qsTr("Dark pages")
            Switch { objectName: "invertPagesSwitch"; checked: Theme.invertPages; onToggled: Theme.invertPages = checked }
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
        objectName: "settingsGroup-symbols"
        title: qsTr("Symbols")
        SettingsRow {
            objectName: "settingsRow-symbolHints"
            label: qsTr("Symbol hints")
            detail: qsTr("Once a paper's symbols are listed (Document panel › Symbols), pointing at one shows its meaning")
            Switch {
                objectName: "aiSymbolHints"
                checked: researchStore.setting("ai.symbolHints", "1") === "1"
                onToggled: researchStore.setSetting("ai.symbolHints", checked ? "1" : "0")
            }
        }
    }
}
