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
        function test_3_modelMenuListsProviderModels() {
            const ai = findChild(workspace, "aiController")
            const p = panel()
            const button = findChild(p, "aiModelButton")
            mouseClick(button)
            const menu = findChild(p, "aiModelMenu")
            tryCompare(menu, "opened", true)
            tryVerify(function() { return findChild(menu.contentItem, "aiModel-claude-claude-sonnet-5-5") !== null })
            const sonnet = findChild(menu.contentItem, "aiModel-claude-claude-sonnet-5-5")
            sonnet.clicked()
            tryCompare(researchStore.ai, "provider", "claude")
            tryVerify(function() { return researchStore.ai.model("claude") === "claude-sonnet-5-5" })
            compare(researchStore.ai.provider, "claude")
            verify(button.text.indexOf("claude-sonnet-5-5") >= 0)
            tryCompare(menu, "opened", false)
            researchStore.ai.setModel("claude", "claude-opus-5-5")
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
            // Provider and model controls stay reachable at this width.
            for (const id of ["claude", "openai", "codex", "ollama"]) {
                const button = findChild(p, "aiProvider-" + id)
                verify(button && button.visible && button.width > 20, id)
            }
            verify(findChild(p, "aiModelButton").width > 60)
            mouseClick(findChild(p, "aiProvider-ollama"))
            tryCompare(researchStore.ai, "provider", "ollama")
            compare(findChild(p, "aiProvider-ollama").checked, true)
            // A provider without a key says where to set it up.
            verify(researchStore.ai.clearApiKey("claude"))
            waitForPolish(p); wait(20)
            mouseClick(findChild(p, "aiProvider-claude"))
            tryCompare(researchStore.ai, "provider", "claude")
            tryVerify(function() { return ai.error.indexOf("Settings") >= 0 })
            verify(findChild(p, "aiOpenSettings").visible)
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            workspace.rightDockWidth = 224
        }
    }
}
