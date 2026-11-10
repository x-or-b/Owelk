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
            // They can be read each in full instead, for the next question (it is off again after it).
            const readEach = findChild(p, "aiReadEach")
            compare(ai.readEachCount, 4)
            verify(readEach.visible && readEach.enabled && !readEach.checked)
            readEach.clicked()
            verify(ai.spec.readEach && ai.readsEach && readEach.checked)
            readEach.clicked()
            verify(!ai.readsEach && !readEach.checked)
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
        function test_2c_webSearchIsTurnedOnForTheQuestions() {
            const ai = findChild(workspace, "aiController")
            const original = ai.threadId
            workspace.showAi()
            const p = panel()
            ai.newThread()
            // With an API key it is off until turned on, then remembered for that provider; the question goes
            // with it and shows that it did. A ChatGPT account starts with it on.
            const web = findChild(p, "aiWebSearchButton")
            verify(web.visible && !web.checked && !ai.searchesWeb)
            researchStore.ai.provider = "chatgpt"
            tryVerify(function() { return ai.webSearch })
            researchStore.ai.provider = "claude"
            tryVerify(function() { return !ai.webSearch })
            mouseClick(web)
            verify(ai.searchesWeb && web.checked)
            compare(researchStore.setting("ai.webSearch.claude", ""), "1")
            verify(ai.send("What came after this paper?"))
            tryVerify(function() { return !ai.streaming && ai.messages.length === 2 }, 10000)
            verify(ai.messages[0].context.webSearch)
            verify(p.sentAttachments(ai.messages[0]).some(function(a) { return a.kind === "web" }))
            mouseClick(web)
            verify(!ai.searchesWeb)
            compare(researchStore.setting("ai.webSearch.claude", ""), "0")
            ai.openThread(original)
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
        function test_5a_anAnswerGoesOnWhileAnotherConversationIsOpen() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const answered = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "answered" }', p)
            answered.target = ai
            const other = researchStore.aiThreads("What is the main claim?")[0].id
            ai.newThread()
            verify(ai.send("Which answer goes on?"))
            const first = ai.request
            // Another conversation at once: the first is not stopped.
            verify(ai.openThread(other))
            compare(ai.streaming, false)
            compare(ai.request, -1)
            verify(ai.running[first] !== undefined)
            // Its finishing does not read the open one again (which would start its view over at the top).
            const reread = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "threadChanged" }', p)
            reread.target = ai
            // It is saved to its own conversation, and a card says it is ready.
            tryVerify(function() { return ai.running[first] === undefined }, 10000)
            const saved = researchStore.aiThreads("Which answer goes on?")
            compare(saved.length, 1)
            compare(researchStore.aiThread(saved[0].id).messages.length, 2)
            tryCompare(answered, "count", 1)
            compare(answered.signalArguments[0][0], saved[0].id)
            compare(reread.count, 0)
            compare(findChild(p, "aiConversation").following, true)
            reread.destroy()
            compare(ai.answeringThreads.length, 0)
            // Opened again: the saved answer, nothing still writing.
            verify(ai.openThread(saved[0].id))
            compare(ai.streaming, false)
            compare(ai.messages.length, 2)
            answered.destroy()
        }
        function test_5b_aQuestionAskedWhileAnsweringGoesNext() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            ai.newThread()
            verify(ai.send("First of two"))
            // Asked while the first answer is coming: it waits, shown under it, and goes once that answer is done.
            verify(ai.queue("Second of two"))
            compare(ai.queuedHere.length, 1)
            tryVerify(function() { return visualChild(p, "aiQueued-0") !== null })
            tryVerify(function() { return !ai.streaming && ai.messages.length === 4 }, 15000)
            compare(ai.messages[0].display, "First of two")
            compare(ai.messages[2].display, "Second of two")
            compare(ai.queuedHere.length, 0)
            // Taken back before it went: not asked.
            verify(ai.send("Third"))
            verify(ai.queue("Never asked"))
            ai.unqueue(0)
            tryVerify(function() { return !ai.streaming && ai.messages.length === 6 }, 15000)
            wait(200)
            compare(ai.messages.length, 6)
            // Send now: the answer coming stops, the chosen one goes first, the other still waits its turn.
            verify(ai.send("Fourth"))
            verify(ai.queue("After it"))
            verify(ai.queue("Asked now"))
            tryVerify(function() { return visualChild(p, "aiQueuedSend-1") !== null })
            compare(visualChild(p, "aiQueuedSend-1").text, "Send now")
            mouseClick(visualChild(p, "aiQueuedSend-1"))
            tryVerify(function() { return ai.streaming && ai.pendingQuestion === "Asked now" }, 10000)
            compare(ai.queuedHere.length, 1)
            tryVerify(function() { return !ai.streaming && !ai.queuedHere.length && ai.messages[ai.messages.length - 2].display === "After it" }, 20000)
            compare(ai.messages[ai.messages.length - 4].display, "Asked now")
        }
        function test_5c_aChatInATabFollowsThePanel() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const id = researchStore.aiThreads("First of two")[0].id
            // Open in the panel and in a tab of its own.
            verify(ai.openThread(id))
            verify(workspace.documents.openAiThread(id, true))
            workspace.homeVisible = false
            let tab = null
            tryVerify(function() {
                const view = workspace.documents.groupView(workspace.documents.activeGroup)
                tab = view && view.aiTab
                return !!tab && tab.controller.threadId === id
            })
            const inTab = tab.controller
            const before = inTab.messages.length
            compare(ai.messages.length, before)
            // Asked in the panel: the tab shows the same answer coming, and a question asked in the tab meanwhile
            // waits in both.
            verify(ai.send("Asked in the panel"))
            tryCompare(inTab, "streaming", true)
            compare(inTab.pendingQuestion, "Asked in the panel")
            verify(inTab.queue("Asked in the tab"))
            compare(ai.queuedHere.length, 1)
            // Both answered in turn, both views showing all of it.
            tryVerify(function() { return !ai.streaming && !inTab.streaming && ai.messages.length === before + 4 && inTab.messages.length === before + 4 }, 15000)
            compare(inTab.messages[before + 2].display, "Asked in the tab")
            // Only once in the window, and gone with its conversation's tab closed.
            verify(workspace.documents.openAiThread(id, true))
            let count = 0
            Tree.leaves(workspace.documents.tree).forEach(function(g) { g.tabs.forEach(function(t) { if (t.kind === "ai" && t.threadId === id) ++count }) })
            compare(count, 1)
            workspace.documents.closeActiveTab()
        }
        function test_5d_aChatDraggedFromThePanelOpensBesideTheTabs() {
            const ai = findChild(workspace, "aiController"), d = workspace.documents
            const id = researchStore.aiThreads("First of two")[0].id
            const chatTabs = function() {
                let list = []
                Tree.leaves(d.tree).forEach(function(g) { g.tabs.forEach(function(t) { if (t.kind === "ai" && t.threadId === id) list.push(g.id) }) })
                return list
            }
            verify(ai.openThread(id))
            const handle = findChild(panel(), "aiTitleDrag")
            verify(handle.enabled)
            const from = Qt.point(10, handle.height / 2)
            d.openLibrary({})
            // Over Home: a new tab.
            workspace.homeVisible = true
            const home = findChild(workspace, "homeView")
            testInput.pointerDrag(handle, from, handle.mapFromItem(home, home.width / 2, home.height / 2), false)
            tryVerify(function() { return !workspace.homeVisible && chatTabs().length === 1 })
            compare(d.dropTarget, null)
            // Beside the tabs: that tab goes into a split of its own.
            const groups = d.groupCount
            let view = d.groupView(d.activeGroup)
            testInput.pointerDrag(handle, from, handle.mapFromItem(view, view.width - 15, view.height / 2), false)
            tryCompare(d, "groupCount", groups + 1)
            compare(chatTabs(), [d.activeGroup])
            // Not in a tab yet: a new one opens in the split; let go over the panel, nothing changes.
            d.closeActiveTab()
            tryCompare(d, "groupCount", groups)
            compare(chatTabs().length, 0)
            const before = JSON.stringify(d.snapshot().tree)
            testInput.pointerDrag(handle, from, Qt.point(from.x + 40, from.y + 30), false)
            wait(50)
            compare(JSON.stringify(d.snapshot().tree), before)
            compare(d.draggedTab, "")
            view = d.groupView(d.activeGroup)
            testInput.pointerDrag(handle, from, handle.mapFromItem(view, view.width - 15, view.height / 2), false)
            tryCompare(d, "groupCount", groups + 1)
            compare(chatTabs(), [d.activeGroup])
            tryVerify(function() { const v = d.groupView(d.activeGroup); return !!v && !!v.aiTab && v.aiTab.controller.threadId === id })
            // Out of the Threads list the same.
            d.closeActiveTab()
            tryCompare(d, "groupCount", groups)
            workspace.threadsVisible = true
            const list = threadsList(), threads = findChild(workspace, "threadsPanel")
            let at = -1
            tryVerify(function() { at = rowIndex(list, function(r) { return r.type === "chat" && r.chat.id === id }); return at >= 0 })
            list.positionViewAtIndex(at, ListView.Contain)
            tryVerify(function() { return list.itemAtIndex(at) !== null })
            const row = list.itemAtIndex(at)
            tryVerify(function() { view = d.groupView(d.activeGroup); return !!view && Math.abs(view.width - d.width) < 2 })
            testInput.pointerDrag(threads, row.mapToItem(threads, 40, row.height / 2), threads.mapFromItem(view, view.width - 15, view.height / 2), false)
            tryCompare(d, "groupCount", groups + 1)
            compare(chatTabs(), [d.activeGroup])
            compare(threads.draggingOut, false)
            compare(d.draggedTab, "")
            workspace.threadsVisible = false
            d.closeActiveTab(); d.closeActiveTab()
        }
        function test_5dd_aChatOpenedInANewTabLeavesThePanel() {
            const ai = findChild(workspace, "aiController"), d = workspace.documents
            const id = researchStore.aiThreads("First of two")[0].id
            verify(ai.openThread(id))
            const button = findChild(panel(), "aiOpenInTab")
            tryCompare(button, "visible", true)
            workspace.homeVisible = true
            mouseClick(button)
            let view = null
            tryVerify(function() { view = d.groupView(d.activeGroup); return !!view && !!view.aiTab && view.aiTab.controller.threadId === id })
            compare(workspace.homeVisible, false)
            // The tab shows it now; the panel closes rather than show it twice.
            compare(workspace.panelShown("ai"), false)
            verify(!findChild(view.aiTab, "aiOpenInTab").visible)
            d.closeActiveTab()
            workspace.showAi()
            panel()
        }
        function test_5e_aChatTabTakesThePaperBesideIt() {
            const ai = findChild(workspace, "aiController"), d = workspace.documents
            const id = researchStore.aiThreads("First of two")[0].id
            workspace.openDocument(fixtureSource)
            workspace.homeVisible = false
            tryVerify(function() { return !!workspace.currentReader && workspace.currentReader.pdfReady && researchStore.sameSource(workspace.currentReader.source, fixtureSource) })
            const paper = workspace.currentReader, paperGroup = d.activeGroup
            const canvas = findChild(paper, "pdfCanvas" + paper.paneIndex)
            d.placeChat(id, {group: paperGroup, edge: "right"})
            let tab = null
            tryVerify(function() { const v = d.groupView(d.activeGroup); tab = v && v.aiTab; return !!tab && tab.controller.threadId === id })
            const chatGroup = d.activeGroup
            // Its paper is the one beside it.
            tryCompare(tab.controller, "reader", paper)
            tab.controller.attachPaper()
            verify(researchStore.sameSource(tab.controller.spec.source, fixtureSource)
                   || (tab.controller.spec.papers || []).some(function(url) { return researchStore.sameSource(url, fixtureSource) }))
            // A selection asked about in that paper goes to the chat beside it, not to the AI panel.
            d.activateGroup(paperGroup)
            const panelSpec = JSON.stringify(ai.spec)
            paper.aiRequested({attach: true, source: fixtureSource, page: 0, selection: "Words from beside"})
            verify(tab.controller.spec.selection.indexOf("Words from beside") >= 0)
            compare(JSON.stringify(ai.spec), panelSpec)
            compare(d.activeGroup, chatGroup)
            // A region goes back to the conversation that asked for it.
            const inPanel = ai.images.length, inTab = tab.controller.images.length
            verify(tab.controller.captureRegion())
            canvas.regionSelected(0, Qt.rect(.1, .1, .3, .2))
            compare(tab.controller.images.length, inTab + 1)
            compare(ai.images.length, inPanel)
            d.activateGroup(paperGroup)
            verify(ai.captureRegion())
            canvas.regionSelected(0, Qt.rect(.1, .4, .3, .2))
            compare(ai.images.length, inPanel + 1)
            compare(tab.controller.images.length, inTab + 1)
            ai.images = []; tab.controller.images = []
            d.activateGroup(chatGroup); d.closeActiveTab()
            d.activateGroup(paperGroup); d.closeActiveTab()
        }
        function test_5f_theLastTurnIsAskedAgainEditedOrBranched() {
            const ai = findChild(workspace, "aiController")
            const id = researchStore.aiThreads("First of two")[0].id
            verify(ai.openThread(id))
            tryVerify(function() { return ai.canRedo })
            const p = panel(), box = findChild(p, "aiQuestion")
            const before = ai.messages.length, asked = ai.messages[before - 2]
            // Asked again: the same question, with what went with it, in place of the last turn.
            verify(ai.askAgain())
            compare(ai.pendingQuestion, asked.display)
            tryVerify(function() { return !ai.streaming && ai.messages.length === before && ai.messages[before - 2].id !== asked.id }, 15000)
            compare(ai.messages[before - 2].content, asked.content)
            compare(ai.messages[before - 2].display, asked.display)
            // Edited: back in the question box; sent, it replaces the last turn. Cancelled, nothing changes.
            verify(ai.editLast())
            compare(box.text, asked.display)
            verify(findChild(p, "aiEditing").visible)
            ai.cancelEdit()
            compare(ai.editing, "")
            compare(box.text, "")
            verify(ai.editLast())
            verify(ai.send("Edited question"))
            compare(ai.editing, "")
            tryVerify(function() { return !ai.streaming && ai.messages.length === before && ai.messages[before - 2].display === "Edited question" }, 15000)
            // Asked again and it fails: the turn comes back, with what went wrong.
            const kept = JSON.stringify(ai.messages.map(function(m) { return m.content }))
            researchStore.setSetting("ai.baseUrl.claude", "http://127.0.0.1:9/")
            verify(ai.askAgain())
            tryVerify(function() { return !ai.streaming && ai.error.length > 0 && ai.messages.length === before }, 15000)
            compare(JSON.stringify(ai.messages.map(function(m) { return m.content })), kept)
            researchStore.setSetting("ai.baseUrl.claude", testInput.webFixture("/").toString())
            ai.error = ""
            // A new chat from the first answer; this one stays whole.
            const branch = ai.branchFrom(1)
            verify(branch.length > 0)
            compare(researchStore.aiThread(branch).messages.length, 2)
            compare(ai.messages.length, before)
            researchStore.purgeAiThreads([branch])
        }
        function test_5h_aChatSavedAsANote() {
            const ai = findChild(workspace, "aiController"), d = workspace.documents
            const id = researchStore.aiThreads("First of two")[0].id
            verify(ai.openThread(id))
            workspace.homeVisible = false
            // The whole chat as a note: each question quoted above its answer, with a link back; it opens.
            const note = ai.saveChatAsNote()
            verify(note.length > 0)
            const body = researchStore.note(note).body
            const asked = ai.messages.filter(function(m) { return m.role === "user" })
            verify(body.indexOf("> " + asked[0].display) >= 0)
            verify(body.indexOf("> " + asked[asked.length - 1].display) >= 0)
            verify(body.indexOf("Mock answer") >= 0)
            verify(body.indexOf("owelk://ai/" + id) >= 0)
            tryVerify(function() { const v = d.groupView(d.activeGroup); return !!v && v.isNote })
            d.closeActiveTab()
        }
        function test_5i_questionsSuggestedNextAreAskedWithAClick() {
            const ai = findChild(workspace, "aiController")
            const id = researchStore.aiThreads("First of two")[0].id
            verify(ai.openThread(id))
            // Under the last answer only; a click asks one.
            verify(researchStore.appendAiMessage(id, {role: "user", content: "Q", display: "Q"}))
            verify(researchStore.appendAiMessage(id, {role: "assistant", content: "A", context: {followUps: ["What next?", "Why?"]}}))
            tryVerify(function() { return ai.canRedo && ai.messages[ai.messages.length - 1].content === "A" })
            const p = panel()
            let chip = null
            tryVerify(function() { chip = findChild(p, "aiFollowUp-0"); return !!chip && chip.visible })
            compare(chip.text, "What next?")
            const before = ai.messages.length
            chip.clicked()
            tryVerify(function() { return !ai.streaming && ai.messages.length === before + 2 }, 15000)
            compare(ai.messages[before].display, "What next?")
            // While an answer is written, its block of questions does not show.
            compare(ai.noteBlocks("Text\n\n<followups>\nOne?").text, "Text")
        }
        function test_5j_answersReadInAColumnAtTheirOwnSize() {
            const ai = findChild(workspace, "aiController"), d = workspace.documents
            const id = researchStore.aiThreads("First of two")[0].id
            verify(d.openAiThread(id, true))
            workspace.homeVisible = false
            let tab = null
            tryVerify(function() { const v = d.groupView(d.activeGroup); tab = v && v.aiTab; return !!tab && tab.controller.threadId === id })
            const conversation = findChild(tab, "aiConversation"), last = tab.controller.messages.length - 1
            let answer = null
            tryVerify(function() { answer = findChild(conversation, "aiMessage-" + last); return !!answer && answer.visible && answer.width > 0 })
            compare(answer.font.pixelSize, Theme.answerSize)
            compare(answer.renderType, TextEdit.NativeRendering)
            // In a wide tab the turns keep to a column in the middle; the question box keeps to it too.
            verify(conversation.width > Theme.answerWidth)
            const left = function(item) { return item.mapToItem(conversation, 0, 0).x }
            tryVerify(function() { return Math.abs(answer.width - Theme.answerWidth) < 1 })
            fuzzyCompare(left(answer), (conversation.width - Theme.answerWidth) / 2, 1)
            const box = findChild(tab, "aiComposer")
            tryVerify(function() { return Math.abs(box.width - Theme.answerWidth) < 1 && Math.abs(left(box) - left(answer)) < 1 })
            Theme.answerColumn = false
            tryVerify(function() { return Math.abs(answer.width - conversation.width) < 1 })
            fuzzyCompare(left(answer), 0, 1)
            Theme.answerColumn = true
            // Tighter lines make the same answer shorter; sharp text can be turned off.
            const comfortable = answer.contentHeight
            Theme.answerSpacing = "compact"
            tryVerify(function() { return answer.contentHeight < comfortable })
            Theme.answerSpacing = "comfortable"
            Theme.answerNative = false
            compare(answer.renderType, TextEdit.QtRendering)
            Theme.answerNative = true
            d.closeActiveTab()
        }
        function test_5k_aClickOnTheTitleRenamesTheChat() {
            const ai = findChild(workspace, "aiController")
            const id = researchStore.aiThreads("First of two")[0].id
            verify(ai.openThread(id))
            const p = panel(), title = findChild(p, "aiThreadTitle"), field = findChild(p, "aiThreadTitleField")
            const before = ai.thread.title
            // Return keeps the new name; Escape leaves the old one.
            mouseClick(title, 10, title.height / 2)
            tryCompare(field, "visible", true)
            compare(field.text, before)
            verify(field.activeFocus)
            field.text = "Renamed in place"
            keyClick(Qt.Key_Return)
            tryCompare(field, "visible", false)
            tryCompare(ai.thread, "title", "Renamed in place")
            compare(researchStore.aiThread(id).title, "Renamed in place")
            mouseClick(title, 10, title.height / 2)
            tryCompare(field, "visible", true)
            field.text = "Not kept"
            keyClick(Qt.Key_Escape)
            tryCompare(field, "visible", false)
            compare(researchStore.aiThread(id).title, "Renamed in place")
            verify(researchStore.renameAiThread(id, before))
        }
        function test_5g_aPaperMarkedAsReadOffersThreeLines() {
            const d = workspace.documents, bar = findChild(workspace, "summaryBar")
            workspace.openDocument(fixtureSource)
            workspace.homeVisible = false
            tryVerify(function() { return !!workspace.currentReader && workspace.currentReader.pdfReady })
            const paperGroup = d.activeGroup
            researchStore.setReadingState(fixtureSource, "unread")
            verify(researchStore.setReadingState(fixtureSource, "read"))
            tryCompare(bar, "visible", true)
            // Again while already read: nothing new.
            bar.visible = false
            verify(researchStore.setReadingState(fixtureSource, "read"))
            wait(400)
            compare(bar.visible, false)
            // Several at once (the Library's selection): nothing is offered.
            researchStore.setReadingState(fixtureSource, "unread"); researchStore.setReadingState(outlineSource, "unread")
            researchStore.setReadingState(fixtureSource, "read"); researchStore.setReadingState(outlineSource, "read")
            wait(400)
            compare(bar.visible, false)
            // Drafted by the AI: a note beside the paper whose empty lines become the answer, with a link to it.
            const note = workspace.writeSummary(fixtureSource, true)
            verify(note.length > 0)
            verify(researchStore.note(note).body.indexOf(d.summaryLines) >= 0)
            verify(d.activeGroup !== paperGroup)
            tryVerify(function() { return researchStore.note(note).body.indexOf("Mock answer") >= 0 }, 15000)
            const body = researchStore.note(note).body
            compare(body.indexOf(d.summaryLines), -1)
            verify(body.indexOf("owelk://ai/") >= 0)
            verify(body.indexOf("owelk://document/") >= 0)
            d.closeActiveTab()
            d.activateGroup(paperGroup); d.closeActiveTab()
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
            // With the largest text too, Send stays inside (the gaps go, then each control is narrower).
            const send = findChild(p, "aiSend"), textSize = Theme.textSize
            Theme.textSize = 17
            tryVerify(function() { return send.width > 20 && send.mapToItem(p, send.width, 0).x <= p.width - 7 })
            Theme.textSize = textSize
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
        function test_6a_theScrollBarMovesTheChatEvenly() {
            const ai = findChild(workspace, "aiController")
            // Short questions between long answers: a view that guessed the height of turns it had not made
            // jumped back and forth while its scroll bar was dragged.
            const messages = []
            for (let i = 0; i < 6; ++i) {
                messages.push({role: "user", display: "Question " + i, content: "q"})
                messages.push({role: "assistant", content: ("Paragraph " + i + " " + "word ".repeat(60) + "\n\n").repeat(4 + (i % 3) * 4)})
            }
            const p = panel()
            const conversation = findChild(p, "aiConversation")
            // It opens with its last screen; the turns above it are laid out after that.
            ai.thread = {id: ai.threadId, title: "Long", messages: messages}
            compare(conversation.count, messages.length)
            verify(!conversation.laidOut)
            verify(conversation.itemAtIndex(0) === null)
            verify(conversation.itemAtIndex(messages.length - 1) !== null)
            tryCompare(conversation, "laidOut", true)
            verify(conversation.itemAtIndex(0) !== null)
            // A new turn leaves the others as they are.
            const first = conversation.itemAtIndex(0), firstAnswer = findChild(conversation, "aiMessage-1")
            const more = messages.concat([{role: "user", display: "One more", content: "q"}, {role: "assistant", content: "Short."}])
            ai.thread = {id: ai.threadId, title: "Long", messages: more}
            compare(conversation.count, more.length)
            verify(conversation.laidOut)
            verify(conversation.itemAtIndex(0) === first)
            verify(findChild(conversation, "aiMessage-1") === firstAnswer)
            waitForPolish(conversation)
            conversation.positionViewAtBeginning()
            const bar = findChild(conversation, "aiConversationScrollBar")
            const height = conversation.contentHeight
            verify(height > conversation.height * 5)
            const from = bar.position * bar.height + 4
            mousePress(bar, bar.width / 2, from)
            let last = conversation.contentY - conversation.originY
            for (let y = from + 6; y < bar.height; y += 6) {
                mouseMove(bar, bar.width / 2, y)
                const now = conversation.contentY - conversation.originY
                compare(conversation.contentHeight, height)
                verify(now >= last, "never back: " + now + " after " + last)
                verify(now - last <= 2 * 6 / bar.height * height, "an even step: " + (now - last))
                last = now
            }
            mouseRelease(bar, bar.width / 2, bar.height - 2)
            verify(conversation.atYEnd)
            // A wider chat wraps the turns on screen as it changes, and the others once it has stopped.
            workspace.rightDockWidth = 300
            tryCompare(conversation, "laidOut", false)
            tryCompare(conversation, "laidOut", true)
            tryVerify(function() { const answer = findChild(conversation, "aiMessage-1"); return !!answer && Math.abs(answer.width - conversation.column) < 1 })
            fuzzyCompare(conversation.turnWidth, conversation.width, 1)
            workspace.rightDockWidth = 224
            tryCompare(conversation, "laidOut", true)
        }
        function test_6b_aDragOverATableDrawsItsLettersOnce() {
            const ai = findChild(workspace, "aiController")
            // Qt drew the cells of a table again over themselves when a moving selection redrew part of the answer,
            // so their letters thickened while a drag went on, with sharp text or without. A drag redraws the selection
            // on every move of the pointer, also when the selection stays the same.
            const content = "Before the tables, words to select.\n\n| Name | Value |\n| --- | --- |\n| alpha | first cell |\n"
                + "| beta | second cell |\n\nBetween the tables, more words.\n\n| Step | What to do |\n| --- | --- |\n"
                + "| one | read the figures |\n| two | read the method |\n\nAfter the tables, more words to select."
            ai.thread = {id: ai.threadId, title: "Table", messages: [{role: "user", display: "Q", content: "q"}, {role: "assistant", content: content}]}
            const conversation = findChild(panel(), "aiConversation")
            let answer = null
            tryVerify(function() { answer = findChild(conversation, "aiMessage-1"); return !!answer && answer.visible && answer.length > 100 })
            waitForPolish(conversation)
            // grabImage cuts an item's rectangle in its parent out of the window: an empty item over the answer, in the
            // window's top item, gives the answer's own pixels.
            const place = answer.mapToItem(null, 0, 0, answer.width, answer.height)
            verify(place.y + place.height <= workspace.height && place.height > 40)
            let top = answer
            while (top.parent) top = top.parent
            const frame = Qt.createQmlObject("import QtQuick; Item {}", top)
            frame.x = place.x; frame.y = place.y; frame.width = place.width; frame.height = place.height
            const color = String(answer.selectedTextColor) // A copy: the property itself follows a change.
            const first = answer.positionToRectangle(3), last = answer.positionToRectangle(answer.length - 4)
            const ends = [Qt.point(first.x, first.y + first.height / 2), Qt.point(last.x, last.y + last.height / 2)]
            for (const native of [true, false]) {
                Theme.answerNative = native
                waitForRendering(answer)
                const clean = grabImage(frame)
                // Down from the first words and up from the last, a few pixels a move; each move is drawn.
                for (const down of [true, false]) {
                    const from = ends[down ? 0 : 1], to = ends[down ? 1 : 0], moves = Math.ceil(Math.abs(to.y - from.y) / 4)
                    let thick = 0
                    mousePress(answer, from.x, from.y)
                    for (let i = 1; i <= moves; ++i) {
                        mouseMove(answer, from.x + (to.x - from.x) * i / moves, from.y + (to.y - from.y) * i / moves, -1, Qt.LeftButton)
                        const moved = grabImage(frame)
                        // A change of color draws the whole answer again.
                        answer.selectedTextColor = "red"
                        answer.selectedTextColor = color
                        if (!grabImage(frame).equals(moved)) ++thick
                    }
                    mouseRelease(answer, to.x, to.y)
                    verify(answer.selectedText.length > 100)
                    compare(thick, 0, (native ? "sharp" : "Qt") + " text, " + (down ? "down" : "up") + ": moves drawn unlike the whole answer")
                    // Let go, the answer is as before the drag.
                    answer.deselect()
                    verify(grabImage(frame).equals(clean), (native ? "sharp" : "Qt") + " text, " + (down ? "down" : "up") + ": after the drag")
                }
            }
            frame.destroy()
            Theme.answerNative = true
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
            // A passage has no ☆; a word is kept in Library › Words with its meaning here.
            verify(!findChild(gloss.contentItem, "glossSave").visible)
            gloss.close()
            c.clearSelection()
            gloss.show({source: fixtureSource, page: 0, text: "occlusion", from: Qt.point(150, 185), to: Qt.point(215, 185)})
            tryCompare(gloss, "streaming", false, 10000)
            const star = findChild(gloss.contentItem, "glossSave")
            verify(star.visible)
            const before = researchStore.words().length
            star.clicked()
            tryVerify(function() { return researchStore.words().length === before + 1 }, 10000)
            const word = researchStore.words()[0]
            compare(word.term, "occlusion")
            verify(word.meaning.indexOf("Mock answer") >= 0)
            compare(word.page, 0)
            compare(star.description, "Saved to Words")
            gloss.close()
            researchStore.removeWords([word.id])
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
