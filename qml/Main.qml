import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import "UiTheme.js" as Theme

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    visible: true
    width: 1440; height: 930
    minimumWidth: 880; minimumHeight: 580
    title: ""
    color: Theme.surfaceChrome
    font.family: Qt.platform.os === "osx" ? ".AppleSystemUIFont" : "sans-serif"
    font.pixelSize: 13
    palette.window: Theme.surfacePanel
    palette.windowText: Theme.text
    palette.highlight: Theme.highlight
    palette.highlightedText: "white"
    palette.button: Theme.surfaceChrome
    palette.buttonText: Theme.textBody
    palette.text: Theme.text
    palette.base: Theme.surface
    palette.alternateBase: Theme.surfaceAlt
    // Rich and Markdown text links (notes, AI answers) use the accent, not default blue.
    palette.link: Theme.accent
    palette.linkVisited: Theme.accent
    palette.light: Theme.surface
    palette.midlight: Theme.surfaceChrome
    palette.mid: Theme.shadeMid
    palette.dark: Theme.shadeDark
    palette.shadow: Theme.shadow
    palette.placeholderText: Theme.textMuted
    property bool shelfVisible: true
    property bool filesVisible: true
    property string filesSide: "left"
    property string capturesSide: "right"
    property bool documentVisible: false
    property string documentSide: "left"
    property bool aiVisible: false
    property string aiSide: "right"
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
        if (aiVisible && aiSide === side) panels.push("ai")
        return panels
    }
    readonly property var dockPanels: ["files", "captures", "document", "ai"]
    function panelSide(panel) { return panel === "files" ? filesSide : panel === "captures" ? capturesSide : panel === "ai" ? aiSide : documentSide }
    function panelShown(panel) { return panel === "files" ? filesVisible : panel === "captures" ? shelfVisible : panel === "ai" ? aiVisible : documentVisible }
    function panelName(panel) { return panel === "files" ? "Files" : panel === "captures" ? "Captures" : panel === "ai" ? "AI threads" : "Document outline and thumbnails" }
    function setPanelShown(panel, shown) {
        if (panel === "files") filesVisible = shown
        else if (panel === "captures") shelfVisible = shown
        else if (panel === "ai") aiVisible = shown
        else documentVisible = shown
    }
    // Reader and capture actions bring the AI panel forward and start a thread there.
    function showAi() { setPanelShown("ai", true); movePanel("ai", aiSide) }
    function askAi(spec) { showAi(); aiController.begin(spec) }
    function openAiThread(id) { if (aiController.openThread(id)) showAi() }
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
        const stays = panelSide(panel) === side
        if (panel === "files") filesSide = side
        if (panel === "captures") capturesSide = side
        if (panel === "document") documentSide = side
        if (panel === "ai") aiSide = side
        // At once when the panel is already in that dock (so a quick second click hides it); after a
        // move, once the docks' panel lists have caught up.
        const dock = side === "left" ? leftDock : rightDock
        if (stays && dock.panels.indexOf(panel) >= 0) dock.activePanel = panel
        Qt.callLater(function() { dock.activePanel = panel })
    }
    // Tab switching must not discard an annotation that is still being edited.
    readonly property bool canSwitchTabs: documents.hasTabs && !restoreFailed && !(currentReader && currentReader.annotationDirty)
    // Browser conventions alongside the menu shortcuts: Cmd+Shift+] / [, Control+Tab, Cmd+1…9 (9 = last tab).
    Shortcut {
        sequences: ["Ctrl+Shift+]", Qt.platform.os === "osx" ? "Meta+Tab" : "Ctrl+Tab"]
        enabled: window.canSwitchTabs
        onActivated: documents.cycleTab(1)
        onActivatedAmbiguously: documents.cycleTab(1)
    }
    Shortcut {
        sequences: ["Ctrl+Shift+[", Qt.platform.os === "osx" ? "Meta+Shift+Tab" : "Ctrl+Shift+Tab"]
        enabled: window.canSwitchTabs
        onActivated: documents.cycleTab(-1)
        onActivatedAmbiguously: documents.cycleTab(-1)
    }
    Instantiator {
        model: 9
        delegate: Shortcut {
            required property int index
            sequence: "Ctrl+" + (index + 1)
            enabled: window.canSwitchTabs
            onActivated: documents.selectTabAt(index === 8 ? -1 : index)
        }
    }
    function showHome() { persist(); homeVisible = true; Qt.callLater(function() { homeView.focusSearch() }) }
    // Cmd+L: the address bar of the current web tab, or a new web tab when a paper or Home is in front.
    function openWebAddress() {
        if (restoreFailed) return
        const view = documents.groupView(documents.activeGroup)
        if (!homeVisible && view && view.isWeb && view.webPane) { view.webPane.focusAddress(); return }
        const start = researchStore.setting("startPage")
        if (documents.openWeb(start.length ? start : "https://scholar.google.com/", true))
            Qt.callLater(function() { const next = documents.groupView(documents.activeGroup); if (next) next.focusAddress() })
    }
    function findInView() {
        if (homeVisible) homeView.focusSearch()
        else if (currentReader) currentReader.find()
        else { const view = documents.groupView(documents.activeGroup); if (view) view.focusHome() }
    }
    function openDocument(source, position) { if (!restoreFailed) documents.openDocument(researchStore.resolvedSource(source), position) }
    function openSearchResult(result) {
        if (result.kind === "paper") openDocument(result.source, result.position)
        else if (result.kind === "capture") researchStore.openCapture(result.id)
        else if (result.kind === "highlight") researchStore.openHighlight(result.id)
        else if (result.kind === "note") captureNote.begin(result.id)
        else if (result.kind === "workspace") openWorkspace(result.id)
        else if (result.kind === "standalone-note" && !restoreFailed) documents.openNote(result.id)
        else if (result.kind === "ai") openAiThread(result.id)
        else if (result.kind === "collection" && !restoreFailed) documents.openLibrary({collection: result.id})
        else if (result.kind === "tag" && !restoreFailed) documents.openLibrary({tag: result.id})
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
    function manageWorkspace(id) {
        if (restoreFailed || captureNote.dirty) { notify("Save or discard note edits before managing a workspace."); return }
        if (id !== activeWorkspace) openWorkspace(id)
        if (activeWorkspace === id && persist()) workspaceManager.begin(id)
    }
    function persist() {
        if (!initialized || restoreFailed) return false
        const state = documents.snapshot()
        Object.assign(state, {shelf: shelfVisible, workspace: activeWorkspace, workspaceName: workspaceName,
            width: width, height: height, panels: {filesVisible: filesVisible, filesSide: filesSide, capturesSide: capturesSide,
                documentVisible: documentVisible, documentSide: documentSide, aiVisible: aiVisible, aiSide: aiSide, navigationMode: navigationMode,
                folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel,
                leftWidth: leftDockWidth, rightWidth: rightDockWidth}})
        return researchStore.saveWorkspace(activeWorkspace, state) && researchStore.saveSession(state)
    }
    function scheduleSave() { if (initialized && !restoreFailed) saveTimer.restart() }
    function notify(text) { notification = text; notificationTimer.restart() }
    function chooseFile() { if (!restoreFailed && !(currentReader && currentReader.annotationDirty)) fileDialog.open() }

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
        aiVisible = !!panels.aiVisible
        aiSide = panels.aiSide === "left" ? "left" : "right"
        navigationMode = [0, 1, 2].indexOf(panels.navigationMode) >= 0 ? panels.navigationMode : 0
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
        if (researchStore.printing) { close.accepted = false; notify("Finish or cancel printing before closing the window."); return }
        if (window.currentReader && window.currentReader.annotationDirty) { close.accepted = false; notify("Save or discard annotation edits before closing the window."); return }
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
        function onDuplicateFound(source, existing, title) { duplicateBar.show(source, existing, title) }
        function onWebSourceRequested(page) { if (!window.restoreFailed) documents.openWeb(page.toString(), true) }
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
            if (window.currentReader && window.currentReader.annotationDirty) { window.notify("Finish annotation editing first."); return }
            switch (command) {
            case "/home": window.showHome(); break
            case "/open paper": window.chooseFile(); break
            case "/find": window.findInView(); break
            case "/split right": documents.duplicateSplit("right"); break
            case "/split down": documents.duplicateSplit("bottom"); break
            case "/split off": documents.joinAll(); break
            case "/web": window.openWebAddress(); break
            case "/library": documents.openLibrary({}); break
            case "/new note": documents.newNote(); break
            case "/settings": settingsDialog.open(); break
            case "/move right": documents.moveActiveTabToSplit("right"); break
            case "/move down": documents.moveActiveTabToSplit("bottom"); break
            case "/next split": documents.focusGroup(1); break
            case "/previous split": documents.focusGroup(-1); break
            case "/capture": if (!window.homeVisible && window.currentReader) window.currentReader.toggleCapture(); break
            case "/capture text": if (!window.homeVisible && window.currentReader) window.currentReader.captureSelection(); break
            case "/highlight": if (!window.homeVisible && window.currentReader) window.currentReader.highlightSelection(); break
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
        UiControls.Menu {
            title: "File"
            Action { text: "Open PDF…"; shortcut: StandardKey.Open; onTriggered: window.chooseFile() }
            Action { objectName: "newNoteAction"; text: "New Note"; shortcut: "Ctrl+Shift+N"; enabled: !window.restoreFailed; onTriggered: documents.newNote() }
            Action { objectName: "openWebAction"; text: "Open Web Page…"; shortcut: "Ctrl+L"; enabled: !window.restoreFailed; onTriggered: window.openWebAddress() }
            Action { objectName: "settingsAction"; text: "Settings…"; shortcut: StandardKey.Preferences; onTriggered: settingsDialog.open() }
            Action { objectName: "newTabAction"; text: "New Tab"; shortcut: "Ctrl+T"; enabled: !window.restoreFailed && !(window.currentReader && window.currentReader.annotationDirty); onTriggered: documents.newHomeTab() }
            Action { objectName: "closeTabAction"; text: "Close Tab"; shortcut: "Ctrl+W"; enabled: !window.homeVisible && !window.restoreFailed && !(window.currentReader && window.currentReader.annotationDirty); onTriggered: documents.closeActiveTab() }
            Action { text: "Reopen Closed Tab"; shortcut: "Ctrl+Shift+T"; enabled: documents.closedTabs.length > 0 && !window.restoreFailed; onTriggered: documents.reopenClosedTab() }
            Action { objectName: "nextTabAction"; text: "Next Tab"; shortcut: "Ctrl+Alt+Right"; enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(1) }
            Action { objectName: "previousTabAction"; text: "Previous Tab"; shortcut: "Ctrl+Alt+Left"; enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(-1) }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: StandardKey.Quit; onTriggered: window.close() }
        }
        UiControls.Menu {
            title: "View"
            Action { text: "Home"; shortcut: "Ctrl+Shift+H"; onTriggered: window.showHome() }
            Action { objectName: "libraryAction"; text: "Library"; shortcut: "Ctrl+Shift+L"; enabled: !window.restoreFailed; onTriggered: documents.openLibrary({}) }
            Action { text: "Search Research"; shortcut: "Ctrl+K"; onTriggered: { commandPalette.close(); searchPalette.open() } }
            Action { text: "Command Palette"; shortcut: "Ctrl+Shift+P"; onTriggered: { searchPalette.close(); commandPalette.open() } }
            Action { text: "Find"; shortcut: StandardKey.Find; onTriggered: window.findInView() }
            Action { text: "Zoom in"; shortcut: StandardKey.ZoomIn; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1.2) }
            Action { text: "Zoom out"; shortcut: StandardKey.ZoomOut; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1 / 1.2) }
            Action { text: "Capture region"; shortcut: "Ctrl+Shift+C"; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.toggleCapture() }
            MenuSeparator {}
            Action { objectName: "splitRightAction"; text: "Duplicate to Right Split"; shortcut: "Ctrl+\\"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.duplicateSplit("right") }
            Action { objectName: "splitDownAction"; text: "Duplicate to Bottom Split"; shortcut: "Ctrl+Alt+\\"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.duplicateSplit("bottom") }
            Action { objectName: "moveRightAction"; text: "Move Tab to Right Split"; shortcut: "Ctrl+Shift+Alt+Right"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.moveActiveTabToSplit("right") }
            Action { objectName: "moveDownAction"; text: "Move Tab to Bottom Split"; shortcut: "Ctrl+Shift+Alt+Down"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.moveActiveTabToSplit("bottom") }
            Action { objectName: "nextSplitAction"; text: "Focus Next Split"; shortcut: "Ctrl+Alt+Down"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.focusGroup(1) }
            Action { objectName: "previousSplitAction"; text: "Focus Previous Split"; shortcut: "Ctrl+Alt+Up"; enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.focusGroup(-1) }
            Action { text: "Join All Groups"; enabled: !window.homeVisible; onTriggered: documents.joinAll() }
        }
    }
    CaptureNoteDialog { id: captureNote }
    SettingsDialog { id: settingsDialog }
    AiController { id: aiController; reader: window.homeVisible ? null : window.currentReader }
    // Same bytes as another library entry: offer the existing copy without merging anything silently.
    // A notice, not a dialog: it never takes keyboard focus from the reader.
    Rectangle {
        id: duplicateBar
        objectName: "duplicateBar"
        parent: window.contentItem
        z: 50
        property url source: ""
        property url existing: ""
        property string existingTitle: ""
        readonly property bool opened: visible
        function show(url, other, title) { source = url; existing = other; existingTitle = title; visible = true }
        function close() { visible = false }
        visible: false
        x: (parent.width - width) / 2; y: 8
        width: Math.min(560, parent.width - 32); height: 44
        color: Theme.surfacePanel; border.color: Theme.borderPopup; radius: Theme.cornerRadius
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 6
            spacing: 6
            Label {
                Layout.fillWidth: true
                text: "Same file as \u201c" + duplicateBar.existingTitle + "\u201d"
                elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text
                ToolTip.visible: duplicateHover.hovered; ToolTip.delay: 450
                ToolTip.text: duplicateBar.existing.toString().length ? decodeURIComponent(duplicateBar.existing.toString().replace("file://", "")) : ""
                HoverHandler { id: duplicateHover }
            }
            UiControls.Button {
                objectName: "openExistingCopy"; text: "Open Existing"; focusPolicy: Qt.NoFocus
                onClicked: {
                    if (researchStore.useExistingCopy(duplicateBar.source, duplicateBar.existing))
                        documents.relinkSource(duplicateBar.source, duplicateBar.existing)
                    duplicateBar.close()
                }
            }
            UiControls.Button {
                objectName: "keepBothCopies"; text: "Keep Both"; focusPolicy: Qt.NoFocus
                onClicked: { researchStore.keepDuplicate(duplicateBar.source); duplicateBar.close() }
            }
            ReaderIconButton { kind: "close"; description: "Dismiss"; focusPolicy: Qt.NoFocus; onClicked: duplicateBar.close() }
        }
    }
    Connections {
        target: researchStore
        function onWorkspaceRenamed(id, name) { if (window.activeWorkspace === id) { window.workspaceName = name; window.persist() } }
        function onWorkspaceDeleted(id) { if (window.activeWorkspace === id) { window.activeWorkspace = ""; window.workspaceName = ""; window.persist() } }
    }
    WorkspaceManager {
        id: workspaceManager
        currentSource: !window.homeVisible && window.currentReader ? window.currentReader.source : ""
        onDocumentChosen: function(source) { window.openDocument(source) }
        onNoteRequested: function(id) { captureNote.begin(id) }
        onDeleteRequested: function(id) {
            if (window.persist() && researchStore.deleteWorkspace(id)) close()
            else error = "Could not delete workspace. Your data is kept."
        }
    }
    RowLayout {
        anchors.fill: parent
        spacing: 1
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"; panels: window.leftPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            aiController: aiController
            onSettingsRequested: settingsDialog.open()
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onAiRequested: function(spec) { window.askAi(spec) }
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
            color: leftResize.containsMouse || leftResize.pressed ? Theme.edgeHandleHover : Theme.edgeHandle
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
            onWorkspaceManageRequested: function(id) { window.manageWorkspace(id) }
            onWorkspaceCreated: function(name) { if (!window.restoreFailed) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) } }
            onResultChosen: function(result) { window.openSearchResult(result) }
            onLibraryRequested: if (!window.restoreFailed) documents.openLibrary({})
            onWebRequested: function(url) { if (!window.restoreFailed) documents.openWeb(url, true) }
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
            onAiRequested: function(spec) { window.askAi(spec) }
            onAiResponseRequested: function(id) { window.openAiThread(id) }
            onOpened: window.homeVisible = false
            onHomeOpenRequested: window.chooseFile()
            onHomeResultChosen: function(result) { window.openSearchResult(result) }
            onHomeWorkspaceChosen: function(id) { window.openWorkspace(id) }
            onHomeWorkspaceManageRequested: function(id) { window.manageWorkspace(id) }
            onHomeWorkspaceCreated: function(name) { if (!window.restoreFailed) { const id = researchStore.createWorkspace(name); if (id.length) window.openWorkspace(id) } }
        }
        Rectangle {
            visible: rightDock.visible
            Layout.preferredWidth: 6; Layout.fillHeight: true
            color: rightResize.containsMouse || rightResize.pressed ? Theme.edgeHandleHover : Theme.edgeHandle
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
            aiController: aiController
            onSettingsRequested: settingsDialog.open()
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onAiRequested: function(spec) { window.askAi(spec) }
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
        color: Theme.surfacePanel
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4; anchors.rightMargin: 4
            spacing: 2
            Repeater {
                model: window.dockPanels.filter(function(p) { return window.panelSide(p) === "left" })
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
                elide: Text.ElideRight; font.pixelSize: 11; color: Theme.textTertiary
            }
            StatusIcon { kind: "search"; description: "Search · Ctrl/Cmd+K"; onTriggered: { commandPalette.close(); searchPalette.open() } }
            UiControls.ToolButton {
                objectName: "manageWorkspaceButton"; text: "Workspace…"
                visible: window.activeWorkspace.length > 0; implicitHeight: 27
                hoverEnabled: true
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: "Manage linked papers and captures in this reading workspace"
                onClicked: window.manageWorkspace(window.activeWorkspace)
            }
            StatusIcon { kind: "split"; description: "Duplicate tab to right split"; visible: !window.homeVisible; selected: documents.groupCount > 1; onTriggered: documents.duplicateSplit("right") }
            Repeater {
                model: window.dockPanels.filter(function(p) { return window.panelSide(p) === "right" })
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
