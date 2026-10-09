import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform
import "Shortcuts.js" as Shortcuts
import "WorkspaceTree.js" as Tree

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    visible: true
    width: 1440; height: 930
    minimumWidth: 880; minimumHeight: 580
    title: ""
    color: Theme.window
    // The platform UI font (San Francisco, Segoe UI, the desktop font on Linux).
    font.pixelSize: Theme.fontBody
    palette.window: Theme.sidebar
    palette.windowText: Theme.text
    palette.highlight: Theme.accent
    palette.highlightedText: Theme.onAccent
    palette.button: Theme.control
    palette.buttonText: Theme.text
    palette.text: Theme.text
    palette.base: Theme.content
    palette.alternateBase: Theme.window
    // Rich and Markdown text links (notes, AI answers) use the accent, not default blue.
    palette.link: Theme.accent
    palette.linkVisited: Theme.accent
    palette.light: Theme.content
    palette.midlight: Theme.window
    palette.mid: Theme.border
    palette.dark: Theme.textTertiary
    palette.shadow: Theme.shadow
    palette.placeholderText: Theme.textTertiary
    palette.toolTipBase: Theme.raised
    palette.toolTipText: Theme.text
    palette.brightText: Theme.onAccent
    // Vertical tabs (Settings → Appearance): the list beside the window is open or a thin rail.
    property bool tabsPanelOpen: researchStore.setting("tabs.panelOpen", "1") === "1"
    function setTabsPanel(open) { tabsPanelOpen = open; researchStore.setSetting("tabs.panelOpen", open ? "1" : "0") }
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
    readonly property var leftPanels: panelsForSide("left")
    readonly property var rightPanels: panelsForSide("right")
    property bool initialized: false
    property bool restoreFailed: false
    property string notification: ""
    property alias documents: documents
    readonly property var currentReader: documents.currentReader
    // Shortcuts the reader changed in Settings (id → keys; "" turns one off).
    property var shortcutOverrides: Shortcuts.parse(researchStore.setting("shortcuts"))
    function keys(id) { return Shortcuts.keys(id, shortcutOverrides, Qt.platform.os) }
    Connections { target: researchStore; function onSettingsChanged() { window.shortcutOverrides = Shortcuts.parse(researchStore.setting("shortcuts")) } }

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
    function panelName(panel) { return panel === "files" ? "Library" : panel === "captures" ? "Captures" : panel === "ai" ? "AI threads" : "Document outline and thumbnails" }
    function setPanelShown(panel, shown) {
        if (panel === "files") filesVisible = shown
        else if (panel === "captures") shelfVisible = shown
        else if (panel === "ai") aiVisible = shown
        else documentVisible = shown
    }
    // One panel per dock: opening one (or moving it into a dock) closes the other there.
    function closeOthers(panel) {
        const side = panelSide(panel)
        dockPanels.forEach(function(other) { if (other !== panel && panelShown(other) && panelSide(other) === side) setPanelShown(other, false) })
    }
    // Reader and capture actions bring the AI panel forward and start a thread there.
    function showAi() { setPanelShown("ai", true); closeOthers("ai") }
    function askAi(spec) { showAi(); aiController.begin(spec) }
    function openAiThread(id) { if (aiController.openThread(id)) showAi() }
    // The AI panel shows this thread right now (panel open and in front in its dock).
    function aiThreadInView(id) {
        const dock = aiSide === "left" ? leftDock : rightDock
        return aiVisible && dock.activePanel === "ai" && aiController.conversationOpen && aiController.threadId === id
    }
    function togglePanel(panel) {
        const shown = panelShown(panel)
        setPanelShown(panel, !shown)
        if (!shown) closeOthers(panel)
    }
    function movePanel(panel, side) {
        if (side !== "left" && side !== "right") return
        if (panel === "files") filesSide = side
        if (panel === "captures") capturesSide = side
        if (panel === "document") documentSide = side
        if (panel === "ai") aiSide = side
        if (panelShown(panel)) closeOthers(panel)
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
    // Cmd/Ctrl+W, as in browsers: the tab in front; Home shown over open tabs goes back to them;
    // with nothing left to close, the window itself.
    function closeTabOrWindow() {
        if (!documents.hasTabs || restoreFailed) window.close()
        else if (homeVisible) homeVisible = false
        else documents.closeActiveTab()
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
        else if (result.kind === "standalone-note" && !restoreFailed) documents.openNote(result.id)
        else if (result.kind === "ai") openAiThread(result.id)
        else if (result.kind === "collection" && !restoreFailed) documents.openLibrary({collection: result.id})
        else if (result.kind === "tag" && !restoreFailed) documents.openLibrary({tag: result.id})
        else if (result.kind === "text" && !restoreFailed) { notify("Checking PDF source…"); researchStore.paperIndex.openResult(result.documentId, Number(result.page), result.sha256) }
    }
    function persist() {
        if (!initialized || restoreFailed) return false
        const state = documents.snapshot()
        Object.assign(state, {shelf: shelfVisible, width: width, height: height, panels: {filesVisible: filesVisible, filesSide: filesSide, capturesSide: capturesSide,
                documentVisible: documentVisible, documentSide: documentSide, aiVisible: aiVisible, aiSide: aiSide, navigationMode: navigationMode,
                folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel,
                leftWidth: leftDockWidth, rightWidth: rightDockWidth}})
        return researchStore.saveSession(state)
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
        navigationMode = [0, 1, 2, 3, 4].indexOf(panels.navigationMode) >= 0 ? panels.navigationMode : 0
        paperFolder = panels.folder || ""
        // Sessions from when a dock held several panels keep the one in front.
        for (const side of ["left", "right"]) {
            const list = panelsForSide(side), front = side === "left" ? panels.leftActive : panels.rightActive
            if (list.length > 1) closeOthers(list.indexOf(front) >= 0 ? front : list[0])
        }
        try { documents.restore(state) }
        catch (error) { restoreFailed = true; notification = error.message }
        initialized = true
        // Files from the command line, Finder or a second launch made before the window was ready.
        const external = initialFiles.concat(typeof appInstance !== "undefined" ? appInstance.takePending() : [])
        if (!restoreFailed) for (let i = 0; i < external.length; ++i) documents.openDocument(external[i])
        homeVisible = restoreFailed || external.length === 0
        if (!restoreFailed) persist()
        // After a restore or an unexpected exit, say what happened.
        if (!restoreFailed && researchStore.startupMessage.length) notify(researchStore.startupMessage)
        else if (!restoreFailed && researchStore.recoveredFromCrash) notify("Owelk closed unexpectedly last time. Your tabs are back; unsaved notes are offered when you reopen them.")
    }
    // PDFs opened from Finder or handed over by another launch while this window is open.
    Connections {
        target: typeof appInstance !== "undefined" ? appInstance : null
        function onFilesRequested(urls) {
            if (!window.visible) window.show()
            window.raise(); window.requestActivate()
            if (window.restoreFailed || !urls.length) return
            urls.forEach(function(url) { window.openDocument(url) })
            window.homeVisible = false
        }
    }
    // Logging out or quitting from the dock can skip the window's close handler.
    Connections { target: Qt.application; function onAboutToQuit() { window.persist() } }
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
        function onPapersDeleted(sources) { documents.closeSources(sources) }
        function onRelinkFinished(success, detail) { if (success) window.notify(detail) }
        function onCaptureSaved(id) {
            // A capture asked for by the AI panel joins the question; others open the shelf.
            if (aiController.takeCapture(id)) { window.showAi(); return }
            window.shelfVisible = true; window.movePanel("captures", window.capturesSide)
        }
        function onSourceReady(url, page, region) { if (!window.restoreFailed) { documents.reveal(url, page, region); window.homeVisible = false } }
        function onPassageReady(url, page, region) { if (!window.restoreFailed) { documents.reveal(url, page, region, true); window.homeVisible = false } }
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
            case "/organize tabs": window.organizeTabsIn(""); break
            case "/ask library": window.askAi({action: "ask", scope: "library"}); break
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
            case "/fit page": if (window.currentReader) window.currentReader.fitPage(); break
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
            Action { objectName: "newNoteAction"; text: "New Note"; shortcut: window.keys("newNote"); enabled: !window.restoreFailed; onTriggered: documents.newNote() }
            Action { objectName: "openWebAction"; text: "Open Web Page…"; shortcut: window.keys("openWeb"); enabled: !window.restoreFailed; onTriggered: window.openWebAddress() }
            Action { objectName: "settingsAction"; text: "Settings…"; shortcut: Qt.platform.os === "osx" ? StandardKey.Preferences : "Ctrl+,"; onTriggered: settingsDialog.open() }
            Action { objectName: "newTabAction"; text: "New Tab"; shortcut: window.keys("newTab"); enabled: !window.restoreFailed && !(window.currentReader && window.currentReader.annotationDirty); onTriggered: documents.newHomeTab() }
            Action { objectName: "closeTabAction"; text: documents.hasTabs ? "Close Tab" : "Close Window"; shortcut: window.keys("closeTab"); enabled: !(!window.homeVisible && window.currentReader && window.currentReader.annotationDirty); onTriggered: window.closeTabOrWindow() }
            Action { text: "Reopen Closed Tab"; shortcut: window.keys("reopenTab"); enabled: documents.closedTabs.length > 0 && !window.restoreFailed; onTriggered: documents.reopenClosedTab() }
            Action { objectName: "nextTabAction"; text: "Next Tab"; shortcut: window.keys("nextTab"); enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(1) }
            Action { objectName: "previousTabAction"; text: "Previous Tab"; shortcut: window.keys("previousTab"); enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(-1) }
            MenuSeparator {}
            Action { text: "Quit"; shortcut: StandardKey.Quit; onTriggered: window.close() }
        }
        Menu {
            title: "View"
            Action { text: "Home"; shortcut: window.keys("home"); onTriggered: window.showHome() }
            Action { objectName: "libraryAction"; text: "Library"; shortcut: window.keys("library"); enabled: !window.restoreFailed; onTriggered: documents.openLibrary({}) }
            Action { objectName: "tabsPanelAction"; text: window.tabsPanelOpen ? "Hide Vertical Tabs" : "Show Vertical Tabs"; shortcut: window.keys("tabsPanel"); enabled: Theme.verticalTabs; onTriggered: window.setTabsPanel(!window.tabsPanelOpen) }
            Action { text: "Search Research"; shortcut: window.keys("search"); onTriggered: { commandPalette.close(); searchPalette.open() } }
            Action { text: "Command Palette"; shortcut: window.keys("commands"); onTriggered: { searchPalette.close(); commandPalette.open() } }
            Action { text: "Find"; shortcut: StandardKey.Find; onTriggered: window.findInView() }
            Action { text: "Zoom in"; shortcut: StandardKey.ZoomIn; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1.2) }
            Action { text: "Zoom out"; shortcut: StandardKey.ZoomOut; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1 / 1.2) }
            Action { objectName: "jumpBackAction"; text: "Back to Previous Spot"; shortcut: window.keys("jumpBack"); enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.goBack() }
            Action { objectName: "jumpForwardAction"; text: "Forward to Next Spot"; shortcut: window.keys("jumpForward"); enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.goForward() }
            Action { objectName: "fitWidthAction"; text: "Fit Width"; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.fitWidth() }
            Action { objectName: "fitPageAction"; text: "Fit Page"; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.fitPage() }
            Action { text: "Capture region"; shortcut: window.keys("capture"); enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.toggleCapture() }
            MenuSeparator {}
            Action { objectName: "splitRightAction"; text: "Duplicate to Right Split"; shortcut: window.keys("splitRight"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.duplicateSplit("right") }
            Action { objectName: "splitDownAction"; text: "Duplicate to Bottom Split"; shortcut: window.keys("splitDown"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.duplicateSplit("bottom") }
            Action { objectName: "moveRightAction"; text: "Move Tab to Right Split"; shortcut: window.keys("moveRight"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.moveActiveTabToSplit("right") }
            Action { objectName: "moveDownAction"; text: "Move Tab to Bottom Split"; shortcut: window.keys("moveDown"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.moveActiveTabToSplit("bottom") }
            Action { objectName: "nextSplitAction"; text: "Focus Next Split"; shortcut: window.keys("nextSplit"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.focusGroup(1) }
            Action { objectName: "previousSplitAction"; text: "Focus Previous Split"; shortcut: window.keys("previousSplit"); enabled: !window.homeVisible && window.canSwitchTabs; onTriggered: documents.focusGroup(-1) }
            Action { text: "Join All Groups"; enabled: !window.homeVisible; onTriggered: documents.joinAll() }
        }
    }
    CaptureNoteDialog { id: captureNote }
    // An answer arrived while its thread is not in view: a card at the bottom right (Open / Dismiss),
    // and while another app is in front, the Dock icon bounces once (the taskbar flashes on Linux).
    AiNotice {
        id: aiNotice
        parent: window.contentItem
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: 16; anchors.bottomMargin: 40
        onOpenRequested: function(id) { window.requestActivate(); window.openAiThread(id) }
    }
    Connections {
        target: aiController
        function onAnswered(id, title, preview) {
            if (!window.active) window.alert(0)
            if (!window.active || !window.aiThreadInView(id)) aiNotice.show(id, title, preview)
        }
    }
    SettingsDialog { id: settingsDialog }
    // Created on first use: the AI tab organizer.
    Loader { id: organizeTabs; active: false; sourceComponent: OrganizeTabsDialog { controller: documents } }
    // Created on first use: the AI paper comparison, for the PDFs open in a tab strip.
    Loader { id: comparePapers; active: false; sourceComponent: ComparePapersDialog { onNoteCreated: function(id) { documents.openNote(id) } } }
    function comparePapersIn(groupId) {
        if (window.restoreFailed) return
        const strip = Tree.find(documents.tree, groupId || documents.activeGroup)
        const seen = {}
        const urls = (strip ? strip.tabs : []).filter(function(t) {
            if (t.kind || seen[t.source]) return false
            seen[t.source] = true
            return true
        }).map(function(t) { return t.source })
        comparePapers.active = true
        comparePapers.item.begin(urls)
    }
    function organizeTabsIn(groupId) {
        if (restoreFailed || homeVisible) return
        organizeTabs.active = true
        organizeTabs.item.begin(groupId || documents.activeGroup)
    }
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
        width: Math.min(620, parent.width - 32); height: duplicateRow.implicitHeight + 16
        color: Theme.raised; border.color: Theme.border; radius: Theme.radiusLarge
        RowLayout {
            id: duplicateRow
            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12; anchors.rightMargin: 6
            spacing: 6
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Label { Layout.fillWidth: true; text: "This PDF is already in your Library"; font.weight: Font.DemiBold; color: Theme.text; wrapMode: Text.Wrap }
                // The title wraps to two lines; anything longer shows in full on hover.
                Label {
                    Layout.fillWidth: true
                    text: "\u201c" + duplicateBar.existingTitle + "\u201d"
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                }
            }
            Button {
                objectName: "openExistingCopy"; text: "Use Existing"; focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: "Read the paper already in your Library (with its notes). This extra entry is set aside; no file is deleted."
                onClicked: {
                    if (researchStore.useExistingCopy(duplicateBar.source, duplicateBar.existing))
                        documents.relinkSource(duplicateBar.source, duplicateBar.existing)
                    duplicateBar.close()
                }
            }
            Button {
                objectName: "keepBothCopies"; text: "Keep Both"; focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: "Keep two separate papers, each with its own notes. Owelk won't ask again about this file."
                onClicked: { researchStore.keepDuplicate(duplicateBar.source); duplicateBar.close() }
            }
            IconButton { icon.name: "close"; description: "Dismiss"; focusPolicy: Qt.NoFocus; onClicked: duplicateBar.close() }
        }
    }
    // Areas are slices separated by 1px edges; an edge darkens under the pointer and drags to resize.
    component ResizeEdge: Rectangle {
        id: edge
        property alias area: grip
        signal moved(real delta)
        property real initialWidth
        Layout.preferredWidth: 1; Layout.fillHeight: true
        z: 2
        color: grip.containsMouse || grip.pressed ? Theme.border : Theme.separator
        MouseArea {
            id: grip
            anchors.fill: parent; anchors.leftMargin: -3; anchors.rightMargin: -3
            hoverEnabled: true; cursorShape: Qt.SplitHCursor
            preventStealing: true
            property real origin
            onPressed: function(mouse) { origin = mapToItem(window.contentItem, mouse.x, mouse.y).x; edge.moved(0) }
            onPositionChanged: function(mouse) { if (pressed) edge.moved(mapToItem(window.contentItem, mouse.x, mouse.y).x - origin) }
        }
    }
    RowLayout {
        anchors.fill: parent
        spacing: 0
        TabsPanel {
            id: tabsPanel
            visible: Theme.verticalTabs && !window.restoreFailed
            controller: documents
            open: window.tabsPanelOpen
            openWidth: Number(researchStore.setting("tabs.panelWidth", "240")) || 240
            onWidthChosen: function(width) { researchStore.setSetting("tabs.panelWidth", String(Math.round(width))) }
            onToggleRequested: window.setTabsPanel(!window.tabsPanelOpen)
            onTabChosen: window.homeVisible = false
            Layout.preferredWidth: implicitWidth; Layout.fillHeight: true
        }
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"; panels: window.leftPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            aiController: aiController
            onSettingsRequested: settingsDialog.openPage("ai")
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onAiRequested: function(spec) { window.askAi(spec) }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.leftDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            documents: documents
            onLibraryFilterRequested: function(filter) { if (!window.restoreFailed) { window.homeVisible = false; documents.openLibrary(filter) } }
            onNoteRequested: function(id) { captureNote.begin(id) }
            onActivePanelChanged: window.scheduleSave()
        }
        ResizeEdge {
            visible: leftDock.visible
            area.objectName: "leftDockResize"
            onMoved: function(delta) {
                if (delta === 0) initialWidth = leftDock.width
                window.leftDockWidth = window.dockWidth(initialWidth + delta)
            }
        }
        HomeView {
            id: homeView
            visible: window.homeVisible
            Layout.fillWidth: true; Layout.fillHeight: true
            onOpenRequested: window.chooseFile()
            onDocumentChosen: function(source, position) { window.openDocument(source, position) }
            onResultChosen: function(result) { window.openSearchResult(result) }
            onLibraryRequested: if (!window.restoreFailed) documents.openLibrary({})
            onLibraryFilterRequested: function(filter) { if (!window.restoreFailed) documents.openLibrary(filter) }
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
            onOrganizeRequested: function(groupId) { window.organizeTabsIn(groupId) }
            onCompareRequested: function(groupId) { window.comparePapersIn(groupId) }
        }
        ResizeEdge {
            visible: rightDock.visible
            area.objectName: "rightDockResize"
            onMoved: function(delta) {
                if (delta === 0) initialWidth = rightDock.width
                window.rightDockWidth = window.dockWidth(initialWidth - delta)
            }
        }
        DockSidebar {
            id: rightDock
            objectName: "rightDock"
            side: "right"; panels: window.rightPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            aiController: aiController
            onSettingsRequested: settingsDialog.openPage("ai")
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onAiRequested: function(spec) { window.askAi(spec) }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.rightDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            documents: documents
            onLibraryFilterRequested: function(filter) { if (!window.restoreFailed) { window.homeVisible = false; documents.openLibrary(filter) } }
            onNoteRequested: function(id) { captureNote.begin(id) }
            onActivePanelChanged: window.scheduleSave()
        }
    }
    footer: Rectangle {
        id: statusBar
        objectName: "statusBar"
        height: 29
        color: Theme.sidebar
        Rectangle { width: parent.width; height: 1; color: Theme.separator } // The edge above it.
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
                    description: window.panelName(kind)
                    selected: window.panelShown(kind)
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
            Label {
                Layout.fillWidth: true
                // A notice while there is one.
                text: window.notification.length ? window.notification : researchStore.busy ? "Saving capture…" : ""
                elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
            }
            StatusIcon { kind: "search"; description: "Search · " + Platform.keys("Ctrl+K"); onTriggered: { commandPalette.close(); searchPalette.open() } }
            StatusIcon { kind: "split"; description: "Duplicate to right split · " + Platform.keys("Ctrl+\\"); visible: !window.homeVisible; selected: documents.groupCount > 1; onTriggered: documents.duplicateSplit("right") }
            Repeater {
                model: window.dockPanels.filter(function(p) { return window.panelSide(p) === "right" })
                delegate: StatusIcon {
                    required property string modelData
                    objectName: "dockIcon-" + modelData
                    kind: modelData; dockSide: "right"
                    description: window.panelName(kind)
                    selected: window.panelShown(kind)
                    onTriggered: window.togglePanel(kind)
                    onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                }
            }
        }
    }
}
