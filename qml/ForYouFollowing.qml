import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// For You › Manage Following: everything For You follows, in one place. One field adds a topic (words, arXiv
// categories such as cs.RO), a researcher or an institution; each row says how many new papers it brought (a click
// shows them), how many it may bring per check, and can be turned off or removed.
Flickable {
    id: root
    objectName: "forYouFollowing"
    readonly property var forYou: researchStore.forYou
    signal sourceChosen(string key)
    // How For You checks (Settings › For You).
    signal settingsRequested()
    contentWidth: width
    contentHeight: column.implicitHeight + 24
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar {}
    // Read again after a change here or from another computer.
    property int revision: 0
    Connections { target: researchStore; function onSettingsChanged() { root.revision++ } }
    Connections {
        target: root.forYou
        function onSettingsChanged() { root.revision++ }
        function onPeopleFound(text, found, problem) { root.asked = text; root.found = found; root.problem = problem }
    }
    readonly property var topics: (revision, forYou.topics())
    readonly property var people: (revision, forYou.people())
    readonly property var researchers: people.filter(function(p) { return p.kind === "person" })
    readonly property var institutions: people.filter(function(p) { return p.kind === "institution" })
    readonly property var collections: (revision, researchStore.documentsRevision, researchStore.collections())
    readonly property var followedCollections: (revision, collections.filter(function(c) { return root.forYou.following(c.id) }))
    // New papers waiting, by where they came from.
    readonly property var waiting: {
        const counts = {}
        forYou.items.forEach(function(p) { counts[p.source] = (counts[p.source] || 0) + 1 })
        return counts
    }
    function newPapers(key) {
        const n = waiting[key] || 0
        return n ? (n === 1 ? qsTr("1 new paper") : qsTr("%1 new papers").arg(n)) : ""
    }

    // The field: a topic at once (no request), researchers and institutions on Return (OpenAlex).
    property string asked: ""
    property var found: []
    property string problem: ""
    readonly property string typed: field.text.trim()
    // arXiv categories (cs.RO, math.OC) go to categories, the rest are words.
    readonly property var typedTopic: {
        const words = [], categories = []
        typed.split(",").map(function(t) { return t.trim() }).filter(function(t) { return t.length }).forEach(function(t) {
            if (/^[a-z-]+\.[A-Za-z-]+$/.test(t)) categories.push(t); else words.push(t)
        })
        return {words: words.join(", "), categories: categories.join(", ")}
    }
    function search() {
        if (typed.length >= 2) forYou.findPeople(typed)
    }
    function followTopic() {
        if (!typed.length) return
        forYou.saveTopics(topics.concat([{words: typedTopic.words, categories: typedTopic.categories, on: true}]))
        clearSearch()
    }
    function clearSearch() { field.clear(); asked = ""; found = []; problem = "" }

    // How many papers one source brings at most in a check: its own number, or the usual one (Settings).
    readonly property var counts: [5, 10, 20, 50]
    component CountBox: ComboBox {
        required property string source
        objectName: "forYouCount-" + source
        Layout.preferredWidth: 96
        model: [qsTr("Usual")].concat(root.counts.map(function(n) { return String(n) }))
        currentIndex: Math.max(0, root.counts.indexOf((root.revision, root.forYou.perCheck(source))) + 1)
        ToolTip.visible: hovered; ToolTip.delay: 500
        ToolTip.text: qsTr("Papers at most in each check")
        onActivated: function(index) { root.forYou.setPerCheck(source, index > 0 ? root.counts[index - 1] : 0) }
    }
    // A followed source: a click shows its papers.
    component SourceRow: SettingsRow {
        id: sourceRow
        required property string sourceKey
        property bool active: true
        opacity: active ? 1 : .55
        TapHandler { onTapped: root.sourceChosen(sourceRow.sourceKey) }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 22
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                TextField {
                    id: field
                    objectName: "forYouFollowField"
                    Layout.fillWidth: true
                    placeholderText: qsTr("A topic (words, cs.RO), a researcher or an institution")
                    onAccepted: root.search()
                    onTextChanged: if (!text.trim().length) { root.asked = ""; root.found = []; root.problem = "" }
                }
                Button {
                    objectName: "forYouFollowSearch"
                    text: root.forYou.findingPeople ? qsTr("Searching…") : qsTr("Search")
                    enabled: !root.forYou.findingPeople && root.typed.length >= 2
                    onClicked: root.search()
                }
            }
            // What the field can follow: the words as a topic, then who OpenAlex knows by that name.
            ListGroup {
                visible: root.typed.length > 0
                Layout.fillWidth: true
                spacing: 0
                SettingsRow {
                    objectName: "forYouFollowTopic"
                    label: root.typedTopic.words.length ? root.typedTopic.words : root.typedTopic.categories
                    detail: qsTr("Topic") + (root.typedTopic.words.length && root.typedTopic.categories.length ? " · " + root.typedTopic.categories : "")
                    Button { objectName: "forYouFollowTopicButton"; text: qsTr("Follow"); onClicked: root.followTopic() }
                }
                Repeater {
                    model: root.asked === root.typed ? root.found : []
                    delegate: SettingsRow {
                        id: foundRow
                        required property var modelData
                        readonly property bool followed: root.people.some(function(p) { return p.id === modelData.id })
                        objectName: "forYouFound-" + modelData.id
                        label: modelData.name
                        detail: [modelData.kind === "person" ? qsTr("Researcher") : qsTr("Institution"), modelData.detail,
                                 modelData.papers + qsTr(" papers")].filter(function(t) { return t && String(t).length }).join(" · ")
                        Button {
                            objectName: "forYouFollowFound-" + foundRow.modelData.id
                            text: foundRow.followed ? qsTr("Following") : qsTr("Follow")
                            enabled: !foundRow.followed
                            onClicked: root.forYou.followPerson(foundRow.modelData)
                        }
                    }
                }
                SettingsRow {
                    objectName: "forYouNobodyFound"
                    visible: root.asked === root.typed && root.asked.length > 0 && !root.found.length && !root.problem.length
                    label: qsTr("Nobody by that name on OpenAlex")
                }
                SettingsRow {
                    objectName: "forYouSearchHint"
                    visible: root.asked !== root.typed && !root.forYou.findingPeople
                    label: qsTr("Return looks for researchers and institutions")
                }
            }
            Label {
                visible: root.problem.length > 0
                Layout.fillWidth: true
                leftPadding: 10
                text: root.problem
                wrapMode: Text.Wrap; font.pixelSize: Theme.fontCaption; color: Theme.danger
            }
        }
        SettingsGroup {
            objectName: "forYouFollowedTopics"
            visible: root.topics.length > 0
            title: qsTr("Topics")
            Repeater {
                model: root.topics
                delegate: SourceRow {
                    id: topicRow
                    required property var modelData
                    required property int index
                    sourceKey: "topic:" + modelData.id
                    active: modelData.on !== false
                    objectName: "forYouTopic-" + index
                    label: modelData.words || modelData.categories
                    detail: [modelData.words ? modelData.categories : "", root.newPapers(sourceKey)].filter(function(t) { return t.length }).join(" · ")
                    CountBox { source: topicRow.sourceKey }
                    Switch {
                        objectName: "forYouTopicSwitch-" + topicRow.index
                        checked: topicRow.active
                        onToggled: root.forYou.saveTopics(root.topics.map(function(t, i) { return i === topicRow.index ? Object.assign({}, t, {on: checked}) : t }))
                    }
                    IconButton {
                        objectName: "forYouRemoveTopic-" + topicRow.index
                        icon.name: "trash"; description: qsTr("Stop following")
                        onClicked: root.forYou.saveTopics(root.topics.filter(function(_, i) { return i !== topicRow.index }))
                    }
                }
            }
        }
        Repeater {
            model: [{kind: "person", title: qsTr("Researchers"), rows: root.researchers},
                    {kind: "institution", title: qsTr("Institutions"), rows: root.institutions}]
            delegate: SettingsGroup {
                id: peopleGroup
                required property var modelData
                objectName: "forYouFollowed-" + modelData.kind
                visible: modelData.rows.length > 0
                title: modelData.title
                Repeater {
                    model: peopleGroup.modelData.rows
                    delegate: SourceRow {
                        id: personRow
                        required property var modelData
                        sourceKey: modelData.kind + ":" + modelData.id
                        active: modelData.on !== false
                        objectName: "forYouPerson-" + modelData.id
                        label: modelData.name
                        detail: [modelData.detail, root.newPapers(sourceKey)].filter(function(t) { return t && t.length }).join(" · ")
                        CountBox { source: personRow.sourceKey }
                        Switch {
                            objectName: "forYouPersonSwitch-" + personRow.modelData.id
                            checked: personRow.active
                            onToggled: root.forYou.setPersonOn(personRow.modelData.id, checked)
                        }
                        IconButton {
                            objectName: "forYouUnfollow-" + personRow.modelData.id
                            icon.name: "trash"; description: qsTr("Stop following")
                            onClicked: root.forYou.unfollowPerson(personRow.modelData.id)
                        }
                    }
                }
            }
        }
        SettingsGroup {
            objectName: "forYouFollowedCollections"
            title: qsTr("Collections")
            Repeater {
                model: root.followedCollections
                delegate: SourceRow {
                    id: collectionRow
                    required property var modelData
                    sourceKey: "collection:" + modelData.id
                    objectName: "forYouCollection-" + modelData.name
                    label: modelData.name
                    detail: root.newPapers(sourceKey)
                    CountBox { source: collectionRow.sourceKey }
                    IconButton {
                        objectName: "forYouUnfollowCollection-" + collectionRow.modelData.name
                        icon.name: "trash"; description: qsTr("Stop following")
                        onClicked: root.forYou.follow(collectionRow.modelData.id, false)
                    }
                }
            }
            // Papers like a collection's (Semantic Scholar, by their arXiv IDs or DOIs).
            SettingsRow {
                id: collectionPick
                objectName: "forYouFollowCollectionRow"
                readonly property var choices: (root.revision, root.collections.filter(function(c) {
                    return !root.forYou.following(c.id) && root.forYou.usablePapers(c.id) > 0
                }))
                label: root.collections.length ? qsTr("Papers like a collection's") : qsTr("Make collections in the Library to follow them here")
                ComboBox {
                    id: collectionChoice
                    objectName: "forYouFollowCollection"
                    visible: collectionPick.choices.length > 0
                    Layout.preferredWidth: 200
                    model: collectionPick.choices.map(function(c) { return "    ".repeat(c.depth || 0) + c.name })
                }
                Button {
                    objectName: "forYouFollowCollectionButton"
                    visible: collectionPick.choices.length > 0
                    text: qsTr("Follow")
                    onClicked: root.forYou.follow(collectionPick.choices[collectionChoice.currentIndex].id, true)
                }
            }
        }
        SettingsGroup {
            SettingsRow {
                objectName: "forYouCheckingSettings"
                label: qsTr("Checking and AI")
                Button { objectName: "forYouCheckingSettingsButton"; text: qsTr("Settings…"); onClicked: root.settingsRequested() }
            }
        }
    }
}
