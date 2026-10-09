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
        function panel() {
            tryVerify(function() { return findChild(workspace, "aiPanel") !== null })
            const p = findChild(workspace, "aiPanel")
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
            compare(workspace.aiSide, "right") // The AI panel docks on the right by default.
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
            // Saving an answer as a note links back to the thread.
            mouseClick(findChild(p, "aiSaveNote-3"))
            verify(researchStore.searchKnowledge("Mock answer").some(function(h) { return h.kind === "standalone-note" }))
        }
        function test_2_threadsListReopensWithoutANewRequest() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const thread = ai.threadId
            mouseClick(findChild(p, "aiThreadsButton"))
            const list = findChild(p, "aiThreadList")
            tryCompare(list, "visible", true)
            tryVerify(function() { return list.count >= 1 && list.itemAtIndex(0) !== null })
            waitForPolish(list)
            mouseClick(list.itemAtIndex(0))
            tryCompare(ai, "threadId", thread)
            compare(ai.messages.length, 4)
            compare(ai.streaming, false)
            // Search results and owelk://ai links open the thread in the panel too.
            mouseClick(findChild(p, "aiThreadsButton"))
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
            // A figure from its preview joins this conversation as an image; no capture is saved.
            const captures = researchStore.captures.length, current = ai.threadId
            verify(ai.attachFigure({source: fixtureSource, page: 0, region: Qt.rect(.05, .5, .9, .25), label: "Figure 1"}))
            compare(ai.threadId, current)
            compare(ai.images[ai.images.length - 1].name, "Figure 1 · p. 1")
            compare(researchStore.captures.length, captures)
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
            pickModel(p, "aiModel-claude-claude-haiku-4-5")
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
            verify(ai.images[0].name.indexOf("Capture · p. 1") === 0)
            compare(ai.captureWanted, false)
            // The AI panel stays in front instead of switching to the shelf.
            tryCompare(findChild(workspace, "rightDock"), "activePanel", "ai")
            verify(ai.send("What does this region show?"))
            tryCompare(ai, "streaming", false, 10000)
            compare(ai.error, "")
            verify(ai.messages[ai.messages.length - 2].context.attachments.indexOf("image") >= 0)
            // A capture made the usual way still goes to the shelf only.
            compare(c.captureMode, false)
            researchStore.captureRegion(fixtureSource, 0, Qt.rect(.1, .5, .3, .1))
            wait(500)
            compare(ai.images.length, 0)
            // The reader toolbar has a capture button again.
            const button = findChild(workspace.currentReader, "readerCaptureButton")
            verify(button)
            button.clicked()
            compare(c.captureMode, true)
            button.clicked()
            compare(c.captureMode, false)
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
