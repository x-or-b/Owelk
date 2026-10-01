import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native

// App preferences. Values are stored locally in the settings table and apply immediately.
UiControls.Dialog {
    id: root
    objectName: "settingsDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(560, parent ? parent.width - 32 : 560)
    height: Math.min(620, parent ? parent.height - 32 : 620)
    title: "Settings"
    modal: true
    standardButtons: Dialog.Close
    readonly property var engines: [
        {name: "Google Scholar", template: "https://scholar.google.com/scholar?q=%s"},
        {name: "Google", template: "https://www.google.com/search?q=%s"},
        {name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"},
        {name: "arXiv", template: "https://arxiv.org/search/?query=%s&searchtype=all"}
    ]
    readonly property var languages: [{name: "Korean", value: "ko"}, {name: "English", value: "en"}, {name: "Same as source", value: "source"}]
    function refresh() {
        const folder = researchStore.setting("downloadFolder")
        folderField.text = folder.length ? folder : researchStore.downloadTarget("x").directory
        engineBox.currentIndex = Math.max(0, engines.findIndex(function(e) { return e.template === researchStore.setting("searchEngine", engines[0].template) }))
        languageBox.currentIndex = Math.max(0, languages.findIndex(function(l) { return l.value === researchStore.setting("aiLanguage", "ko") }))
    }
    onAboutToShow: refresh()
    Native.FolderDialog {
        id: folderDialog
        title: "Download folder for web PDFs"
        onAccepted: {
            const path = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
            if (researchStore.setSetting("downloadFolder", path)) root.refresh()
        }
    }
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ColumnLayout {
            id: sections
            width: parent.width
            spacing: 14
            Label { text: "Web"; font.bold: true; color: Theme.text }
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                Label { text: "PDF downloads"; color: Theme.textBody }
                RowLayout {
                    Layout.fillWidth: true
                    UiControls.TextField { id: folderField; objectName: "downloadFolderField"; Layout.fillWidth: true; readOnly: true }
                    UiControls.Button { text: "Choose…"; onClicked: folderDialog.open() }
                }
                Label { text: "Search with"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: engineBox; objectName: "searchEngineBox"
                    Layout.fillWidth: true
                    model: root.engines.map(function(e) { return e.name })
                    onActivated: function(index) { researchStore.setSetting("searchEngine", root.engines[index].template) }
                }
            }
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary
                text: "PDFs opened from web pages are saved here and open in the reader. Existing files are never overwritten."
            }
            Label { text: "AI"; font.bold: true; color: Theme.text }
            GridLayout {
                Layout.fillWidth: true
                columns: 2; columnSpacing: 10; rowSpacing: 8
                Label { text: "Answer language"; color: Theme.textBody }
                UiControls.ComboBox {
                    id: languageBox; objectName: "aiLanguageBox"
                    Layout.fillWidth: true
                    model: root.languages.map(function(l) { return l.name })
                    onActivated: function(index) { researchStore.setSetting("aiLanguage", root.languages[index].value) }
                }
            }
        }
    }
}
