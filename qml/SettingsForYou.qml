import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// For You: how often and how far back to look, the AI, and the OpenAlex key. What is followed, and how many papers
// each brings, is chosen in Library › For You › Following.
ColumnLayout {
    id: root
    objectName: "forYouSettings"
    spacing: 22
    readonly property var forYou: researchStore.forYou
    // Read again after a change here.
    property int revision: 0
    Connections { target: researchStore; function onSettingsChanged() { root.revision++ } }
    // What is followed lives in the library (it syncs).
    Connections { target: root.forYou; function onSettingsChanged() { root.revision++ } }
    readonly property var people: (revision, forYou.people())
    readonly property bool openAlexKey: (revision, forYou.hasOpenAlexKey())
    readonly property int followed: (revision, researchStore.documentsRevision,
        forYou.topics().length + people.length + researchStore.collections().filter(function(c) { return root.forYou.following(c.id) }).length)
    // What is followed is chosen in For You itself (Library › For You › Following); here, how For You looks.
    SettingsGroup {
        objectName: "settingsGroup-following"
        title: qsTr("Following")
        SettingsRow {
            objectName: "settingsRow-following"
            label: root.followed === 1 ? qsTr("1 topic, researcher, institution or collection") : qsTr("%1 topics, researchers, institutions and collections").arg(root.followed)
            detail: qsTr("And how many papers each brings")
            Button {
                objectName: "forYouEditFollowing"
                text: qsTr("Edit in For You…")
                onClicked: root.forYou.manageFollowing()
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-forYouChecking"
        title: qsTr("Checking")
        note: root.forYou.problem.length ? root.forYou.problem
            : qsTr("Papers found wait in Home and in Library › For You until you add or dismiss them. Only the words, categories, arXiv IDs or DOIs of what you follow, and the OpenAlex IDs of the researchers and institutions you follow, are sent.")
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
            label: qsTr("Look back")
            detail: qsTr("How far back each check looks. The Today and This week chips in For You only narrow what was found.")
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
        SettingsRow {
            objectName: "settingsRow-openAlexKey"
            wide: !root.openAlexKey
            label: qsTr("OpenAlex key")
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
    }
}
