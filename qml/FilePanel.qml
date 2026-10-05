import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Owelk.Ui

Item {
    id: root
    property url folder
    property var pending: ({})
    property var latestRequests: ({})
    property bool initialized: false
    property string status: ""
    signal folderChosen(url folder)
    signal documentChosen(url source)

    function load(url, parentUrl, depth) {
        const request = researchStore.listFolder(url)
        pending[request] = {parentUrl: parentUrl, depth: depth}
        latestRequests[parentUrl] = request
    }
    function refresh() {
        if (!rows) return
        rows.clear()
        pending = ({})
        latestRequests = ({})
        status = ""
        if (folder.toString().length) { status = "Loading…"; load(folder, "", 0) }
    }
    function toggle(index) {
        const row = rows.get(index)
        if (!row.directory) { documentChosen(row.url); return }
        if (row.expanded) {
            let count = 0
            while (index + count + 1 < rows.count && rows.get(index + count + 1).depth > row.depth) count++
            if (count) rows.remove(index + 1, count)
            rows.setProperty(index, "expanded", false)
        } else {
            rows.setProperty(index, "expanded", true)
            rows.setProperty(index, "loading", true)
            load(row.url, row.url, row.depth + 1)
        }
    }
    onFolderChanged: if (initialized) refresh()
    Component.onCompleted: { initialized = true; refresh() }
    ListModel { id: rows }
    Connections {
        target: researchStore
        function onFolderLoaded(requestId, folder, entries, error) {
            const request = root.pending[requestId]
            if (!request) return
            delete root.pending[requestId]
            if (root.latestRequests[request.parentUrl] !== requestId) return
            let insertAt = 0
            if (request.parentUrl.length) {
                let parentIndex = -1
                for (let i = 0; i < rows.count; ++i) {
                    if (rows.get(i).url === request.parentUrl) { parentIndex = i; break }
                }
                if (parentIndex < 0) return
                rows.setProperty(parentIndex, "loading", false)
                if (!rows.get(parentIndex).expanded) return
                insertAt = parentIndex + 1
                if (error.length) rows.setProperty(parentIndex, "expanded", false)
            }
            root.status = error
            for (let i = 0; i < entries.length; ++i) {
                rows.insert(insertAt + i, {name: entries[i].name, url: entries[i].url,
                    directory: entries[i].directory, depth: request.depth, expanded: false, loading: false})
            }
            if (!rows.count && !error.length) root.status = "No PDFs or subfolders."
        }
    }
    FolderDialog { id: folderDialog; title: "Open paper folder"; onAccepted: root.folderChosen(selectedFolder) }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            UiControls.Button { text: "Open folder…"; onClicked: folderDialog.open() }
            Item { Layout.fillWidth: true }
            UiControls.ToolButton { text: "↻"; enabled: root.folder.toString().length > 0; onClicked: root.refresh(); Accessible.name: "Refresh folder" }
        }
        Label {
            Layout.fillWidth: true
            text: root.folder.toString().length ? researchStore.fileName(root.folder) : "Recent files"
            elide: Text.ElideMiddle
            font.bold: true
            ToolTip.visible: folderHover.hovered
            ToolTip.text: root.folder.toString()
            HoverHandler { id: folderHover }
        }
        Label { Layout.fillWidth: true; visible: root.status.length > 0; text: root.status; wrapMode: Text.Wrap; color: Theme.textTertiary }
        ListView {
            objectName: "folderTree"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.folder.toString().length > 0
            model: rows
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: UiControls.ItemDelegate {
                required property int index
                required property string name
                required property string url
                required property bool directory
                required property bool expanded
                required property bool loading
                required property int depth
                width: ListView.view.width
                height: 28
                leftPadding: 6 + depth * 14
                text: (loading ? "… " : directory ? (expanded ? "▾ " : "▸ ") : "  ") + name
                onClicked: root.toggle(index)
                ToolTip.visible: hovered
                ToolTip.text: url
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.folder.toString().length
            model: researchStore.recentDocuments
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: RecentPaperDelegate {
                width: ListView.view.width
                height: 30
                onDocumentChosen: function(source, position) { root.documentChosen(source) }
            }
        }
    }
}
