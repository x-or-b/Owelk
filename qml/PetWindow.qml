import QtQuick
import QtQuick.Controls
import Owelk.Ui

// The desktop pet: the picture theme's picture in a small window that floats above other apps while
// Owelk runs (Settings › Appearance › Picture). Drag it anywhere; a click pokes it (poke(): the screen stays
// where it is); its menu (right button) opens Owelk. While Owelk is behind other apps it says when an AI answer is ready or
// failed and when For You has new papers, in a bubble above it; it bobs while an answer is written.
// PDFs dropped on it open in Owelk; text dropped on it is explained by the AI. After a stretch of
// reading it suggests a break. Nothing moves or redraws while nothing happens.
Window {
    id: pet
    objectName: "petWindow"
    // Bring Owelk's window forward; with an AI conversation or For You to show.
    signal openRequested()
    signal threadRequested(string threadId)
    signal forYouRequested()
    signal pdfsDropped(var urls)
    signal explainRequested(string text)
    // A Settings page to open (Sync & Backup, Search).
    signal settingsRequested(string page)
    // Something dropped on the pet: PDFs to open, else text to explain. False if it was neither.
    function received(urls, text) {
        const pdfs = (urls || []).filter(function(url) { return /^file:.*\.pdf$/i.test(String(url)) })
        if (pdfs.length) { pdfsDropped(pdfs); return true }
        const words = String(text || "").trim()
        if (!words.length) return false
        explainRequested(words)
        return true
    }
    // Where the news comes from (researchStore.ai and researchStore.forYou in the app).
    property QtObject ai: null
    property QtObject forYou: null
    // Owelk is in front: news has nothing to add then, and goes. Behind again while an answer is being
    // written, the pet says so.
    property bool ownerActive: Qt.application.state === Qt.ApplicationActive
    onOwnerActiveChanged: {
        if (ownerActive) { if (message && !message.reminder) message = null }
        else if (writing && !message) sayWriting()
    }
    // What the bubble says: {text, thread} (thread: the conversation to open; writing: true while it is
    // answered), {text, forYou: true} or {text, reminder: true} (a break reminder, shown also while Owelk
    // is in front).
    property var message: null
    function say(next, quiet) {
        if (ownerActive && !next.reminder) return
        message = next
        if (!quiet) hop.restart()
    }
    function sayWriting() {
        const threads = Object.keys(answering).map(function(request) { return answering[request] })
        if (threads.length) say({text: qsTr("Writing your answer…"), thread: threads[threads.length - 1], writing: true}, true)
    }
    // A click on the pet. The screen stays where it is: Owelk opens from the menu, a bubble's click goes to what it
    // says. The one place for what a click does: for now a hop, and a break reminder goes.
    signal poked()
    function poke() {
        if (message && message.reminder) message = null
        stir()
        poking = true
        pokeFace.restart()
        hop.restart()
        poked()
    }
    // A click on the bubble: what it says, in Owelk.
    function act() {
        const m = message
        message = null
        if (m && m.reminder) return
        if (m && m.thread) threadRequested(m.thread)
        else if (m && m.forYou) forYouRequested()
        else if (m && m.settings) { openRequested(); settingsRequested(m.settings) }
        else openRequested()
    }
    // Conversations being answered (gloss and other requests are not news).
    property var answering: ({})
    readonly property bool writing: Object.keys(answering).length > 0
    Connections {
        target: pet.ai
        ignoreUnknownSignals: true
        function onStarted(request, threadId) {
            const next = Object.assign({}, pet.answering); next[request] = threadId; pet.answering = next
            pet.sayWriting()
        }
        function onFinished(request) {
            const thread = pet.answering[request]
            if (thread === undefined) return
            pet.settle(request)
            pet.say({text: qsTr("Your answer is ready."), thread: thread, mood: "happy"})
        }
        function onFailed(request, error) {
            const thread = pet.answering[request]
            if (thread === undefined) return
            pet.settle(request)
            pet.say({text: qsTr("The AI could not answer: ") + String(error).split("\n")[0], thread: thread, mood: "worried"})
        }
    }
    // A finished or failed answer; a "writing" bubble for it goes (another one still written keeps it).
    function settle(request) {
        const next = Object.assign({}, answering); delete next[request]; answering = next
        if (message && message.writing) { message = null; sayWriting() }
    }
    // Long work (activities: the status bar's list in the app — downloads, folder imports, copying PDFs, For You,
    // indexing, sync, backups): what has run three seconds is told when it starts and when it ends, or fails.
    // Endings close together are told as one ("3 downloads finished"). A click goes where it belongs.
    property var activities: []
    // How long work runs before it is told about, in milliseconds (tests shorten it).
    property int workDelay: 3000
    // id → {label, since, told}; what ended and is waiting to be told; what failed, by id.
    property var work: ({})
    property var ended: []
    property var failed: ({})
    property string lastMessage: ""
    onActivitiesChanged: {
        if (activities.length) stir()
        const now = Date.now(), before = work, next = {}
        for (const a of activities) next[a.id] = before[a.id] || {label: a.label, since: now, told: false}
        // Ended: told when it started, or failed.
        const done = Object.keys(before).filter(function(id) { return !next[id] && (before[id].told || !!pet.failed[id]) })
        work = next
        if (!done.length) return
        ended = ended.concat(done.map(function(id) { return {id: id, label: before[id].label} }))
        endings.restart()
    }
    function workKind(id) { return id.indexOf("download:") === 0 || id === "forYouAdd" ? "download" : id }
    // Where a click on news about it goes.
    function workPlace(id) {
        const kind = workKind(id)
        return kind === "sync" || kind === "backup" ? {settings: "sync"} : kind === "index" || kind === "meaning" ? {settings: "search"}
             : kind === "forYou" || kind === "forYouAi" ? {forYou: true} : {}
    }
    function workDone(item) {
        const kind = workKind(item.id)
        if (kind === "download") return qsTr("Downloaded: %1").arg(item.label.replace(/^Downloading /, ""))
        if (kind === "sync") return qsTr("Sync finished.")
        if (kind === "backup") return qsTr("Backup finished.")
        if (kind === "index") return qsTr("Indexing finished.")
        if (kind === "meaning") return qsTr("Meaning search is up to date.")
        return qsTr("Finished: %1").arg(item.label.replace(/…$/, ""))
    }
    Timer {
        objectName: "petWorkClock"
        interval: pet.workDelay / 3; repeat: true
        running: Object.keys(pet.work).some(function(id) { return !pet.work[id].told })
        onTriggered: {
            const now = Date.now(), started = []
            for (const id in pet.work)
                if (!pet.work[id].told && now - pet.work[id].since >= pet.workDelay) { pet.work[id].told = true; started.push(id) }
            if (!started.length) return
            pet.work = Object.assign({}, pet.work)
            const first = pet.work[started[0]]
            pet.say(Object.assign({text: started.length > 1 ? qsTr("%1 and %2 more").arg(first.label).arg(started.length - 1) : first.label},
                                  pet.workPlace(started[0])), true)
        }
    }
    Timer {
        id: endings
        interval: pet.workDelay / 2
        onTriggered: {
            const list = pet.ended
            pet.ended = []
            if (!list.length) return
            // For You tells what it found itself.
            const told = list.filter(function(item) { return pet.workKind(item.id) !== "forYou" && pet.workKind(item.id) !== "forYouAi" })
            if (!told.length) return
            const failures = told.filter(function(item) { return !!pet.failed[item.id] })
            let text
            if (told.length === 1) text = pet.failed[told[0].id] || pet.lastMessage || pet.workDone(told[0])
            else if (failures.length) text = pet.failed[failures[0].id]
            else if (told.every(function(item) { return pet.workKind(item.id) === "download" })) text = qsTr("%1 downloads finished.").arg(told.length)
            else text = qsTr("%1 tasks finished.").arg(told.length)
            // Glad when it went well; worried when something failed; as Owelk put it, when it said something.
            const failed = failures.length > 0 || (told.length === 1 && !!pet.failed[told[0].id])
            const mood = failed ? "worried" : told.length === 1 && pet.lastMessage.length ? "talk" : "happy"
            pet.failed = ({}); pet.lastMessage = ""
            pet.say(Object.assign({text: text, mood: mood}, pet.workPlace((failures[0] || told[0]).id)))
        }
    }
    // What Owelk said as work ended ("Download failed: …", "Saved …") is the news, for a single ending.
    Connections {
        target: typeof researchStore !== "undefined" ? researchStore : null
        ignoreUnknownSignals: true
        function onMessage(text) { if (pet.ended.length) pet.lastMessage = text }
        function onBackupFinished(ok, path, message) {
            if (ok) return
            const text = qsTr("Backup failed: ") + message
            // Told with the backup's ending when it is still running or about to be told; otherwise now.
            if (pet.work.backup || pet.ended.some(function(item) { return item.id === "backup" })) {
                const next = Object.assign({}, pet.failed); next.backup = text; pet.failed = next
                if (!pet.work.backup) endings.restart()
            } else {
                pet.say({text: text, settings: "sync", mood: "worried"})
            }
        }
    }
    // Break reminder: after DesktopPet.breakMinutes of reading (stretch: researchStore.readingClock's seconds read
    // since the last break, which five minutes away from reading start again) the pet suggests a break, also
    // while Owelk is in front; again after as many more. A reminder nobody answers goes after two minutes.
    property int stretch: 0
    property int reminded: 0
    onStretchChanged: {
        stir()
        if (stretch === 0) {
            reminded = 0
            if (message && message.reminder) message = null
            return
        }
        const every = DesktopPet.breakMinutes * 60
        if (every <= 0 || stretch < (reminded + 1) * every) return
        reminded = Math.floor(stretch / every)
        say({text: qsTr("%1 minutes of reading. Time for a short break?").arg(DesktopPet.breakMinutes), reminder: true})
    }
    Timer {
        interval: 2 * 60000
        running: pet.message !== null && !!pet.message.reminder
        onTriggered: pet.message = null
    }
    // New papers in For You: said when there are more than before (counted when the pet starts, not
    // bound: the count would follow the list before the handler below compares).
    property int knownPapers: 0
    onForYouChanged: knownPapers = forYou && forYou.items ? forYou.items.length : 0
    Connections {
        target: pet.forYou
        ignoreUnknownSignals: true
        function onChanged() {
            const count = pet.forYou.items.length
            if (count > pet.knownPapers) pet.say({text: qsTr("New papers in For You: ") + (count - pet.knownPapers), forYou: true, mood: "happy"})
            pet.knownPapers = count
        }
    }
    // Its face, by what is happening (the first that applies): held (dragged), poke (just clicked), what the bubble
    // says (happy, worried, rest, else talk), think (an answer being written), sleepy (nothing for a while). A mood
    // without faces of its own shows talking's for news, else the picture (Settings › Appearance › Pet faces).
    readonly property string mood: held ? "held" : poking ? "poke"
        : message && !message.writing ? (message.mood || (message.reminder ? "rest" : "talk"))
        : writing ? "think" : sleepy ? "sleepy" : ""
    readonly property var face: Theme.pictureMoods[mood]
        || (["happy", "worried", "rest"].indexOf(mood) >= 0 && Theme.pictureMoods.talk) || null
    // Of several faces: one picked as the mood comes ("random"), or each in turn while it lasts ("cycle").
    property int frame: 0
    onMoodChanged: frame = face && face.mode === "random" ? Math.floor(Math.random() * face.frames.length) : 0
    Timer {
        objectName: "petFaceTurn"
        interval: 600; repeat: true
        running: pet.visible && !!pet.face && pet.face.mode === "cycle" && pet.face.frames.length > 1
        onTriggered: pet.frame = (pet.frame + 1) % pet.face.frames.length
    }
    readonly property url shown: face ? face.frames[Math.min(frame, face.frames.length - 1)].url : Theme.picture
    // Every face, for the shape that takes clicks: worked out again only when they change, not at each turn.
    readonly property var faces: {
        const list = [Theme.picture]
        for (const name in Theme.pictureMoods) for (const f of Theme.pictureMoods[name].frames) list.push(f.url)
        return list
    }
    readonly property string facesKey: faces.join("\n")
    onFacesKeyChanged: Qt.callLater(fitClicks)
    // As wide as the widest face of a cut-out, so each stands the same height at the bottom middle.
    readonly property real aspect: {
        const clamp = function(a) { return Math.max(.3, Math.min(1.6, a)) }
        let widest = Theme.pictureSize.height > 0 ? clamp(Theme.pictureSize.width / Theme.pictureSize.height) : 1
        if (Theme.pictureCutout)
            for (const name in Theme.pictureMoods)
                for (const f of Theme.pictureMoods[name].frames) widest = Math.max(widest, clamp(f.aspect))
        return widest
    }
    // Sleepy once nothing has happened for half an hour (ten minutes late at night): no reading, news, click or drag.
    property bool sleepy: false
    // A minute, in milliseconds (tests shorten it).
    property real minute: 60000
    function stir() {
        sleepy = false
        idleClock.interval = (new Date().getHours() < 6 ? 10 : 30) * minute
        idleClock.restart()
    }
    Timer { id: idleClock; objectName: "petIdleClock"; onTriggered: pet.sleepy = true }
    onMessageChanged: if (message) stir()
    // Just clicked: its poked face for a moment.
    property bool poking: false
    Timer { id: pokeFace; interval: 1500; onTriggered: pet.poking = false }
    // Held while dragged: until the window has stood still a moment.
    property bool held: false
    Timer { id: heldSettle; interval: 400; onTriggered: pet.held = false }
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint | Qt.WindowDoesNotAcceptFocus
    // Its own window, not one that follows Owelk's (minimised, on another desktop).
    transientParent: null
    color: "transparent"
    title: "Owelk"
    // The app's colors (a window of its own does not take the main window's).
    palette.window: Theme.sidebar
    palette.windowText: Theme.text
    palette.highlight: Theme.accent
    palette.highlightedText: Theme.onAccent
    palette.button: Theme.control
    palette.buttonText: Theme.text
    palette.text: Theme.text
    palette.base: Theme.content
    palette.mid: Theme.border
    palette.toolTipBase: Theme.raised
    palette.toolTipText: Theme.text
    // Room above the picture for a hop.
    readonly property int headroom: 12
    height: DesktopPet.height + headroom
    width: Math.round(DesktopPet.height * aspect)
    Component.onCompleted: {
        knownPapers = forYou && forYou.items ? forYou.items.length : 0
        DesktopPet.prepare(pet)
        const at = DesktopPet.place(width, height)
        x = at.x; y = at.y
        visible = true
        DesktopPet.floatEverywhere(pet)
        fitClicks()
        stir()
    }
    // Clicks on the transparent parts go to whatever is behind the pet.
    function fitClicks() { DesktopPet.letClicksThroughAll(pet, faces, Qt.size(width, DesktopPet.height), headroom, headroom + 4) }
    onWidthChanged: Qt.callLater(fitClicks)
    onHeightChanged: Qt.callLater(fitClicks)
    // Where it was left, once it stops moving.
    onXChanged: { if (moving) dragged(); rememberLater.restart() }
    onYChanged: { if (moving) dragged(); rememberLater.restart() }
    function dragged() { movedAt = Date.now(); held = true; heldSettle.restart() }
    Timer { id: rememberLater; interval: 500; onTriggered: DesktopPet.remember(pet.x, pet.y) }

    Image {
        objectName: "petPicture"
        width: parent.width; height: DesktopPet.height
        y: pet.headroom
        // Not before the screen is known (its pixel ratio sets the size it is decoded at).
        source: Screen.width > 0 ? pet.shown : ""
        fillMode: Theme.pictureCutout ? Image.PreserveAspectFit : Image.PreserveAspectCrop
        verticalAlignment: Image.AlignBottom
        // The face it had stays until the next one is ready.
        retainWhileLoading: true
        sourceSize: Qt.size(Math.ceil(width * Screen.devicePixelRatio), Math.ceil(height * Screen.devicePixelRatio))
        asynchronous: true
        transform: [Translate { id: lift }, Translate { id: bob }]
        // A little larger while something is dragged over it.
        scale: drop.containsDrag ? 1.06 : 1
        transformOrigin: Item.Bottom
        Behavior on scale { NumberAnimation { duration: 120 } }
    }
    DropArea {
        id: drop
        anchors.fill: parent
        onDropped: function(event) { if (pet.received(event.urls, event.hasText ? event.text : "")) event.acceptProposedAction() }
    }
    // A hop when it has something to say.
    SequentialAnimation {
        id: hop
        NumberAnimation { target: lift; property: "y"; to: -pet.headroom; duration: 140; easing.type: Easing.OutQuad }
        NumberAnimation { target: lift; property: "y"; to: 0; duration: 360; easing.type: Easing.OutBounce }
    }
    // A slow bob only while an answer is being written.
    SequentialAnimation {
        objectName: "petBob"
        running: pet.writing && pet.visible
        loops: Animation.Infinite
        onRunningChanged: if (!running) bob.y = 0
        NumberAnimation { target: bob; property: "y"; to: -4; duration: 600; easing.type: Easing.InOutSine }
        NumberAnimation { target: bob; property: "y"; to: 0; duration: 600; easing.type: Easing.InOutSine }
    }
    // Dragged: the system moves it, and the press that started the drag is no click; nor is a release right after
    // the window moved (the system's move can end with one).
    property bool moving: false
    property real movedAt: 0
    DragHandler {
        objectName: "petMove"
        target: null
        onActiveChanged: if (active) { pet.moving = true; pet.held = true; heldSettle.restart(); pet.stir(); pet.startSystemMove() }
    }
    TapHandler {
        objectName: "petTap"
        onPressedChanged: if (pressed) pet.moving = false
        onTapped: if (!pet.moving && Date.now() - pet.movedAt > 600) pet.poke()
    }
    TapHandler { acceptedButtons: Qt.RightButton; onTapped: menu.popup() }
    Menu {
        id: menu
        objectName: "petMenu"
        // Its own window: the pet's is too small to hold it. That window takes the system's colors (white
        // text in dark mode), not the pet window's, so the menu has the app's here.
        popupType: Popup.Window
        // Its window, like the pet's, does not bring Owelk forward when a choice is clicked (Open Owelk does).
        onOpened: DesktopPet.floatEverywhere(contentItem.Window.window)
        palette.windowText: Theme.text
        palette.text: Theme.text
        palette.buttonText: Theme.text
        palette.highlight: Theme.accent
        palette.highlightedText: Theme.onAccent
        MenuItem { objectName: "openOwelk"; text: qsTr("Open Owelk"); onTriggered: pet.openRequested() }
        MenuItem { objectName: "hidePet"; text: qsTr("Hide Pet"); onTriggered: DesktopPet.enabled = false }
    }

    // The bubble: its own small window above the pet (below it near the top of the screen), so the
    // pet's window stays the size of the picture. A click does what it says; the right button
    // dismisses it.
    Window {
        id: bubble
        objectName: "petBubble"
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint | Qt.WindowDoesNotAcceptFocus
        color: "transparent"
        title: "Owelk"
        visible: pet.message !== null && pet.visible
        width: card.width + 4; height: card.height + 4
        readonly property bool below: pet.y - height - 4 < pet.screen.virtualY
        x: Math.round(pet.x + (pet.width - width) / 2)
        y: below ? pet.y + pet.height + 4 : pet.y + pet.headroom - height + 4
        Component.onCompleted: DesktopPet.prepare(bubble)
        onVisibleChanged: if (visible) DesktopPet.floatEverywhere(bubble)
        Rectangle {
            id: card
            x: 2; y: 2
            width: Math.min(260, words.implicitWidth + 24); height: words.implicitHeight + 16
            radius: Theme.radiusLarge
            color: Theme.raised
            border.color: Theme.border
            Label {
                id: words
                objectName: "petBubbleText"
                x: 12; y: 8; width: parent.width - 24
                text: pet.message ? pet.message.text : ""
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                color: Theme.text
            }
        }
        TapHandler { onTapped: pet.act() }
        TapHandler { acceptedButtons: Qt.RightButton; onTapped: pet.message = null }
    }
}
