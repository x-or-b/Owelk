import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "AiPanel"
        when: windowShown
        function cleanupTestCase() { researchStore.ai.clearApiKey("claude"); workspace.visible = false }
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
        function test_1_explainSelectionOpensThePanelAndKeepsAThread() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.selectPage(0)
            verify(c.selectedText.length > 0)
            const ai = findChild(workspace, "aiController")
            compare(workspace.aiVisible, false)
            // Without a key the panel explains what is missing and sends nothing.
            findChild(workspace.currentReader, "aiExplainSelection").triggered()
            tryCompare(workspace, "aiVisible", true)
            compare(workspace.aiSide, "right") // The AI panel docks on the right by default.
            tryCompare(findChild(workspace, "rightDock"), "activePanel", "ai")
            const p = panel()
            tryVerify(function() { return ai.error.indexOf("API key") >= 0 })
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            // The first request to a provider shows what will be sent.
            mouseClick(findChild(p, "aiSend"))
            const consent = findChild(workspace, "aiConsentDialog")
            tryCompare(consent, "opened", true)
            verify(ai.attachments.some(function(a) { return a.kind === "selection" }))
            verify(ai.attachments.some(function(a) { return a.kind === "paper" }))
            consent.accept()
            tryCompare(ai, "streaming", false, 10000)
            verify(researchStore.ai.consented("claude"))
            // The turn is a thread: question and answer, searchable and linked to the paper.
            verify(ai.threadId.length > 0)
            compare(ai.messages.length, 2)
            compare(ai.messages[1].content, "Mock answer about **occlusion**.")
            compare(ai.messages[0].display, "Explain")
            const hits = researchStore.searchKnowledge("Mock answer")
            verify(hits.some(function(h) { return h.kind === "ai" && h.id === ai.threadId }))
            const paper = researchStore.documentLinkId(fixtureSource)
            verify(researchStore.backlinks("document", paper).some(function(b) { return b.kind === "ai" }))
            // A follow-up continues the same thread.
            const thread = ai.threadId
            const question = findChild(p, "aiQuestion")
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
            tryCompare(findChild(p, "aiModelButton"), "text", "Claude Opus 5.5 ▾")
            // Opus: effort levels and fast mode.
            tryCompare(effort, "visible", true)
            compare(effort.text, "Medium ▾")
            compare(fast.visible, true)
            mouseClick(effort)
            const levels = findChild(p, "aiEffortMenu")
            tryCompare(levels, "opened", true)
            tryVerify(function() { return findChild(levels, "aiEffort-xhigh") !== null })
            findChild(levels, "aiEffort-xhigh").triggered()
            levels.close(); tryCompare(levels, "visible", false)
            compare(ai.effectiveEffort, "xhigh")
            compare(effort.text, "Extra high ▾")
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
            ai.attach("page")
            verify(ai.attachments.some(function(a) { return a.kind === "page" }))
            ai.detach("page")
            verify(!ai.attachments.some(function(a) { return a.kind === "page" }))
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
        function test_7_agentsInstallFromSettingsAndJoinThePanel() {
            const p = panel()
            // Not installed: agents stay out of the model picker.
            mouseClick(findChild(p, "aiModelButton"))
            const menu = findChild(p, "aiModelMenu")
            tryCompare(menu, "opened", true)
            verify(findChild(menu.contentItem, "aiModel-codex-agent-fast") === null)
            menu.close(); tryCompare(menu, "opened", false)
            const settings = findChild(workspace, "settingsDialog")
            settings.open(); tryCompare(settings, "opened", true)
            researchStore.ai.provider = "codex-agent"
            const install = findChild(settings, "agentInstall")
            tryCompare(install, "visible", true)
            compare(install.text, "Install…")
            install.clicked()
            const confirm = findChild(workspace, "agentInstallConfirm")
            tryCompare(confirm, "opened", true)
            confirm.reject()
            tryCompare(confirm, "opened", false)
            // Installed (a stand-in agent): it signs in on its own and joins the panel.
            testInput.setEnvironment("OWELK_ACP_COMMAND", testInput.sourcePath("fake_acp.py"))
            researchStore.ai.provider = "claude"
            researchStore.ai.provider = "codex-agent"
            tryCompare(install, "text", "Update")
            const content = settings.contentItem
            tryVerify(function() { return visualChild(content, "agentAuth-browser") !== null }, 5000)
            visualChild(content, "agentAuth-browser").clicked()
            tryVerify(function() { return visualChild(content, "agentAuth-browser") === null }, 5000)
            settings.close()
            const ai = findChild(workspace, "aiController")
            // Signed in: the agent's own models appear under its name.
            pickModel(p, "aiModel-codex-agent-fast")
            tryCompare(researchStore.ai, "provider", "codex-agent")
            tryCompare(findChild(p, "aiEffortButton"), "visible", false)
            researchStore.ai.giveConsent("codex-agent")
            mouseClick(findChild(p, "aiNewThread"))
            verify(ai.send("Hello agent"))
            tryCompare(ai, "streaming", false, 10000)
            compare(ai.error, "")
            compare(ai.messages[ai.messages.length - 1].content, "Agent answer (declined, fast)")
            researchStore.ai.provider = "claude"
            testInput.setEnvironment("OWELK_ACP_COMMAND", "")
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
            const url = "file://" + folder + "/figure.png"
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
    }
}
