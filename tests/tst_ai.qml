import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "AiComposer"
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
        function test_explainSelectionAsksConsentStreamsAndSaves() {
            workspace.documents.restore({})
            workspace.openDocument(fixtureSource)
            const c = canvas()
            c.selectPage(0)
            verify(c.selectedText.length > 0)
            const composer = findChild(workspace, "aiComposer")
            // Without a key the composer explains what is missing and sends nothing.
            findChild(workspace.currentReader, "aiExplainSelection").triggered()
            tryCompare(composer, "opened", true)
            tryVerify(function() { return composer.error.indexOf("API key") >= 0 })
            verify(researchStore.ai.setApiKey("claude", "sk-ui-test-key"))
            // The first request to a provider shows what will be sent.
            mouseClick(findChild(composer, "aiSend"))
            const consent = findChild(workspace, "aiConsentDialog")
            tryCompare(consent, "opened", true)
            verify(composer.attachments.some(function(a) { return a.kind === "selection" }))
            verify(composer.attachments.some(function(a) { return a.kind === "paper" }))
            consent.accept()
            tryVerify(function() { return composer.answer === "Mock answer about **occlusion**." }, 10000)
            verify(researchStore.ai.consented("claude"))
            // Saving keeps the answer searchable and linked to the paper.
            mouseClick(findChild(composer, "aiSaveNote"))
            tryVerify(function() { return composer.savedId.length > 0 })
            const hits = researchStore.searchKnowledge("Mock answer")
            verify(hits.some(function(h) { return h.kind === "ai" }))
            verify(hits.some(function(h) { return h.kind === "standalone-note" }))
            const paper = researchStore.documentLinkId(fixtureSource)
            verify(researchStore.backlinks("document", paper).some(function(b) { return b.kind === "ai" }))
            // A saved answer reopens from search without a new request.
            composer.close()
            workspace.openSearchResult(hits.filter(function(h) { return h.kind === "ai" })[0])
            tryCompare(composer, "opened", true)
            compare(composer.showingSaved, true)
            compare(composer.answer, "Mock answer about **occlusion**.")
            composer.close()
        }
        function test_pageQuestionWaitsForTheReader() {
            const c = canvas()
            workspace.currentReader.requestAi("ask", "page")
            const composer = findChild(workspace, "aiComposer")
            tryCompare(composer, "opened", true)
            compare(composer.streaming, false) // A question is typed first.
            verify(composer.attachments.some(function(a) { return a.kind === "page" }))
            findChild(composer, "aiQuestion").text = "What is the main claim?"
            mouseClick(findChild(composer, "aiSend"))
            tryVerify(function() { return composer.answer.indexOf("Mock answer") === 0 }, 10000)
            composer.close()
        }
    }
}
