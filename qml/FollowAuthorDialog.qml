import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// Follow Author: a paper's authors from OpenAlex, the last and the corresponding author first (usually who leads
// the work), each with where they work, and their institutions below. One click follows; nothing is guessed.
Dialog {
    id: root
    objectName: "followAuthorDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(520, parent ? parent.width - 40 : 520)
    modal: true
    title: qsTr("Follow Author")
    standardButtons: Dialog.Close
    readonly property var forYou: researchStore.forYou
    property string paperTitle: ""
    property var authors: []
    property string problem: ""
    property bool looking: false
    property int request: -1
    property int revision: 0
    readonly property var followed: (revision, forYou.people().map(function(p) { return p.id }))
    // No record of the paper: look the person up by name instead (For You › Following).
    signal searchRequested()
    // paper: {title, doi, arxiv, openalex}
    function begin(paper) {
        paperTitle = paper.title || ""
        authors = []
        problem = ""
        looking = true
        request = forYou.findAuthors(paper)
        open()
    }
    Connections {
        target: root.forYou
        function onAuthorsFound(request, authors, problem) {
            if (request !== root.request) return
            root.looking = false
            root.authors = authors
            root.problem = problem
        }
        function onSettingsChanged() { root.revision++ }
    }
    // Each institution once, in the order its authors come.
    readonly property var institutions: {
        const seen = {}, list = []
        authors.forEach(function(a) {
            (a.institutions || []).forEach(function(i) { if (!seen[i.id]) { seen[i.id] = true; list.push(i) } })
        })
        return list
    }
    function roles(person) {
        const parts = []
        if (person.position === "last") parts.push(qsTr("Last author"))
        if (person.position === "first") parts.push(qsTr("First author"))
        if (person.corresponding) parts.push(qsTr("Corresponding"))
        if (person.detail) parts.push(person.detail)
        return parts.join(" · ")
    }
    component FollowRow: RowLayout {
        id: row
        required property var modelData
        property string detail: ""
        readonly property bool following: root.followed.indexOf(modelData.id) >= 0
        objectName: "followAuthor-" + modelData.id
        Layout.fillWidth: true
        spacing: 10
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1
            Label { Layout.fillWidth: true; text: row.modelData.name; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
            Label {
                visible: row.detail.length > 0
                Layout.fillWidth: true
                text: row.detail
                elide: Text.ElideRight; textFormat: Text.PlainText
                font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
            }
        }
        Button {
            objectName: "followAuthorButton-" + row.modelData.id
            text: row.following ? qsTr("Following") : qsTr("Follow")
            enabled: !row.following
            implicitHeight: Theme.controlHeightSmall
            onClicked: root.forYou.followPerson(row.modelData)
        }
    }
    contentItem: ColumnLayout {
        spacing: 10
        Label {
            visible: root.paperTitle.length > 0
            Layout.fillWidth: true
            text: root.paperTitle
            elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
        }
        Label {
            objectName: "followAuthorLooking"
            visible: root.looking
            text: qsTr("Finding the authors…")
            color: Theme.textTertiary
        }
        Label {
            objectName: "followAuthorProblem"
            visible: !root.looking && root.problem.length > 0
            Layout.fillWidth: true
            text: root.problem
            wrapMode: Text.Wrap; color: Theme.danger
        }
        Button {
            objectName: "followAuthorSearch"
            visible: !root.looking && root.authors.length === 0
            text: qsTr("Search by Name…")
            onClicked: { root.close(); root.searchRequested() }
        }
        ScrollView {
            visible: root.authors.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(440, list.implicitHeight)
            contentWidth: availableWidth
            ColumnLayout {
                id: list
                width: parent.width
                spacing: 8
                Repeater {
                    model: root.authors
                    delegate: FollowRow { detail: root.roles(modelData) }
                }
                Label {
                    visible: root.institutions.length > 0
                    Layout.topMargin: 6
                    text: qsTr("Institutions")
                    font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary
                }
                Repeater {
                    model: root.institutions
                    delegate: FollowRow { detail: modelData.detail || "" }
                }
            }
        }
    }
}
