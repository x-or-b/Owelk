import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    visible: true
    width: 1440; height: 930
    minimumWidth: 880; minimumHeight: 580
    title: ""
    color: "#eeeeee"
    font.family: Qt.platform.os === "osx" ? ".AppleSystemUIFont" : "sans-serif"
    font.pixelSize: 13
    palette.window: "#fafafa"
    palette.windowText: "#242424"
    palette.highlight: "#555555"
    palette.highlightedText: "white"
    palette.button: "#eeeeee"
    palette.buttonText: "#333333"
    palette.text: "#242424"
    palette.base: "#ffffff"
    palette.alternateBase: "#f5f5f5"
    palette.light: "#ffffff"
    palette.midlight: "#eeeeee"
    palette.mid: "#c5c5c5"
    palette.dark: "#888888"
    palette.shadow: "#555555"
    palette.placeholderText: "#777777"
    property bool shelfVisible: true
    property bool filesVisible: true
    property string filesSide: "left"
    property string capturesSide: "right"
    property url paperFolder
    property bool homeVisible: true
    property string activeWorkspace: ""
    property string workspaceName: ""
    readonly property var leftPanels: panelsForSide("left")
    readonly property var rightPanels: panelsForSide("right")
    property bool initialized: false
    property bool restoreFailed: false
    property string notification: ""
    property alias documents: documents
    readonly property var currentReader: documents.currentReader

    function panelsForSide(side) {
        const panels = []
        if (filesVisible && filesSide === side) panels.push("files")
        if (shelfVisible && capturesSide === side) panels.push("captures")
        return panels
    }
    function togglePanel(panel) {
        const side = panel === "files" ? filesSide : capturesSide
        const dock = side === "left" ? leftDock : rightDock
        const shown = panel === "files" ? filesVisible : shelfVisible
        if (shown && dock.activePanel === panel) {
            if (panel === "files") filesVisible = false; else shelfVisible = false
        } else {
            if (panel === "files") filesVisible = true; else shelfVisible = true
            movePanel(panel, side)
        }
    }
    function movePanel(panel, side) {
        if (side !== "left" && side !== "right") return
        if (panel === "files") filesSide = side
        if (panel === "captures") capturesSide = side
        Qt.callLater(function() { (side === "left" ? leftDock : rightDock).activePanel = panel })
    }
    function showHome() { persist(); homeVisible = true; Qt.callLater(function() { homeView.focusSearch() }) }
    function openDocument(source, position) { if (!restoreFailed) documents.openDocument(source, position) }
    function openWorkspace(id) {
        if (restoreFailed || !persist()) return
        const state = researchStore.loadWorkspace(id)
        if (!state.workspace) return
        saveTimer.stop(); initialized = false
        try { documents.restore(state) }
        catch (error) { initialized = true; notify(error.message); return }
        activeWorkspace = state.workspace; workspaceName = state.workspaceName || ""
        paperFolder = state.panels ? state.panels.folder || "" : ""
        homeVisible = !documents.currentReader || !documents.currentReader.source.toString().length
        initialized = true; persist()
    }
    function persist() {
        if (!initialized || restoreFailed) return false
        const state = documents.snapshot()
        Object.assign(state, {shelf: shelfVisible, workspace: activeWorkspace, workspaceName: workspaceName,
            width: width, height: height, panels: {filesVisible: filesVisible, filesSide: filesSide, capturesSide: capturesSide,
                folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel}})
        return researchStore.saveWorkspace(activeWorkspace, state) && researchStore.saveSession(state)
    }
    function scheduleSave() { if (initialized && !restoreFailed) saveTimer.restart() }
    function notify(text) { notification = text; notificationTimer.restart() }
    function chooseFile() { if (!restoreFailed) fileDialog.open() }

    Component.onCompleted: {
        const state = researchStore.session
        if (state.width) width = Math.max(minimumWidth, Math.min(Screen.width, state.width))
        if (state.height) height = Math.max(minimumHeight, Math.min(Screen.height, state.height))
        shelfVisible = state.shelf === undefined ? true : state.shelf
        const panels = state.panels || {}
        filesVisible = panels.filesVisible === undefined ? true : panels.filesVisible
        filesSide = panels.filesSide === "right" ? "right" : "left"
        capturesSide = panels.capturesSide === "left" ? "left" : "right"
        paperFolder = panels.folder || ""
        if (leftPanels.indexOf(panels.leftActive) >= 0) leftDock.activePanel = panels.leftActive
        if (rightPanels.indexOf(panels.rightActive) >= 0) rightDock.activePanel = panels.rightActive
        activeWorkspace = state.workspace || ""; workspaceName = state.workspaceName || ""
        try { documents.restore(state) }
        catch (error) { restoreFailed = true; notification = error.message }
        initialized = true
        if (!restoreFailed) for (let i = 0; i < initialFiles.length; ++i) documents.openDocument(initialFiles[i])
        homeVisible = true
        if (!restoreFailed) persist()
    }
    onClosing: function(close) {
        if (researchStore.busy) { close.accepted = false; notify("Saving capture. Please close the window after saving finishes.") }
        else if (initialized && !restoreFailed && !persist()) { close.accepted = false; notify("Cannot save the session. Check storage and try again.") }
    }
    onWidthChanged: scheduleSave()
    onHeightChanged: scheduleSave()
    onShelfVisibleChanged: scheduleSave()
    onFilesVisibleChanged: scheduleSave()
    onFilesSideChanged: scheduleSave()
    onCapturesSideChanged: scheduleSave()
    onPaperFolderChanged: scheduleSave()
    Timer { id: saveTimer; interval: 500; onTriggered: window.persist() }
    Timer { id: notificationTimer; interval: 6500; onTriggered: if (!window.restoreFailed) window.notification = "" }
    Native.FileDialog { id: fileDialog; title: "Open PDF"; nameFilters: ["PDF documents (*.pdf)"]; onAccepted: window.openDocument(selectedFile) }
    Connections {
        target: researchStore
        function onMessage(text) { window.notify(text) }
        function onCaptureSaved(id) { window.shelfVisible = true; window.movePanel("captures", window.capturesSide) }
        function onSourceReady(url, page, region) { if (!window.restoreFailed) { documents.reveal(url, page, region); window.homeVisible = false } }
    }
    CommandPalette {
        id: commandPalette
        parent: Overlay.overlay
        recentDocuments: researchStore.recentDocuments
        onDocumentChosen: function(source) { window.openDocument(source) }
        onCommandChosen: function(command) {
            switch (command) {
            case "/home": window.showHome(); break
            case "/open paper": window.chooseFile(); break
            case "/find": if (window.homeVisible) homeView.focusSearch(); else if (window.currentReader) window.currentReader.find(); break
            case "/split right": documents.duplicateSplit("right"); break
            case "/split down": documents.duplicateSplit("bottom"); break
            case "/split off": documents.joinAll(); break
            case "/capture": if (!window.homeVisible && window.currentReader) window.currentReader.toggleCapture(); break
            case "/files": window.filesVisible = true; window.movePanel("files", window.filesSide); break
            case "/captures": window.shelfVisible = true; window.movePanel("captures", window.capturesSide); break
            }
        }
    }
    menuBar: MenuBar {
        Menu {
            title: "File"
            Action { text: "Open PDF…"; shortcut: StandardKey.Open; onTriggered: window.chooseFile() }
            Action { objectName: "closeTabAction"; text: "Close Tab"; shortcut: "Ctrl+W"; enabled: !window.homeVisible && !window.restoreFailed; onTriggered: documents.closeActiveTab() }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: StandardKey.Quit; onTriggered: window.close() }
        }
        Menu {
            title: "View"
            Action { text: "Home"; shortcut: "Ctrl+Shift+H"; onTriggered: window.showHome() }
            Action { text: "Command palette"; shortcut: "Ctrl+K"; onTriggered: commandPalette.open() }
            Action { text: "Find"; shortcut: StandardKey.Find; onTriggered: { if (window.homeVisible) homeView.focusSearch(); else if (window.currentReader) window.currentReader.find() } }
            Action { text: "Zoom in"; shortcut: StandardKey.ZoomIn; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1.2) }
            Action { text: "Zoom out"; shortcut: StandardKey.ZoomOut; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1 / 1.2) }
            Action { text: "Capture region"; shortcut: "Ctrl+Shift+C"; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.toggleCapture() }
            MenuSeparator {}
            Action { text: "Duplicate to Right Split"; enabled: !window.homeVisible; onTriggered: documents.duplicateSplit("right") }
            Action { text: "Duplicate to Bottom Split"; enabled: !window.homeVisible; onTriggered: documents.duplicateSplit("bottom") }
            Action { text: "Join All Groups"; enabled: !window.homeVisible; onTriggered: documents.joinAll() }
        }
    }
    RowLayout {
        anchors.fill: parent
        spacing: 1
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"; panels: window.leftPanels; folder: window.paperFolder
            visible: panels.length > 0
            Layout.preferredWidth: 224; Layout.fillHeight: true
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            onActivePanelChanged: window.scheduleSave()
        }
        HomeView {
            id: homeView
            visible: window.homeVisible
            Layout.fillWidth: true; Layout.fillHeight: true
            onOpenRequested: window.chooseFile()
            onDocumentChosen: function(source, position) { window.openDocument(source, position) }
            onWorkspaceChosen: function(id) { window.openWorkspace(id) }
            onWorkspaceCreated: function(name) { if (!window.restoreFailed) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) } }
            onResultChosen: function(result) {
                if (result.kind === "paper") window.openDocument(result.source, result.position)
                else if (result.kind === "capture") researchStore.openCapture(result.id)
                else if (result.kind === "workspace") window.openWorkspace(result.id)
            }
        }
        DocumentWorkspace {
            id: documents
            visible: !window.homeVisible
            suspended: window.homeVisible
            enabled: !window.restoreFailed
            Layout.fillWidth: true; Layout.fillHeight: true
            onBeforeChange: window.persist()
            onChanged: window.scheduleSave()
            onEmpty: window.showHome()
            onOpened: window.homeVisible = false
        }
        DockSidebar {
            id: rightDock
            objectName: "rightDock"
            side: "right"; panels: window.rightPanels; folder: window.paperFolder
            visible: panels.length > 0
            Layout.preferredWidth: 224; Layout.fillHeight: true
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            onActivePanelChanged: window.scheduleSave()
        }
    }
    footer: Rectangle {
        id: statusBar
        objectName: "statusBar"
        height: 29
        color: "#fafafa"
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4; anchors.rightMargin: 4
            spacing: 2
            Repeater {
                model: ["files", "captures"].filter(function(p) { return (p === "files" ? window.filesSide : window.capturesSide) === "left" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData; dockSide: "left"
                    description: (kind === "files" ? "Files" : "Captures") + " · Right-click to change dock"
                    selected: kind === "files" ? window.filesVisible : window.shelfVisible
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
            Label {
                Layout.fillWidth: true
                text: window.notification.length ? window.notification : researchStore.busy ? "Saving capture…" : window.workspaceName.length ? window.workspaceName : "Local workspace"
                elide: Text.ElideRight; font.pixelSize: 11; color: "#666666"
            }
            StatusIcon { kind: "search"; description: "Command palette · Ctrl/Cmd+K"; onTriggered: commandPalette.open() }
            StatusIcon { kind: "split"; description: "Duplicate tab to right split"; visible: !window.homeVisible; selected: documents.groupCount > 1; onTriggered: documents.duplicateSplit("right") }
            Repeater {
                model: ["files", "captures"].filter(function(p) { return (p === "files" ? window.filesSide : window.capturesSide) === "right" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData; dockSide: "right"
                    description: (kind === "files" ? "Files" : "Captures") + " · Right-click to change dock"
                    selected: kind === "files" ? window.filesVisible : window.shelfVisible
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
        }
    }
}
