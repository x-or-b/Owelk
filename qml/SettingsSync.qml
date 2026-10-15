import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui

// Sync through a shared folder (LibrarySync.h), backups (a folder with the library database and
// images; restore is applied on next start) and exports.
ColumnLayout {
    id: root
    objectName: "syncSettings"
    spacing: 22
    property string result: ""
    property string syncProblem: ""
    readonly property var sync: researchStore.sync
    readonly property bool syncing: sync.folder.length > 0
    Connections { target: researchStore; function onBackupFinished(ok, path, message) { root.result = message } }
    SettingsGroup {
        objectName: "settingsGroup-sync"
        title: qsTr("Sync")
        note: root.syncProblem.length ? root.syncProblem
            : qsTr("Keeps this library the same on your other computers. Choose a folder inside Google Drive, Dropbox or Syncthing (for example My Drive) on each computer; Owelk works in an Owelk folder there and copies the Library's PDFs into it, so there is nothing to move by hand. On Ubuntu, reach Google Drive with rclone or Insync. Papers, annotations, notes, collections, reading state and AI threads travel; when one item changes on two computers, the later change wins.")
        noteColor: root.syncProblem.length ? Theme.danger : Theme.textTertiary
        SettingsRow {
            label: qsTr("Sync folder")
            detail: root.syncing ? root.sync.folder : qsTr("Off")
            Button { objectName: "syncOff"; visible: root.syncing; text: qsTr("Turn Off"); onClicked: root.sync.turnOff() }
            Button { objectName: "syncFolder"; text: qsTr("Choose Folder…"); onClicked: syncFolderDialog.open() }
        }
        SettingsRow {
            visible: root.syncing
            label: root.sync.status.length ? root.sync.status : qsTr("Waiting to sync")
            detail: root.sync.computers.length ? qsTr("With ") + root.sync.computers.join(", ") : qsTr("No other computer has synced yet")
            Button {
                objectName: "syncNow"
                text: root.sync.running ? qsTr("Syncing…") : qsTr("Sync Now")
                enabled: !root.sync.running
                onClicked: root.sync.syncNow()
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-backup"
        title: qsTr("Backup")
        note: root.result.length ? root.result
            : qsTr("A backup copies the library (papers' details, notes, annotations, AI threads) and its images into a folder. Your PDFs stay where they are and are not copied. Automatic backups go to the data folder's backups/auto.")
        SettingsRow {
            label: qsTr("Back up automatically")
            detail: qsTr("Once a day; keeps the last 7")
            Switch {
                objectName: "autoBackup"
                checked: researchStore.setting("backup.auto", "1") === "1"
                onToggled: researchStore.setSetting("backup.auto", checked ? "1" : "0")
            }
        }
        SettingsRow {
            label: qsTr("Back up now")
            Button {
                objectName: "backUpNow"
                text: researchStore.backingUp ? qsTr("Backing Up…") : qsTr("Choose Folder…")
                enabled: !researchStore.backingUp
                onClicked: backupFolderDialog.open()
            }
        }
        SettingsRow {
            label: qsTr("Restore from a backup")
            Button { objectName: "restoreBackup"; text: qsTr("Choose Backup…"); onClicked: restoreFolderDialog.open() }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-export"
        title: qsTr("Export")
        note: qsTr("Each note becomes a Markdown file. A paper's annotations are exported from the reader's ⋯ menu.")
        SettingsRow {
            label: qsTr("All notes as Markdown")
            Button { objectName: "exportNotes"; text: qsTr("Export…"); onClicked: notesFolderDialog.open() }
        }
    }
    Label { objectName: "backupResult"; visible: false; text: root.result }
    Native.FolderDialog {
        id: syncFolderDialog
        title: qsTr("Choose the shared folder to sync with")
        onAccepted: root.syncProblem = root.sync.setFolder(selectedFolder)
    }
    Native.FolderDialog {
        id: backupFolderDialog
        title: qsTr("Choose where to put the backup")
        onAccepted: { researchStore.setSetting("backup.folder", researchStore.localPath(selectedFolder)); researchStore.backUp(researchStore.localPath(selectedFolder)) }
    }
    Native.FolderDialog {
        id: notesFolderDialog
        title: qsTr("Export every note as Markdown to…")
        onAccepted: root.result = researchStore.exportNotesMarkdown(researchStore.localPath(selectedFolder)) + qsTr(" notes exported.")
    }
    Native.FolderDialog {
        id: restoreFolderDialog
        title: qsTr("Choose an Owelk backup folder")
        onAccepted: {
            const folder = researchStore.localPath(selectedFolder)
            const problem = researchStore.checkBackup(folder)
            if (problem.length) { root.result = problem; return }
            restoreConfirm.folder = folder
            restoreConfirm.open()
        }
    }
    Dialog {
        id: restoreConfirm
        objectName: "restoreConfirm"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 420
        modal: true
        property string folder: ""
        title: qsTr("Restore this backup?")
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            width: parent.width; wrapMode: Text.Wrap
            text: qsTr("Owelk replaces its library with the backup the next time it starts. The current library is moved to the data folder's backups, not deleted. Your PDFs are not touched.")
                  + (root.syncing ? " " + qsTr("Sync is on, so your other computers then bring this library up to date again: changes made since the backup come back. To get back something deleted, look in Library › Trash first.") : "")
        }
        onAccepted: if (researchStore.scheduleRestore(folder)) root.result = qsTr("Quit and reopen Owelk to finish restoring.")
    }
}
