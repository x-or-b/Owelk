import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine
import "WorkspaceTree.js" as Tree
import "UiTheme.js" as Theme

// A web page inside a tab. PDFs reached here are downloaded through the page's own session
// (so institution logins keep working) and open in the reader.
Rectangle {
    id: root
    objectName: "webPane"
    required property var controller
    property string tabId: ""
    property bool isActive: false
    // The address this tab was opened with; a PDF fetched from it replaces the tab instead of opening beside it.
    property string openedUrl: ""
    readonly property alias view: view
    signal activated()
    color: Theme.surface
    function open(url) {
        if (openedUrl === url.toString() && view.url.toString() === url.toString()) return
        openedUrl = url.toString()
        view.url = url
    }
    function go(text) {
        const url = Tree.addressToUrl(text, researchStore.setting("searchEngine", "https://scholar.google.com/scholar?q=%s"))
        if (url.length) { view.url = url; view.forceActiveFocus() }
    }
    function focusAddress() { address.forceActiveFocus(); address.selectAll() }
    function isPdf(download) {
        return download.mimeType === "application/pdf" || /\.pdf$/i.test(download.suggestedFileName || "")
            || /\.pdf([?#]|$)/i.test(download.url.toString())
    }
    Connections {
        target: root.controller.webProfile
        function onDownloadRequested(download) {
            // The profile is shared by every web tab; handle only this view's downloads.
            if (download.view !== undefined && download.view !== null && download.view !== view) return
            if ((download.view === undefined || download.view === null) && !root.isActive) return
            const pdf = root.isPdf(download)
            const target = researchStore.downloadTarget(download.suggestedFileName || (pdf ? "download.pdf" : "download"))
            download.downloadDirectory = target.directory
            download.downloadFileName = target.fileName
            const replace = !view.canGoBack && download.url.toString() === root.openedUrl
            download.isFinishedChanged.connect(function() {
                if (download.state === WebEngineDownloadRequest.DownloadCompleted) {
                    if (pdf) root.controller.openDownloaded(root.tabId, target.url, replace)
                    else researchStore.notify("Saved " + target.fileName + " to " + target.directory)
                } else if (download.state === WebEngineDownloadRequest.DownloadInterrupted) {
                    researchStore.notify("Download failed: " + download.interruptReasonString)
                }
            })
            download.accept()
        }
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            color: Theme.surfaceAlt
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4
                spacing: 2
                ReaderIconButton { objectName: "webBack"; kind: "back"; implicitWidth: 24; description: "Back"; enabled: view.canGoBack; onClicked: view.goBack() }
                ReaderIconButton { objectName: "webForward"; kind: "forward"; implicitWidth: 24; description: "Forward"; enabled: view.canGoForward; onClicked: view.goForward() }
                ReaderIconButton {
                    objectName: "webReload"; kind: view.loading ? "close" : "reload"; implicitWidth: 24
                    description: view.loading ? "Stop" : "Reload"
                    onClicked: view.loading ? view.stop() : view.reload()
                }
                UiControls.TextField {
                    id: address
                    objectName: "webAddress"
                    Layout.fillWidth: true; Layout.preferredHeight: 25
                    placeholderText: "Address or search"
                    selectByMouse: true
                    font.pixelSize: 12
                    text: activeFocus ? text : view.url.toString()
                    onActiveFocusChanged: if (activeFocus) { root.activated(); text = view.url.toString(); selectAll() }
                    onAccepted: root.go(text)
                    Keys.onEscapePressed: { text = view.url.toString(); view.forceActiveFocus() }
                }
                UiControls.Button {
                    objectName: "webOpenArxivPdf"
                    visible: Tree.arxivPdf(view.url).length > 0
                    text: "Open PDF"
                    Layout.preferredHeight: 25
                    ToolTip.visible: hovered; ToolTip.delay: 450
                    ToolTip.text: "Download this paper and open it in the reader"
                    onClicked: view.url = Tree.arxivPdf(view.url)
                }
                ReaderIconButton {
                    implicitWidth: 24; description: "More"
                    onClicked: webMenu.popup(this, 0, height)
                    UiControls.Menu {
                        id: webMenu
                        UiControls.MenuItem { text: "Open in Browser"; onTriggered: Qt.openUrlExternally(view.url) }
                        UiControls.MenuItem { text: "Copy Address"; onTriggered: researchStore.copyText(view.url.toString()) }
                    }
                }
            }
            Rectangle {
                anchors.left: parent.left; anchors.bottom: parent.bottom
                height: 2; width: parent.width * view.loadProgress / 100
                visible: view.loading
                color: Theme.accent
            }
        }
        WebEngineView {
            id: view
            objectName: "webView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            profile: root.controller.webProfile
            // PDFs go to the reader rather than Chromium's viewer.
            settings.pdfViewerEnabled: false
            onUrlChanged: if (root.tabId.length) root.controller.updateWebTab(root.tabId, url.toString(), title)
            onTitleChanged: if (root.tabId.length) root.controller.updateWebTab(root.tabId, url.toString(), title)
            onNewWindowRequested: function(request) { root.controller.openWeb(request.requestedUrl.toString(), true) }
            onActiveFocusChanged: if (activeFocus) root.activated()
        }
    }
}
