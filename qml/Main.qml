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
    property bool documentVisible: false
    property string documentSide: "left"
    property real leftDockWidth: 224
    property real rightDockWidth: 224
    function dockWidth(value) { return Math.max(160, Math.min(value, 560, (width - 360) / 2)) }
    property int navigationMode: 0
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
        if (documentVisible && documentSide === side) panels.push("document")
        return panels
    }
    function panelSide(panel) { return panel === "files" ? filesSide : panel === "captures" ? capturesSide : documentSide }
    function panelShown(panel) { return panel === "files" ? filesVisible : panel === "captures" ? shelfVisible : documentVisible }
    function panelName(panel) { return panel === "files" ? "Files" : panel === "captures" ? "Captures" : "Document outline and thumbnails" }
    function setPanelShown(panel, shown) { if (panel === "files") filesVisible = shown; else if (panel === "captures") shelfVisible = shown; else documentVisible = shown }
    function togglePanel(panel) {
        const side = panelSide(panel)
        const dock = side === "left" ? leftDock : rightDock
        const shown = panelShown(panel)
        if (shown && dock.activePanel === panel) {
            setPanelShown(panel, false)
        } else {
            setPanelShown(panel, true)
            movePanel(panel, side)
        }
    }
    function movePanel(panel, side) {
        if (side !== "left" && side !== "right") return
        if (panel === "files") filesSide = side
        if (panel === "captures") capturesSide = side
        if (panel === "document") documentSide = side
        Qt.callLater(function() { (side === "left" ? leftDock : rightDock).activePanel = panel })
    }
    function showHome() { persist(); homeVisible = true; Qt.callLater(function() { homeView.focusSearch() }) }
    function findInView() {
        if (homeVisible) homeView.focusSearch()
        else if (currentReader) currentReader.find()
        else { const view = documents.groupView(documents.activeGroup); if (view) view.focusHome() }
    }
    function openDocument(source, position) { if (!restoreFailed) documents.openDocument(researchStore.resolvedSource(source), position) }
    function openSearchResult(result) {
        if (result.kind === "paper") openDocument(result.source, result.position)
        else if (result.kind === "capture") researchStore.openCapture(result.id)
        else if (result.kind === "note") captureNote.begin(result.id)
        else if (result.kind === "workspace") openWorkspace(result.id)
        else if (result.kind === "text" && !restoreFailed) { notify("Checking PDF source…"); researchStore.paperIndex.openResult(result.documentId, Number(result.page), result.sha256) }
    }
    function openWorkspace(id) {
        if (restoreFailed || !persist()) return
        const state = researchStore.loadWorkspace(id)
        if (!state.workspace) return
        saveTimer.stop(); initialized = false
        try { documents.restore(state) }
        catch (error) { initialized = true; notify(error.message); return }
        activeWorkspace = state.workspace; workspaceName = state.workspaceName || ""
        paperFolder = state.panels ? state.panels.folder || "" : ""
        homeVisible = !documents.hasTabs
        initialized = true; persist()
    }
    function persist() {
        if (!initialized || restoreFailed) return false
        const state = documents.snapshot()
        Object.assign(state, {shelf: shelfVisible, workspace: activeWorkspace, workspaceName: workspaceName,
            width: width, height: height, panels: {filesVisible: filesVisible, filesSide: filesSide, capturesSide: capturesSide,
                documentVisible: documentVisible, documentSide: documentSide, navigationMode: navigationMode,
                folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel,
                leftWidth: leftDockWidth, rightWidth: rightDockWidth}})
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
        leftDockWidth = Number(panels.leftWidth) || 224
        rightDockWidth = Number(panels.rightWidth) || 224
        filesVisible = panels.filesVisible === undefined ? true : panels.filesVisible
        filesSide = panels.filesSide === "right" ? "right" : "left"
        capturesSide = panels.capturesSide === "left" ? "left" : "right"
        documentVisible = !!panels.documentVisible
        documentSide = panels.documentSide === "right" ? "right" : "left"
        navigationMode = panels.navigationMode === 1 ? 1 : 0
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
        if (captureNote.dirty) { close.accepted = false; captureNote.open(); notify("Save or discard your note edits before closing the window.") }
        else if (researchStore.busy) { close.accepted = false; notify("Saving capture. Please close the window after saving finishes.") }
        else if (initialized && !restoreFailed && !persist()) { close.accepted = false; notify("Cannot save the session. Check storage and try again.") }
    }
    onWidthChanged: scheduleSave()
    onHeightChanged: scheduleSave()
    onShelfVisibleChanged: scheduleSave()
    onFilesVisibleChanged: scheduleSave()
    onFilesSideChanged: scheduleSave()
    onCapturesSideChanged: scheduleSave()
    onDocumentSideChanged: scheduleSave()
    onDocumentVisibleChanged: scheduleSave()
    onNavigationModeChanged: scheduleSave()
    onPaperFolderChanged: scheduleSave()
    onLeftDockWidthChanged: scheduleSave()
    onRightDockWidthChanged: scheduleSave()
    Timer { id: saveTimer; interval: 500; onTriggered: window.persist() }
    Timer { id: notificationTimer; interval: 6500; onTriggered: if (!window.restoreFailed) window.notification = "" }
    Native.FileDialog { id: fileDialog; title: "Open PDF"; nameFilters: ["PDF documents (*.pdf)"]; onAccepted: window.openDocument(selectedFile) }
    Connections {
        target: researchStore
        function onMessage(text) { window.notify(text) }
        function onRelinkRequested(source) { if (!window.restoreFailed && !researchStore.relinking && window.persist()) relinkDialog.begin(source) }
        function onSourceRelinked(source, candidate) { documents.relinkSource(source, candidate) }
        function onRelinkFinished(success, detail) { if (success) window.notify(detail) }
        function onCaptureSaved(id) { window.shelfVisible = true; window.movePanel("captures", window.capturesSide) }
        function onSourceReady(url, page, region) { if (!window.restoreFailed) { documents.reveal(url, page, region); window.homeVisible = false } }
    }
    Connections {
        target: researchStore.paperIndex
        function onResultReady(source, page) { if (!window.restoreFailed) documents.openAtPage(source, page) }
    }
    RelinkDialog { id: relinkDialog; parent: Overlay.overlay }
    CommandPalette {
        id: commandPalette
        parent: Overlay.overlay
        hasDocument: !window.homeVisible && !!window.currentReader && window.currentReader.pdfReady
        hasSelection: hasDocument && window.currentReader.selectedText.length > 0
        canReopenTab: documents.closedTabs.length > 0
        canCloseTab: !window.homeVisible && documents.hasTabs
        onCommandChosen: function(command) {
            switch (command) {
            case "/home": window.showHome(); break
            case "/open paper": window.chooseFile(); break
            case "/find": window.findInView(); break
            case "/split right": documents.duplicateSplit("right"); break
            case "/split down": documents.duplicateSplit("bottom"); break
            case "/split off": documents.joinAll(); break
            case "/capture": if (!window.homeVisible && window.currentReader) window.currentReader.toggleCapture(); break
            case "/capture text": if (!window.homeVisible && window.currentReader) window.currentReader.captureSelection(); break
            case "/files": window.togglePanel("files"); break
            case "/captures": window.togglePanel("captures"); break
            case "/document": window.togglePanel("document"); break
            case "/close tab": documents.closeActiveTab(); break
            case "/new tab": if (!window.restoreFailed) documents.newHomeTab(); break
            case "/reopen tab": documents.reopenClosedTab(); break
            case "/fit width": if (window.currentReader) window.currentReader.fitWidth(); break
            }
        }
    }
    SearchPalette {
        currentSource: !window.homeVisible && window.currentReader ? window.currentReader.source : ""
        id: searchPalette
        parent: Overlay.overlay
        onResultChosen: function(result) { window.openSearchResult(result) }
    }
    menuBar: MenuBar {
        Menu {
            title: "File"
            Action { text: "Open PDF…"; shortcut: StandardKey.Open; onTriggered: window.chooseFile() }
            Action { objectName: "newTabAction"; text: "New Tab"; shortcut: "Ctrl+T"; enabled: !window.restoreFailed; onTriggered: documents.newHomeTab() }
            Action { objectName: "closeTabAction"; text: "Close Tab"; shortcut: "Ctrl+W"; enabled: !window.homeVisible && !window.restoreFailed; onTriggered: documents.closeActiveTab() }
            Action { text: "Reopen Closed Tab"; shortcut: "Ctrl+Shift+T"; enabled: documents.closedTabs.length > 0 && !window.restoreFailed; onTriggered: documents.reopenClosedTab() }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: StandardKey.Quit; onTriggered: window.close() }
        }
        Menu {
            title: "View"
            Action { text: "Home"; shortcut: "Ctrl+Shift+H"; onTriggered: window.showHome() }
            Action { text: "Search Research"; shortcut: "Ctrl+K"; onTriggered: { commandPalette.close(); searchPalette.open() } }
            Action { text: "Command Palette"; shortcut: "Ctrl+Shift+P"; onTriggered: { searchPalette.close(); commandPalette.open() } }
            Action { text: "Find"; shortcut: StandardKey.Find; onTriggered: window.findInView() }
            Action { text: "Zoom in"; shortcut: StandardKey.ZoomIn; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1.2) }
            Action { text: "Zoom out"; shortcut: StandardKey.ZoomOut; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1 / 1.2) }
            Action { text: "Capture region"; shortcut: "Ctrl+Shift+C"; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.toggleCapture() }
            MenuSeparator {}
            Action { text: "Duplicate to Right Split"; enabled: !window.homeVisible; onTriggered: documents.duplicateSplit("right") }
            Action { text: "Duplicate to Bottom Split"; enabled: !window.homeVisible; onTriggered: documents.duplicateSplit("bottom") }
            Action { text: "Join All Groups"; enabled: !window.homeVisible; onTriggered: documents.joinAll() }
        }
    }
    CaptureNoteDialog { id: captureNote }
    RowLayout {
        anchors.fill: parent
        spacing: 1
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"; panels: window.leftPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.leftDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            onNoteRequested: function(id) { captureNote.begin(id) }
            onActivePanelChanged: window.scheduleSave()
        }
        Rectangle {
            visible: leftDock.visible
            Layout.preferredWidth: 6; Layout.fillHeight: true
            color: leftResize.containsMouse || leftResize.pressed ? "#bcbcbc" : "#eeeeee"
            MouseArea {
                id: leftResize
                objectName: "leftDockResize"
                anchors.fill: parent
                hoverEnabled: true; cursorShape: Qt.SplitHCursor
                preventStealing: true
                property real origin
                property real initialWidth
                onPressed: function(mouse) { origin = mapToItem(window.contentItem, mouse.x, mouse.y).x; initialWidth = leftDock.width }
                onPositionChanged: function(mouse) {
                    if (pressed) window.leftDockWidth = window.dockWidth(initialWidth + mapToItem(window.contentItem, mouse.x, mouse.y).x - origin)
                }
            }
        }
        HomeView {
            id: homeView
            visible: window.homeVisible
            Layout.fillWidth: true; Layout.fillHeight: true
            onOpenRequested: window.chooseFile()
            onDocumentChosen: function(source, position) { window.openDocument(source, position) }
            onWorkspaceChosen: function(id) { window.openWorkspace(id) }
            onWorkspaceCreated: function(name) { if (!window.restoreFailed) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) } }
            onResultChosen: function(result) { window.openSearchResult(result) }
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
            onHomeOpenRequested: window.chooseFile()
            onHomeResultChosen: function(result) { window.openSearchResult(result) }
            onHomeWorkspaceChosen: function(id) { window.openWorkspace(id) }
            onHomeWorkspaceCreated: function(name) { if (!window.restoreFailed) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) } }
        }
        Rectangle {
            visible: rightDock.visible
            Layout.preferredWidth: 6; Layout.fillHeight: true
            color: rightResize.containsMouse || rightResize.pressed ? "#bcbcbc" : "#eeeeee"
            MouseArea {
                id: rightResize
                objectName: "rightDockResize"
                anchors.fill: parent
                hoverEnabled: true; cursorShape: Qt.SplitHCursor
                preventStealing: true
                property real origin
                property real initialWidth
                onPressed: function(mouse) { origin = mapToItem(window.contentItem, mouse.x, mouse.y).x; initialWidth = rightDock.width }
                onPositionChanged: function(mouse) {
                    if (pressed) window.rightDockWidth = window.dockWidth(initialWidth - mapToItem(window.contentItem, mouse.x, mouse.y).x + origin)
                }
            }
        }
        DockSidebar {
            id: rightDock
            objectName: "rightDock"
            side: "right"; panels: window.rightPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.rightDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            onNoteRequested: function(id) { captureNote.begin(id) }
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
                model: ["files", "captures", "document"].filter(function(p) { return window.panelSide(p) === "left" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData; dockSide: "left"
                    description: window.panelName(kind) + " · Right-click to change dock"
                    selected: window.panelShown(kind)
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
            Label {
                Layout.fillWidth: true
                text: window.notification.length ? window.notification : researchStore.busy ? "Saving capture…" : window.workspaceName.length ? window.workspaceName : "Local workspace"
                elide: Text.ElideRight; font.pixelSize: 11; color: "#666666"
            }
            StatusIcon { kind: "search"; description: "Search · Ctrl/Cmd+K"; onTriggered: { commandPalette.close(); searchPalette.open() } }
            StatusIcon { kind: "split"; description: "Duplicate tab to right split"; visible: !window.homeVisible; selected: documents.groupCount > 1; onTriggered: documents.duplicateSplit("right") }
            Repeater {
                model: ["files", "captures", "document"].filter(function(p) { return window.panelSide(p) === "right" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData; dockSide: "right"
                    description: window.panelName(kind) + " · Right-click to change dock"
                    selected: window.panelShown(kind)
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
        }
    }
}
