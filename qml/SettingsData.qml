import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui

// Backups: a folder with the library database and images; restore is applied on next start.
ColumnLayout {
    id: root
    objectName: "dataSettings"
    spacing: 22
    property string result: ""
    Connections { target: researchStore; function onBackupFinished(ok, path, message) { root.result = message } }
    SettingsGroup {
        title: "Backup"
        note: root.result.length ? root.result
            : "A backup copies the library (papers' details, captures, notes, annotations, AI threads, workspaces) and its images into a folder. Your PDFs stay where they are and are not copied. Automatic backups go to the data folder's backups/auto."
        SettingsRow {
            label: "Back up automatically"
            detail: "Once a day; keeps the last 7"
            Switch {
                objectName: "autoBackup"
                checked: researchStore.setting("backup.auto", "1") === "1"
                onToggled: researchStore.setSetting("backup.auto", checked ? "1" : "0")
            }
        }
        SettingsRow {
            label: "Back up now"
            Button {
                objectName: "backUpNow"
                text: researchStore.backingUp ? "Backing Up…" : "Choose Folder…"
                enabled: !researchStore.backingUp
                onClicked: backupFolderDialog.open()
            }
        }
        SettingsRow {
            label: "Restore from a backup"
            Button { objectName: "restoreBackup"; text: "Choose Backup…"; onClicked: restoreFolderDialog.open() }
        }
    }
    SettingsGroup {
        title: "Export"
        note: "Each note becomes a Markdown file. A paper's highlights and captures are exported from the reader's ⋯ menu."
        SettingsRow {
            label: "All notes as Markdown"
            Button { objectName: "exportNotes"; text: "Export…"; onClicked: notesFolderDialog.open() }
        }
    }
    Label { objectName: "backupResult"; visible: false; text: root.result }
    Native.FolderDialog {
        id: backupFolderDialog
        title: "Choose where to put the backup"
        onAccepted: { researchStore.setSetting("backup.folder", researchStore.localPath(selectedFolder)); researchStore.backUp(researchStore.localPath(selectedFolder)) }
    }
    Native.FolderDialog {
        id: notesFolderDialog
        title: "Export every note as Markdown to…"
        onAccepted: root.result = researchStore.exportNotesMarkdown(researchStore.localPath(selectedFolder)) + " notes exported."
    }
    Native.FolderDialog {
        id: restoreFolderDialog
        title: "Choose an Owelk backup folder"
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
        title: "Restore this backup?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            width: parent.width; wrapMode: Text.Wrap
            text: "Owelk replaces its library with the backup the next time it starts. The current library is moved to the data folder's backups, not deleted. Your PDFs are not touched."
        }
        onAccepted: if (researchStore.scheduleRestore(folder)) root.result = "Quit and reopen Owelk to finish restoring."
    }
}
