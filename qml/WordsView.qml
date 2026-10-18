import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// Library › Words: the words saved from Gloss (its ☆), newest first, with their own search. A click goes to the
// word's page in its paper and lights it; the right button edits the meaning or removes the word, which Undo
// brings back for a while.
ColumnLayout {
    id: root
    objectName: "wordsView"
    signal linkRequested(string link)
    property string query: ""
    property var rows: []
    function refresh() { rows = visible ? researchStore.words(query) : [] }
    onQueryChanged: refresh()
    onVisibleChanged: refresh()
    Component.onCompleted: refresh()
    Connections {
        target: researchStore
        function onWordsChanged() { root.refresh() }
        function onDocumentsChanged() { root.refresh() }
    }
    // The meaning as one plain line (Gloss writes it in Markdown).
    function plain(text) { return String(text || "").replace(/\*\*|__|`/g, "").replace(/\s+/g, " ").trim() }
    function open(word) {
        if (!word.documentId || !word.source.toString().length) return
        linkRequested("owelk://document/" + word.documentId + "#page=" + (word.page + 1) + "&q=" + encodeURIComponent(word.term))
    }
    // The words just removed, for Undo.
    property var removed: []
    function remove(ids) {
        if (!researchStore.removeWords(ids)) return
        removed = ids
        undoHide.restart()
    }
    Timer { id: undoHide; interval: 8000; onTriggered: root.removed = [] }
    spacing: 6
    RowLayout {
        Layout.fillWidth: true
        Label { Layout.fillWidth: true; text: qsTr("Words"); font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; color: Theme.text }
    }
    TextField {
        objectName: "wordsQuery"
        Layout.fillWidth: true
        placeholderText: qsTr("Find a word, its meaning, its sentence or its paper")
        onTextChanged: root.query = text
    }
    Label {
        objectName: "wordsCount"
        text: root.rows.length + (root.rows.length === 1 ? qsTr(" word") : qsTr(" words"))
        font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
    }
    ListView {
        id: list
        objectName: "wordsList"
        Layout.fillWidth: true; Layout.fillHeight: true
        clip: true
        model: root.rows
        ScrollBar.vertical: ScrollBar {}
        delegate: ItemDelegate {
            id: wordRow
            required property var modelData
            required property int index
            objectName: "word-" + index
            width: list.width
            height: column.implicitHeight + 16
            separator: index < list.count - 1
            onClicked: root.open(modelData)
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: { wordMenu.word = wordRow.modelData; wordMenu.popup() } }
            ToolTip.visible: hovered && wordRow.modelData.sentence.length > 0
            ToolTip.delay: 700
            ToolTip.text: wordRow.modelData.sentence
            contentItem: ColumnLayout {
                id: column
                spacing: 2
                Label { Layout.fillWidth: true; text: wordRow.modelData.term; elide: Text.ElideRight; textFormat: Text.PlainText; font.weight: Font.DemiBold; color: Theme.text }
                Label {
                    objectName: "wordMeaning-" + wordRow.index
                    Layout.fillWidth: true
                    text: root.plain(wordRow.modelData.meaning)
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                }
                Label {
                    Layout.fillWidth: true
                    text: wordRow.modelData.paper.length ? wordRow.modelData.paper + qsTr(" · p. ") + (wordRow.modelData.page + 1) : qsTr("Paper no longer in the Library")
                    elide: Text.ElideRight; textFormat: Text.PlainText
                    font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                }
            }
        }
        Label {
            anchors.centerIn: parent
            width: parent.width - 40
            visible: list.count === 0
            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
            text: root.query.length ? qsTr("No words match.") : qsTr("Words you save from Gloss (select a word, Gloss it, then ☆) appear here.")
            color: Theme.textTertiary
        }
    }
    // Removed just now: Undo puts them back.
    RowLayout {
        objectName: "wordsUndoBar"
        visible: root.removed.length > 0
        Layout.fillWidth: true
        Label {
            Layout.fillWidth: true
            text: root.removed.length === 1 ? qsTr("Removed a word.") : qsTr("Removed %1 words.").arg(root.removed.length)
            font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
        }
        Button {
            objectName: "wordsUndo"
            flat: true; font.pixelSize: Theme.fontSmall; implicitHeight: Theme.controlHeightSmall
            text: qsTr("Undo")
            onClicked: { researchStore.restoreWords(root.removed); root.removed = [] }
        }
    }
    Menu {
        id: wordMenu
        objectName: "wordMenu"
        property var word: ({})
        MenuItem { objectName: "wordOpen"; text: qsTr("Open"); onTriggered: root.open(wordMenu.word) }
        MenuItem { objectName: "wordEdit"; text: qsTr("Edit Meaning…"); onTriggered: meaningDialog.begin(wordMenu.word) }
        MenuSeparator {}
        MenuItem { objectName: "wordRemove"; text: qsTr("Remove"); palette.windowText: Theme.danger; onTriggered: root.remove([wordMenu.word.id]) }
    }
    Dialog {
        id: meaningDialog
        objectName: "wordMeaningDialog"
        property string wordId: ""
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(460, parent ? parent.width - 32 : 460)
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        function begin(word) { wordId = word.id; title = word.term; meaningField.text = word.meaning; open(); meaningField.forceActiveFocus() }
        TextArea {
            id: meaningField
            objectName: "wordMeaningField"
            width: parent.width
            wrapMode: TextEdit.Wrap
        }
        onAccepted: researchStore.setWordMeaning(wordId, meaningField.text)
    }
}
