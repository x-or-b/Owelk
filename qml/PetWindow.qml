import QtQuick
import QtQuick.Controls
import Owelk.Ui

// The desktop pet: the picture theme's picture in a small window that floats above other apps while
// Owelk runs (Settings › Appearance › Picture). Drag it anywhere; a click brings Owelk forward; the
// right button has its menu. While Owelk is behind other apps it says when an AI answer is ready or
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
    function act() {
        const m = message
        message = null
        if (m && m.reminder) return
        if (m && m.thread) threadRequested(m.thread)
        else if (m && m.forYou) forYouRequested()
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
            pet.say({text: qsTr("Your answer is ready."), thread: thread})
        }
        function onFailed(request, error) {
            const thread = pet.answering[request]
            if (thread === undefined) return
            pet.settle(request)
            pet.say({text: qsTr("The AI could not answer: ") + String(error).split("\n")[0], thread: thread})
        }
    }
    // A finished or failed answer; a "writing" bubble for it goes (another one still written keeps it).
    function settle(request) {
        const next = Object.assign({}, answering); delete next[request]; answering = next
        if (message && message.writing) { message = null; sayWriting() }
    }
    // Break reminder: after DesktopPet.breakMinutes of reading (stretch: researchStore.readingClock's seconds read
    // since the last break, which five minutes away from reading start again) the pet suggests a break, also
    // while Owelk is in front; again after as many more. A reminder nobody answers goes after two minutes.
    property int stretch: 0
    property int reminded: 0
    onStretchChanged: {
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
            if (count > pet.knownPapers) pet.say({text: qsTr("New papers in For You: ") + (count - pet.knownPapers), forYou: true})
            pet.knownPapers = count
        }
    }
    // Its face: the picture, or the one for talking (a bubble) or thinking (an answer being written) when the
    // picture has them (Settings › Appearance › Picture).
    readonly property string mood: writing ? "think" : message ? "talk" : ""
    readonly property var face: Theme.pictureMoods[mood] || null
    readonly property url shown: face ? face.url : Theme.picture
    onShownChanged: Qt.callLater(fitClicks)
    // As wide as the widest face of a cut-out, so each stands the same height at the bottom middle.
    readonly property real aspect: {
        const clamp = function(a) { return Math.max(.3, Math.min(1.6, a)) }
        let widest = Theme.pictureSize.height > 0 ? clamp(Theme.pictureSize.width / Theme.pictureSize.height) : 1
        if (Theme.pictureCutout)
            for (const name in Theme.pictureMoods) widest = Math.max(widest, clamp(Theme.pictureMoods[name].aspect))
        return widest
    }
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
    }
    // Clicks on the transparent parts go to whatever is behind the pet.
    function fitClicks() { DesktopPet.letClicksThrough(pet, shown, Qt.size(width, DesktopPet.height), headroom, headroom + 4) }
    onWidthChanged: Qt.callLater(fitClicks)
    onHeightChanged: Qt.callLater(fitClicks)
    Connections { target: Theme; function onPicturesChanged() { Qt.callLater(pet.fitClicks) } }
    // Where it was left, once it stops moving.
    onXChanged: rememberLater.restart()
    onYChanged: rememberLater.restart()
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
    DragHandler { target: null; onActiveChanged: if (active) pet.startSystemMove() }
    TapHandler { objectName: "petTap"; onTapped: pet.act() }
    TapHandler { acceptedButtons: Qt.RightButton; onTapped: menu.popup() }
    Menu {
        id: menu
        objectName: "petMenu"
        // Its own window: the pet's is too small to hold it. That window takes the system's colors (white
        // text in dark mode), not the pet window's, so the menu has the app's here.
        popupType: Popup.Window
        palette.windowText: Theme.text
        palette.text: Theme.text
        palette.buttonText: Theme.text
        palette.highlight: Theme.accent
        palette.highlightedText: Theme.onAccent
        MenuItem { text: qsTr("Open Owelk"); onTriggered: pet.openRequested() }
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
