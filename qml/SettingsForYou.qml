import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// For You: the topics, researchers, institutions and collections followed, and how often and how far back to look.
ColumnLayout {
    id: root
    objectName: "forYouSettings"
    spacing: 22
    readonly property var forYou: researchStore.forYou
    // Read again after a change here.
    property int revision: 0
    Connections { target: researchStore; function onSettingsChanged() { root.revision++ } }
    // Topics and followed collections live in the library (they sync).
    Connections { target: root.forYou; function onSettingsChanged() { root.revision++ } }
    readonly property var topics: (revision, forYou.topics())
    readonly property var collections: (revision, researchStore.documentsRevision, researchStore.collections())
    function saveTopics(list) { forYou.saveTopics(list) }
    function setTopic(index, change) {
        const list = topics.map(function(t) { return Object.assign({}, t) })
        Object.assign(list[index], change)
        saveTopics(list)
    }
    function addTopic() {
        if (!topicWords.text.trim().length && !topicCategories.text.trim().length) return
        saveTopics(topics.concat([{words: topicWords.text, categories: topicCategories.text, on: true}]))
        topicWords.clear(); topicCategories.clear()
        topicWords.forceActiveFocus()
    }
    SettingsGroup {
        objectName: "settingsGroup-topics"
        title: qsTr("Topics")
        note: qsTr("New arXiv papers with any of the words (separate them with commas), in any of the categories, such as cs.RO or cs.CV. Either may be left empty.")
        Repeater {
            model: root.topics
            delegate: SettingsRow {
                id: topicRow
                required property var modelData
                required property int index
                objectName: "forYouTopic-" + index
                label: modelData.words || modelData.categories
                detail: modelData.words ? modelData.categories : ""
                opacity: modelData.on === false ? .55 : 1
                IconButton {
                    objectName: "forYouRemoveTopic-" + topicRow.index
                    icon.name: "trash"; description: qsTr("Remove")
                    onClicked: root.saveTopics(root.topics.filter(function(_, i) { return i !== topicRow.index }))
                }
                Switch {
                    objectName: "forYouTopicSwitch-" + topicRow.index
                    checked: topicRow.modelData.on !== false
                    onToggled: root.setTopic(topicRow.index, {on: checked})
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-addTopic"
            wide: true
            TextField {
                id: topicWords
                objectName: "forYouTopicWords"
                Layout.fillWidth: true
                placeholderText: qsTr("Words: lidar odometry, SLAM")
                onAccepted: root.addTopic()
            }
            TextField {
                id: topicCategories
                objectName: "forYouTopicCategories"
                Layout.preferredWidth: 130
                placeholderText: qsTr("cs.RO, cs.CV")
                onAccepted: root.addTopic()
            }
            Button {
                objectName: "forYouAddTopic"
                text: qsTr("Add")
                enabled: topicWords.text.trim().length > 0 || topicCategories.text.trim().length > 0
                onClicked: root.addTopic()
            }
        }
    }
    // Researchers and institutions, found by name on OpenAlex. Searching asks only when told to (Return or
    // Search): without a key every search spends the allowance everyone on this network shares.
    readonly property var people: (revision, forYou.people())
    readonly property bool openAlexKey: (revision, forYou.hasOpenAlexKey())
    property var peopleFound: []
    property string peopleAsked: ""
    property string peopleProblem: ""
    Connections {
        target: root.forYou
        function onPeopleFound(text, found, problem) { root.peopleAsked = text; root.peopleFound = found; root.peopleProblem = problem }
    }
    function findPeople() { if (peopleSearch.text.trim().length >= 2) forYou.findPeople(peopleSearch.text) }
    function kindName(kind) { return kind === "person" ? qsTr("Researcher") : qsTr("Institution") }
    SettingsGroup {
        objectName: "settingsGroup-people"
        title: qsTr("Researchers and institutions")
        note: root.peopleProblem.length ? root.peopleProblem
            : qsTr("Their new articles and preprints, from OpenAlex. They are always shown, first, whatever the AI makes of them.")
        noteColor: root.peopleProblem.length ? Theme.danger : Theme.textTertiary
        Repeater {
            model: root.people
            delegate: SettingsRow {
                id: personRow
                required property var modelData
                objectName: "forYouPerson-" + modelData.id
                label: modelData.name
                detail: root.kindName(modelData.kind) + (modelData.detail ? " · " + modelData.detail : "")
                opacity: modelData.on === false ? .55 : 1
                IconButton {
                    objectName: "forYouUnfollow-" + personRow.modelData.id
                    icon.name: "trash"; description: qsTr("Stop following")
                    onClicked: root.forYou.unfollowPerson(personRow.modelData.id)
                }
                Switch {
                    objectName: "forYouPersonSwitch-" + personRow.modelData.id
                    checked: personRow.modelData.on !== false
                    onToggled: root.forYou.setPersonOn(personRow.modelData.id, checked)
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-findPeople"
            wide: true
            TextField {
                id: peopleSearch
                objectName: "forYouPeopleSearch"
                Layout.fillWidth: true
                placeholderText: qsTr("A researcher's or an institution's name")
                onAccepted: root.findPeople()
            }
            Button {
                objectName: "forYouFindPeople"
                text: root.forYou.findingPeople ? qsTr("Searching…") : qsTr("Search")
                enabled: !root.forYou.findingPeople && peopleSearch.text.trim().length >= 2
                onClicked: root.findPeople()
            }
        }
        // What the search found: each with where they are and how many papers OpenAlex knows, to tell
        // people of the same name apart.
        Repeater {
            model: root.peopleFound
            delegate: SettingsRow {
                id: foundRow
                required property var modelData
                readonly property bool followed: root.people.some(function(p) { return p.id === modelData.id })
                objectName: "forYouFound-" + modelData.id
                label: modelData.name
                detail: [root.kindName(modelData.kind), modelData.detail, modelData.papers + qsTr(" papers")]
                        .filter(function(t) { return t && String(t).length }).join(" · ")
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
            visible: root.peopleAsked.length > 0 && !root.peopleFound.length && !root.peopleProblem.length
            label: qsTr("Nobody by that name on OpenAlex")
        }
        SettingsRow {
            objectName: "settingsRow-openAlexKey"
            wide: !root.openAlexKey
            label: qsTr("OpenAlex key")
            detail: root.openAlexKey ? qsTr("Kept in %1.").arg(researchStore.ai.keyStorage())
                : qsTr("Optional and free (openalex.org/settings/api). Without one, everyone on this network shares a small daily allowance.")
            TextField {
                id: openAlexKeyField
                objectName: "forYouOpenAlexKey"
                visible: !root.openAlexKey
                Layout.fillWidth: true
                echoMode: TextInput.Password
                placeholderText: qsTr("Paste a key")
                onAccepted: if (text.trim().length) { root.forYou.setOpenAlexKey(text); clear() }
            }
            Button {
                objectName: "forYouOpenAlexKeySave"
                text: root.openAlexKey ? qsTr("Remove") : qsTr("Save")
                enabled: root.openAlexKey || openAlexKeyField.text.trim().length > 0
                onClicked: {
                    root.forYou.setOpenAlexKey(root.openAlexKey ? "" : openAlexKeyField.text)
                    openAlexKeyField.clear()
                }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-followCollections"
        title: qsTr("Collections")
        note: root.collections.length ? qsTr("Papers like the ones in a followed collection, from Semantic Scholar. It looks at the papers that have an arXiv ID or a DOI (Paper Details).")
                                      : qsTr("Make collections in the Library to follow them here.")
        Repeater {
            model: root.collections
            delegate: SettingsRow {
                id: collectionRow
                required property var modelData
                readonly property int usable: (root.revision, root.forYou.usablePapers(modelData.id))
                readonly property bool followed: (root.revision, root.forYou.following(modelData.id))
                objectName: "forYouCollection-" + modelData.name
                label: "    ".repeat(modelData.depth || 0) + modelData.name
                detail: usable ? usable + (usable === 1 ? qsTr(" paper to compare with") : qsTr(" papers to compare with"))
                               : qsTr("Needs a paper with an arXiv ID or DOI")
                Switch {
                    objectName: "forYouFollow-" + collectionRow.modelData.name
                    checked: collectionRow.followed
                    enabled: collectionRow.usable > 0 || collectionRow.followed
                    onToggled: root.forYou.follow(collectionRow.modelData.id, checked)
                }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-forYouChecking"
        title: qsTr("Checking")
        note: root.forYou.problem.length ? root.forYou.problem
            : qsTr("Papers found wait in Home and in Library › For You until you add or dismiss them. Only the words, categories, arXiv IDs or DOIs and the OpenAlex IDs of the researchers and institutions above are sent.")
        noteColor: root.forYou.problem.length ? Theme.danger : Theme.textTertiary
        SettingsRow {
            objectName: "settingsRow-forYouDaily"
            label: qsTr("Check once a day")
            detail: qsTr("A little after Owelk opens")
            Switch {
                objectName: "forYouDaily"
                checked: (root.revision, researchStore.setting("forYou.auto", "1") === "1")
                onToggled: researchStore.setSetting("forYou.auto", checked ? "1" : "0")
            }
        }
        // The AI orders new papers by how well they fit and gives each a reason. Turning it on is the OK to
        // send their titles and abstracts, with what is followed, to the AI chosen in Settings › AI.
        SettingsRow {
            id: aiRow
            objectName: "settingsRow-forYouAi"
            readonly property var ai: researchStore.ai
            readonly property var provider: (root.revision, ai.providers.find(function(p) { return p.id === ai.provider })) || ({})
            readonly property bool usable: !!provider.configured || provider.id === "ollama"
            label: qsTr("Explain with AI")
            detail: !usable ? qsTr("Set up AI in Settings › AI first.")
                : qsTr("Orders new papers by how well they fit what you follow, with one sentence each. Sends their titles and abstracts and what you follow to ") + (provider.sends || provider.name) + "."
            Switch {
                objectName: "forYouAi"
                enabled: aiRow.usable
                checked: (root.revision, researchStore.setting("forYou.ai", "1") === "1" && !!aiRow.provider.consented && aiRow.usable)
                onToggled: {
                    if (checked) researchStore.ai.giveConsent(researchStore.ai.provider)
                    researchStore.setSetting("forYou.ai", checked ? "1" : "0")
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-forYouDays"
            label: qsTr("Papers from the last")
            ComboBox {
                objectName: "forYouDays"
                Layout.preferredWidth: 140
                readonly property var days: [1, 7, 30]
                model: [qsTr("Day"), qsTr("7 days"), qsTr("30 days")]
                currentIndex: Math.max(0, days.indexOf(Number((root.revision, researchStore.setting("forYou.days", "7")))))
                onActivated: function(index) { researchStore.setSetting("forYou.days", String(days[index])) }
            }
        }
        SettingsRow {
            objectName: "settingsRow-forYouKeep"
            label: qsTr("Keep papers in the list")
            detail: qsTr("Until you add or dismiss them, for at most")
            ComboBox {
                objectName: "forYouKeep"
                Layout.preferredWidth: 140
                readonly property var days: [7, 15, 30, 60, 0]
                model: [qsTr("7 days"), qsTr("15 days"), qsTr("30 days"), qsTr("60 days"), qsTr("Always")]
                currentIndex: Math.max(0, days.indexOf(Number((root.revision, researchStore.setting("forYou.keepDays", "30")))))
                onActivated: function(index) { researchStore.setSetting("forYou.keepDays", String(days[index])) }
            }
        }
        SettingsRow {
            objectName: "settingsRow-forYouCount"
            label: qsTr("At most, per topic or collection")
            ComboBox {
                objectName: "forYouCount"
                Layout.preferredWidth: 140
                readonly property var counts: [5, 10, 20]
                model: counts.map(function(n) { return n + qsTr(" papers") })
                currentIndex: Math.max(0, counts.indexOf(Number((root.revision, researchStore.setting("forYou.perSource", "10")))))
                onActivated: function(index) { researchStore.setSetting("forYou.perSource", String(counts[index])) }
            }
        }
        SettingsRow {
            objectName: "settingsRow-forYouCheck"
            label: root.forYou.checking ? qsTr("Looking for new papers…")
                 : root.forYou.lastChecked.getTime && !isNaN(root.forYou.lastChecked.getTime()) ? qsTr("Last checked ") + root.forYou.lastChecked.toLocaleString(Qt.locale(), Locale.ShortFormat)
                 : qsTr("Not checked yet")
            Button {
                objectName: "forYouCheckNow"
                text: qsTr("Check Now")
                enabled: root.forYou.configured && !root.forYou.checking
                onClicked: root.forYou.refresh()
            }
        }
    }
}
