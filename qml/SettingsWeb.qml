import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform
import "WebSearch.js" as WebSearch

ColumnLayout {
    id: root
    spacing: 22
    // Read again after a change here (Settings › Web keeps them in the settings table).
    property int revision: 0
    readonly property var engines: (revision, WebSearch.all(researchStore))
    readonly property string defaultEngine: (revision, WebSearch.template(researchStore))
    readonly property bool keepsPdfs: researchStore.setting("library.keepPdfs", "1") === "1"
    function folder() { const f = researchStore.setting("downloadFolder"); return f.length ? f : researchStore.downloadTarget("x").directory }
    Native.FolderDialog {
        id: folderDialog
        title: qsTr("Download folder for web PDFs")
        onAccepted: if (researchStore.setSetting("downloadFolder", researchStore.localPath(selectedFolder))) folderField.text = root.folder()
    }
    SettingsGroup {
        title: qsTr("PDFs")
        note: (root.keepsPdfs ? qsTr("Downloaded PDFs go to Owelk's own PDF folder (Settings › Data); other files go to the folder above. ") : "")
            + qsTr("A downloaded PDF is named after its paper when its first page shows the title; files already in the Library keep their names. Existing files are never overwritten. In a web tab, Show Here reads a PDF in place; Open in Reader sends it to the reader, where annotations and notes work.")
        SettingsRow {
            label: root.keepsPdfs ? qsTr("Other downloads to") : qsTr("Download to")
            wide: true
            TextField { id: folderField; objectName: "downloadFolderField"; Layout.fillWidth: true; readOnly: true; text: root.folder() }
            IconButton { icon.name: "open"; description: qsTr("Choose a folder…"); onClicked: folderDialog.open() }
        }
        SettingsRow {
            label: qsTr("Name PDFs")
            ComboBox {
                objectName: "webPdfNamesBox"
                Layout.preferredWidth: 260
                model: [qsTr("Paper title"), qsTr("Name from the website")]
                currentIndex: researchStore.setting("web.pdfNames", "title") === "original" ? 1 : 0
                onActivated: function(index) { researchStore.setSetting("web.pdfNames", index === 1 ? "original" : "title") }
            }
        }
        // PDFs added or opened from elsewhere keep their file names in Owelk's folder until renamed here.
        SettingsRow {
            label: qsTr("Kept PDFs")
            detail: qsTr("Rename Owelk's copies after their paper titles, as downloads are. Files outside Owelk's folder are never renamed.")
            Button {
                objectName: "renameKeptPdfs"
                text: qsTr("Rename to Titles")
                onClicked: researchStore.renamePapersToTitles(researchStore.libraryDocuments({}).map(function(d) { return d.url }))
            }
        }
        SettingsRow {
            label: qsTr("PDF links")
            ComboBox {
                objectName: "webPdfModeBox"
                Layout.preferredWidth: 260
                model: [qsTr("Download and open in the reader"), qsTr("Show in the web tab")]
                currentIndex: researchStore.setting("webPdfMode", "reader") === "browser" ? 1 : 0
                onActivated: function(index) { researchStore.setSetting("webPdfMode", index === 1 ? "browser" : "reader") }
            }
        }
    }
    SettingsGroup {
        title: qsTr("Search engines")
        note: qsTr("Words typed in an address bar or on Home search with the default engine; Home has a button for each. Add your own with its search address, %s standing for the words. ")
            + Platform.keys("Ctrl+L") + qsTr(" opens the default engine's page when no web tab is in front.")
        Repeater {
            model: root.engines
            delegate: SettingsRow {
                required property var modelData
                label: modelData.name
                detail: modelData.template
                RadioButton {
                    objectName: "defaultEngine-" + modelData.name
                    text: qsTr("Default")
                    checked: root.defaultEngine === modelData.template
                    onClicked: { WebSearch.setDefault(researchStore, modelData.template); root.revision++ }
                }
                IconButton {
                    visible: !WebSearch.isBuiltIn(modelData.template)
                    objectName: "removeEngine-" + modelData.name
                    icon.name: "trash"; description: qsTr("Remove")
                    onClicked: { WebSearch.remove(researchStore, modelData.template); root.revision++ }
                }
            }
        }
        SettingsRow {
            wide: true
            TextField { id: engineName; objectName: "engineNameField"; Layout.preferredWidth: 140; placeholderText: qsTr("Name") }
            TextField {
                id: engineAddress
                objectName: "engineAddressField"
                Layout.fillWidth: true
                placeholderText: "https://example.org/search?q=%s"
                onAccepted: addEngine.clicked()
            }
            Button {
                id: addEngine
                objectName: "addEngine"
                text: qsTr("Add")
                enabled: engineName.text.trim().length > 0 && engineAddress.text.indexOf("%s") >= 0
                onClicked: {
                    if (WebSearch.add(researchStore, engineName.text, engineAddress.text)) { engineName.clear(); engineAddress.clear(); root.revision++ }
                    else researchStore.notify(qsTr("Use a web address with %s where the words go, not one already listed."))
                }
            }
        }
    }
}
