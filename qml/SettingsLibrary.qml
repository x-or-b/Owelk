import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// Where the Library's PDFs live, what papers are called, and how long the Trash keeps things.
ColumnLayout {
    id: root
    objectName: "librarySettings"
    spacing: 22
    // Read again after a change here.
    property int revision: 0
    property bool keepPdfs: researchStore.setting("library.keepPdfs", "1") === "1"
    // Read again after copying or when papers change.
    readonly property int outside: researchStore.documentsRevision >= 0 && !researchStore.copyingPdfs ? researchStore.outsidePdfCount() : 0
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
    SettingsGroup {
        objectName: "settingsGroup-pdfFiles"
        title: qsTr("PDF files")
        note: qsTr("Like a note app, Owelk keeps its own copy of every PDF you open, add or download, in its data folder. The original files are never moved or deleted; you can remove them yourself.")
        SettingsRow {
            objectName: "settingsRow-keepPdfs"
            label: qsTr("Keep PDFs in Owelk")
            Switch {
                objectName: "keepPdfs"
                checked: root.keepPdfs
                onToggled: { researchStore.setSetting("library.keepPdfs", checked ? "1" : "0"); root.keepPdfs = checked }
            }
        }
        SettingsRow {
            visible: root.keepPdfs && (root.outside > 0 || researchStore.copyingPdfs)
            label: researchStore.copyingPdfs ? qsTr("Copying PDFs…") : root.outside + (root.outside === 1 ? qsTr(" paper still reads its PDF from elsewhere") : qsTr(" papers still read their PDFs from elsewhere"))
            detail: qsTr("Each copy is checked byte for byte before the paper uses it.")
            Button {
                objectName: "copyPdfsIn"
                text: qsTr("Copy Into Owelk")
                enabled: !researchStore.copyingPdfs
                onClicked: researchStore.copyPdfsIntoLibrary()
            }
        }
        SettingsRow {
            objectName: "settingsRow-pdfFolder"
            label: qsTr("PDF folder")
            Button { objectName: "showPapersFolder"; text: qsTr("Show Folder"); onClicked: Qt.openUrlExternally(researchStore.papersFolderUrl()) }
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
            objectName: "settingsRow-renamePdfs"
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
        objectName: "settingsGroup-trash"
        title: qsTr("Trash")
        SettingsRow {
            objectName: "settingsRow-trash"
            label: qsTr("Empty the Trash")
            detail: qsTr("Deleted papers, notes and AI conversations wait in Library › Trash until then")
            ComboBox {
                objectName: "trashDaysBox"
                Layout.preferredWidth: 160
                readonly property var days: [7, 30, 0]
                model: [qsTr("After 7 days"), qsTr("After 30 days"), qsTr("Never")]
                currentIndex: Math.max(0, days.indexOf(researchStore.trashDays()))
                onActivated: function(index) { researchStore.setSetting("trash.days", String(days[index])) }
            }
        }
    }
}
