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
    // File names from paper details: every part in its order, on or off ("author,year,title,-arxiv").
    readonly property var nameKeys: ["title", "author", "year", "arxiv"]
    readonly property var nameLabels: ({title: qsTr("Title"), author: qsTr("First author"), year: qsTr("Year"), arxiv: qsTr("arXiv ID")})
    readonly property var nameParts: {
        revision
        const list = researchStore.setting("pdfNames.parts", "title").split(",").filter(function(p) { return p.length })
            .map(function(p) { return {key: p.replace(/^-/, ""), on: p[0] !== "-"} })
            .filter(function(p) { return root.nameKeys.indexOf(p.key) >= 0 })
        root.nameKeys.forEach(function(k) { if (!list.some(function(p) { return p.key === k })) list.push({key: k, on: false}) })
        // Nothing on (or nothing saved): the title, as before.
        if (!list.some(function(p) { return p.on })) list.find(function(p) { return p.key === "title" }).on = true
        return list
    }
    readonly property var namesOn: nameParts.filter(function(p) { return p.on }).map(function(p) { return p.key })
    function saveNames(list) {
        researchStore.setSetting("pdfNames.parts", list.map(function(p) { return (p.on ? "" : "-") + p.key }).join(","))
        revision++
    }
    function moveName(index, step) {
        const list = nameParts.slice(), to = index + step
        if (to < 0 || to >= list.length) return
        const item = list.splice(index, 1)[0]
        list.splice(to, 0, item)
        saveNames(list)
    }
    function switchName(index, on) {
        const list = nameParts.map(function(p) { return {key: p.key, on: p.on} })
        list[index].on = on
        saveNames(list)
    }
    function folder() { const f = researchStore.setting("downloadFolder"); return f.length ? f : researchStore.downloadTarget("x").directory }
    Native.FolderDialog {
        id: folderDialog
        title: qsTr("Download folder for web PDFs")
        onAccepted: if (researchStore.setSetting("downloadFolder", researchStore.localPath(selectedFolder))) folderField.text = root.folder()
    }
    SettingsGroup {
        title: qsTr("PDFs")
        note: (root.keepsPdfs ? qsTr("Downloaded PDFs go to Owelk's own PDF folder (Settings › Data); other files go to the folder above. ") : "")
            + qsTr("A downloaded PDF is named from its paper (Paper names below) when its first page shows the title; files already in the Library keep their names. Existing files are never overwritten. In a web tab, Show Here reads a PDF in place; Open in Reader sends it to the reader, where annotations and notes work.")
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
                model: [qsTr("From the paper"), qsTr("Name from the website")]
                currentIndex: researchStore.setting("web.pdfNames", "title") === "original" ? 1 : 0
                onActivated: function(index) { researchStore.setSetting("web.pdfNames", index === 1 ? "original" : "title") }
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
    // Which paper details make a paper's name (shown in Owelk and given to its file), in which order.
    SettingsGroup {
        objectName: "pdfNameGroup"
        title: qsTr("Paper names")
        note: qsTr("Example: ") + researchStore.sampleFileName(root.namesOn).replace(/\.pdf$/, "")
            + qsTr(". Owelk shows papers by this name (Library, tabs, search); downloads and Rename Now name their files the same way.")
        Repeater {
            model: root.nameParts
            delegate: SettingsRow {
                id: partRow
                required property var modelData
                required property int index
                objectName: "pdfNamePart-" + modelData.key
                label: root.nameLabels[modelData.key]
                opacity: modelData.on ? 1 : .55
                IconButton {
                    objectName: "pdfNameUp-" + partRow.modelData.key
                    icon.name: "up"; description: qsTr("Move up")
                    enabled: partRow.index > 0
                    onClicked: root.moveName(partRow.index, -1)
                }
                IconButton {
                    objectName: "pdfNameDown-" + partRow.modelData.key
                    icon.name: "down"; description: qsTr("Move down")
                    enabled: partRow.index < root.nameParts.length - 1
                    onClicked: root.moveName(partRow.index, 1)
                }
                Switch {
                    objectName: "pdfNameSwitch-" + partRow.modelData.key
                    checked: partRow.modelData.on
                    // One part stays on.
                    enabled: !(partRow.modelData.on && root.namesOn.length === 1)
                    onToggled: root.switchName(partRow.index, checked)
                }
            }
        }
        // PDFs added or opened from elsewhere keep their file names in Owelk's folder until renamed here.
        SettingsRow {
            label: qsTr("Kept PDFs")
            detail: qsTr("Rename Owelk's copies the same way. Files outside Owelk's folder are never renamed.")
            Button {
                objectName: "renameKeptPdfs"
                text: qsTr("Rename Now")
                onClicked: researchStore.renamePapersToTitles(researchStore.libraryDocuments({}).map(function(d) { return d.url }))
            }
        }
    }
    SettingsGroup {
        title: qsTr("Search engines")
        note: qsTr("The search box (") + Platform.keys("Ctrl+K") + qsTr(", Home) offers the engines shown here and starts on the default one. ")
            + Platform.keys("Ctrl+L") + qsTr(" opens the default engine's page when no web tab is in front.")
        Repeater {
            model: root.engines
            delegate: SettingsRow {
                id: engineRow
                required property var modelData
                readonly property bool isDefault: root.defaultEngine === modelData.template
                readonly property bool isHidden: (root.revision, WebSearch.hidden(researchStore).indexOf(modelData.template) >= 0) && !isDefault
                label: modelData.name
                detail: modelData.template
                opacity: isHidden ? .55 : 1
                // Small and quiet; the default one is filled with the accent.
                AbstractButton {
                    objectName: "defaultEngine-" + engineRow.modelData.name
                    implicitWidth: defaultLabel.implicitWidth + 14; implicitHeight: Theme.controlHeightSmall - 4
                    checkable: true
                    checked: engineRow.isDefault
                    hoverEnabled: true
                    background: Rectangle {
                        radius: height / 2
                        color: engineRow.isDefault ? Theme.accent : parent.hovered ? Theme.hover : "transparent"
                        border.color: engineRow.isDefault ? Theme.accent : Theme.border
                    }
                    contentItem: Label {
                        id: defaultLabel
                        text: qsTr("Default")
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        font.pixelSize: Theme.fontCaption
                        color: engineRow.isDefault ? Theme.onAccent : Theme.textSecondary
                    }
                    onClicked: { WebSearch.setDefault(researchStore, engineRow.modelData.template); root.revision++ }
                }
                IconButton {
                    objectName: "showEngine-" + engineRow.modelData.name
                    enabled: !engineRow.isDefault
                    icon.name: engineRow.isHidden ? "hidden" : "preview"
                    tint: engineRow.isHidden ? Theme.textDisabled : Theme.icon
                    description: engineRow.isDefault ? qsTr("The default engine is always shown") : engineRow.isHidden ? qsTr("Show in the search box") : qsTr("Hide from the search box")
                    onClicked: { WebSearch.setHidden(researchStore, engineRow.modelData.template, !engineRow.isHidden); root.revision++ }
                }
                IconButton {
                    visible: !WebSearch.isBuiltIn(engineRow.modelData.template)
                    objectName: "removeEngine-" + engineRow.modelData.name
                    icon.name: "trash"; description: qsTr("Remove")
                    onClicked: { WebSearch.remove(researchStore, engineRow.modelData.template); root.revision++ }
                }
            }
        }
        // A site is enough ("google.com"); its search address is filled in.
        SettingsRow {
            wide: true
            detail: engineAddress.text.trim().length ? (root.typedTemplate.length ? "\u2192 " + root.typedTemplate : qsTr("Type a site such as google.com, or an address with %s for the words.")) : ""
            TextField {
                id: engineAddress
                objectName: "engineAddressField"
                Layout.fillWidth: true
                placeholderText: qsTr("Add a site (google.com) or an address with %s")
                onAccepted: addEngine.clicked()
            }
            TextField { id: engineName; objectName: "engineNameField"; Layout.preferredWidth: 130; placeholderText: root.typedName.length ? root.typedName : qsTr("Name") }
            Button {
                id: addEngine
                objectName: "addEngine"
                text: qsTr("Add")
                enabled: root.typedTemplate.length > 0
                onClicked: {
                    const name = engineName.text.trim().length ? engineName.text : root.typedName
                    if (WebSearch.add(researchStore, name, root.typedTemplate)) { engineName.clear(); engineAddress.clear(); root.revision++ }
                    else researchStore.notify(qsTr("That engine is already listed."))
                }
            }
        }
    }
    readonly property string typedTemplate: WebSearch.templateFor(engineAddress.text)
    readonly property string typedName: WebSearch.nameFor(engineAddress.text)
}
