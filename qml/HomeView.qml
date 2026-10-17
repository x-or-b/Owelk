import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform
import "WorkspaceTree.js" as Tree

Rectangle {
    id: root
    objectName: "homeView"
    color: Theme.sidebar
    readonly property var continuation: researchStore.continueReading
    signal openRequested()
    signal libraryRequested()
    // Unsorted chosen on Home: the Library opens filtered to it.
    signal libraryFilterRequested(var filter)
    // What Home lists, last opened first; read again when papers, notes or conversations change (and when shown).
    property var recentCollections: []
    property var recentNotes: []
    property var recentThreads: []
    function refreshLists() {
        if (!visible) return
        recentCollections = researchStore.recentItems("collection", 50)
        recentNotes = researchStore.recentItems("note", 50)
        recentThreads = researchStore.recentItems("ai", 50)
    }
    signal newNoteRequested()
    onVisibleChanged: refreshLists()
    Component.onCompleted: refreshLists()
    Timer { id: listsLater; interval: 150; onTriggered: root.refreshLists() }
    Connections {
        target: researchStore
        function onHomeChanged() { listsLater.restart() }
        function onNotesChanged() { listsLater.restart() }
        function onAiThreadsChanged() { listsLater.restart() }
        function onDocumentsChanged() { listsLater.restart() }
    }
    signal documentChosen(url source, var position)
    // A Settings page to open (For You's gear and hint).
    signal settingsRequested(string page)
    // A paper's page to read in a web tab.
    signal webRequested(url address)
    // Without the top bar (Settings › Appearance, Windows and Linux): the search field is Home's, at its top, and
    // Home filling the window also takes the bar's Back, Forward and ≡ (in tabs, the tab strip has them).
    property bool searchShown: false
    property bool controlsShown: false
    property var palette: null
    property var appMenu: null
    property bool canGoBack: false
    property bool canGoForward: false
    property string backKeys: ""
    property string forwardKeys: ""
    signal backRequested()
    signal forwardRequested()
    readonly property alias searchBox: homeSearch
    // A note or an AI chat chosen in Home's lists.
    signal resultChosen(var result)
    // A list in a slot of fixed height (rows rows): the rounded box grows with its rows up to the slot and
    // shows no more (the rest is in the Library), so the page keeps its layout however long each list is.
    readonly property real rowStep: Theme.rowHeight + 4
    component ListBox: Item {
        id: slot
        property var model: []
        property alias delegate: boxList.delegate
        property string empty: ""
        property int rows: 7
        Layout.fillWidth: true
        Layout.preferredHeight: rows * root.rowStep + rows - 1 + 8
        Rectangle {
            width: parent.width
            height: boxList.count ? Math.min(slot.height, boxList.contentHeight + 8) : root.rowStep + 8
            radius: Theme.radiusLarge
            color: Theme.content
            border.color: Theme.separator
            ListView {
                id: boxList
                anchors.fill: parent; anchors.margins: 4
                interactive: false
                spacing: 1
                model: slot.model.slice(0, slot.rows)
            }
            Label { anchors.centerIn: parent; visible: boxList.count === 0; text: slot.empty; color: Theme.textTertiary }
        }
    }
    // A box heading, with an optional + on the right. A heading that goes somewhere (opened) shows a
    // chevron and the hover colour.
    component BoxHeading: RowLayout {
        id: boxHeading
        property alias text: heading.text
        property alias adding: add.visible
        property alias addDescription: add.description
        // A quiet count after the heading, and a gear for the box's settings.
        property alias detail: detailLabel.text
        property alias configurable: gear.visible
        property alias configureDescription: gear.description
        property bool goes: false
        signal added()
        signal opened()
        signal configureRequested()
        Layout.fillWidth: true
        Layout.preferredHeight: 32
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Label {
                    id: heading
                    font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold
                    color: boxHeading.goes && headingHover.hovered ? Theme.accent : Theme.text
                }
                Icon { visible: boxHeading.goes; anchors.verticalCenter: parent.verticalCenter; name: "right"; size: Theme.fontBody; color: headingHover.hovered ? Theme.accent : Theme.textTertiary }
                HoverHandler { id: headingHover; enabled: boxHeading.goes; cursorShape: Qt.PointingHandCursor }
                TapHandler { enabled: boxHeading.goes; onTapped: boxHeading.opened() }
            }
        }
        Label { id: detailLabel; visible: text.length > 0; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
        IconButton { id: add; visible: false; icon.name: "add"; onClicked: boxHeading.added() }
        IconButton { id: gear; objectName: boxHeading.objectName + "Settings"; visible: false; icon.name: "settings"; onClicked: boxHeading.configureRequested() }
    }
    // The picture theme's picture behind the page (cards stay opaque).
    PictureLayer { objectName: "homePicture"; anchors.fill: parent }
    Item {
        id: homeBar
        objectName: "homeSearchBar"
        visible: root.searchShown
        width: parent.width; height: visible ? Theme.barHeight + 16 : 0
        Row {
            visible: root.controlsShown
            anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            IconButton {
                objectName: "homeBack"; icon.name: "back"; enabled: root.canGoBack
                description: qsTr("Back") + (root.backKeys.length ? " · " + root.backKeys : "")
                onClicked: root.backRequested()
            }
            IconButton {
                objectName: "homeForward"; icon.name: "forward"; enabled: root.canGoForward
                description: qsTr("Forward") + (root.forwardKeys.length ? " · " + root.forwardKeys : "")
                onClicked: root.forwardRequested()
            }
        }
        SearchBox {
            id: homeSearch
            objectName: "homeSearchBox"
            fieldName: "homeSearchField"
            palette: root.palette
            anchors.centerIn: parent
            width: Math.min(680, Math.max(320, root.width * .5))
        }
        IconButton {
            objectName: "homeMenuButton"
            visible: root.controlsShown && !!root.appMenu
            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
            icon.name: "menu"; description: qsTr("Menu")
            onClicked: root.appMenu.popup(this, width - root.appMenu.width, height)
        }
    }
    Flickable {
        anchors.fill: parent
        anchors.topMargin: homeBar.height
        clip: true
        contentWidth: width
        contentHeight: body.height + 64
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: body
            x: (parent.width - width) / 2
            y: 32
            width: Math.min(780, parent.width - 48)
            spacing: 20
            // Searching is the top bar's (Cmd+K); here only a quiet line while PDFs are being indexed or some
            // cannot be read (details in Settings › Search).
            IndexStatus { Layout.fillWidth: true; quiet: true }
            // The paper last read, as a card: click anywhere on it to go back to the page.
            ItemDelegate {
                id: continueCard
                objectName: "continueReading"
                Layout.fillWidth: true
                // The same room above and below the card (the headings below sit in a taller row), and the
                // same padding inside on every side.
                Layout.topMargin: (32 - Theme.fontHeadline * 1.3) / 2
                padding: 18
                readonly property var details: root.continuation.source ? (researchStore.documentsRevision, researchStore.documentDetails(root.continuation.source)) : ({})
                onClicked: {
                    if (root.continuation.source) root.documentChosen(root.continuation.source, root.continuation.position)
                    else root.openRequested()
                }
                // Hovered: the hover tint over the page colour, opaque so a picture behind stays behind.
                background: Rectangle {
                    radius: Theme.radiusLarge
                    color: continueCard.hovered ? Theme.sidebar : Theme.content
                    border.color: Theme.separator
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: continueCard.hovered ? Theme.hover : "transparent" }
                }
                contentItem: RowLayout {
                    spacing: 16
                    ColumnLayout {
                        id: continueColumn
                        Layout.fillWidth: true
                        spacing: 4
                        Label { text: qsTr("Continue Reading"); font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textTertiary }
                        Label {
                            Layout.fillWidth: true
                            text: root.continuation.name || qsTr("Start with a paper")
                            elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap; textFormat: Text.PlainText
                            font.pixelSize: Theme.fontTitle; font.weight: Font.Medium; color: Theme.text
                        }
                        Label {
                            Layout.fillWidth: true
                            text: root.continuation.source
                                ? [continueCard.details.authors, continueCard.details.year, qsTr("Page ") + (((root.continuation.position || {}).page || 0) + 1)].filter(function(t) { return t && String(t).length }).join("  ·  ")
                                : qsTr("Open a PDF. Your reading position is saved automatically.")
                            elide: Text.ElideRight; textFormat: Text.PlainText
                            color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                        }
                    }
                    Button {
                        highlighted: true
                        text: root.continuation.source ? qsTr("Continue") : qsTr("Open PDF…")
                        onClicked: continueCard.clicked()
                    }
                }
            }
            // For You: the newest papers found for the topics and collections followed (all of them in
            // Library › For You). Nothing followed yet: one line that leads to the settings; nothing new: hidden.
            ColumnLayout {
                id: forYouBox
                objectName: "homeForYou"
                readonly property var forYou: researchStore.forYou
                readonly property var shown: forYou.items.slice(0, 5)
                visible: forYou.configured ? shown.length > 0 : true
                Layout.fillWidth: true
                spacing: 6
                BoxHeading {
                    objectName: "homeForYouHeading"
                    text: qsTr("For You"); goes: true
                    detail: forYouBox.forYou.items.length ? forYouBox.forYou.items.length + qsTr(" new") : ""
                    configurable: true; configureDescription: qsTr("For You settings")
                    onOpened: root.libraryFilterRequested({view: "foryou"})
                    onConfigureRequested: root.settingsRequested("foryou")
                }
                ItemDelegate {
                    objectName: "homeForYouHint"
                    visible: !forYouBox.forYou.configured
                    Layout.fillWidth: true
                    padding: 14
                    onClicked: researchStore.forYou.manageFollowing()
                    background: Rectangle {
                        radius: Theme.radiusLarge
                        color: parent.hovered ? Theme.sidebar : Theme.content
                        border.color: Theme.separator
                        Rectangle { anchors.fill: parent; radius: parent.radius; color: parent.parent.hovered ? Theme.hover : "transparent" }
                    }
                    contentItem: RowLayout {
                        spacing: 10
                        Icon { name: "forYou"; size: Theme.fontBody + 2; color: Theme.textTertiary }
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Follow a topic, a collection, a researcher or an institution to see new papers here")
                            elide: Text.ElideRight; color: Theme.textSecondary
                        }
                        Icon { name: "right"; size: Theme.fontBody; color: Theme.textTertiary }
                    }
                }
                Rectangle {
                    visible: forYouBox.shown.length > 0
                    Layout.fillWidth: true
                    implicitHeight: forYouRows.implicitHeight + 8
                    radius: Theme.radiusLarge
                    color: Theme.content
                    border.color: Theme.separator
                    Column {
                        id: forYouRows
                        x: 4; y: 4; width: parent.width - 8
                        spacing: 1
                        Repeater {
                            model: forYouBox.shown
                            delegate: ItemDelegate {
                                id: suggestion
                                required property var modelData
                                required property int index
                                readonly property bool adding: forYouBox.forYou.adding.indexOf(modelData.id) >= 0
                                objectName: "homeForYou-" + index
                                width: forYouRows.width
                                height: Theme.rowHeightTall + 10
                                separator: index < forYouBox.shown.length - 1
                                rightPadding: actions.width + 12
                                // Opens in Library › For You, the whole abstract shown (a web page takes a while).
                                onClicked: root.libraryFilterRequested({view: "foryou", open: modelData.id})
                                readonly property string details: [modelData.authors, modelData.date, modelData.sourceName].filter(function(t) { return t && t.length }).join("  ·  ")
                                ToolTip.visible: hovered; ToolTip.delay: 700
                                ToolTip.text: details + ((modelData.abstract || "").length ? "\n\n" + modelData.abstract.slice(0, 600) : "")
                                contentItem: ColumnLayout {
                                    spacing: 3
                                    Label { Layout.fillWidth: true; text: suggestion.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; font.weight: Font.Medium; color: Theme.text }
                                    // Why to read it (the AI's sentence), else who and when.
                                    Label {
                                        objectName: "homeForYouWhy-" + suggestion.index
                                        Layout.fillWidth: true
                                        text: suggestion.modelData.why || suggestion.details
                                        elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption
                                        color: suggestion.modelData.why ? Theme.textSecondary : Theme.textTertiary
                                    }
                                }
                                // Add and Dismiss on hover (Adding… while the PDF comes).
                                Row {
                                    id: actions
                                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2
                                    opacity: suggestion.hovered || suggestion.adding ? 1 : 0
                                    Label { visible: suggestion.adding; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Adding…"); font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                                    IconButton {
                                        objectName: "homeForYouAdd-" + suggestion.index
                                        visible: !suggestion.adding
                                        icon.name: suggestion.modelData.hasPdf ? "download" : "external"
                                        description: suggestion.modelData.hasPdf ? qsTr("Add to the Library") : qsTr("No free PDF: open its page")
                                        onClicked: suggestion.modelData.hasPdf ? forYouBox.forYou.add([suggestion.modelData.id]) : (forYouBox.forYou.expect(suggestion.modelData.id), root.webRequested(suggestion.modelData.url))
                                    }
                                    IconButton {
                                        objectName: "homeForYouDismiss-" + suggestion.index
                                        visible: !suggestion.adding
                                        icon.name: "close"; description: qsTr("Dismiss")
                                        onClicked: forYouBox.forYou.dismiss([suggestion.modelData.id])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Collections and recent papers, then notes and AI conversations; all last opened first.
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 28
                rowSpacing: 18
                ColumnLayout {
                    objectName: "homeCollections"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { objectName: "homeCollectionsHeading"; text: qsTr("Collections"); goes: true; onOpened: root.libraryFilterRequested({}) }
                    ListBox {
                        model: root.recentCollections
                        empty: qsTr("No collections yet")
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            objectName: "homeCollection-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < Math.min(7, root.recentCollections.length) - 1
                            rightPadding: 40
                            text: modelData.name
                            onClicked: root.libraryFilterRequested({collection: modelData.id})
                            Label {
                                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                text: parent.modelData.count; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                            }
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    // The heading goes to the Library; + opens a PDF from disk.
                    BoxHeading {
                        objectName: "homeRecentHeading"
                        text: qsTr("Recent Papers"); goes: true; onOpened: root.libraryRequested()
                        adding: true; addDescription: qsTr("Open PDF…"); onAdded: root.openRequested()
                    }
                    ListBox {
                        model: researchStore.recentDocuments
                        empty: qsTr("No recent papers")
                        delegate: RecentPaperDelegate {
                            required property int index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < Math.min(7, researchStore.recentDocuments.length) - 1
                            onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                            onMenuRequested: function(row) { recentMenu.show(row) }
                        }
                    }
                }
                ColumnLayout {
                    objectName: "homeNotes"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { objectName: "homeNotesHeading"; text: qsTr("Notes"); goes: true; onOpened: root.libraryFilterRequested({view: "notes"}); adding: true; addDescription: qsTr("New note"); onAdded: root.newNoteRequested() }
                    ListBox {
                        rows: 5
                        model: root.recentNotes
                        empty: qsTr("No notes yet")
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            objectName: "homeNote-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < Math.min(5, root.recentNotes.length) - 1
                            text: modelData.title
                            onClicked: root.resultChosen({kind: "note", id: modelData.id})
                        }
                    }
                }
                ColumnLayout {
                    objectName: "homeThreads"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { text: qsTr("AI Conversations") }
                    ListBox {
                        rows: 5
                        model: root.recentThreads
                        empty: qsTr("No conversations yet")
                        // The question, and the paper it was about.
                        delegate: ItemDelegate {
                            id: threadRow
                            required property var modelData
                            required property int index
                            objectName: "homeThread-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < Math.min(5, root.recentThreads.length) - 1
                            text: modelData.title
                            onClicked: root.resultChosen({kind: "ai", id: modelData.id})
                            contentItem: RowLayout {
                                spacing: 8
                                Label { Layout.fillWidth: true; text: threadRow.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                                Label {
                                    visible: text.length > 0
                                    Layout.maximumWidth: threadRow.width * .4
                                    text: threadRow.modelData.paper || ""
                                    elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    PaperMenu {
        id: recentMenu
        objectName: "recentPaperMenu"
        recent: true
        onOpenRequested: function(source, position) { root.documentChosen(source, position) }
    }
    // PDFs dropped on Home open; a folder becomes a collection of the PDFs in it (subfolders as collections
    // inside it). Files are not moved.
    DropArea {
        id: drops
        objectName: "homeDrop"
        anchors.fill: parent
        z: 10
        keys: ["text/uri-list"]
        function take(urls) {
            const pdfs = urls.filter(function(u) { return /\.pdf$/i.test(u.toString()) })
            const folders = urls.filter(function(u) { return researchStore.isFolder(u) })
            pdfs.forEach(function(u) { root.documentChosen(u, undefined) })
            folders.forEach(function(u) { researchStore.importFolder(u, "", true) })
            return pdfs.length + folders.length > 0
        }
        onDropped: function(drop) { if (take(drop.urls)) drop.acceptProposedAction() }
        Rectangle {
            anchors.fill: parent; anchors.margins: 6
            visible: drops.containsDrag
            radius: Theme.radiusLarge
            color: "transparent"
            border.width: 2; border.color: Theme.accent
            Label { anchors.centerIn: parent; text: qsTr("Open"); font.pixelSize: Theme.fontSmall; color: Theme.textSecondary }
        }
    }
}
