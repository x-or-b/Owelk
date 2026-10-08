import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform
import "StrokePath.js" as Stroke

// Annotations beside the page: every mark on the paper — pen, highlights, comments, text boxes and
// pictures — in page order (top to bottom) or grouped by kind. Hover one to outline its place on the
// page, click to go there; comments and highlight notes are written and edited in place, text boxes in
// their editor. They are the same annotations as on the page, so export, search and undo work on them.
Rectangle {
    id: root
    objectName: "marginNotes"
    required property var canvas
    property url source
    // The note being written for a new place: {page, selection} or {page, rectangle}.
    property var draft: null
    property string editingId: ""
    // "page": top to bottom through the paper; "type": pen, highlights, comments, text, pictures.
    property string sortMode: researchStore.setting("annotations.sort", "page") === "type" ? "type" : "page"
    function setSortMode(mode) { sortMode = mode; researchStore.setSetting("annotations.sort", mode) }
    readonly property var kinds: ["draw", "highlight", "comment", "text", "image"]
    readonly property var kindNames: ({draw: "Pen", highlight: "Highlights", comment: "Comments", text: "Text", image: "Pictures"})
    readonly property var notes: canvas.savedHighlights
        .filter(function(h) { return root.kinds.indexOf(h.kind) >= 0 })
        .sort(function(a, b) {
            const byPlace = a.page - b.page || ((a.rectangles[0] || {}).y || 0) - ((b.rectangles[0] || {}).y || 0)
            return root.sortMode === "type" ? root.kinds.indexOf(a.kind) - root.kinds.indexOf(b.kind) || byPlace : byPlace
        })
    color: Theme.sidebar
    // Comments go straight into the list (on the selection, or a place clicked next); other kinds use their
    // page tool: click or drag on the page, as with the toolbar.
    function newAnnotation(kind) {
        if (kind === "comment" && canvas.selectedAnchor) { beginDraft({page: canvas.selectedAnchor.page, selection: canvas.selectedAnchor}); return }
        canvas.captureMode = false
        canvas.tool = kind
    }
    function beginDraft(spec) {
        draft = spec
        editingId = ""
        list.positionViewAtBeginning()
        Qt.callLater(function() { const card = list.headerItem ? list.headerItem.item : null; if (card) card.field.forceActiveFocus() })
    }
    function edit(id) {
        draft = null
        editingId = id
        const at = notes.findIndex(function(n) { return n.id === id })
        if (at >= 0) list.positionViewAtIndex(at, ListView.Contain)
    }
    function saveDraft(body) {
        if (!draft || !body.trim().length) { draft = null; return }
        const color = canvas.markColor
        if (draft.selection) {
            const s = draft.selection
            researchStore.commentText(root.source, s.page, s.from, s.to, s.text, body, color)
        } else {
            researchStore.saveAnnotation(root.source, draft.page, {kind: "comment", page: draft.page, rectangles: [draft.rectangle],
                                                                   color: color, sha256: canvas.documentFingerprint, body: body})
        }
        draft = null
    }
    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 1
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 12; Layout.rightMargin: 6
            Label {
                Layout.fillWidth: true
                text: "Annotations" + (root.notes.length ? "  " + root.notes.length : "")
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary
            }
            TabBar {
                objectName: "annotationSort"
                currentIndex: root.sortMode === "type" ? 1 : 0
                TabButton { objectName: "annotationSortPage"; text: "Page"; width: 48; onClicked: root.setSortMode("page"); ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: "Top to bottom through the paper" }
                TabButton { objectName: "annotationSortType"; text: "Type"; width: 48; onClicked: root.setSortMode("type"); ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: "Pen, highlights, comments, text, pictures" }
            }
            // New annotation of any kind: a comment is written here; the others are placed on the page.
            IconButton {
                id: addButton
                objectName: "newMarginNote"
                icon.name: "add"
                description: "New annotation · comment, text box, picture or pen"
                onClicked: addMenu.popup(addButton, 0, addButton.height)
                Menu {
                    id: addMenu
                    objectName: "newAnnotationMenu"
                    MenuItem {
                        objectName: "newCommentItem"
                        text: root.canvas.selectedAnchor ? "Comment on Selection" : "Comment…"
                        onTriggered: root.newAnnotation("comment")
                    }
                    MenuItem { objectName: "newTextItem"; text: "Text Box"; onTriggered: root.newAnnotation("text") }
                    MenuItem { objectName: "newImageItem"; text: "Picture"; onTriggered: root.newAnnotation("image") }
                    MenuItem { objectName: "newPenItem"; text: "Pen"; onTriggered: root.newAnnotation("draw") }
                }
            }
        }
        ListView {
            id: list
            objectName: "marginNoteList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            topMargin: 4; bottomMargin: 12
            model: root.notes
            ScrollBar.vertical: ScrollBar {}
            header: Loader {
                id: draftCard
                width: list.width
                active: root.draft !== null
                height: active && item ? item.implicitHeight + 8 : 0
                sourceComponent: NoteCard {
                    width: list.width
                    page: root.draft ? root.draft.page : 0
                    quote: root.draft && root.draft.selection ? root.draft.selection.text || "" : ""
                    ink: root.canvas.markColor
                    editing: true
                    onCommitted: function(body) { root.saveDraft(body) }
                    onCancelled: root.draft = null
                }
            }
            delegate: NoteCard {
                id: card
                required property var modelData
                required property int index
                width: list.width
                objectName: "marginNote-" + modelData.id
                noteId: modelData.id
                kind: modelData.kind
                record: modelData
                page: modelData.page
                quote: modelData.text || ""
                body: modelData.body || ""
                ink: modelData.color
                headingIsPage: root.sortMode === "page"
                // A heading above the first of each page (or of each kind, sorted by type).
                heading: root.sortMode === "type"
                    ? (index === 0 || root.notes[index - 1].kind !== modelData.kind ? root.kindNames[modelData.kind] : "")
                    : (index === 0 || root.notes[index - 1].page !== modelData.page ? "Page " + (modelData.page + 1) : "")
                current: root.canvas.currentPage === modelData.page
                editing: root.editingId === modelData.id
                onHoveredChanged: root.canvas.focusedMark = hovered ? modelData.id : (root.canvas.focusedMark === modelData.id ? "" : root.canvas.focusedMark)
                onOpened: root.canvas.showSource(modelData.page, modelData.rectangles[0])
                // Text boxes are edited in their editor (it fits the font to the box); pen and pictures have no text.
                onEditRequested: {
                    if (modelData.kind === "text") root.canvas.editRequested(modelData, null)
                    else if (modelData.kind === "highlight" || modelData.kind === "comment") root.edit(modelData.id)
                }
                onCommitted: function(text) {
                    root.editingId = ""
                    if (text.trim().length && text !== (modelData.body || "")) researchStore.updateHighlight(modelData.id, modelData.color, text)
                }
                onCancelled: root.editingId = ""
                onRemoveRequested: { const id = modelData.id; Qt.callLater(function() { researchStore.removeHighlight(id) }) }
            }
            // Follow the page being read (unless the pointer is in the list).
            Connections {
                target: root.canvas
                function onCurrentPageChanged() {
                    if (listHover.hovered || root.editingId.length || root.draft) return
                    const at = root.notes.findIndex(function(n) { return n.page >= root.canvas.currentPage })
                    if (at >= 0) list.positionViewAtIndex(at, ListView.Beginning)
                }
            }
            HoverHandler { id: listHover }
            Label {
                anchors.centerIn: parent
                width: parent.width - 32
                visible: root.notes.length === 0 && !root.draft
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Pen, highlights, comments, text boxes and pictures on this paper appear here. Select text and add a note, or use + and click a place on the page."
                color: Theme.textTertiary
                font.pixelSize: Theme.fontSmall
            }
        }
    }

    // One note: page, the quoted text with its ink, and the note itself (editable in place).
    component NoteCard: Item {
        id: card
        property string noteId: ""
        property string kind: "comment"
        property var record: ({})
        property string heading: ""
        // A page heading follows the page being read; kind headings stay quiet.
        property bool headingIsPage: true
        property int page: 0
        property string quote: ""
        property string body: ""
        property color ink: Theme.accent
        property bool current: true
        property bool editing: false
        property alias field: editor
        readonly property bool hovered: hover.hovered
        signal opened()
        signal editRequested()
        signal committed(string text)
        signal cancelled()
        signal removeRequested()
        implicitHeight: column.implicitHeight
        height: implicitHeight
        ColumnLayout {
            id: column
            width: parent.width
            spacing: 4
            Label {
                visible: card.heading.length > 0
                Layout.leftMargin: 14; Layout.topMargin: 6
                text: card.heading
                font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold
                color: card.current && card.headingIsPage ? Theme.text : Theme.textTertiary
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 8; Layout.rightMargin: 8
                implicitHeight: inner.implicitHeight + 16
                radius: Theme.radius
                color: Theme.content
                border.width: card.editing || hover.hovered ? 1 : 1
                border.color: card.editing ? Theme.accentBorder : hover.hovered ? Theme.border : Theme.separator
                HoverHandler { id: hover }
                TapHandler { enabled: !card.editing; onTapped: card.opened(); onDoubleTapped: card.editRequested() }
                TapHandler { acceptedButtons: Qt.RightButton; enabled: card.noteId.length > 0; onTapped: noteMenu.popup() }
                Menu {
                    id: noteMenu
                    MenuItem { text: "Go to"; onTriggered: card.opened() }
                    MenuItem { visible: card.kind !== "draw" && card.kind !== "image"; height: visible ? implicitHeight : 0; text: "Edit"; onTriggered: card.editRequested() }
                    MenuItem { visible: card.body.length > 0; height: visible ? implicitHeight : 0; text: "Copy Text"; onTriggered: researchStore.copyText(card.body) }
                    MenuSeparator {}
                    MenuItem { objectName: "removeMarginNote"; text: "Delete"; palette.windowText: Theme.danger; onTriggered: card.removeRequested() }
                }
                ColumnLayout {
                    id: inner
                    x: 10; y: 8
                    width: parent.width - 20
                    spacing: 6
                    // The quoted text, marked with the note's ink.
                    RowLayout {
                        visible: card.quote.length > 0
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle { Layout.preferredWidth: 3; Layout.fillHeight: true; radius: 1.5; color: card.ink }
                        Label {
                            Layout.fillWidth: true
                            text: card.quote
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                            font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                        }
                    }
                    // What the mark is, for pen and pictures (and empty highlights); a small picture of it.
                    RowLayout {
                        visible: card.kind === "draw" || card.kind === "image" || card.kind === "text" || (card.kind === "highlight" && !card.body && !card.quote)
                        Layout.fillWidth: true
                        spacing: 8
                        Icon { name: ({draw: "draw", image: "image", text: "text", highlight: "highlight"})[card.kind] || "comment"; color: card.ink; size: Theme.fontBody }
                        Label {
                            Layout.fillWidth: true
                            text: ({draw: "Drawing", image: "Picture", text: "Text box", highlight: "Highlight"})[card.kind] || ""
                            font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                        }
                    }
                    Image {
                        objectName: "marginPicture-" + card.noteId
                        visible: card.kind === "image" && status === Image.Ready
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? Math.min(90, implicitHeight) : 0
                        source: card.kind === "image" ? (card.record.image || "") : ""
                        sourceSize.height: 180
                        fillMode: Image.PreserveAspectFit
                        horizontalAlignment: Image.AlignLeft
                        asynchronous: true
                    }
                    Canvas {
                        objectName: "marginDrawing-" + card.noteId
                        visible: card.kind === "draw"
                        Layout.fillWidth: true
                        Layout.preferredHeight: visible ? 44 : 0
                        readonly property var points: card.kind === "draw" ? (card.record.drawing || []) : []
                        onPointsChanged: requestPaint()
                        onWidthChanged: requestPaint()
                        onPaint: {
                            const c = getContext("2d"); c.reset()
                            if (points.length < 2) return
                            // The stroke scaled into the strip, keeping its proportions.
                            const xs = points.map(function(p) { return p.x }), ys = points.map(function(p) { return p.y })
                            const x0 = Math.min.apply(null, xs), y0 = Math.min.apply(null, ys)
                            const w = Math.max(.001, Math.max.apply(null, xs) - x0), h = Math.max(.001, Math.max.apply(null, ys) - y0)
                            const scale = Math.min((width - 8) / w, (height - 8) / (h * 1.3))
                            c.strokeStyle = card.ink; c.lineWidth = 2; c.lineCap = "round"; c.lineJoin = "round"; c.beginPath()
                            Stroke.trace(c, points, function(p) { return 4 + (p.x - x0) * scale }, function(p) { return 4 + (p.y - y0) * scale * 1.3 })
                            c.stroke()
                        }
                    }
                    Label {
                        visible: !card.editing && card.body.length > 0
                        Layout.fillWidth: true
                        text: card.body
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: card.current ? Theme.text : Theme.textSecondary
                    }
                    TextArea {
                        id: editor
                        objectName: "marginNoteEditor"
                        visible: card.editing
                        Layout.fillWidth: true
                        text: card.body
                        placeholderText: "Write a note…"
                        wrapMode: TextEdit.Wrap
                        onVisibleChanged: if (visible) { text = card.body; forceActiveFocus(); cursorPosition = length }
                        // Cmd+Return saves, Esc cancels, leaving the field saves.
                        Keys.onPressed: function(event) {
                            // Commit a character still being composed (Korean and the like) before saving.
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { event.accepted = true; Qt.inputMethod.commit(); card.committed(text) }
                            else if (event.key === Qt.Key_Escape) { event.accepted = true; card.cancelled() }
                        }
                        onActiveFocusChanged: if (!activeFocus && card.editing) card.committed(text)
                    }
                    Label {
                        visible: card.editing
                        Layout.fillWidth: true
                        text: Platform.keys("Ctrl+Return") + " to save · Esc to cancel"
                        font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                    }
                }
            }
        }
    }
}
