import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    visible: true
    width: 1440
    height: 930
    minimumWidth: Math.max(880, 680 + (leftPanels.length ? 224 : 0) + (rightPanels.length ? 224 : 0))
    minimumHeight: 580
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
    property int activePane: 0
    property bool splitEnabled: true
    property bool shelfVisible: true
    property bool filesVisible: true
    property string filesSide: "left"
    property string capturesSide: "right"
    property url paperFolder
    property bool homeVisible: true
    property string activeWorkspace: ""
    property string workspaceName: ""
    property string draggingPanel: ""
    property string dragSide: ""
    readonly property var leftPanels: panelsForSide("left")
    readonly property var rightPanels: panelsForSide("right")
    property bool initialized: false
    property string notification: ""
    readonly property var currentReader: activePane === 1 && splitEnabled ? rightReader : leftReader

    function panelsForSide(side) {
        const panels = []
        if (filesVisible && filesSide === side) panels.push("files")
        if (shelfVisible && capturesSide === side) panels.push("captures")
        return panels
    }
    function closePanel(panel) {
        if (panel === "files") filesVisible = false
        if (panel === "captures") shelfVisible = false
    }
    function togglePanel(panel) {
        const side = panel === "files" ? filesSide : capturesSide
        const dock = side === "left" ? leftDock : rightDock
        const shown = panel === "files" ? filesVisible : shelfVisible
        if (shown && dock.activePanel === panel) closePanel(panel)
        else {
            if (panel === "files") filesVisible = true
            else shelfVisible = true
            movePanel(panel, side)
        }
    }
    function movePanel(panel, side) {
        if (side !== "left" && side !== "right") return
        if (panel === "files") filesSide = side
        if (panel === "captures") capturesSide = side
        Qt.callLater(function() { (side === "left" ? leftDock : rightDock).activePanel = panel })
    }
    function footerSide(x, y) {
        const origin = statusBar.mapToItem(null, 0, 0)
        if (x < origin.x || x > origin.x + statusBar.width || y < origin.y || y > origin.y + statusBar.height) return ""
        return x < width / 2 ? "left" : "right"
    }
    function dragPanel(panel, x, y) { draggingPanel = panel; dragSide = footerSide(x, y) }
    function dropPanel(panel, x, y, cancelled) {
        const side = footerSide(x, y)
        draggingPanel = ""
        dragSide = ""
        if (!cancelled && side.length) Qt.callLater(function() { window.movePanel(panel, side) })
    }
    function showHome() {
        persist()
        homeVisible = true
        Qt.callLater(function() { homeView.focusSearch() })
    }
    function openDocument(source, position) {
        if (currentReader.openFile(source, position)) homeVisible = false
    }
    function openWorkspace(id) {
        persist()
        const state = researchStore.loadWorkspace(id)
        if (!state.workspace) return
        saveTimer.stop()
        initialized = false
        activeWorkspace = state.workspace
        workspaceName = state.workspaceName || ""
        activePane = state.active || 0
        splitEnabled = !!state.split
        paperFolder = state.panels ? state.panels.folder || "" : ""
        leftReader.restore(state.left)
        rightReader.restore(state.right)
        homeVisible = !(state.left && state.left.source) && !(state.right && state.right.source)
        initialized = true
        persist()
    }

    function persist() {
        if (!initialized) return
        const state = {version: 1, left: leftReader.state(), right: rightReader.state(),
                       split: splitEnabled, shelf: shelfVisible, active: activePane, home: homeVisible,
                       workspace: activeWorkspace, workspaceName: workspaceName,
                       width: width, height: height, leftWidth: leftReader.width,
                       panels: {filesVisible: filesVisible, filesSide: filesSide, capturesSide: capturesSide,
                           folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel}}
        researchStore.saveWorkspace(activeWorkspace, state)
        researchStore.saveSession(state)
    }
    function scheduleSave() { if (initialized) saveTimer.restart() }
    function notify(text) { notification = text; notificationTimer.restart() }

    Component.onCompleted: {
        const state = researchStore.session
        if (state.width) width = Math.max(minimumWidth, Math.min(Screen.width, state.width))
        if (state.height) height = Math.max(minimumHeight, Math.min(Screen.height, state.height))
        splitEnabled = state.split === undefined ? true : state.split
        shelfVisible = state.shelf === undefined ? true : state.shelf
        const panels = state.panels || {}
        filesVisible = panels.filesVisible === undefined ? true : panels.filesVisible
        filesSide = panels.filesSide === "right" ? "right" : "left"
        capturesSide = panels.capturesSide === "left" ? "left" : "right"
        paperFolder = panels.folder || ""
        if (leftPanels.indexOf(panels.leftActive) >= 0) leftDock.activePanel = panels.leftActive
        if (rightPanels.indexOf(panels.rightActive) >= 0) rightDock.activePanel = panels.rightActive
        activePane = state.active || 0
        activeWorkspace = state.workspace || ""
        workspaceName = state.workspaceName || ""
        homeVisible = state.home === true || (!(state.left && state.left.source) && !(state.right && state.right.source))
        if (state.leftWidth) leftReader.SplitView.preferredWidth = state.leftWidth
        leftReader.restore(state.left)
        rightReader.restore(state.right)
        initialized = true
        if (initialFiles.length > 0) leftReader.openFile(initialFiles[0])
        if (initialFiles.length > 1) { splitEnabled = true; rightReader.openFile(initialFiles[1]) }
    }
    onClosing: function(close) {
        if (researchStore.busy) {
            close.accepted = false
            notify("Saving capture. Please close the window after saving finishes.")
        } else persist()
    }
    onWidthChanged: scheduleSave()
    onHeightChanged: scheduleSave()
    onSplitEnabledChanged: scheduleSave()
    onShelfVisibleChanged: scheduleSave()
    onFilesVisibleChanged: scheduleSave()
    onFilesSideChanged: scheduleSave()
    onCapturesSideChanged: scheduleSave()
    onPaperFolderChanged: scheduleSave()
    onActivePaneChanged: scheduleSave()
    onHomeVisibleChanged: scheduleSave()

    Timer { id: saveTimer; interval: 500; onTriggered: window.persist() }
    Timer { id: notificationTimer; interval: 6500; onTriggered: window.notification = "" }

    Connections {
        target: researchStore
        function onMessage(text) { window.notify(text) }
        function onCaptureSaved(id) {
            window.shelfVisible = true
            Qt.callLater(function() { (window.capturesSide === "left" ? leftDock : rightDock).activePanel = "captures" })
        }
        function onSourceReady(url, page, region) {
            window.homeVisible = false
            const reader = leftReader.source.toString() === url.toString() ? leftReader
                         : (rightReader.source.toString() === url.toString() && window.splitEnabled ? rightReader : window.currentReader)
            window.activePane = reader.paneIndex
            reader.reveal(url, page, region)
        }
    }

    CommandPalette {
        id: commandPalette
        parent: Overlay.overlay
        recentDocuments: researchStore.recentDocuments
        onDocumentChosen: function(source) { window.openDocument(source) }
        onCommandChosen: function(command) {
            switch (command) {
            case "/home": window.showHome(); break
            case "/open paper": window.currentReader.chooseFile(); break
            case "/find": if (window.homeVisible) homeView.focusSearch(); else window.currentReader.find(); break
            case "/split right": window.splitEnabled = true; break
            case "/split off": window.splitEnabled = false; window.activePane = 0; break
            case "/capture": window.currentReader.toggleCapture(); break
            case "/files": window.filesVisible = true; window.movePanel("files", window.filesSide); break
            case "/captures":
                window.shelfVisible = true
                window.movePanel("captures", window.capturesSide)
                window.notify("Saved captures: " + researchStore.captures.length + " · Select an item to return to its source.")
                break
            }
        }
    }

    menuBar: MenuBar {
        Menu {
            title: "File"
            Action { text: "Open PDF…"; shortcut: StandardKey.Open; onTriggered: window.currentReader.chooseFile() }
            Action { text: "Open PDF on the right…"; shortcut: "Ctrl+Shift+O"; onTriggered: { window.splitEnabled = true; rightReader.chooseFile() } }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: StandardKey.Quit; onTriggered: window.close() }
        }
        Menu {
            title: "View"
            Action { text: "Home"; shortcut: "Ctrl+Shift+H"; onTriggered: window.showHome() }
            Action { text: "Command palette"; shortcut: "Ctrl+K"; onTriggered: commandPalette.open() }
            Action { text: "Find"; shortcut: StandardKey.Find; onTriggered: { if (window.homeVisible) homeView.focusSearch(); else window.currentReader.find() } }
            Action { text: "Zoom in"; shortcut: StandardKey.ZoomIn; onTriggered: window.currentReader.zoom(1.2) }
            Action { text: "Zoom out"; shortcut: StandardKey.ZoomOut; onTriggered: window.currentReader.zoom(1 / 1.2) }
            Action { text: "Capture region"; shortcut: "Ctrl+Shift+C"; onTriggered: window.currentReader.toggleCapture() }
            Action { text: "Split view"; checkable: true; checked: window.splitEnabled; onTriggered: window.splitEnabled = !window.splitEnabled }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 6
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"
            panels: window.leftPanels
            folder: window.paperFolder
            visible: panels.length > 0
            Layout.preferredWidth: 224
            Layout.fillHeight: true
            onClosePanel: function(panel) { window.closePanel(panel) }
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            onActivePanelChanged: window.scheduleSave()
        }
        HomeView {
            id: homeView
            visible: window.homeVisible
            Layout.fillWidth: true
            Layout.fillHeight: true
            onOpenRequested: window.currentReader.chooseFile()
            onDocumentChosen: function(source, position) { window.openDocument(source, position) }
            onWorkspaceChosen: function(id) { window.openWorkspace(id) }
            onWorkspaceCreated: function(name) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) }
            onResultChosen: function(result) {
                if (result.kind === "paper") window.openDocument(result.source, result.position)
                else if (result.kind === "capture") researchStore.openCapture(result.id)
                else if (result.kind === "workspace") window.openWorkspace(result.id)
            }
        }
        SplitView {
            id: split
            visible: !window.homeVisible
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Horizontal
            handle: Rectangle { implicitWidth: 8; color: SplitHandle.hovered ? "#cccccc" : "transparent" }
            ReaderPane {
                id: leftReader
                paneIndex: 0
                isActive: !window.homeVisible && (window.activePane === 0 || !window.splitEnabled)
                SplitView.minimumWidth: 300
                SplitView.preferredWidth: (split.width - 8) / 2
                onActivated: window.activePane = 0
                onDocumentAboutToOpen: window.persist()
                onDocumentOpened: window.homeVisible = false
                onChanged: window.scheduleSave()
                onWidthChanged: window.scheduleSave()
            }
            ReaderPane {
                id: rightReader
                paneIndex: 1
                visible: window.splitEnabled
                isActive: !window.homeVisible && window.splitEnabled && window.activePane === 1
                SplitView.minimumWidth: 300
                SplitView.fillWidth: true
                onActivated: window.activePane = 1
                onDocumentAboutToOpen: window.persist()
                onDocumentOpened: window.homeVisible = false
                onChanged: window.scheduleSave()
            }
        }
        DockSidebar {
            id: rightDock
            objectName: "rightDock"
            side: "right"
            panels: window.rightPanels
            folder: window.paperFolder
            visible: panels.length > 0
            Layout.preferredWidth: 224
            Layout.fillHeight: true
            onClosePanel: function(panel) { window.closePanel(panel) }
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
        Rectangle {
            visible: window.dragSide.length > 0
            x: window.dragSide === "left" ? 0 : parent.width / 2
            width: parent.width / 2
            height: parent.height
            color: "#dddddd"
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            spacing: 2
            StatusIcon { kind: "home"; description: "Home · Ctrl/Cmd+Shift+H"; selected: window.homeVisible; onTriggered: window.showHome() }
            Repeater {
                model: ["files", "captures"].filter(function(p) { return (p === "files" ? window.filesSide : window.capturesSide) === "left" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData
                    description: (kind === "files" ? "Files" : "Captures") + " · Click to toggle; drag along the status bar to move"
                    selected: kind === "files" ? window.filesVisible : window.shelfVisible
                    draggable: true
                    onTriggered: window.togglePanel(kind)
                    onDragProgress: function(panel, x, y) { window.dragPanel(panel, x, y) }
                    onDragEnded: function(panel, x, y, cancelled) { window.dropPanel(panel, x, y, cancelled) }
                }
            }
            Label {
                Layout.fillWidth: true
                text: window.notification.length ? window.notification
                    : researchStore.busy ? "Saving capture…" : window.workspaceName.length ? window.workspaceName : "Local workspace"
                elide: Text.ElideRight
                font.pixelSize: 11
                color: "#666666"
            }
            StatusIcon { kind: "search"; description: "Command palette · Ctrl/Cmd+K"; onTriggered: commandPalette.open() }
            StatusIcon { kind: "split"; description: "Toggle split view"; selected: window.splitEnabled; onTriggered: { window.splitEnabled = !window.splitEnabled; window.homeVisible = false } }
            Repeater {
                model: ["files", "captures"].filter(function(p) { return (p === "files" ? window.filesSide : window.capturesSide) === "right" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData
                    description: (kind === "files" ? "Files" : "Captures") + " · Click to toggle; drag along the status bar to move"
                    selected: kind === "files" ? window.filesVisible : window.shelfVisible
                    draggable: true
                    onTriggered: window.togglePanel(kind)
                    onDragProgress: function(panel, x, y) { window.dragPanel(panel, x, y) }
                    onDragEnded: function(panel, x, y, cancelled) { window.dropPanel(panel, x, y, cancelled) }
                }
            }
        }
    }
}
