import QtQuick
import QtTest
import Owelk.Ui
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "AiPanel"
        when: windowShown
        function cleanupTestCase() {
            researchStore.ai.clearApiKey("claude")
            // The data folder is shared with later test files: leave the panels as they were.
            workspace.aiVisible = false; workspace.persist()
            workspace.visible = false
        }
        function initTestCase() {
            researchStore.setSetting("ai.baseUrl.claude", testInput.webFixture("/").toString())
            researchStore.setSetting("ai.consent.claude", "")
            researchStore.ai.provider = "claude"
        }
        function canvas() {
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader, "pdfCanvas0")
            tryCompare(c, "ready", true); tryCompare(c, "restoring", false)
            return c
        }
        function visualChild(item, name) {
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        // The AI panel in the dock it is in now (one just closed elsewhere may not be gone yet).
        function panel() {
            const dock = function() { return findChild(workspace, workspace.aiSide === "left" ? "leftDock" : "rightDock") }
            tryVerify(function() { return findChild(dock(), "aiPanel") !== null })
            const p = findChild(dock(), "aiPanel")
            waitForPolish(p)
            return p
        }
        function test_1_askingAboutTheSelectionAttachesItAndKeepsAThread() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.selectPage(0)
            verify(c.selectedText.length > 0)
            const ai = findChild(workspace, "aiController")
            compare(workspace.aiVisible, false)
            // Ask AI about Selection: the selection joins a new conversation about this paper; nothing is sent.
            findChild(workspace.currentReader, "menuAskSelection").triggered()
            tryCompare(workspace, "aiVisible", true)
            // On first start the AI docks on the left with Threads; Library and Document on the right.
            compare(workspace.aiSide, "left")
            compare(workspace.threadsSide, "left")
            compare(workspace.filesSide, "right")
            compare(workspace.documentSide, "right")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "ai")
            // Status bar icons: Threads, AI chat, Library, Document from the left; the right side mirrored.
            workspace.filesSide = "left"
            compare(workspace.panelIcons("left"), ["threads", "ai", "files"])
            compare(workspace.panelIcons("right"), ["document"])
            workspace.aiSide = "right"; workspace.filesSide = "right"
            compare(workspace.panelIcons("right"), ["document", "files", "ai"])
            // The tests below were written with the Library on the left and the AI on the right.
            workspace.filesSide = "left"
            tryCompare(findChild(workspace, "rightDock"), "activePanel", "ai")
            const p = panel()
            compare(ai.threadId, "")
            verify(!ai.streaming)
            verify(ai.attachments.some(function(a) { return a.kind === "selection" }))
            verify(ai.attachments.some(function(a) { return a.kind === "paper" }))
            // Without a key the panel explains what is missing and sends nothing.
            const question = findChild(p, "aiQuestion")
            tryVerify(function() { return question.activeFocus || question.focus })
            question.text = "What does this say?"
            mouseClick(findChild(p, "aiSend"))
            tryVerify(function() { return ai.error.indexOf("API key") >= 0 })
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            // The first request to a provider shows what will be sent.
            mouseClick(findChild(p, "aiSend"))
            const consent = findChild(workspace, "aiConsentDialog")
            tryCompare(consent, "opened", true)
            consent.accept()
            tryCompare(ai, "streaming", false, 10000)
            verify(researchStore.ai.consented("claude"))
            // The turn is a thread: question and answer, searchable and linked to the paper.
            verify(ai.threadId.length > 0)
            compare(ai.messages.length, 2)
            compare(ai.messages[1].content, "Mock answer about **occlusion**.")
            compare(ai.messages[0].display, "What does this say?")
            verify(ai.messages[0].context.attachments.indexOf("selection") >= 0)
            const hits = researchStore.searchKnowledge("Mock answer")
            verify(hits.some(function(h) { return h.kind === "ai" && h.id === ai.threadId }))
            const paper = researchStore.documentLinkId(fixtureSource)
            verify(researchStore.backlinks("document", paper).some(function(b) { return b.kind === "ai" }))
            // A follow-up continues the same thread.
            const thread = ai.threadId
            question.text = "Why does it matter?"
            testInput.keyClick(question, Qt.Key_Return)
            compare(question.text, "")
            tryVerify(function() { return ai.messages.length === 4 }, 10000)
            compare(ai.threadId, thread)
            compare(ai.messages[2].display, "Why does it matter?")
            // Saving an answer as a note quotes the question and links back to the thread and the paper.
            const before = researchStore.backlinks("document", paper).filter(function(b) { return b.kind === "note" }).length
            if (before === 0) mouseClick(findChild(p, "aiSaveNote-3"))
            else { ai.saveAsNote(3) }
            let saved = null
            tryVerify(function() { saved = researchStore.backlinks("document", paper).filter(function(b) { return b.kind === "note" }); return saved.length === before + 1 })
            const note = saved[0].id
            verify(researchStore.note(note).body.indexOf("> Why does it matter?\n\nMock answer") === 0, researchStore.note(note).body)
            verify(researchStore.searchKnowledge("Mock answer").some(function(h) { return h.kind === "note" }))
            // With a note about the paper, the button offers adding to it.
            const saveButton = findChild(p, "aiSaveNote-3")
            mouseClick(saveButton)
            const menu = findChild(saveButton, "aiSaveNoteMenu")
            tryCompare(menu, "opened", true)
            verify(menu.count >= 3)
            menu.itemAt(2).triggered()
            menu.close()
            tryVerify(function() { return researchStore.note(note).body.split("Mock answer").length === 3 })
        }
        function threadsList() {
            tryVerify(function() { return findChild(workspace, "threadsPanel") !== null })
            const list = findChild(findChild(workspace, "threadsPanel"), "threadsList")
            waitForPolish(list)
            return list
        }
        function rowIndex(list, test) {
            for (let i = 0; i < list.model.length; ++i) if (test(list.model[i])) return i
            return -1
        }
        function test_2_threadsPanelReopensWithoutANewRequest() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const thread = ai.threadId
            researchStore.setSetting("threads.sort", "recent")
            // The AI panel's button opens Threads, a panel of its own: the AI panel stays open.
            mouseClick(findChild(p, "aiThreadsButton"))
            tryCompare(workspace, "threadsVisible", true)
            compare(workspace.threadsSide, "left")
            compare(workspace.aiVisible, true)
            const list = threadsList()
            // The chat about the paper is in the paper's Thread, unfolded because it is open.
            let at = -1
            tryVerify(function() { at = rowIndex(list, function(r) { return r.type === "chat" && r.chat.id === thread }); return at > 0 && list.itemAtIndex(at) !== null })
            const paperThread = list.model[at].folder
            compare(paperThread, "document:" + researchStore.documentLinkId(fixtureSource))
            compare(list.model[rowIndex(list, function(r) { return r.type === "group" && r.id === paperThread })].name, researchStore.displayName(fixtureSource))
            ai.showThreads()
            mouseClick(list.itemAtIndex(at))
            tryCompare(ai, "threadId", thread)
            compare(ai.messages.length, 4)
            compare(ai.streaming, false)
            verify(list.itemAtIndex(at).current) // The open chat is marked.
            // Search results and owelk://ai links open the thread in the panel too.
            ai.showThreads()
            workspace.openSearchResult({kind: "ai", id: thread})
            tryCompare(ai, "threadId", thread)
            verify(workspace.documents.openLink("owelk://ai/" + thread))
            compare(ai.conversationOpen, true)
            // The reader's turns are accent bubbles with room on the left; answers can be selected.
            const conv = findChild(p, "aiConversation")
            tryVerify(function() { return findChild(conv, "aiQuestion-2") !== null && findChild(conv, "aiMessage-3") !== null })
            waitForPolish(conv)
            const bubble = findChild(conv, "aiQuestion-2")
            verify(Qt.colorEqual(bubble.color, Theme.accent))
            verify(bubble.x > 0)
            fuzzyCompare(bubble.x + bubble.width, conv.width, 1)
            const answer = findChild(conv, "aiMessage-3")
            answer.selectAll()
            verify(answer.selectedText.indexOf("Mock answer") >= 0)
            answer.deselect()
            // Right-click: Copy and Ask About This need a selection; Select All provides one.
            mouseClick(answer, 20, 8, Qt.RightButton)
            const menu = findChild(p, "aiTextMenu")
            tryCompare(menu, "opened", true)
            verify(!findChild(menu, "aiTextCopy").enabled)
            verify(!findChild(menu, "aiTextAsk").enabled)
            findChild(menu, "aiTextSelectAll").triggered()
            menu.close(); tryCompare(menu, "opened", false)
            verify(answer.selectedText.indexOf("Mock answer") >= 0)
            mouseClick(answer, 20, 8, Qt.RightButton)
            tryCompare(menu, "opened", true)
            verify(findChild(menu, "aiTextCopy").enabled)
            findChild(menu, "aiTextAsk").triggered()
            menu.close(); tryCompare(menu, "opened", false)
            // The passage joins the next question as a chip, not as text in the box.
            verify(ai.spec.quote.indexOf("Mock answer about occlusion") === 0)
            verify(ai.attachments.some(function(a) { return a.kind === "quote" }))
            compare(findChild(p, "aiQuestion").text, "")
            ai.detach("quote")
            verify(!ai.attachments.some(function(a) { return a.kind === "quote" }))
            answer.deselect()
            // The paper chip can be removed too: the question then goes out on its own.
            if (ai.attachments.some(function(a) { return a.kind === "paper" })) {
                ai.detach("paper")
                verify(!ai.attachments.some(function(a) { return a.kind === "paper" }))
            }
            // Three lines or more: the corner button makes the question box taller, and back.
            const box = findChild(p, "aiQuestion"), size = findChild(p, "aiComposerSize")
            compare(size.visible, false)
            box.text = "one\ntwo\nthree\nfour"
            tryCompare(size, "visible", true)
            const composerBox = findChild(p, "aiComposer"), before = composerBox.limit
            mouseClick(size)
            verify(composerBox.limit > before)
            // Expanded, the box keeps its height even for short text.
            box.text = "one\ntwo\nthree"
            tryCompare(composerBox, "height", composerBox.limit)
            box.text = ""
            tryCompare(size, "visible", false)
            compare(composerBox.expanded, false)
            // A figure from its preview joins this conversation as an image.
            const current = ai.threadId
            verify(ai.attachFigure({source: fixtureSource, page: 0, region: Qt.rect(.05, .5, .9, .25), label: "Figure 1"}))
            compare(ai.threadId, current)
            compare(ai.images[ai.images.length - 1].name, "Figure 1 · p. 1")
            ai.images = []
            // The reasoning summary is folded above the answer and unfolds on a click; off, it is hidden.
            const thought = findChild(conv, "aiThought-3")
            const toggle = findChild(thought, "aiThoughtToggle")
            verify(toggle.visible)
            verify(/^Thought for \d+s/.test(toggle.text))
            compare(thought.expanded, false)
            mouseClick(toggle)
            tryCompare(thought, "expanded", true)
            tryVerify(function() { return findChild(thought, "aiThoughtText").text.indexOf("Reading the selection") >= 0 })
            verify(answer.text.indexOf("Reading the selection") < 0)
            compare(ai.messages[3].content, "Mock answer about **occlusion**.")
            compare(ai.thinkingHeadline("Intro.\n\n**Checking the table**\nMore text here."), "Checking the table")
            researchStore.setSetting("ai.showThinking", "0")
            tryCompare(thought, "visible", false)
            researchStore.setSetting("ai.showThinking", "1")
            tryCompare(thought, "visible", true)
            // Back to the question stops following; the latest button (or toEnd) resumes it.
            mouseClick(findChild(conv, "aiToQuestion-3"))
            compare(conv.following, false)
            conv.toEnd()
            compare(conv.following, true)
        }
        function pickModel(p, name) {
            const button = findChild(p, "aiModelButton")
            mouseClick(button)
            const menu = findChild(p, "aiModelMenu")
            tryCompare(menu, "opened", true)
            tryVerify(function() { return findChild(menu.contentItem, name) !== null }, 5000)
            const row = findChild(menu.contentItem, name)
            waitForPolish(menu.contentItem); wait(30)
            mouseClick(row)
            tryCompare(menu, "visible", false)
        }
        function test_2a_threadsAreFoldersOfChats() {
            const ai = findChild(workspace, "aiController")
            const thread = ai.threadId
            workspace.threadsVisible = true
            const list = threadsList(), threads = findChild(workspace, "threadsPanel")
            const groupAt = function(id) { return rowIndex(list, function(r) { return r.type === "group" && r.id === id }) }
            const chatAt = function(id) { return rowIndex(list, function(r) { return r.type === "chat" && r.chat.id === id }) }
            const paperThread = researchStore.aiThread(thread).folder
            // + names a new Thread and starts a chat in it; the first answer keeps the chat there.
            mouseClick(findChild(threads, "threadsNewThread"))
            const dialog = findChild(threads, "threadsNameDialog")
            tryCompare(dialog, "opened", true)
            const name = "Thesis " + Date.now()
            findChild(threads, "threadsNameField").text = name
            dialog.accept()
            let folder = ""
            tryVerify(function() { const g = list.model.find(function(r) { return r.type === "group" && r.name === name }); folder = g ? g.id : ""; return folder.length > 0 })
            compare(ai.threadId, "")
            compare(ai.spec.folder, folder)
            verify(ai.attachments.some(function(a) { return a.kind === "paper" }))
            verify(ai.send("Where does this belong?"))
            tryVerify(function() { return !ai.streaming && ai.threadId.length > 0 }, 10000)
            const asked = ai.threadId
            compare(researchStore.aiThread(asked).folder, folder)
            tryVerify(function() { return chatAt(asked) > groupAt(folder) && groupAt(folder) >= 0 })
            // A chat dragged onto another Thread moves there.
            const from = chatAt(thread)
            tryVerify(function() { return list.itemAtIndex(chatAt(thread)) !== null && list.itemAtIndex(groupAt(folder)) !== null })
            waitForPolish(list)
            const source = list.itemAtIndex(chatAt(thread)), target = list.itemAtIndex(groupAt(folder))
            testInput.pointerDrag(threads, source.mapToItem(threads, 40, source.height / 2), target.mapToItem(threads, 40, target.height / 2), false)
            tryVerify(function() { return researchStore.aiThread(thread).folder === folder })
            // Its menu moves it back; Shift-click chooses both chats in the Thread, and both move at once.
            threads.moveChats([thread], paperThread)
            compare(researchStore.aiThread(thread).folder, paperThread)
            threads.moveChats([thread], folder)
            tryVerify(function() { return chatAt(thread) > groupAt(folder) && chatAt(asked) > groupAt(folder) })
            threads.selectedChats = []
            threads.selectionAnchor = chatAt(asked)
            threads.selectRange(chatAt(thread))
            compare(threads.selectedChats.length, 2)
            // Renamed; then deleted: its chats stay, unfiled.
            verify(researchStore.renameAiFolder(folder, name + " renamed"))
            tryVerify(function() { return groupAt(folder) >= 0 && list.model[groupAt(folder)].name === name + " renamed" })
            tryVerify(function() { return list.itemAtIndex(groupAt(folder)) !== null })
            mouseClick(list.itemAtIndex(groupAt(folder)), 40, 10, Qt.RightButton)
            const groupMenu = findChild(threads, "threadsGroupMenu")
            tryCompare(groupMenu, "opened", true)
            findChild(groupMenu, "threadsGroupDelete").triggered()
            groupMenu.close()
            tryVerify(function() { return groupAt(folder) < 0 })
            compare(researchStore.aiThread(thread).folder, "")
            compare(researchStore.aiThread(asked).folder, "")
            verify(groupAt("") >= 0) // Unfiled
            // Sorted by name or by the latest; the search keeps chats whose words match.
            threads.setSort("name")
            const names = list.model.filter(function(r) { return r.type === "group" && r.id.length }).map(function(r) { return r.name })
            compare(names, names.slice().sort(function(a, b) { return a.localeCompare(b) }))
            threads.setSort("recent")
            const search = findChild(threads, "threadsSearch")
            search.text = "Where does this belong"
            tryVerify(function() { const chats = list.model.filter(function(r) { return r.type === "chat" }); return chats.length === 1 && chats[0].chat.id === asked })
            search.text = ""
            threads.moveChats([thread], paperThread)
            // Threads moves by right-click like the other panels and stays on the outer side.
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-threads")
            mouseClick(icon, 15, 14, Qt.RightButton)
            const menu = findChild(icon, "dockMenu-threads")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "rightDockOption"))
            tryCompare(workspace, "threadsSide", "right")
            tryCompare(findChild(workspace, "rightThreads"), "active", true)
            compare(workspace.aiSide, "right")
            waitForPolish(workspace)
            verify(findChild(workspace, "rightThreads").x > findChild(workspace, "rightDock").x)
            compare(workspace.panelIcons("right")[workspace.panelIcons("right").length - 1], "threads")
            workspace.movePanel("ai", "left")
            workspace.movePanel("threads", "left")
            tryCompare(findChild(workspace, "leftThreads"), "active", true)
            waitForPolish(workspace)
            verify(findChild(workspace, "leftThreads").x < findChild(workspace, "leftDock").x)
            compare(workspace.panelIcons("left")[0], "threads")
            workspace.persist()
            compare(researchStore.session.panels.threadsSide, "left")
            compare(researchStore.session.panels.threadsVisible, true)
            // Back as it was for the tests after this one.
            workspace.movePanel("ai", "right")
            workspace.threadsVisible = false
            researchStore.purgeAiThreads([asked]) // Gone for good: the Trash is counted by later test files.
            ai.openThread(thread)
        }
        function test_2b_papersAndCollectionsAttachFromTheChat() {
            const ai = findChild(workspace, "aiController")
            const original = ai.threadId
            workspace.documents.restore({})
            workspace.openDocument(outlineSource)
            workspace.openDocument(fixtureSource)
            canvas()
            verify(researchStore.rememberDocument(longSource))
            workspace.showAi()
            const p = panel()
            ai.newThread()
            verify(researchStore.sameSource(ai.spec.source, fixtureSource))
            // Papers…: the open tabs first (not the chat's own paper), then the Library; several at once.
            findChild(p, "aiAttachPapers").triggered()
            const picker = findChild(p, "aiPicker")
            tryCompare(picker, "opened", true)
            tryVerify(function() { return picker.rows.length >= 4 })
            compare(picker.rows[0].type, "section")
            compare(picker.rows[1].url, outlineSource.toString())
            verify(!picker.rows.some(function(r) { return r.url === fixtureSource.toString() }))
            const long = picker.rows.find(function(r) { return r.url === longSource.toString() })
            verify(long !== undefined)
            picker.choose(picker.rows[1]); picker.choose(long)
            mouseClick(findChild(p, "aiPickerAttach"))
            tryCompare(picker, "opened", false)
            compare(ai.spec.papers, [outlineSource.toString(), longSource.toString()])
            compare(ai.attachments.filter(function(a) { return a.kind === "extra" }).length, 2)
            verify(!ai.attachments.some(function(a) { return a.kind === "passages" }))
            // Sent with the question (read whole, three papers), shown as chips above it; then in the chat.
            verify(ai.send("Compare the three"))
            tryVerify(function() { return !ai.streaming && ai.messages.length === 2 }, 10000)
            const sent = ai.messages[0]
            verify(sent.context.attachments.indexOf("papers") >= 0)
            compare(sent.context.papers.length, 2)
            verify(sent.content.indexOf("=== P2: ") >= 0)
            compare(ai.spec.papers, undefined)
            // A collection, or the whole library: passages for each question; × goes back to the paper.
            const name = "Attach test " + Date.now()
            const collection = researchStore.createCollection(name)
            findChild(p, "aiAttachCollection").triggered()
            tryCompare(picker, "opened", true)
            const row = picker.rows.find(function(r) { return r.id === collection })
            verify(row !== undefined)
            picker.choose(row)
            compare(ai.spec.scope, "library")
            compare(ai.spec.collection, collection)
            verify(ai.attachments.some(function(a) { return a.kind === "library" && a.label.indexOf(name) >= 0 }))
            ai.detach("library")
            compare(ai.spec.scope, "none")
            compare(ai.spec.collection, undefined)
            findChild(p, "aiAttachLibrary").triggered()
            compare(ai.spec.scope, "library"); compare(ai.spec.collection, "")
            ai.detach("library")
            // More than three papers are searched; a reopened chat goes on asking what it searched.
            ai.attachPapers([outlineSource, longSource, linkSource])
            verify(!ai.attachments.some(function(a) { return a.kind === "passages" })) // Three, after the chat's own.
            ai.newThread()
            ai.attachPapers([outlineSource, longSource, linkSource, fixtureSource])
            compare(ai.spec.papers.length, 3)
            verify(ai.attachments.some(function(a) { return a.kind === "passages" }))
            const filed = ai.continuing({source: fixtureSource, messages: [{role: "user", context: {attachments: ["library"], collection: collection, collectionName: name, searchUrls: [longSource.toString()]}}]})
            compare(filed.scope, "library"); compare(filed.collection, collection); compare(filed.papers, [longSource.toString()])
            const several = ai.continuing({source: fixtureSource, messages: [{role: "user", context: {attachments: ["library"], searchUrls: [longSource.toString(), fixtureSource.toString()]}}]})
            compare(several.scope, "none"); verify(several.searchPapers); compare(several.papers, [longSource.toString()])
            compare(ai.continuing({source: fixtureSource, messages: []}).scope, "none")
            // A drop that attached something lights up the attachments row.
            p.attached(true)
            tryVerify(function() { return findChild(p, "aiAttachedFlash").opacity > 0 })
            researchStore.deleteCollection(collection)
            ai.openThread(original) // The next tests go on with the first conversation.
        }
        function test_3_modelPickerOffersEffortAndFastWhereTheModelHasThem() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const effort = findChild(p, "aiEffortButton"), fast = findChild(p, "aiFastButton")
            // Grouped by company, with a filter.
            mouseClick(findChild(p, "aiModelButton"))
            const menu = findChild(p, "aiModelMenu")
            tryCompare(menu, "opened", true)
            tryVerify(function() { return findChild(menu.contentItem, "aiModel-claude-claude-opus-5-5") !== null }, 5000)
            findChild(menu.contentItem, "aiModelFilter").text = "sonnet"
            tryVerify(function() { return findChild(menu.contentItem, "aiModel-claude-claude-opus-5-5") === null })
            verify(findChild(menu.contentItem, "aiModel-claude-claude-sonnet-5-5") !== null)
            menu.close(); tryCompare(menu, "opened", false)
            pickModel(p, "aiModel-claude-claude-opus-5-5")
            tryVerify(function() { return researchStore.ai.model("claude") === "claude-opus-5-5" })
            tryCompare(findChild(p, "aiModelButton"), "text", "Claude Opus 5.5")
            // In a narrow panel the model list stays inside the window.
            workspace.rightDockWidth = 170
            tryVerify(function() { return p.width < 200 })
            mouseClick(findChild(p, "aiModelButton"))
            const list = findChild(p, "aiModelMenu")
            tryCompare(list, "opened", true)
            verify(list.contentItem.mapToItem(null, list.contentItem.width, 0).x <= workspace.width, "the model list fits the window")
            list.close(); tryCompare(list, "visible", false)
            workspace.rightDockWidth = 224
            // Opus: effort levels and fast mode.
            tryCompare(effort, "visible", true)
            compare(effort.text, "Medium")
            compare(fast.visible, true)
            mouseClick(effort)
            const levels = findChild(p, "aiEffortMenu")
            tryCompare(levels, "opened", true)
            tryVerify(function() { return findChild(levels, "aiEffort-xhigh") !== null })
            findChild(levels, "aiEffort-xhigh").triggered()
            levels.close(); tryCompare(levels, "visible", false)
            compare(ai.effectiveEffort, "xhigh")
            compare(effort.text, "Extra high")
            compare(researchStore.setting("ai.effort.claude"), "xhigh")
            mouseClick(fast)
            compare(ai.effectiveFast, true)
            // Sonnet: effort but no fast mode; Haiku: neither.
            pickModel(p, "aiModel-claude-claude-sonnet-5-5")
            tryCompare(fast, "visible", false)
            compare(ai.effectiveFast, false)
            compare(effort.visible, true)
            pickModel(p, "aiModel-claude-claude-haiku-5-5")
            tryCompare(effort, "visible", false)
            pickModel(p, "aiModel-claude-claude-opus-5-5")
            tryCompare(fast, "visible", true)
            compare(ai.effectiveFast, true) // Remembered for the provider.
            mouseClick(fast)
            ai.setEffort("medium")
        }
        function test_4_rightClickMovesThePanelBetweenDocks() {
            const icon = visualChild(findChild(workspace, "statusBar"), "dockIcon-ai")
            verify(icon)
            compare(icon.dockSide, "right")
            mouseClick(icon, icon.width / 2, icon.height / 2, Qt.RightButton)
            const menu = findChild(icon, "dockMenu-ai")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "leftDockOption"))
            tryCompare(workspace, "aiSide", "left")
            workspace.persist()
            compare(researchStore.session.panels.aiSide, "left")
            tryCompare(findChild(workspace, "leftDock"), "activePanel", "ai")
            verify(workspace.leftPanels.indexOf("ai") >= 0)
            verify(workspace.rightPanels.indexOf("ai") < 0)
            // The conversation survives the move.
            compare(findChild(workspace, "aiController").messages.length, 4)
            workspace.movePanel("ai", "right")
            tryCompare(workspace, "aiSide", "right")
        }
        function test_5_newThreadAttachesThePageOnRequest() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            mouseClick(findChild(p, "aiNewThread"))
            compare(ai.threadId, "")
            compare(ai.conversationOpen, true)
            verify(ai.attachments.some(function(a) { return a.kind === "paper" }))
            // The paper chip is the whole paper: a new thread sends its text; removed, This Paper brings it back once.
            compare(ai.spec.scope, "paper")
            ai.detach("paper")
            verify(!ai.attachments.some(function(a) { return a.kind === "paper" }))
            ai.attachPaper()
            ai.attachPaper()
            compare(ai.attachments.filter(function(a) { return a.kind === "paper" }).length, 1)
            compare(ai.spec.scope, "paper")
            verify(ai.send("What is the main claim?"))
            tryCompare(ai, "streaming", false, 10000)
            compare(ai.messages.length, 2)
            compare(ai.thread.title, "What is the main claim?")
        }
        // Visible items whose right edge passes the panel (in panel coordinates).
        function overflowing(item, panel, list) {
            if (!item.visible || item.opacity === 0) return list
            if (item !== panel && item.width > 0) {
                const right = item.mapToItem(panel, item.width, 0).x
                if (right > panel.width + 1) list.push((item.objectName || item.toString()) + " right=" + Math.round(right))
            }
            if (item.clip && item !== panel) return list
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) overflowing(children[i], panel, list)
            return list
        }
        function test_6_narrowPanelWrapsEverything() {
            const ai = findChild(workspace, "aiController")
            const long = "긴 답변입니다. " + "https://example.com/" + "a".repeat(160) + " and `" + "b".repeat(120) + "`\n\n"
                + "| col | col |\n| --- | --- |\n| " + "c".repeat(80) + " | d |\n\n```\n" + "e".repeat(150) + "\n```"
            ai.thread = {id: ai.threadId, title: "Narrow", messages: [{role: "user", display: "q".repeat(200), content: "q"}, {role: "assistant", content: long}]}
            workspace.rightDockWidth = 160
            const p = panel()
            tryVerify(function() { return Math.abs(p.width - findChild(workspace, "rightDock").width) < 4 })
            waitForPolish(p)
            wait(50)
            const bad = overflowing(p, p, [])
            compare(bad.join(", "), "")
            const conversation = findChild(p, "aiConversation")
            verify(conversation.contentWidth <= conversation.width + 1)
            // The model, effort and send controls stay reachable at this width.
            for (const name of ["aiAttachButton", "aiModelButton", "aiEffortButton", "aiSend"]) {
                const control = findChild(p, name)
                verify(control && control.visible && control.width > 20, name)
            }
            // Fast mode, when the model has it, is never pushed out of the panel.
            const fast = findChild(p, "aiFastButton")
            if (fast.visible) verify(fast.mapToItem(p, fast.width, 0).x <= p.width + 1, "Fast is inside the panel")
            // A provider without a key is offered for set-up instead of its models.
            verify(researchStore.ai.clearApiKey("claude"))
            mouseClick(findChild(p, "aiModelButton"))
            const menu = findChild(p, "aiModelMenu")
            tryCompare(menu, "opened", true)
            const setup = findChild(menu.contentItem, "aiModelSetup")
            tryCompare(setup, "visible", true)
            verify(findChild(menu.contentItem, "aiModel-claude-claude-opus-5-5") === null || !findChild(menu.contentItem, "aiModel-claude-claude-opus-5-5").visible)
            const opened = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "opened" }', p)
            opened.target = findChild(workspace, "settingsDialog")
            setup.clicked()
            tryCompare(opened, "count", 1)
            findChild(workspace, "settingsDialog").close()
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            workspace.rightDockWidth = 224
        }
        function test_8_imagesAttachToTheNextQuestion() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            mouseClick(findChild(p, "aiNewThread"))
            // A picture made here stands in for a screenshot on disk.
            const folder = testInput.temporaryFolder("ai-images")
            let saved = false
            p.grabToImage(function(result) { saved = result.saveToFile(folder + "/figure.png") })
            tryVerify(function() { return saved })
            const url = researchStore.fileUrl(folder + "/figure.png").toString()
            verify(ai.attachImage(url))
            verify(!ai.attachImage(url)) // Once only.
            verify(!ai.attachImage("file:///tmp/notes.txt"))
            const chip = findChild(p, "aiChip-image-0")
            tryVerify(function() { return chip !== null && chip.visible })
            verify(ai.attachments.some(function(a) { return a.kind === "image" && a.label === "figure.png" }))
            verify(ai.send("Describe the figure"))
            compare(ai.images.length, 0) // Sent with this question only.
            tryCompare(ai, "streaming", false, 10000)
            compare(ai.error, "")
            const asked = ai.messages[ai.messages.length - 2]
            verify(asked.context.attachments.indexOf("image") >= 0)
            // The question keeps showing what went with it: the image, named, with its thumbnail.
            compare(asked.context.images, ["figure.png"])
            compare(asked.context.imageFiles.length, 1)
            const sent = p.sentAttachments(asked)
            verify(sent.some(function(a) { return a.kind === "image" && a.label === "figure.png" && a.url.length > 0 }))
            tryVerify(function() { const chip = findChild(p, "aiSentChip-" + (ai.messages.length - 2) + "-0"); return chip !== null && chip.width > 40 && chip.visible })
            // × removes an image before sending.
            verify(ai.attachImage(url))
            ai.detach("image", 0)
            compare(ai.images.length, 0)
        }
        function test_9_capturedRegionJoinsTheQuestion() {
            const ai = findChild(workspace, "aiController")
            const c = canvas()
            const p = panel()
            mouseClick(findChild(p, "aiNewThread"))
            verify(ai.captureRegion())
            compare(c.captureMode, true)
            const paper = findChild(c, "paperPage0")
            const start = paper.mapToItem(c, paper.width * .12, paper.height * .2)
            mouseDrag(c, start.x, start.y, paper.width * .5, paper.height * .12, Qt.LeftButton, Qt.NoModifier, 40)
            tryVerify(function() { return ai.images.length === 1 }, 15000)
            verify(ai.images[0].name.indexOf("Region · p. 1") === 0)
            tryCompare(findChild(workspace, "rightDock"), "activePanel", "ai")
            verify(ai.send("What does this region show?"))
            tryCompare(ai, "streaming", false, 10000)
            compare(ai.error, "")
            verify(ai.messages[ai.messages.length - 2].context.attachments.indexOf("image") >= 0)
            // Marking a region on the page keeps it as an annotation; nothing goes to the AI.
            compare(c.captureMode, false)
            const button = findChild(workspace.currentReader, "areaTool")
            verify(button)
            button.clicked()
            compare(c.tool, "area")
            mouseDrag(c, start.x, start.y + 40, paper.width * .4, paper.height * .1, Qt.LeftButton, Qt.NoModifier, 40)
            tryVerify(function() { return c.savedHighlights.some(function(h) { return h.kind === "area" }) }, 10000)
            compare(c.tool, "")
            compare(ai.images.length, 0)
        }
        function test_9y_aNoteProposedByTheAiChangesOnlyOnApply() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key")); researchStore.ai.giveConsent("claude")
            const note = researchStore.createNote("Draft", "old body\n")
            const ai = findChild(workspace, "aiController")
            workspace.showAi()
            ai.newThread("")
            ai.attachNote(note)
            verify(ai.attachments.some(function(a) { return a.kind === "note" && a.label.indexOf("Draft") >= 0 }))
            verify(ai.send("Rewrite my note more clearly"))
            tryCompare(ai, "streaming", false, 10000)
            const at = ai.messages.length - 1
            verify(ai.messages[at].content.indexOf("<note_update") >= 0)
            compare(ai.messages[at - 1].context.notes, ["Draft"])
            // The answer shows its words and a card; the note is untouched until Apply.
            const p = panel()
            let card = null
            tryVerify(function() { card = findChild(p, "aiNoteCard-" + at + "-0"); return card !== null && card.visible })
            verify(findChild(p, "aiMessage-" + at).text.indexOf("note_update") < 0)
            compare(findChild(card, "aiNoteTitle").text, "Draft \u2192 Rewritten", "the note that will change, by its name now")
            compare(researchStore.note(note).body, "old body\n")
            findChild(card, "aiNoteApply").clicked()
            compare(researchStore.note(note).body, "# Rewritten\n\nNew body.")
            compare(researchStore.note(note).title, "Rewritten")
            verify(!!ai.appliedNotes[ai.noteKey(at, 0)])
            // Undo puts the note back as it was.
            findChild(card, "aiNoteUndo").clicked()
            compare(researchStore.note(note).body, "old body\n")
            compare(researchStore.note(note).title, "Draft")
            // A new note is created only on Create Note, linked to the conversation.
            verify(ai.send("Write a new note about it"))
            tryCompare(ai, "streaming", false, 10000)
            const next = ai.messages.length - 1
            tryVerify(function() { card = findChild(p, "aiNoteCard-" + next + "-0"); return card !== null && card.visible })
            const count = researchStore.notes(false).length
            findChild(card, "aiNoteApply").clicked()
            compare(researchStore.notes(false).length, count + 1)
            const made = ai.appliedNotes[ai.noteKey(next, 0)].noteId
            compare(researchStore.note(made).title, "Fresh note")
            verify(researchStore.note(made).body.indexOf("A fresh note.") === 0)
            verify(researchStore.note(made).body.indexOf("owelk://ai/" + ai.threadId) > 0)
            // Plain answers carry no card.
            compare(ai.noteBlocks("Just text.").notes.length, 0)
            compare(ai.noteBlocks("Partly <note_new title=\"x\">still").preparing, true)
            // The card opens the note; the note's own AI button attaches it to a chat.
            findChild(card, "aiNoteOpen").clicked()
            tryVerify(function() { const g = Tree.find(workspace.documents.tree, workspace.documents.activeGroup); const t = g.tabs.find(function(x) { return x.id === g.activeTab }); return t.kind === "note" && t.noteId === made })
            ai.newThread("")
            let button = null
            tryVerify(function() {
                const pane = visualChild(workspace.documents.groupView(workspace.documents.activeGroup), "notePane")
                button = pane && pane.noteId === made ? visualChild(pane, "noteAskAiButton") : null
                return button !== null && button.visible
            }, 5000)
            button.clicked()
            tryVerify(function() { return (ai.spec.noteIds || []).indexOf(made) >= 0 })
            verify(workspace.aiVisible)
            // Gone for good: the Trash is counted by later test files.
            for (const id of [note, made]) { researchStore.deleteNote(id); researchStore.purgeNote(id) }
        }
        function test_9z_organizeTabsAppliesOnlyOnApply() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            researchStore.ai.provider = "claude"
            const d = workspace.documents
            d.restore({})
            workspace.openDocument(fixtureSource); canvas()
            d.openDocument(fixtureSource, null, true); canvas()
            const strip = Tree.leaves(d.tree)[0]
            workspace.organizeTabsIn(strip.id)
            const dialog = findChild(workspace, "organizeTabsDialog")
            tryCompare(dialog, "opened", true)
            compare(dialog.tabs.length, 2)
            mouseClick(findChild(dialog, "organizeAsk"))
            tryVerify(function() { return dialog.suggestions.length === 1 }, 10000)
            compare(dialog.suggestions[0].name, "Fixture papers")
            verify(Tree.leaves(d.tree)[0].labels === undefined) // Nothing changes before Apply.
            // The second tab moves to a group of its own, renamed, before applying.
            const second = dialog.suggestions[0].ids[1]
            let move = null
            tryVerify(function() { move = visualChild(dialog.contentItem, "groupMemberMove-0-1"); return move !== null && move.visible })
            mouseClick(move)
            const menu = findChild(dialog, "groupMoveMenu")
            tryCompare(menu, "opened", true)
            mouseClick(findChild(menu, "groupMoveNew"))
            tryVerify(function() { return dialog.suggestions.length === 2 && dialog.suggestions[1].ids[0] === second })
            // The new group's name is ready to type.
            tryCompare(menu, "opened", false)
            let name = null
            tryVerify(function() { name = visualChild(dialog.contentItem, "groupName-1"); return name !== null && name.visible && name.focus })
            keyClick(Qt.Key_Backspace); "Second".split("").forEach(function(ch) { keyClick(ch) })
            compare(dialog.suggestions[1].name, "Second")
            const apply = findChild(dialog, "organizeApply")
            verify(apply.enabled)
            mouseClick(apply)
            tryCompare(dialog, "opened", false)
            const leaf = Tree.leaves(d.tree)[0], labels = leaf.labels
            compare(labels.length, 2)
            compare(labels.map(function(l) { return l.name }).sort(), ["Fixture papers", "Second"])
            compare(leaf.tabs.find(function(t) { return t.id === second }).label, labels.find(function(l) { return l.name === "Second" }).id)
        }
        function test_9zz_organizePapersIntoCollectionsOnApply() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            researchStore.ai.provider = "claude"
            const one = testInput.copyFixture("occlusion one.pdf"), two = testInput.copyFixture("occlusion two.pdf")
            verify(researchStore.rememberDocument(one)); verify(researchStore.rememberDocument(two))
            const existing = researchStore.createCollection("Occlusion Studies")
            workspace.documents.openLibrary({})
            let view = null
            tryVerify(function() { view = findChild(workspace.documents.groupView(workspace.documents.activeGroup), "libraryView"); return view !== null && view.width > 0 })
            verify(visualChild(view, "libraryOrganize").enabled)
            view.organizeWithAi([one.toString(), two.toString()])
            const dialog = findChild(view, "organizePapersDialog")
            tryCompare(dialog, "opened", true)
            compare(dialog.papers.length, 2)
            mouseClick(findChild(dialog, "organizePapersAsk"))
            tryVerify(function() { return dialog.suggestions.length === 1 }, 10000)
            compare(dialog.suggestions[0].ids.length, 2)
            // The answer reuses the existing collection (names match regardless of case).
            tryVerify(function() { const kind = visualChild(dialog.contentItem, "groupKind-0"); return kind && kind.text === "Existing" })
            compare(researchStore.libraryDocuments({collection: existing}).length, 0, "nothing changes before Apply")
            // Renamed to a new name, Apply makes that collection instead.
            const name = visualChild(dialog.contentItem, "groupName-0")
            name.selectAll(); name.forceActiveFocus()
            keyClick(Qt.Key_Backspace); "Depth cues".split("").forEach(function(ch) { keyClick(ch) })
            tryCompare(visualChild(dialog.contentItem, "groupKind-0"), "text", "New")
            // Unchecking one paper leaves it out; it waits under Not grouped.
            const left = dialog.suggestions[0].ids[1]
            mouseClick(visualChild(dialog.contentItem, "groupMemberCheck-0-1"))
            tryVerify(function() { return dialog.suggestions[0].ids.length === 1 })
            tryVerify(function() { return visualChild(dialog.contentItem, "ungroupedAdd-0") !== null })
            mouseClick(findChild(dialog, "organizePapersApply"))
            tryCompare(dialog, "opened", false)
            const made = researchStore.collections().find(function(c) { return c.name === "Depth cues" })
            verify(made !== undefined)
            const members = researchStore.libraryDocuments({collection: made.id})
            compare(members.length, 1)
            verify(!researchStore.sameSource(members[0].url, left))
            compare(researchStore.libraryDocuments({collection: existing}).length, 0)
            researchStore.deleteCollection(made.id); researchStore.deleteCollection(existing)
        }
        function test_9zzz_comparePapersMakesATableAndANote() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            researchStore.ai.provider = "claude"
            const one = testInput.copyFixture("compare one.pdf"), two = testInput.copyFixture("compare two.pdf")
            verify(researchStore.rememberDocument(one)); verify(researchStore.rememberDocument(two))
            workspace.documents.openLibrary({})
            let view = null
            tryVerify(function() { view = findChild(workspace.documents.groupView(workspace.documents.activeGroup), "libraryView"); return view !== null && view.width > 0 })
            view.compareWithAi([one.toString(), two.toString()])
            const dialog = findChild(view, "comparePapersDialog")
            tryCompare(dialog, "opened", true)
            compare(dialog.papers.length, 2)
            verify(!findChild(dialog, "compareSave").enabled, "nothing to save before asking")
            mouseClick(findChild(dialog, "compareAsk"))
            tryVerify(function() { return !dialog.asking && dialog.answer.indexOf("occlusion") >= 0 }, 10000)
            compare(dialog.error, "")
            const before = researchStore.notes().length
            mouseClick(findChild(dialog, "compareSave"))
            tryCompare(dialog, "opened", false)
            const notes = researchStore.notes()
            compare(notes.length, before + 1)
            const note = researchStore.note(notes.find(function(n) { return n.title.indexOf("Comparison: ") === 0 }).id)
            verify(note.body.indexOf("owelk://document/") >= 0, "links each paper")
            verify(note.body.indexOf("| One 2020 | occlusion |") >= 0)
            // The PDFs open in a tab strip, each once, can be compared too.
            const d = workspace.documents
            d.restore({})
            workspace.openDocument(fixtureSource); canvas()
            d.openDocument(fixtureSource, null, true); canvas()
            workspace.comparePapersIn(Tree.leaves(d.tree)[0].id)
            const fromTabs = findChild(workspace, "comparePapersDialog")
            tryCompare(fromTabs, "opened", true)
            compare(fromTabs.papers.length, 1)
            fromTabs.close()
        }
        function test_9zzzz_rightClickOffersWhatIsThere() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            researchStore.ai.provider = "claude"
            researchStore.ai.giveConsent("claude")
            workspace.aiVisible = false
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.clearSelection()
            const ai = findChild(workspace, "aiController"), reader = workspace.currentReader
            ai.showThreads()
            // On running text: the page menu. Translate: this page, then the next from the panel, each on its own.
            c.jump(0, 0, 0); tryCompare(c, "restoring", false)
            const pageMenu = findChild(reader, "pageContextMenu")
            c.contextRequested(Qt.point(200, 200), 0, Qt.point(120, 230))
            tryCompare(pageMenu, "opened", true, 3000)
            findChild(reader, "menuTranslatePage").triggered()
            pageMenu.close()
            tryCompare(workspace, "aiVisible", true)
            const p = panel()
            tryVerify(function() { return !ai.streaming && ai.messages.length === 2 }, 10000)
            compare(ai.messages[0].display, "Translate page 1")
            verify(ai.messages[0].content.indexOf("Research finding 1.1") >= 0)
            const next = findChild(p, "aiTranslateNext")
            tryCompare(next, "visible", true)
            compare(next.text, "Translate Page 2")
            mouseClick(next)
            tryVerify(function() { return !ai.streaming && ai.messages.length === 4 }, 10000)
            compare(ai.messages[2].display, "Translate page 2")
            verify(ai.messages[2].content.indexOf("Research finding 2.1") >= 0)
            // On the chart: Ask AI about Figure 1 attaches its image, named, to the open conversation.
            const thread = ai.threadId
            const objectMenu = findChild(reader, "objectContextMenu")
            c.contextRequested(Qt.point(200, 200), 0, Qt.point(250, 520))
            tryCompare(objectMenu, "opened", true, 3000)
            const ask = findChild(reader, "menuAskObject")
            compare(ask.text, "Ask AI about Figure 1")
            ask.triggered()
            objectMenu.close()
            compare(ai.threadId, thread)
            compare(ai.images.length, 1)
            compare(ai.images[0].name, "Figure 1 · p. 1")
            compare(ai.images[0].about, "Figure 1, page 1")
            verify(!ai.streaming)
            verify(ai.attachments.some(function(a) { return a.kind === "image" && a.label === "Figure 1 · p. 1" }))
            ai.detach("image", 0)
            // With no conversation open, a new one about this paper.
            ai.showThreads()
            c.contextRequested(Qt.point(200, 200), 0, Qt.point(250, 520))
            tryCompare(objectMenu, "opened", true, 3000)
            findChild(reader, "menuAskObject").triggered()
            objectMenu.close()
            compare(ai.threadId, "")
            compare(ai.conversationOpen, true)
            compare(ai.images.length, 1)
            verify(ai.attachments.some(function(a) { return a.kind === "paper" }))
            ai.showThreads()
        }
        function test_9zzzzz_glossShowsBesideTheSelection() {
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            researchStore.ai.provider = "claude"
            researchStore.ai.giveConsent("claude")
            workspace.aiVisible = false
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            wait(400) // The pages settle at their new width (the AI panel just closed) before selecting.
            c.selectPage(0)
            const reader = workspace.currentReader
            const threads = researchStore.aiThreads().length
            findChild(reader, "menuGloss").triggered()
            const gloss = findChild(reader, "glossPopup")
            tryCompare(gloss, "opened", true)
            tryCompare(gloss, "streaming", false, 10000)
            verify(gloss.answer.indexOf("Mock answer") >= 0)
            // Nothing opens in the AI panel and no conversation is kept.
            compare(workspace.aiVisible, false)
            compare(researchStore.aiThreads().length, threads)
            verify(gloss.x >= 0 && gloss.x + gloss.width <= c.width)
            // Its model chip: the fast model by default; another one (and its effort) asks again.
            tryVerify(function() { return gloss.models.length > 0 })
            compare(findChild(gloss.contentItem, "glossModelButton").text, "Haiku 5.5")
            gloss.choose("claude-sonnet-5-5", "low")
            compare(researchStore.ai.glossChoice("claude"), "claude-sonnet-5-5")
            tryCompare(findChild(gloss.contentItem, "glossModelButton"), "text", "Sonnet 5.5 · Low")
            tryCompare(gloss, "streaming", false, 10000)
            verify(gloss.answer.indexOf("Mock answer") >= 0)
            gloss.choose("", "low")
            tryCompare(gloss, "streaming", false, 10000)
            // The same words again: at once, without a request.
            gloss.close()
            reader.glossSelection()
            tryCompare(gloss, "opened", true)
            verify(!gloss.streaming)
            verify(gloss.answer.indexOf("Mock answer") >= 0)
            gloss.close()
            c.clearSelection()
        }
        function test_9zzzzzy_aPageLinkInFrontLeavesABackButton() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.jump(0, 0, 0); tryCompare(c, "restoring", false)
            c.backStack = []
            const paper = researchStore.documentLinkId(fixtureSource)
            verify(workspace.documents.openLink("owelk://document/" + paper + "#page=4&q=" + encodeURIComponent("Research finding 4.2")))
            tryCompare(c, "currentPage", 3)
            compare(c.backTarget.page, 0)
            // The words are lit where the link pointed.
            tryVerify(function() { return c.highlight !== null && c.highlight.page === 3 }, 5000)
            verify(c.goBack())
            tryCompare(c, "currentPage", 0)
        }
        function test_9zzzzzz_symbolHintsMatchWhatIsPrinted() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.symbols = [{symbol: "\\omega_m", text: ["ωm"], meaning: "angular velocity", page: 2},
                         {symbol: "\\boxplus", text: ["⊞"], meaning: "adds a small change to a state", page: 2},
                         {symbol: "b", text: ["b"], meaning: "IMU bias", page: 0}]
            // As printed, a longer run of it (ωmi: ω, m, then the index), an operator inside a run.
            compare(c.symbolFor({word: "ωm,", glyph: "ω"}).meaning, "angular velocity")
            compare(c.symbolFor({word: "ωmi", glyph: "m"}).meaning, "angular velocity")
            compare(c.symbolFor({word: "x⊞δx", glyph: "⊞"}).symbol, "\\boxplus")
            compare(c.symbolFor({word: "b", glyph: "b"}).page, 0)
            // Words are not symbols.
            compare(c.symbolFor({word: "a", glyph: "a"}), null)
            compare(c.symbolFor({word: "bias", glyph: "b"}), null)
            // Plain forms: math letters as plain ones.
            c.symbols = c.symbols.concat([{symbol: "\\mathbf{p}_r", text: ["𝐩𝑟"], match: ["pr"], meaning: "robot position", page: 4}])
            compare(c.symbolFor({word: "𝐩𝑟", plainWord: "pr", glyph: "𝐩", plainGlyph: "p"}).meaning, "robot position")
            c.symbolHint = {entry: c.symbols[0], page: 0, box: Qt.rect(10, 10, 5, 5), x: 100, y: 100}
            const tip = findChild(c, "symbolHint")
            verify(tip.visible)
            verify(tip.width > 40 && tip.width <= 320)
            // It stays while the pointer moves on the symbol, and goes once it leaves.
            c.restOn(0, Qt.point(13, 12), Qt.point(104, 101))
            verify(tip.visible)
            c.restOn(0, Qt.point(30, 12), Qt.point(120, 101))
            verify(!tip.visible)
            c.symbolHint = {entry: c.symbols[0], page: 0, box: Qt.rect(10, 10, 5, 5), x: 100, y: 100}
            c.leaveRest()
            verify(!tip.visible)
            c.symbols = []
        }
    }
}
