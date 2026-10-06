import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "Notes"
        when: windowShown
        function cleanupTestCase() { workspace.visible = false }
        function init() {
            workspace.width = 1440; workspace.height = 930
            workspace.documents.restore({})
            workspace.homeVisible = true
        }
        function visualChild(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        function activeTab() {
            const d = workspace.documents, g = Tree.find(d.tree, d.activeGroup)
            return g.tabs.find(function(t) { return t.id === g.activeTab })
        }
        function pane() {
            let found = null
            tryVerify(function() { found = visualChild(workspace.documents.groupView(workspace.documents.activeGroup), "notePane"); return found !== null && found.noteId.length > 0 }, 5000)
            return found
        }
        function test_newNoteAutosavesLinksAndTrash() {
            findChild(workspace, "newNoteAction").trigger()
            compare(activeTab().kind, "note")
            const note = pane()
            const id = note.noteId
            const title = visualChild(note, "noteTitle"), body = visualChild(note, "noteBody")
            title.text = "Reading plan"; title.textEdited()
            const paper = researchStore.documentLinkId(fixtureSource)
            body.text = "Compare with " + researchStore.markdownLink("document", paper)
            // Saved shortly after editing stops; the tab label follows the title.
            tryVerify(function() { return researchStore.note(id).body.indexOf("owelk://document/") >= 0 }, 3000)
            tryCompare(activeTab(), "title", "Reading plan")
            // Other test files may link the same fixture paper; this note must be among its backlinks.
            verify(researchStore.backlinks("document", paper).some(function(b) { return b.kind === "note" && b.id === id }))
            // The same note never opens twice.
            const tabCount = Tree.leaves(workspace.documents.tree)[0].tabs.length
            verify(workspace.documents.openNote(id, true))
            compare(Tree.leaves(workspace.documents.tree)[0].tabs.length, tabCount)
            // Links in a note open their source.
            verify(workspace.documents.openLink("owelk://document/" + paper))
            tryVerify(function() { return activeTab().kind === undefined && researchStore.sameSource(activeTab().source, fixtureSource) })
            // The Document panel lists notes linking to the paper.
            workspace.navigationMode = 2
            workspace.togglePanel("document")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "document")
            tryVerify(function() { const list = findChild(workspace, "backlinkList"); return list && list.count >= 1 }, 5000)
            workspace.togglePanel("document")
            // Trash closes its tab; restore and purge from the library.
            verify(workspace.documents.openNote(id))
            findChild(pane(), "deleteNoteOption").triggered()
            tryVerify(function() { return !Tree.leaves(workspace.documents.tree).some(function(g) { return g.tabs.some(function(t) { return t.noteId === id }) }) })
            compare(researchStore.notes(true).filter(function(n) { return n.id === id }).length, 1)
            workspace.documents.openLibrary({notesTrash: true})
            let library = null
            tryVerify(function() { library = visualChild(workspace.documents.groupView(workspace.documents.activeGroup), "libraryView"); return library && library.width > 0 })
            tryVerify(function() { return visualChild(library, "restoreNote-" + id) !== null })
            mouseClick(visualChild(library, "restoreNote-" + id))
            tryVerify(function() { return !researchStore.note(id).deleted })
            workspace.navigationMode = 0
        }
        function test_restoreDeletedWorkspaceFromHome() {
            const id = researchStore.createWorkspace("Restorable workspace")
            verify(researchStore.deleteWorkspace(id))
            const home = findChild(workspace, "homeView")
            tryVerify(function() { const b = visualChild(home, "deletedWorkspacesButton"); return b && b.visible })
            mouseClick(visualChild(home, "deletedWorkspacesButton"))
            const dialog = findChild(home, "deletedWorkspacesDialog")
            tryCompare(dialog, "opened", true)
            tryVerify(function() { return visualChild(dialog.contentItem, "restoreWorkspace-" + id) !== null })
            // The sheet centres itself as its rows lay out; click once the row stops moving.
            const restore = visualChild(dialog.contentItem, "restoreWorkspace-" + id)
            let last = null
            tryVerify(function() { const at = restore.mapToItem(null, 0, 0), still = last && at.y === last.y; last = at; return still })
            mouseClick(restore)
            tryVerify(function() { return researchStore.recentWorkspaces.some(function(w) { return w.id === id }) })
            dialog.close()
            researchStore.deleteWorkspace(id)
        }
        function test_linkPickerInsertsMarkdownLink() {
            const id = workspace.documents.newNote()
            const note = pane()
            const body = visualChild(note, "noteBody")
            note.preview = false
            body.forceActiveFocus()
            body.insert(0, "Related: [[")
            body.cursorPosition = body.text.length
            const picker = visualChild(note, "noteLinkPicker")
            note.insertLink("document", researchStore.documentLinkId(fixtureSource))
            verify(body.text.indexOf("[[") < 0)
            verify(body.text.indexOf("](owelk://document/") > 0)
            tryVerify(function() { return researchStore.note(id).body === body.text }, 3000)
            researchStore.deleteNote(id); researchStore.purgeNote(id)
        }
    }
}
