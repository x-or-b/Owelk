import QtQuick
import QtTest
import "../qml" as App
import "../qml/WorkspaceTree.js" as Tree

Item {
    width: 1440; height: 930
    App.Main { id: workspace }
    TestCase {
        name: "SourceRelink"
        when: windowShown
        property var fixture
        function init() {
            workspace.documents.restore({}); workspace.activeWorkspace = ""; workspace.homeVisible = true
            fixture = testInput.relinkFixture()
            workspace.openDocument(fixture.source, {page: 3,y: .1,x: 0,zoom: 1.2})
            canvas()
            tryCompare(researchStore.paperIndex,"busy",false,10000)
        }
        function canvas() {
            tryVerify(function() { return workspace.currentReader !== null })
            const c = findChild(workspace.currentReader,"pdfCanvas0")
            tryCompare(c,"ready",true); tryCompare(c,"restoring",false)
            return c
        }
        function cleanup() { findChild(workspace,"relinkDialog").close() }
        function cleanupTestCase() { workspace.visible = false }
        function test_confirmUpdatesSplitsAndClosedTabs() {
            const d = workspace.documents
            d.duplicateSplit("right"); canvas()
            d.closeActiveTab(); canvas()
            compare(d.closedTabs.length,1)
            const activeId = Tree.leaves(d.tree)[0].activeTab
            researchStore.requestRelink(fixture.source)
            const dialog = findChild(workspace,"relinkDialog")
            tryCompare(dialog,"opened",true)
            dialog.candidate = fixture.candidate
            mouseClick(findChild(dialog,"verifyRelink"))
            tryCompare(dialog,"visible",false,10000)
            tryCompare(researchStore.paperIndex,"busy",false,10000)
            compare(workspace.currentReader.source.toString(),fixture.candidate.toString())
            compare(canvas().currentPage,3)
            fuzzyCompare(canvas().zoomFactor,1.2,.01)
            compare(Tree.leaves(d.tree)[0].activeTab,activeId)
            compare(d.closedTabs[0].tab.source,fixture.candidate.toString())
            d.reopenClosedTab(); canvas()
            compare(workspace.currentReader.source.toString(),fixture.candidate.toString())
            workspace.persist()
            verify(JSON.stringify(researchStore.session).indexOf(fixture.source.toString()) < 0)
        }
        function test_cancelDoesNotChangeReferences() {
            researchStore.requestRelink(fixture.source)
            const dialog = findChild(workspace,"relinkDialog")
            tryCompare(dialog,"opened",true); dialog.candidate = fixture.candidate; dialog.reject()
            tryCompare(dialog,"visible",false)
            compare(researchStore.resolvedSource(fixture.source).toString(),fixture.source.toString())
            compare(workspace.currentReader.source.toString(),fixture.source.toString())
        }
        function test_wrongCandidateStaysOpenWithExplanation() {
            researchStore.requestRelink(fixture.source)
            const dialog = findChild(workspace,"relinkDialog")
            tryCompare(dialog,"opened",true); dialog.candidate = fixture.wrong
            mouseClick(findChild(dialog,"verifyRelink"))
            tryVerify(function() { return dialog.detail.indexOf("not byte-for-byte") >= 0 },10000)
            compare(dialog.visible,true)
            compare(workspace.currentReader.source.toString(),fixture.source.toString())
        }
    }
}
