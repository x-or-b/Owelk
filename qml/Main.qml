import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform
import "Shortcuts.js" as Shortcuts
import "WorkspaceTree.js" as Tree
import "WebSearch.js" as WebSearch

ApplicationWindow {
    id: window
    objectName: "mainWindow"
    visible: true
    width: 1440; height: 930
    minimumWidth: 880; minimumHeight: 580
    title: ""
    // In focus mode the strip a camera notch keeps free (full screen) takes the pages' backdrop, so it blends in.
    color: focusMode ? Theme.pdfBackdrop : Theme.window
    // macOS: the window draws under the title bar, where the top bar takes its place beside the traffic lights.
    // (Only on a real macOS desktop: the offscreen platform keeps the menu bar inside the window.)
    readonly property bool unifiedTitleBar: Qt.platform.os === "osx" && Qt.platform.pluginName === "cocoa"
    flags: unifiedTitleBar ? Qt.Window | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint : Qt.Window
    // The top bar (Back, Forward, search, ≡): always on macOS, where it is the title bar; on Windows and Linux a
    // choice in Settings › Appearance, off unless chosen, so the window has one row fewer. Off, its search is Home's
    // (Cmd+K elsewhere) and its buttons go to the tab strip. With vertical tabs it stays: no strip on top takes them.
    property string topBarChoice: researchStore.setting("appearance.topBar")
    Connections { target: researchStore; function onSettingsChanged() { window.topBarChoice = researchStore.setting("appearance.topBar") } }
    readonly property bool topBarHidden: !unifiedTitleBar && !Theme.verticalTabs
        && (topBarChoice.length ? topBarChoice === "hide" : Qt.platform.os !== "osx")
    // Focus mode (⌘⇧F, Ctrl+Shift+F): only the pages and the side panels; no top bar, tab strips or reader toolbars.
    // The window goes full screen too unless Settings › General says otherwise, and back as it was when it ends. The
    // top edge brings a bar back for a moment; the left and right edges open a side panel. Not remembered: Owelk
    // starts as usual.
    property bool focusMode: false
    property bool focusPeek: false
    // The bar kept down (its pin), with room made for it above the pages; remembered on this computer.
    property bool focusPinned: researchStore.setting("focus.pinned") === "1"
    readonly property bool focusBarShown: focusMode && (focusPeek || focusPinned)
    function setFocusPinned(on) {
        focusPinned = on
        researchStore.setSetting("focus.pinned", on ? "1" : "0")
        // Unpinned under the pointer: it stays until the pointer leaves.
        if (!on) { focusPeek = focusTopHover.hovered; if (!focusPeek) focusLeave.restart() }
    }
    // macOS keeps a blank strip for the title bar's (empty) toolbar in full screen; it goes while full screen lasts.
    onVisibilityChanged: if (typeof windowChrome !== "undefined") windowChrome.setToolbarShown(window, visibility !== Window.FullScreen)
    property int visibilityBeforeFocus: Window.Windowed
    function setFocusMode(on) {
        if (on === focusMode || (on && restoreFailed)) return
        if (on) {
            visibilityBeforeFocus = window.visibility
            focusMode = true
            if (researchStore.setting("focus.fullScreen", "1") === "1" && window.visibility !== Window.FullScreen) window.showFullScreen()
        } else {
            focusMode = false
            focusPeek = false
            if (window.visibility === Window.FullScreen && visibilityBeforeFocus !== Window.FullScreen) {
                if (visibilityBeforeFocus === Window.Maximized) window.showMaximized()
                else window.showNormal()
            }
        }
    }
    // Focus mode's tab list: every strip's tabs (a line between strips), the one in front marked, ⌘1–9 beside the
    // tabs of the strip in front, then New Tab.
    function focusTabRows() {
        const rows = []
        Tree.leaves(documents.tree).forEach(function(g, at) {
            if (at > 0) rows.push({separator: true})
            const front = g.id === documents.activeGroup
            g.tabs.forEach(function(t, i) {
                rows.push({id: t.id, title: Tree.tabTitle(t, function(source) { return researchStore.displayName(source) }),
                           current: front && g.activeTab === t.id && !window.homeVisible,
                           keys: front ? (i < 8 ? Platform.keys("Ctrl+" + (i + 1)) : i === g.tabs.length - 1 ? Platform.keys("Ctrl+9") : "") : ""})
            })
        })
        if (rows.length) rows.push({separator: true})
        rows.push({newTab: true, title: qsTr("New Tab"), keys: Platform.keys(window.keys("newTab"))})
        return rows
    }
    function focusTabTitle() {
        const revision = documents.revision
        const g = Tree.find(documents.tree, documents.activeGroup)
        const t = g ? g.tabs.find(function(tab) { return tab.id === g.activeTab }) : null
        return t ? Tree.tabTitle(t, function(source) { return researchStore.displayName(source) }) : qsTr("No open tabs")
    }
    // The field the search results hang from: the top bar's, or without it Home's while Home is in front.
    readonly property var searchHost: {
        if (topBar.visible) return topBar.searchBox
        if (!topBarHidden && !focusMode) return null
        if (homeVisible) return homeView.searchBox
        const revision = documents.revision
        const view = documents.groupView(documents.activeGroup)
        return view && view.isHome && view.homeView ? view.homeView.searchBox : null
    }

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
    property bool filesVisible: true
    // First start: Threads and the AI on the left, Document and Library on the right.
    property string filesSide: "right"
    property bool documentVisible: false
    property string documentSide: "right"
    property bool aiVisible: false
    property string aiSide: "left"
    // Threads (folders of AI chats) is a panel of its own, always on the outer side of its
    // dock, so beside the AI panel it is the farther one; it opens and closes on its own.
    property bool threadsVisible: false
    property string threadsSide: "left"
    property real threadsWidth: 220
    function threadsPanelWidth(value) { return Math.max(160, Math.min(value, 420, (width - 360) / 3)) }
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
        if (documentVisible && documentSide === side) panels.push("document")
        if (aiVisible && aiSide === side) panels.push("ai")
        return panels
    }
    readonly property var dockPanels: ["files", "document", "ai"]
    function panelSide(panel) { return panel === "files" ? filesSide : panel === "ai" ? aiSide : panel === "threads" ? threadsSide : documentSide }
    function panelShown(panel) { return panel === "files" ? filesVisible : panel === "ai" ? aiVisible : panel === "threads" ? threadsVisible : documentVisible }
    function panelName(panel) { return panel === "files" ? qsTr("Library") : panel === "ai" ? qsTr("AI chat") : panel === "threads" ? qsTr("Threads") : qsTr("Document: contents, annotations, symbols and related papers") }
    function setPanelShown(panel, shown) {
        if (panel === "files") filesVisible = shown
        else if (panel === "ai") aiVisible = shown
        else if (panel === "threads") threadsVisible = shown
        else documentVisible = shown
    }
    // Left to right: Threads, AI chat, Library, Document; the right side the other way round, Threads last.
    readonly property var panelOrder: ["threads", "ai", "files", "document"]
    function panelIcons(side) {
        const order = side === "left" ? panelOrder : panelOrder.slice().reverse()
        return order.filter(function(p) { return panelSide(p) === side })
    }
    // One panel per dock: opening one (or moving it into a dock) closes the other there.
    function closeOthers(panel) {
        if (panel === "threads") return
        const side = panelSide(panel)
        dockPanels.forEach(function(other) { if (other !== panel && panelShown(other) && panelSide(other) === side) setPanelShown(other, false) })
    }
    // Reader actions bring the AI panel forward and start a thread there.
    function showAi() { setPanelShown("ai", true); closeOthers("ai") }
    function askAi(spec) { showAi(); aiController.begin(spec) }
    // Ask AI (shortcut): about the selection in the paper in front, or a new chat about that paper.
    function askAiNow() {
        if (!homeVisible && currentReader && currentReader.selectedText.length) { currentReader.askAboutSelection(); return }
        showAi()
        aiController.newThread()
    }
    // A For You paper's page (its abstract), in a web tab of its own.
    function openForYouPage(address) {
        if (window.restoreFailed || !address || !address.toString().length) return
        homeVisible = false
        documents.openWeb(address, true, "", true)
    }
    Connections { target: researchStore.forYou; function onWebRequested(address) { window.openForYouPage(address) } }
    function openAiThread(id) { if (aiController.openThread(id)) showAi() }
    // A new chat from the Threads panel, in the Thread it was asked for (spec.folder).
    function newAiChat(spec) {
        showAi()
        aiController.newThread(undefined, spec && spec.folder ? spec.folder : "")
    }
    // The Document panel's Annotations view (the reader toolbar button opens and closes it).
    function toggleAnnotations() {
        if (documentVisible && navigationMode === 1) { documentVisible = false; return }
        showDocumentView(1)
    }
    // The Document panel open at one of its views (0 Contents, 1 Annotations, 2 Symbols, 3 Related, 4 Figures).
    function showDocumentView(mode) {
        navigationMode = mode
        setPanelShown("document", true); closeOthers("document")
    }
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
        if (panel === "document") documentSide = side
        if (panel === "ai") aiSide = side
        if (panel === "threads") threadsSide = side
        if (panelShown(panel)) closeOthers(panel)
    }
    // Tab switching must not discard an annotation that is still being edited.
    readonly property bool canSwitchTabs: documents.hasTabs && !restoreFailed && !(currentReader && currentReader.annotationDirty)
    // Browser conventions alongside the menu shortcuts: Cmd+Shift+] / [, Control+Tab, Cmd+1…9 (9 = last tab).
    Shortcut {
        sequence: "Ctrl+Shift+]"
        enabled: window.canSwitchTabs
        onActivated: documents.cycleTab(1)
    }
    Shortcut {
        sequence: "Ctrl+Shift+["
        enabled: window.canSwitchTabs
        onActivated: documents.cycleTab(-1)
    }
    // Control+Tab: the next tab, or back and forth between the last two (Settings › Appearance › Tabs).
    function controlTab(step) {
        if (researchStore.setting("tabs.controlTab", "next") === "recent" && documents.switchToPreviousTab()) return
        documents.cycleTab(step)
    }
    Shortcut {
        sequence: Qt.platform.os === "osx" ? "Meta+Tab" : "Ctrl+Tab"
        enabled: window.canSwitchTabs
        onActivated: window.controlTab(1)
        onActivatedAmbiguously: window.controlTab(1)
    }
    Shortcut {
        sequence: Qt.platform.os === "osx" ? "Meta+Shift+Tab" : "Ctrl+Shift+Tab"
        enabled: window.canSwitchTabs
        onActivated: window.controlTab(-1)
        onActivatedAmbiguously: window.controlTab(-1)
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
    // Owelk's window in front (from Finder, another launch, the desktop pet).
    function comeForward() {
        if (!window.visible) window.show()
        else if (window.visibility === Window.Minimized) window.showNormal()
        window.raise(); window.requestActivate()
    }
    // The desktop pet (or its bubble) asked: Owelk's window comes to the desktop (macOS Space) the pet was clicked
    // on, as a pet brings things to you, instead of the screen going to the window's desktop.
    function comeHere() {
        if (typeof windowChrome !== "undefined") windowChrome.bringToThisDesktop(window)
        comeForward()
    }
    function showHome() { persist(); homeVisible = true; Qt.callLater(function() { window.focusSearch(false) }) }
    // The top bar's search field: the cursor in it (Home, a new tab), or its results open too (Cmd+K).
    function focusSearch(withResults) {
        commandPalette.close()
        const host = searchHost
        if (!host) { if (withResults) searchPalette.open(); return }
        if (withResults) searchPalette.begin()
        else { host.field.forceActiveFocus(); host.field.selectAll() }
    }
    // Cmd+L: the address bar of the current web tab, or a new web tab when a paper or Home is in front.
    function openWebAddress() {
        if (restoreFailed) return
        const view = documents.groupView(documents.activeGroup)
        if (!homeVisible && view && view.isWeb && view.webPane) { view.webPane.focusAddress(); return }
        // A new web tab opens on the default search engine's own page.
        if (documents.openWeb(WebSearch.home(WebSearch.template(researchStore)), true))
            Qt.callLater(function() { const next = documents.groupView(documents.activeGroup); if (next) next.focusAddress() })
    }
    function findInView() {
        if (homeVisible) focusSearch(true)
        else if (currentReader) currentReader.find()
        else { const view = documents.groupView(documents.activeGroup); if (view) view.focusHome() }
    }
    // Where one has been, as a browser keeps it: Home, or a tab (Library, a paper, a note, a web page).
    // Back and forward step through these places once the tab in front has none of its own to go through.
    property var places: []
    property int placeIndex: -1
    property bool replaying: false
    function placeKey() { return homeVisible || !documents.currentTab.length ? "home" : "tab:" + documents.currentTab }
    function recordPlace() {
        if (!initialized || replaying || restoreFailed) return
        const key = placeKey()
        if (places[placeIndex] === key) return
        places = places.slice(0, placeIndex + 1).concat([key]).slice(-60)
        placeIndex = places.length - 1
    }
    onHomeVisibleChanged: Qt.callLater(recordPlace)
    Connections { target: documents; function onCurrentTabChanged() { Qt.callLater(window.recordPlace) } }
    function placeExists(key) { return key === "home" || Tree.leaves(documents.tree).some(function(g) { return g.tabs.some(function(t) { return "tab:" + t.id === key }) }) }
    function placeStep(step) {
        let at = placeIndex + step
        while (at >= 0 && at < places.length && (!placeExists(places[at]) || places[at] === placeKey())) at += step
        return at >= 0 && at < places.length ? at : -1
    }
    readonly property bool canGoBackPlace: (places, placeIndex, documents.tree, homeVisible, placeStep(-1) >= 0)
    readonly property bool canGoForwardPlace: (places, placeIndex, documents.tree, homeVisible, placeStep(1) >= 0)
    function goToPlace(step) {
        const at = placeStep(step)
        if (at < 0) return false
        replaying = true
        placeIndex = at
        const key = places[at]
        if (key === "home") showHome()
        else { homeVisible = false; documents.activateTab(key.slice(4)) }
        Qt.callLater(function() { window.replaying = false })
        return true
    }
    // Back and forward in what is in front first: a web tab's pages, or the reader's jumps (links, citations).
    readonly property var frontWeb: {
        const view = (documents.tree, documents.activeGroup, documents.groupView(documents.activeGroup))
        return !homeVisible && view && view.isWeb ? view.webPane : null
    }
    readonly property bool tabCanGoBack: frontWeb ? frontWeb.view.canGoBack : !homeVisible && !!currentReader && currentReader.canGoBack
    readonly property bool tabCanGoForward: frontWeb ? frontWeb.view.canGoForward : !homeVisible && !!currentReader && currentReader.canGoForward
    readonly property bool canGoBack: tabCanGoBack || canGoBackPlace
    readonly property bool canGoForward: tabCanGoForward || canGoForwardPlace
    function goBack() {
        if (frontWeb && frontWeb.view.canGoBack) frontWeb.view.goBack()
        else if (!frontWeb && !homeVisible && currentReader && currentReader.canGoBack) currentReader.goBack()
        else goToPlace(-1)
    }
    function goForward() {
        if (frontWeb && frontWeb.view.canGoForward) frontWeb.view.goForward()
        else if (!frontWeb && !homeVisible && currentReader && currentReader.canGoForward) currentReader.goForward()
        else goToPlace(1)
    }
    Binding { target: swipeNavigation; property: "window"; value: window }
    Binding { target: swipeNavigation; property: "enabled"; value: window.active && swipeNavigation.systemSwipes() }
    function swipeAllowed(x, y, back, towardLeft) {
        if (window.frontWeb || (back ? !window.canGoBack : !window.canGoForward)) return false
        const surface = window.homeVisible ? homeView : documents.groupView(documents.activeGroup)
        if (!surface) return false
        const p = surface.mapFromItem(null, x, y)
        if (p.x < 0 || p.y < 0 || p.x > surface.width || p.y > surface.height) return false
        if (!window.homeVisible && window.currentReader && window.currentReader.visible) {
            const canvas = window.currentReader.pdfCanvas
            const c = canvas.mapFromItem(null, x, y)
            if (c.x < 0 || c.y < 0 || c.x > canvas.width || c.y > canvas.height || canvas.overPreview) return false
            if (canvas.canScrollAcross(towardLeft)) return false
        }
        return true
    }
    Connections {
        target: swipeNavigation
        function onBack() { window.goBack() }
        function onForward() { window.goForward() }
    }
    Rectangle {
        parent: Overlay.overlay
        readonly property real progress: swipeNavigation.progress
        readonly property real amount: Math.abs(progress)
        visible: amount > 0
        width: Theme.controlHeight; height: width; radius: width / 2
        x: progress < 0 ? -width + (width + 12) * amount : parent.width - (width + 12) * amount
        y: (parent.height - height) / 2
        color: amount >= 1 ? Theme.accent : Theme.raised
        border.width: 1; border.color: Theme.border
        Icon { anchors.centerIn: parent; name: parent.progress < 0 ? "back" : "forward"; color: parent.amount >= 1 ? Theme.onAccent : Theme.text }
    }
    function openDocument(source, position) { if (!restoreFailed) documents.openDocument(researchStore.resolvedSource(source), position) }
    function openSearchResult(result) {
        if (result.kind === "paper") openDocument(result.source, result.position)
        else if (result.kind === "highlight") researchStore.openHighlight(result.id)
        else if (result.kind === "note" && !restoreFailed) documents.openNote(result.id)
        else if (result.kind === "ai") openAiThread(result.id)
        else if (result.kind === "collection" && !restoreFailed) documents.openLibrary({collection: result.id})
        else if (result.kind === "tag" && !restoreFailed) documents.openLibrary({tag: result.id})
        else if (result.kind === "text" && !restoreFailed) { notify(qsTr("Checking PDF source…")); researchStore.paperIndex.openResult(result.documentId, Number(result.page), result.sha256) }
    }
    function persist() {
        if (!initialized || restoreFailed) return false
        const state = documents.snapshot()
        Object.assign(state, {width: width, height: height, panels: {filesVisible: filesVisible, filesSide: filesSide,
                documentVisible: documentVisible, documentSide: documentSide, aiVisible: aiVisible, aiSide: aiSide, navigationMode: navigationMode,
                threadsVisible: threadsVisible, threadsSide: threadsSide, threadsWidth: threadsWidth,
                folder: paperFolder.toString(), leftActive: leftDock.activePanel, rightActive: rightDock.activePanel,
                leftWidth: leftDockWidth, rightWidth: rightDockWidth}})
        return researchStore.saveSession(state)
    }
    // Long work in progress, for the status bar: the store's tasks (folder imports, copying PDFs, downloads)
    // and what reports its own progress (text and meaning indexing, sync, backup). total 0: no measure.
    readonly property var activities: {
        const list = researchStore.tasks.slice()
        const counted = function(id, label) {
            const m = /(\d+)\s*\/\s*(\d+)/.exec(label || "")
            return {id: id, label: label, done: m ? Number(m[1]) : 0, total: m ? Number(m[2]) : 0}
        }
        const index = researchStore.paperIndex, meaning = researchStore.semantic, sync = researchStore.sync
        if (index.busy && !index.paused && index.progress.length) list.push(counted("index", index.progress))
        if (meaning.busy && meaning.progress.length) list.push(counted("meaning", meaning.progress))
        if (sync.running) list.push({id: "sync", label: qsTr("Syncing…"), done: 0, total: 0})
        if (researchStore.backingUp) list.push({id: "backup", label: qsTr("Backing up…"), done: 0, total: 0})
        return list
    }
    // Where a piece of long work is seen (a click on it in the status bar goes there): null when nowhere.
    function activityPlace(id) {
        if (/^forYou/.test(id)) return {library: {view: "foryou"}}
        if (id === "fillDetails") return {library: {missing: true}}
        if (id === "arxivGet" || id === "copyPdfs" || /^import:/.test(id)) return {library: {}}
        if (id === "index" || id === "meaning") return {settings: "search"}
        if (id === "sync" || id === "backup") return {settings: "sync"}
        return null
    }
    function goToActivity(id) {
        const place = activityPlace(id)
        if (!place || restoreFailed) return
        if (place.settings) settingsDialog.openPage(place.settings)
        else { documents.openLibrary(place.library); homeVisible = false }
    }
    function scheduleSave() { if (initialized && !restoreFailed) saveTimer.restart() }
    function notify(text) { notification = text; notificationTimer.restart() }
    function chooseFile() { if (!restoreFailed && !(currentReader && currentReader.annotationDirty)) fileDialog.open() }

    Component.onCompleted: {
        swipeNavigation.setAllowed(window.swipeAllowed)
        const state = researchStore.session
        if (state.width) width = Math.max(minimumWidth, Math.min(Screen.width, state.width))
        if (state.height) height = Math.max(minimumHeight, Math.min(Screen.height, state.height))
        const panels = state.panels || {}
        leftDockWidth = Number(panels.leftWidth) || 224
        rightDockWidth = Number(panels.rightWidth) || 224
        filesVisible = panels.filesVisible === undefined ? true : panels.filesVisible
        filesSide = panels.filesSide === "left" ? "left" : "right"
        documentVisible = !!panels.documentVisible
        documentSide = panels.documentSide === "left" ? "left" : "right"
        aiVisible = !!panels.aiVisible
        aiSide = panels.aiSide === "right" ? "right" : "left"
        threadsVisible = !!panels.threadsVisible
        threadsSide = panels.threadsSide === "right" ? "right" : "left"
        threadsWidth = Number(panels.threadsWidth) || 220
        navigationMode = [0, 1, 2, 3, 4].indexOf(panels.navigationMode) >= 0 ? panels.navigationMode : 0
        paperFolder = panels.folder || ""
        // Sessions from when a dock held several panels keep the one in front.
        for (const side of ["left", "right"]) {
            const list = panelsForSide(side), front = side === "left" ? panels.leftActive : panels.rightActive
            if (list.length > 1) closeOthers(list.indexOf(front) >= 0 ? front : list[0])
        }
        try { documents.restore(state) }
        catch (error) { restoreFailed = true; notification = error.message }
        moveMenusIntoButton()
        menusBringWindowBack()
        initialized = true
        Qt.callLater(recordPlace)
        // Files from the command line, Finder or a second launch made before the window was ready.
        const external = initialFiles.concat(typeof appInstance !== "undefined" ? appInstance.takePending() : [])
        if (!restoreFailed) for (let i = 0; i < external.length; ++i) documents.openDocument(external[i])
        // Home, unless the reader chose to come back to the last tabs (Settings › Appearance) and there are some.
        homeVisible = restoreFailed || (external.length === 0 && !(researchStore.setting("startup.view", "home") === "tabs" && documents.hasTabs))
        if (!restoreFailed) persist()
        // After a restore or an unexpected exit, say what happened.
        if (!restoreFailed && researchStore.startupMessage.length) notify(researchStore.startupMessage)
        else if (!restoreFailed && researchStore.recoveredFromCrash) notify(qsTr("Owelk closed unexpectedly last time. Your tabs are back; unsaved notes are offered when you reopen them."))
    }
    // Time read counts while a paper is in front of this window, open and not minimised, also behind another app:
    // the reader may read it there, scrolling it now and then (the clock stops once nothing comes for a while).
    Binding {
        target: researchStore.readingClock; property: "source"
        value: window.visible && window.visibility !== Window.Minimized && !window.homeVisible && window.currentReader
            && window.currentReader.isActive ? window.currentReader.source : ""
    }
    Binding {
        target: Theme; property: "pictureRotationAllowed"
        value: window.homeVisible || !window.visible || Qt.application.state !== Qt.ApplicationActive
    }
    Shortcut {
        sequence: "Ctrl+Alt+Shift+P"
        context: Qt.ApplicationShortcut
        enabled: Theme.picture.toString().length > 0
        onActivated: Theme.pictureHidden = !Theme.pictureHidden
    }
    // The desktop pet (Settings › Appearance › Picture), only while it is on.
    Loader {
        id: petLoader
        objectName: "petLoader"
        active: !Theme.pictureHidden && DesktopPet.enabled && DesktopPet.supported && Theme.picture.toString().length > 0
        sourceComponent: PetWindow {
            ai: researchStore.ai
            forYou: researchStore.forYou
            stretch: researchStore.readingClock.stretch
            activities: window.activities
            onSettingsRequested: function(page) { settingsDialog.openPage(page) }
            onContinueRequested: function(source, position) { window.comeHere(); window.openDocument(source, position); window.homeVisible = false }
            // Owelk's window in front; closed (macOS), the pet keeps saying what happened.
            ownerActive: window.visible && Qt.application.state === Qt.ApplicationActive
            onOpenRequested: window.comeHere()
            onThreadRequested: function(threadId) { window.comeHere(); window.openAiThread(threadId) }
            onForYouRequested: { window.comeHere(); window.showHome() }
            onPdfsDropped: function(urls) {
                window.comeHere()
                if (window.restoreFailed) return
                urls.forEach(function(url) { window.openDocument(url) })
                window.homeVisible = false
            }
            // Data for the AI, not interface text: the label is kept with the conversation like "Ask".
            onExplainRequested: function(text) { window.comeHere(); window.askAi({action: "explain", selection: text, label: "Explain"}) }
        }
    }
    // PDFs opened from Finder or handed over by another launch while this window is open.
    Connections {
        target: typeof appInstance !== "undefined" ? appInstance : null
        function onFilesRequested(urls) {
            window.comeForward()
            if (window.restoreFailed || !urls.length) return
            urls.forEach(function(url) { window.openDocument(url) })
            window.homeVisible = false
        }
    }
    // Logging out or quitting from the dock can skip the window's close handler.
    Connections { target: Qt.application; function onAboutToQuit() { window.persist() } }
    // Nothing would be lost by closing the window now (the session is saved); otherwise it says why not.
    function readyToClose() {
        if (researchStore.printing) { notify(qsTr("Finish or cancel printing before closing the window.")); return false }
        if (window.currentReader && window.currentReader.annotationDirty) { notify(qsTr("Save or discard annotation edits before closing the window.")); return false }
        if (researchStore.busy) { notify(qsTr("Saving. Please close the window after saving finishes.")); return false }
        if (initialized && !restoreFailed && !persist()) { notify(qsTr("Cannot save the session. Check storage and try again.")); return false }
        return true
    }
    // Quit (Cmd+Q, ≡ › Quit): Owelk ends, the desktop pet with it. A closed window comes back to say what is in the way.
    property bool quitting: false
    function quit() {
        if (!readyToClose()) { comeForward(); return }
        quitting = true
        if (petLoader.item) petLoader.item.close()
        Qt.quit()
    }
    onClosing: function(close) {
        if (quitting) return
        if (!readyToClose()) { close.accepted = false; return }
        // macOS: closing the window (its red button, Cmd+W with no tabs) leaves Owelk running, as Mac apps do, and
        // the desktop pet with it; the Dock icon, the pet and opening a PDF bring the window back as it was.
        if (Qt.platform.os === "osx") {
            close.accepted = false
            // Out of full screen first, then hidden; focus mode ends with it.
            if (typeof windowChrome !== "undefined") windowChrome.hideWindow(window)
            else window.hide()
            setFocusMode(false)
            return
        }
        // Elsewhere closing this window ends Owelk: the pet, a window of its own, would keep it running.
        Qt.callLater(function() { if (petLoader.item) petLoader.item.close() })
    }
    onWidthChanged: scheduleSave()
    onHeightChanged: scheduleSave()
    onFilesVisibleChanged: scheduleSave()
    onFilesSideChanged: scheduleSave()
    onDocumentSideChanged: scheduleSave()
    onDocumentVisibleChanged: scheduleSave()
    onNavigationModeChanged: scheduleSave()
    onPaperFolderChanged: scheduleSave()
    onLeftDockWidthChanged: scheduleSave()
    onThreadsVisibleChanged: scheduleSave()
    onThreadsSideChanged: scheduleSave()
    onThreadsWidthChanged: scheduleSave()
    onRightDockWidthChanged: scheduleSave()
    // The top bar is the title bar: no padding above it (elsewhere the window keeps its own).
    Binding { target: window; property: "topPadding"; value: 0; when: window.unifiedTitleBar }
    Timer { id: saveTimer; interval: 500; onTriggered: window.persist() }
    Timer { id: notificationTimer; interval: 6500; onTriggered: if (!window.restoreFailed) window.notification = "" }
    Native.FileDialog { id: fileDialog; title: qsTr("Open PDF"); nameFilters: ["PDF documents (*.pdf)"]; onAccepted: window.openDocument(selectedFile) }
    Connections {
        target: researchStore
        function onMessage(text) { window.notify(text) }
        function onDuplicateFound(source, existing, title) { duplicateBar.show(source, existing, title) }
        function onRelinkRequested(source) { if (!window.restoreFailed && !researchStore.relinking && window.persist()) relinkDialog.begin(source) }
        function onSourceRelinked(source, candidate) { documents.relinkSource(source, candidate) }
        function onPapersDeleted(sources) { documents.closeSources(sources) }
        function onRelinkFinished(success, detail) { if (success) window.notify(detail) }
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
        canSwitchTabs: window.canSwitchTabs
        canGoBack: window.canGoBack
        canGoForward: window.canGoForward
        canMinimize: window.visibility !== Window.FullScreen
        canDarkPages: Theme.canInvertPages
        hasVerticalTabs: Theme.verticalTabs
        hasCodeLinks: hasDocument && window.currentReader.codeLinks.length > 0
        canExportAnnotated: researchStore.canExportAnnotatedPdf()
        onCommandChosen: function(command) {
            if (window.currentReader && window.currentReader.annotationDirty) { window.notify(qsTr("Finish annotation editing first.")); return }
            switch (command) {
            case "/home": window.showHome(); break
            case "/open paper": window.chooseFile(); break
            case "/find": window.findInView(); break
            case "/split right": documents.duplicateSplit("right"); break
            case "/split down": documents.duplicateSplit("bottom"); break
            case "/split off": documents.joinAll(); break
            case "/focus": window.setFocusMode(!window.focusMode); break
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
            case "/mark region": if (!window.homeVisible && window.currentReader) window.currentReader.setTool("area"); break
            case "/highlight": if (!window.homeVisible && window.currentReader) window.currentReader.highlightSelection(); break
            case "/files": window.togglePanel("files"); break
            case "/document": window.togglePanel("document"); break
            case "/threads": window.togglePanel("threads"); break
            case "/annotations": window.toggleAnnotations(); break
            case "/paper note": if (window.currentReader) documents.newNoteFor(window.currentReader.source); break
            case "/close tab": documents.closeActiveTab(); break
            case "/new tab": if (!window.restoreFailed) documents.newHomeTab(); break
            case "/reopen tab": documents.reopenClosedTab(); break
            case "/fit width": if (window.currentReader) window.currentReader.fitWidth(); break
            case "/fit page": if (window.currentReader) window.currentReader.fitPage(); break
            case "/next tab": documents.cycleTab(1); break
            case "/previous tab": documents.cycleTab(-1); break
            case "/back": window.goBack(); break
            case "/forward": window.goForward(); break
            case "/dark pages": Theme.invertPages = !Theme.invertPages; break
            case "/minimize": window.showMinimized(); break
            case "/ai": window.togglePanel("ai"); break
            case "/vertical tabs": window.setTabsPanel(!window.tabsPanelOpen); break
            case "/contents": window.showDocumentView(0); break
            case "/symbols": window.showDocumentView(2); break
            case "/related": window.showDocumentView(3); break
            case "/figures": window.showDocumentView(4); break
            case "/for you": documents.openLibrary({view: "foryou"}); break
            case "/notes": documents.openLibrary({view: "notes"}); break
            case "/words": documents.openLibrary({view: "words"}); break
            case "/trash": documents.openLibrary({view: "trash"}); break
            case "/missing details": documents.openLibrary({missing: true}); break
            case "/search": window.focusSearch(true); break
            case "/ask ai": window.askAiNow(); break
            case "/customize home": settingsDialog.openPage("general#settingsGroup-home"); break
            case "/settings appearance": settingsDialog.openPage("appearance"); break
            case "/settings shortcuts": settingsDialog.openPage("shortcuts"); break
            case "/settings foryou": settingsDialog.openPage("foryou"); break
            case "/settings ai": settingsDialog.openPage("ai"); break
            case "/settings sync": settingsDialog.openPage("sync"); break
            }
            // The paper in front, for the rest.
            const reader = !window.homeVisible ? window.currentReader : null
            if (!reader) return
            switch (command) {
            case "/zoom in": reader.zoom(1.2); break
            case "/zoom out": reader.zoom(1 / 1.2); break
            case "/comment": reader.addComment(); break
            case "/draw": reader.setTool("draw"); break
            case "/text box": reader.setTool("text"); break
            case "/code links": reader.showCodeLinks(); break
            case "/print": reader.printDocument(); break
            case "/export annotated": reader.exportAnnotated(); break
            case "/export markdown": reader.exportMarkdown(); break
            case "/mark read": researchStore.setReadingState(reader.source, "read"); break
            case "/paper details": reader.showDetails(); break
            case "/gloss": reader.glossSelection(); break
            case "/translate page": reader.translatePage(); break
            }
        }
    }
    // A press anywhere else takes the cursor out of a text box that asks for it (releaseFocusOnOutsidePress: the
    // top bar's search field, the AI question box); presses inside its keepFocusWithin items keep it. The layer
    // only watches (a passive point handler), so every press still reaches what is under it.
    function releaseFocusAt(at) {
        const focus = window.activeFocusItem
        if (!focus || !focus.releaseFocusOnOutsidePress) return
        const inside = function(item) { return !!item && item.visible && item.contains(item.mapFromItem(null, at.x, at.y)) }
        if (inside(focus) || (focus.keepFocusWithin || []).some(inside)) return
        window.contentItem.forceActiveFocus()
    }
    Item {
        objectName: "focusReleaseLayer"
        parent: window.contentItem.parent
        anchors.fill: parent
        z: 100000
        PointHandler {
            acceptedButtons: Qt.AllButtons
            onActiveChanged: if (active) window.releaseFocusAt(point.scenePosition)
        }
        // A mouse's Back and Forward buttons (buttons 4 and 5), anywhere in the window: the same Back and
        // Forward as the arrows (a web tab's pages first). Taken here, so a web page does not go back twice.
        TapHandler {
            objectName: "mouseBackForward"
            acceptedButtons: Qt.BackButton | Qt.ForwardButton
            gesturePolicy: TapHandler.WithinBounds
            onTapped: function(eventPoint, button) { if (button === Qt.BackButton) window.goBack(); else window.goForward() }
        }
    }
    // Windows and Linux: the menus move behind the top bar's ≡ (their shortcuts keep working), so the window has
    // no separate menu bar under its title bar. macOS keeps them in the system menu bar.
    Menu { id: appMenu; objectName: "appMenu" }
    Component { id: menuLine; MenuSeparator {} }
    // ≡ is one list: File's items, a line, View's. The emptied menus are kept, in the window: they still own the
    // actions, whose keys only work while their menu belongs to a window.
    property var movedMenus: []
    // macOS keeps Owelk's menu bar while its window is closed: a command there brings the window back (not
    // Close and Quit, which have nothing to do then).
    function menusBringWindowBack() {
        if (Qt.platform.os !== "osx" || !window.menuBar) return
        for (let m = 0; m < window.menuBar.count; ++m) {
            const menu = window.menuBar.menuAt(m)
            for (let i = 0; i < menu.count; ++i) {
                const action = menu.actionAt(i)
                if (action && action.objectName !== "closeTabAction" && action.objectName !== "quitAction")
                    action.triggered.connect(function() { if (!window.visible && !window.quitting) window.comeForward() })
            }
        }
    }
    function moveMenusIntoButton() {
        if (Qt.platform.os === "osx" || !window.menuBar) return
        const moved = []
        while (window.menuBar.count > 0) {
            const menu = window.menuBar.takeMenu(0)
            menu.parent = window.contentItem
            moved.push(menu)
            if (appMenu.count > 0) appMenu.addItem(menuLine.createObject(appMenu))
            while (menu.count > 0) appMenu.addItem(menu.takeItem(0))
        }
        movedMenus = moved
        window.menuBar.visible = false
    }
    SearchPalette {
        currentSource: !window.homeVisible && window.currentReader ? window.currentReader.source : ""
        // Hangs from the search field in view (the top bar's, or Home's); otherwise on its own, in the middle.
        parent: window.searchHost ? window.searchHost : Overlay.overlay
        inputField: window.searchHost ? window.searchHost.field : null
        id: searchPalette
        onResultChosen: function(result) { window.openSearchResult(result) }
        // A Home tab in front becomes the page (as a browser's new tab does); otherwise a new tab opens.
        onWebRequested: function(url) {
            if (window.restoreFailed) return
            const view = documents.groupView(documents.activeGroup)
            if (documents.openWeb(url, window.homeVisible || !view || !view.isHome)) window.homeVisible = false
        }
    }
    // The menus hold only what one looks for there: making and opening things, places, panels and how a page
    // is shown. Everything else with a key (search, the Command Palette, Back and Forward, tab and split moves,
    // reading tools) works by its key below and from the Command Palette, and is set in Settings › Shortcuts.
    // macOS shows these menus in its menu bar (Settings and Quit move into the Owelk menu); Windows and Linux
    // list them behind the top bar's ≡.
    menuBar: MenuBar {
        Menu {
            title: qsTr("File")
            Action { objectName: "newTabAction"; text: qsTr("New Tab"); shortcut: window.keys("newTab"); enabled: !window.restoreFailed && !(window.currentReader && window.currentReader.annotationDirty); onTriggered: documents.newHomeTab() }
            Action { text: qsTr("Open PDF…"); shortcut: StandardKey.Open; onTriggered: window.chooseFile() }
            Action { objectName: "openWebAction"; text: qsTr("Open Web Page…"); shortcut: window.keys("openWeb"); enabled: !window.restoreFailed; onTriggered: window.openWebAddress() }
            Action { objectName: "newNoteAction"; text: qsTr("New Note"); shortcut: window.keys("newNote"); enabled: !window.restoreFailed; onTriggered: documents.newNote() }
            MenuSeparator {}
            Action { objectName: "closeTabAction"; text: documents.hasTabs ? qsTr("Close Tab") : qsTr("Close Window"); shortcut: window.keys("closeTab"); enabled: window.visible && !(!window.homeVisible && window.currentReader && window.currentReader.annotationDirty); onTriggered: window.closeTabOrWindow() }
            Action { text: qsTr("Reopen Closed Tab"); shortcut: window.keys("reopenTab"); enabled: documents.closedTabs.length > 0 && !window.restoreFailed; onTriggered: documents.reopenClosedTab() }
            MenuSeparator {}
            Action { objectName: "settingsAction"; text: qsTr("Settings…"); shortcut: Qt.platform.os === "osx" ? StandardKey.Preferences : "Ctrl+,"; onTriggered: settingsDialog.open() }
            Action { objectName: "quitAction"; text: qsTr("Quit"); shortcut: StandardKey.Quit; onTriggered: window.quit() }
        }
        Menu {
            title: qsTr("View")
            Action { text: qsTr("Home"); shortcut: window.keys("home"); onTriggered: window.showHome() }
            Action { objectName: "libraryAction"; text: qsTr("Library"); shortcut: window.keys("library"); enabled: !window.restoreFailed; onTriggered: documents.openLibrary({}) }
            MenuSeparator {}
            Action { text: qsTr("Zoom In"); shortcut: StandardKey.ZoomIn; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1.2) }
            Action { text: qsTr("Zoom Out"); shortcut: StandardKey.ZoomOut; enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.zoom(1 / 1.2) }
            Action { objectName: "fitWidthAction"; text: qsTr("Fit Width"); shortcut: window.keys("fitWidth"); enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.fitWidth() }
            Action { objectName: "fitPageAction"; text: qsTr("Fit Page"); shortcut: window.keys("fitPage"); enabled: !window.homeVisible; onTriggered: if (window.currentReader) window.currentReader.fitPage() }
            Action { objectName: "focusModeAction"; text: qsTr("Focus Mode"); shortcut: window.keys("focusMode"); checkable: true; checked: window.focusMode; enabled: !window.restoreFailed; onTriggered: window.setFocusMode(!window.focusMode) }
            Action { objectName: "darkPagesAction"; text: qsTr("Dark Pages"); shortcut: window.keys("darkPages"); checkable: true; checked: Theme.invertPages; enabled: Theme.canInvertPages; onTriggered: Theme.invertPages = checked }
            MenuSeparator {}
            Action { objectName: "filesPanelAction"; text: qsTr("Library Panel"); shortcut: window.keys("filesPanel"); onTriggered: window.togglePanel("files") }
            Action { objectName: "documentPanelAction"; text: qsTr("Document Panel"); shortcut: window.keys("documentPanel"); onTriggered: window.togglePanel("document") }
            Action { objectName: "aiPanelAction"; text: qsTr("AI Chat"); shortcut: window.keys("aiPanel"); onTriggered: window.togglePanel("ai") }
            Action { objectName: "threadsPanelAction"; text: qsTr("Threads"); shortcut: window.keys("threadsPanel"); onTriggered: window.togglePanel("threads") }
            Action { objectName: "tabsPanelAction"; text: window.tabsPanelOpen ? qsTr("Hide Vertical Tabs") : qsTr("Show Vertical Tabs"); shortcut: window.keys("tabsPanel"); enabled: Theme.verticalTabs; onTriggered: window.setTabsPanel(!window.tabsPanelOpen) }
        }
        // As in every Mac app: Cmd+M minimises the window to the Dock (not from full screen, which macOS refuses).
        Menu {
            title: qsTr("Window")
            Action {
                objectName: "minimizeAction"; text: qsTr("Minimize")
                shortcut: Qt.platform.os === "osx" ? "Ctrl+M" : ""
                enabled: window.visible && window.visibility !== Window.Minimized && window.visibility !== Window.FullScreen
                onTriggered: window.showMinimized()
            }
        }
    }
    // Keys without a menu item. Tab switching stays an action too (the Command Palette and tests trigger it).
    Action { id: nextTabAction; objectName: "nextTabAction"; enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(1) }
    Action { id: previousTabAction; objectName: "previousTabAction"; enabled: window.canSwitchTabs; onTriggered: documents.cycleTab(-1) }
    Shortcut { sequence: window.keys("nextTab"); enabled: nextTabAction.enabled; onActivated: nextTabAction.trigger() }
    Shortcut { sequence: window.keys("previousTab"); enabled: previousTabAction.enabled; onActivated: previousTabAction.trigger() }
    Shortcut { sequence: window.keys("search"); onActivated: window.focusSearch(true) }
    Shortcut { sequence: window.keys("commands"); onActivated: { searchPalette.close(); commandPalette.open() } }
    Shortcut { sequences: [StandardKey.Find]; onActivated: window.findInView() }
    // Back and Forward, as the top bar's arrows: within the tab first (pages, jumps), then between places.
    Shortcut { objectName: "jumpBackShortcut"; sequence: window.keys("jumpBack"); enabled: window.canGoBack; onActivated: window.goBack() }
    Shortcut { objectName: "jumpForwardShortcut"; sequence: window.keys("jumpForward"); enabled: window.canGoForward; onActivated: window.goForward() }
    Shortcut { sequence: window.keys("markRegion"); enabled: !window.homeVisible; onActivated: if (window.currentReader) window.currentReader.setTool("area") }
    Shortcut { sequence: window.keys("highlight"); enabled: !window.homeVisible && !!window.currentReader; onActivated: window.currentReader.useHighlight() }
    Shortcut { sequence: window.keys("comment"); enabled: !window.homeVisible && !!window.currentReader; onActivated: window.currentReader.setTool("comment") }
    Shortcut { sequence: window.keys("askAi"); enabled: !window.restoreFailed; onActivated: window.askAiNow() }
    Shortcut { sequence: window.keys("annotations"); enabled: !window.homeVisible; onActivated: window.toggleAnnotations() }
    Shortcut { sequence: window.keys("splitRight"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.duplicateSplit("right") }
    Shortcut { sequence: window.keys("splitDown"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.duplicateSplit("bottom") }
    Shortcut { sequence: window.keys("moveRight"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.moveActiveTabToSplit("right") }
    Shortcut { sequence: window.keys("moveDown"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.moveActiveTabToSplit("bottom") }
    Shortcut { sequence: window.keys("nextSplit"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.focusGroup(1) }
    Shortcut { sequence: window.keys("previousSplit"); enabled: !window.homeVisible && window.canSwitchTabs; onActivated: documents.focusGroup(-1) }
    // Focus mode's top edge: touching it brings a bar for a moment (Back, Forward, search, Exit Focus), drawn over
    // the page so nothing moves; leaving it lets the bar go. Over the whole window, the strip beside a camera notch
    // too, with the bar just below that strip, or below macOS's menu bar, which also comes down there in full screen.
    Item {
        id: focusTop
        objectName: "focusTop"
        parent: Overlay.overlay
        z: 1000
        visible: window.focusMode
        readonly property real notch: Overlay.overlay ? Overlay.overlay.SafeArea.margins.top : 0
        readonly property real offset: Qt.platform.os === "osx" && window.visibility === Window.FullScreen ? Math.max(notch, 24) : notch
        width: parent ? parent.width : 0
        height: window.focusBarShown ? offset + focusBar.height : offset + 4
        HoverHandler {
            id: focusTopHover
            onHoveredChanged: {
                if (hovered) { focusLeave.stop(); window.focusPeek = true }
                else if (!focusTabsPopup.opened) focusLeave.restart()
            }
        }
        // While the bar is down, the strip above it (where macOS's menu bar comes down) has its color, not the page's.
        Rectangle {
            objectName: "focusBarStrip"
            visible: window.focusBarShown && focusTop.offset > 0
            width: parent.width; height: focusTop.offset
            color: Theme.window
        }
        Rectangle {
            id: focusBar
            objectName: "focusBar"
            visible: window.focusBarShown
            y: focusTop.offset
            width: parent.width; height: Theme.barHeight
            color: Theme.window
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
            // Everything focus mode hides, in one place: the side panels (as in the status bar, each on its side),
            // Back, Forward and search, the open tabs, and the way out.
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 8
                spacing: 2
                Repeater {
                    model: window.panelIcons("left")
                    delegate: StatusIcon {
                        required property string modelData
                        objectName: "focusPanel-" + modelData
                        kind: modelData; dockSide: "left"
                        description: window.panelName(kind)
                        selected: window.panelShown(kind)
                        onTriggered: window.togglePanel(kind)
                        onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                    }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 16; Layout.leftMargin: 6; Layout.rightMargin: 6; color: Theme.separator }
                IconButton { icon.name: "back"; enabled: window.canGoBack; description: qsTr("Back") + " · " + Platform.keys(window.keys("jumpBack")); onClicked: window.goBack() }
                IconButton { icon.name: "forward"; enabled: window.canGoForward; description: qsTr("Forward") + " · " + Platform.keys(window.keys("jumpForward")); onClicked: window.goForward() }
                IconButton { icon.name: "search"; description: qsTr("Search · ") + Platform.keys("Ctrl+K"); onClicked: window.focusSearch(true) }
                Item { Layout.fillWidth: true }
                // The tab in front; a click lists the open tabs to go to.
                Chip {
                    id: focusTabButton
                    objectName: "focusTabs"
                    Layout.maximumWidth: Math.max(160, focusBar.width - 640)
                    text: window.homeVisible ? qsTr("Home") : window.focusTabTitle()
                    trailingIcon: "down"
                    checked: focusTabsPopup.opened
                    onClicked: focusTabsPopup.opened ? focusTabsPopup.close() : focusTabsPopup.open()
                }
                Item { Layout.fillWidth: true }
                Repeater {
                    model: window.panelIcons("right")
                    delegate: StatusIcon {
                        required property string modelData
                        objectName: "focusPanel-" + modelData
                        kind: modelData; dockSide: "right"
                        description: window.panelName(kind)
                        selected: window.panelShown(kind)
                        onTriggered: window.togglePanel(kind)
                        onDockSideChosen: function(side) { const panel = kind; Qt.callLater(function() { window.movePanel(panel, side) }) }
                    }
                }
                IconButton {
                    objectName: "focusPinButton"
                    Layout.leftMargin: 6
                    icon.name: "pin"
                    checked: window.focusPinned
                    description: window.focusPinned ? qsTr("Let the bar hide") : qsTr("Keep the bar shown")
                    onClicked: window.setFocusPinned(!window.focusPinned)
                }
                Button {
                    objectName: "exitFocusButton"
                    Layout.leftMargin: 8
                    text: qsTr("Exit Focus") + " · " + Platform.keys(window.keys("focusMode"))
                    onClicked: window.setFocusMode(false)
                }
            }
            // The open tabs, each strip after a line; ⌘1–9 beside the ones of the strip in front.
            Popup {
                id: focusTabsPopup
                objectName: "focusTabsPopup"
                z: 1001
                x: focusTabButton.x + focusTabButton.width / 2 - width / 2
                y: parent.height + 4
                width: 360
                padding: 6
                property var rows: []
                onAboutToShow: rows = window.focusTabRows()
                // The bar stays while the list is open.
                onOpened: focusLeave.stop()
                onClosed: if (!focusTopHover.hovered) focusLeave.restart()
                contentItem: ListView {
                    implicitHeight: Math.min(contentHeight, 420)
                    clip: true
                    model: focusTabsPopup.rows
                    delegate: ItemDelegate {
                        id: tabRow
                        required property var modelData
                        objectName: modelData.separator ? "" : "focusTab-" + modelData.id
                        width: ListView.view.width
                        height: modelData.separator ? 9 : Theme.rowHeight
                        enabled: !modelData.separator
                        highlighted: !!modelData.current
                        background: Rectangle {
                            radius: Theme.radiusSmall
                            color: tabRow.modelData.separator ? "transparent" : tabRow.highlighted ? Theme.selection : tabRow.hovered ? Theme.hover : "transparent"
                            Rectangle { visible: !!tabRow.modelData.separator; anchors.centerIn: parent; width: parent.width - 8; height: 1; color: Theme.separator }
                        }
                        contentItem: RowLayout {
                            visible: !tabRow.modelData.separator
                            spacing: 8
                            Label {
                                Layout.fillWidth: true
                                text: tabRow.modelData.title || ""
                                elide: Text.ElideRight; textFormat: Text.PlainText
                                color: tabRow.highlighted ? Theme.selectedText : Theme.text
                            }
                            Label { text: tabRow.modelData.keys || ""; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                        }
                        onClicked: {
                            focusTabsPopup.close()
                            if (modelData.newTab) documents.newHomeTab()
                            else documents.activateTab(modelData.id)
                        }
                    }
                }
            }
        }
    }
    Timer { id: focusLeave; interval: 600; onTriggered: window.focusPeek = false }
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
    // For You › Manage Following, asked for from Settings, Home or a paper's Follow Author.
    Connections {
        target: researchStore.forYou
        function onManageRequested() {
            if (window.restoreFailed) return
            settingsDialog.close()
            window.homeVisible = false
            documents.openLibrary({view: "foryou", manage: true})
        }
    }
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
    AiController { id: aiController; reader: window.homeVisible ? null : window.currentReader; workspace: documents }
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
                Label { Layout.fillWidth: true; text: qsTr("This PDF is already in your Library"); font.weight: Font.DemiBold; color: Theme.text; wrapMode: Text.Wrap }
                // The title wraps to two lines; anything longer shows in full on hover.
                Label {
                    Layout.fillWidth: true
                    text: "\u201c" + duplicateBar.existingTitle + "\u201d"
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                }
            }
            Button {
                objectName: "openExistingCopy"; text: qsTr("Use Existing"); focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: qsTr("Read the paper already in your Library (with its notes). This extra entry is set aside; no file is deleted.")
                onClicked: {
                    if (researchStore.useExistingCopy(duplicateBar.source, duplicateBar.existing))
                        documents.relinkSource(duplicateBar.source, duplicateBar.existing)
                    duplicateBar.close()
                }
            }
            Button {
                objectName: "keepBothCopies"; text: qsTr("Keep Both"); focusPolicy: Qt.NoFocus
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: qsTr("Keep two separate papers, each with its own notes. Owelk won't ask again about this file.")
                onClicked: { researchStore.keepDuplicate(duplicateBar.source); duplicateBar.close() }
            }
            IconButton { icon.name: "close"; description: qsTr("Dismiss"); focusPolicy: Qt.NoFocus; onClicked: duplicateBar.close() }
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
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // Focus Mode's bar pinned: room for it (and the strip above it), so it covers none of the page.
        Item {
            objectName: "focusPinnedRoom"
            visible: window.focusBarShown && window.focusPinned
            Layout.fillWidth: true
            Layout.preferredHeight: focusTop.offset + Theme.barHeight
        }
        TopBar {
            id: topBar
            Layout.fillWidth: true
            visible: !window.restoreFailed && !window.topBarHidden && !window.focusMode
            titleBar: window.unifiedTitleBar
            // The traffic lights' room, and the title bar's height (not in full screen, where they hide).
            readonly property bool fullScreen: window.visibility === Window.FullScreen
            leading: titleBar && !fullScreen ? 72 : 0
            palette: searchPalette
            appMenu: Qt.platform.os === "osx" ? null : appMenu
            Layout.preferredHeight: titleBar && !fullScreen && window.contentItem.SafeArea.margins.top >= 24 ? window.contentItem.SafeArea.margins.top : implicitHeight
            canGoBack: window.canGoBack
            canGoForward: window.canGoForward
            backKeys: Platform.keys(window.keys("jumpBack"))
            forwardKeys: Platform.keys(window.keys("jumpForward"))
            // macOS: presses on the bar's empty space move the window (handled natively, see TitleBar.h).
            function reportDragArea() {
                if (titleBar && typeof windowChrome !== "undefined") windowChrome.setDragArea(window, height, controlRects())
            }
            onWidthChanged: Qt.callLater(reportDragArea)
            onHeightChanged: Qt.callLater(reportDragArea)
            onLeadingChanged: Qt.callLater(reportDragArea)
            Component.onCompleted: Qt.callLater(reportDragArea)
            onBack: window.goBack()
            onForward: window.goForward()
        }
    RowLayout {
        Layout.fillWidth: true; Layout.fillHeight: true
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
        Loader {
            id: leftThreads
            objectName: "leftThreads"
            active: window.threadsVisible && window.threadsSide === "left"
            visible: active
            sourceComponent: threadsPanel
            Layout.preferredWidth: window.threadsPanelWidth(window.threadsWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
        }
        ResizeEdge {
            visible: leftThreads.active
            area.objectName: "leftThreadsResize"
            onMoved: function(delta) {
                if (delta === 0) initialWidth = leftThreads.width
                window.threadsWidth = window.threadsPanelWidth(initialWidth + delta)
            }
        }
        DockSidebar {
            id: leftDock
            objectName: "leftDock"
            side: "left"; panels: window.leftPanels; folder: window.paperFolder
            reader: window.homeVisible ? null : window.currentReader
            aiController: aiController
            threadsOpen: window.threadsVisible
            onThreadsToggled: window.togglePanel("threads")
            onSettingsRequested: settingsDialog.openPage("ai")
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onNewNoteRequested: function(source) { if (!window.restoreFailed) { if (source.toString().length) documents.newNoteFor(source); else documents.newNote() } }
            onAiRequested: function(spec) { window.askAi(spec) }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.leftDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            documents: documents
            onLibraryFilterRequested: function(filter) { if (!window.restoreFailed) { window.homeVisible = false; documents.openLibrary(filter) } }
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
            onNewNoteRequested: if (!window.restoreFailed) documents.newNote()
            onSettingsRequested: function(page) { settingsDialog.openPage(page) }
            onWebRequested: function(address) { window.openForYouPage(address) }
            searchShown: window.topBarHidden || window.focusMode
            controlsShown: true
            palette: searchPalette
            appMenu: Qt.platform.os === "osx" ? null : appMenu
            canGoBack: window.canGoBack
            canGoForward: window.canGoForward
            backKeys: Platform.keys(window.keys("jumpBack"))
            forwardKeys: Platform.keys(window.keys("jumpForward"))
            onBackRequested: window.goBack()
            onForwardRequested: window.goForward()
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
            onSettingsRequested: function(page) { settingsDialog.openPage(page) }
            topControls: window.topBarHidden
            focusMode: window.focusMode
            appMenu: Qt.platform.os === "osx" ? null : appMenu
            searchPalette: searchPalette
            canGoBack: window.canGoBack
            canGoForward: window.canGoForward
            backKeys: Platform.keys(window.keys("jumpBack"))
            forwardKeys: Platform.keys(window.keys("jumpForward"))
            onBackRequested: window.goBack()
            onForwardRequested: window.goForward()
            onSearchRequested: window.focusSearch(true)
            onAnnotationsToggled: window.toggleAnnotations()
            onAiResponseRequested: function(id) { window.openAiThread(id) }
            onOpened: window.homeVisible = false
            onSearchFocusRequested: window.focusSearch(false)
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
            threadsOpen: window.threadsVisible
            onThreadsToggled: window.togglePanel("threads")
            onSettingsRequested: settingsDialog.openPage("ai")
            navigationMode: window.navigationMode
            onNavigationModeChosen: function(mode) { window.navigationMode = mode }
            onLinkActivated: function(link) { if (!window.restoreFailed) documents.openLink(link) }
            onNewNoteRequested: function(source) { if (!window.restoreFailed) { if (source.toString().length) documents.newNoteFor(source); else documents.newNote() } }
            onAiRequested: function(spec) { window.askAi(spec) }
            visible: panels.length > 0
            Layout.preferredWidth: window.dockWidth(window.rightDockWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
            onFolderChosen: function(folder) { window.paperFolder = folder }
            onDocumentChosen: function(source) { window.openDocument(source) }
            documents: documents
            onLibraryFilterRequested: function(filter) { if (!window.restoreFailed) { window.homeVisible = false; documents.openLibrary(filter) } }
            onActivePanelChanged: window.scheduleSave()
        }
        ResizeEdge {
            visible: rightThreads.active
            area.objectName: "rightThreadsResize"
            onMoved: function(delta) {
                if (delta === 0) initialWidth = rightThreads.width
                window.threadsWidth = window.threadsPanelWidth(initialWidth - delta)
            }
        }
        Loader {
            id: rightThreads
            objectName: "rightThreads"
            active: window.threadsVisible && window.threadsSide === "right"
            visible: active
            sourceComponent: threadsPanel
            Layout.preferredWidth: window.threadsPanelWidth(window.threadsWidth); Layout.fillHeight: true
            Layout.minimumWidth: Layout.preferredWidth; Layout.maximumWidth: Layout.preferredWidth
        }
    }
    Component {
        id: threadsPanel
        ThreadsPanel {
            controller: aiController
            onChatChosen: function(id) { window.openAiThread(id) }
            onNewChatRequested: function(spec) { window.newAiChat(spec) }
            onTrashRequested: if (!window.restoreFailed) { window.homeVisible = false; documents.openLibrary({view: "trash"}) }
        }
    }
    }
    footer: Rectangle {
        id: statusBar
        objectName: "statusBar"
        // Focus mode: only the pages (the side panels still open from their keys and the window's edges).
        visible: !window.focusMode
        height: visible ? 29 : 0
        color: Theme.sidebar
        Rectangle { width: parent.width; height: 1; color: Theme.separator } // The edge above it.
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4; anchors.rightMargin: 4
            spacing: 2
            Repeater {
                model: window.panelIcons("left")
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
            // Search closes the left group, after the panels there (Threads stays at the edge).
            StatusIcon { objectName: "statusSearch"; kind: "search"; description: qsTr("Search · ") + Platform.keys("Ctrl+K"); onTriggered: window.focusSearch(true) }
            // Long work: what it is, with a thin bar (filling, or sliding when there is no measure); +N when
            // more is running, all of it on hover.
            RowLayout {
                id: activity
                objectName: "statusActivity"
                visible: window.activities.length > 0
                Layout.leftMargin: 6
                spacing: 6
                readonly property var first: window.activities.length ? window.activities[0] : ({label: "", done: 0, total: 0})
                readonly property bool measured: first.total > 0
                Label {
                    id: activityLabel
                    objectName: "statusActivityLabel"
                    Layout.maximumWidth: 300
                    text: activity.first.label + (window.activities.length > 1 ? "  +" + (window.activities.length - 1) : "")
                    elide: Text.ElideMiddle; textFormat: Text.PlainText
                    font.pixelSize: Theme.fontCaption; color: Theme.textSecondary
                }
                Item {
                    objectName: "statusActivityBar"
                    implicitWidth: 90; implicitHeight: 4
                    clip: true
                    Rectangle { anchors.fill: parent; radius: 2; color: Theme.separator }
                    Rectangle {
                        visible: activity.measured
                        height: parent.height; radius: 2; color: Theme.accent
                        width: parent.width * Math.min(1, activity.first.done / Math.max(1, activity.first.total))
                        Behavior on width { NumberAnimation { duration: 150 } }
                    }
                    Rectangle {
                        id: slider
                        visible: !activity.measured
                        width: parent.width * .35; height: parent.height; radius: 2; color: Theme.accent
                        NumberAnimation on x {
                            running: activity.visible && !activity.measured
                            from: -slider.width; to: 90; duration: 1100; loops: Animation.Infinite
                        }
                    }
                }
                // All of it on hover when cut short or when more is running; a click goes where the work is seen
                // (with more than one, a list to choose from).
                readonly property bool goes: window.activities.some(function(a) { return window.activityPlace(a.id) !== null })
                HoverHandler { id: activityHover; cursorShape: activity.goes ? Qt.PointingHandCursor : Qt.ArrowCursor }
                ToolTip.visible: activityHover.hovered && !activityMenu.opened && (window.activities.length > 1 || activityLabel.truncated)
                ToolTip.text: window.activities.map(function(a) { return a.label }).join("\n")
                TapHandler {
                    objectName: "statusActivityTap"
                    enabled: activity.goes
                    onTapped: {
                        if (window.activities.length === 1) window.goToActivity(window.activities[0].id)
                        else activityMenu.popup(activity, 0, -activityMenu.implicitHeight - 4)
                    }
                }
                Menu {
                    id: activityMenu
                    objectName: "statusActivityMenu"
                    Instantiator {
                        model: window.activities
                        delegate: MenuItem {
                            required property var modelData
                            text: modelData.label
                            enabled: window.activityPlace(modelData.id) !== null
                            onTriggered: window.goToActivity(modelData.id)
                        }
                        onObjectAdded: function(index, object) { activityMenu.insertItem(index, object) }
                        onObjectRemoved: function(index, object) { activityMenu.removeItem(object) }
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                // A notice while there is one.
                text: window.notification.length ? window.notification : researchStore.busy ? qsTr("Saving…") : ""
                elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
            }
            StatusIcon { kind: "split"; description: qsTr("Duplicate to right split · ") + Platform.keys("Ctrl+\\"); visible: !window.homeVisible; selected: documents.groupCount > 1; onTriggered: documents.duplicateSplit("right") }
            Repeater {
                model: window.panelIcons("right")
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
