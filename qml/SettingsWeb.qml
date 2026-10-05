import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform

ColumnLayout {
    id: root
    spacing: 22
    readonly property var engines: [
        {name: "Google Scholar", template: "https://scholar.google.com/scholar?q=%s"},
        {name: "Google", template: "https://www.google.com/search?q=%s"},
        {name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"},
        {name: "arXiv", template: "https://arxiv.org/search/?query=%s&searchtype=all"}
    ]
    function folder() { const f = researchStore.setting("downloadFolder"); return f.length ? f : researchStore.downloadTarget("x").directory }
    Native.FolderDialog {
        id: folderDialog
        title: "Download folder for web PDFs"
        onAccepted: if (researchStore.setSetting("downloadFolder", researchStore.localPath(selectedFolder))) folderField.text = root.folder()
    }
    SettingsGroup {
        title: "PDFs"
        note: "Existing files are never overwritten. In a web tab, Show Here reads a PDF in place; Open in Reader sends it to the reader, where highlights, captures and notes work."
        SettingsRow {
            label: "Download to"
            wide: true
            TextField { id: folderField; objectName: "downloadFolderField"; Layout.fillWidth: true; readOnly: true; text: root.folder() }
            IconButton { icon.name: "open"; description: "Choose a folder…"; onClicked: folderDialog.open() }
        }
        SettingsRow {
            label: "PDF links"
            ComboBox {
                objectName: "webPdfModeBox"
                Layout.preferredWidth: 260
                model: ["Download and open in the reader", "Show in the web tab"]
                currentIndex: researchStore.setting("webPdfMode", "reader") === "browser" ? 1 : 0
                onActivated: function(index) { researchStore.setSetting("webPdfMode", index === 1 ? "browser" : "reader") }
            }
        }
    }
    SettingsGroup {
        title: "Browsing"
        note: "The start page opens with " + Platform.keys("Ctrl+L") + " when no web tab is in front."
        SettingsRow {
            label: "Search with"
            ComboBox {
                objectName: "searchEngineBox"
                Layout.preferredWidth: 200
                model: root.engines.map(function(e) { return e.name })
                currentIndex: Math.max(0, root.engines.findIndex(function(e) { return e.template === researchStore.setting("searchEngine", root.engines[0].template) }))
                onActivated: function(index) { researchStore.setSetting("searchEngine", root.engines[index].template) }
            }
        }
        SettingsRow {
            label: "Start page"
            wide: true
            TextField {
                objectName: "startPageField"
                Layout.fillWidth: true
                text: researchStore.setting("startPage")
                placeholderText: "https://scholar.google.com/"
                onEditingFinished: researchStore.setSetting("startPage", text.trim())
            }
        }
    }
}
