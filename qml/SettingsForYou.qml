import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// For You: the topics and collections followed, and how often and how far back to look.
ColumnLayout {
    id: root
    objectName: "forYouSettings"
    spacing: 22
    readonly property var forYou: researchStore.forYou
    // Read again after a change here.
    property int revision: 0
    Connections { target: researchStore; function onSettingsChanged() { root.revision++ } }
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
            : qsTr("Papers found wait in Home and in Library › For You until you add or dismiss them. Only the words, categories and arXiv IDs or DOIs above are sent.")
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
