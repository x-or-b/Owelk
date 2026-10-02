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
    // PDFs from the web open in the reader (downloaded first) unless this tab shows them in place.
    property bool browserPdf: researchStore.setting("webPdfMode", "reader") === "browser"
    // One-off: download the PDF shown in this tab and open it in the reader.
    property bool fetchPdf: false
    readonly property bool showsPdf: /\.pdf([?#]|$)/i.test(view.url.toString()) || Tree.arxivPdf(view.url).length === 0 && /arxiv\.org\/pdf\//i.test(view.url.toString())
    // The download in progress for this tab (WebEngineDownloadRequest), shown under the toolbar.
    property var download: null
    property bool downloadOpening: false
    signal downloadStarted(string fileName)
    signal activated()
    color: Theme.surface
    property bool capturing: false
    // Screenshot the visible page and keep the chosen part (normalised to the view).
    function captureRegion(rect) {
        const region = Qt.rect(rect.x / view.width, rect.y / view.height, rect.width / view.width, rect.height / view.height)
        view.grabToImage(function(result) {
            researchStore.captureWebImage(view.url, view.title, result.image, region)
        })
        capturing = false
    }
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
            const fetched = root.fetchPdf
            root.fetchPdf = false
            download.isFinishedChanged.connect(function() {
                if (root.download === download) root.download = null
                if (download.state === WebEngineDownloadRequest.DownloadCompleted) {
                    // A PDF shown in this tab opens beside it; the tab stays on the page.
                    if (pdf) {
                        root.downloadOpening = true
                        Qt.callLater(function() { root.downloadOpening = false; root.controller.openDownloaded(root.tabId, target.url, replace && !fetched) })
                    } else researchStore.notify("Saved " + target.fileName + " to " + target.directory)
                } else if (download.state === WebEngineDownloadRequest.DownloadInterrupted) {
                    researchStore.notify("Download failed: " + download.interruptReasonString)
                } else if (download.state === WebEngineDownloadRequest.DownloadCancelled) {
                    researchStore.notify("Download cancelled.")
                }
            })
            root.download = download
            root.downloadStarted(target.fileName)
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
                ReaderIconButton {
                    objectName: "webCapture"; kind: "capture"; implicitWidth: 24; checkable: true
                    checked: root.capturing
                    description: "Capture a region of this page"
                    onClicked: root.capturing = !root.capturing
                }
                UiControls.Button {
                    objectName: "webOpenInReader"
                    visible: root.showsPdf && view.settings.pdfViewerEnabled
                    text: "Open in Reader"
                    Layout.preferredHeight: 25
                    ToolTip.visible: hovered; ToolTip.delay: 450
                    ToolTip.text: "Download this PDF and read it in Owelk (highlights, captures and notes work there)"
                    onClicked: { root.fetchPdf = true; view.reload() }
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
                        UiControls.MenuItem {
                            objectName: "webBrowserPdf"
                            text: "Show PDFs in This Tab"
                            checkable: true; checked: root.browserPdf
                            onTriggered: root.browserPdf = checked
                        }
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
        // Download progress: name, bytes, a bar (sliding while the size is unknown) and Cancel.
        Rectangle {
            id: downloadBar
            objectName: "webDownloadBar"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            visible: root.download !== null || root.downloadOpening
            color: Theme.surfacePanel
            readonly property real received: root.download ? root.download.receivedBytes : 0
            readonly property real total: root.download ? root.download.totalBytes : 0
            function size(bytes) { return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(bytes / 1024)) + " KB" }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 4
                spacing: 8
                BusyIndicator { running: downloadBar.visible; implicitWidth: 16; implicitHeight: 16 }
                Label {
                    objectName: "webDownloadLabel"
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    elide: Text.ElideMiddle; font.pixelSize: 12; color: Theme.textBody; textFormat: Text.PlainText
                    text: root.downloadOpening ? "Opening in the reader…"
                        : root.download ? "Downloading " + root.download.downloadFileName
                          + (downloadBar.received > 0 ? " · " + downloadBar.size(downloadBar.received) + (downloadBar.total > 0 ? " of " + downloadBar.size(downloadBar.total) : "") : "")
                        : ""
                }
                Rectangle {
                    id: track
                    Layout.preferredWidth: Math.min(160, downloadBar.width / 4); Layout.preferredHeight: 4
                    radius: 2; color: Theme.border
                    clip: true
                    Rectangle {
                        id: fill
                        height: parent.height; radius: 2; color: Theme.accent
                        readonly property bool known: downloadBar.total > 0
                        onKnownChanged: if (known) x = 0
                        width: known ? parent.width * Math.min(1, downloadBar.received / downloadBar.total) : parent.width / 3
                        SequentialAnimation on x {
                            running: downloadBar.visible && !fill.known
                            loops: Animation.Infinite
                            NumberAnimation { from: -track.width / 3; to: track.width; duration: 1100; easing.type: Easing.InOutQuad }
                        }
                    }
                }
                UiControls.ToolButton {
                    objectName: "webDownloadCancel"
                    visible: root.download !== null
                    text: "Cancel"; implicitHeight: 24; font.pixelSize: 11
                    onClicked: root.download.cancel()
                }
            }
        }
        WebEngineView {
            id: view
            objectName: "webView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            profile: root.controller.webProfile
            // PDFs go to the reader rather than Chromium's viewer, unless this tab shows them in place.
            settings.pdfViewerEnabled: root.browserPdf && !root.fetchPdf
            // Chromium's PDF viewer is a built-in plugin.
            settings.pluginsEnabled: root.browserPdf
            onUrlChanged: if (root.tabId.length) root.controller.updateWebTab(root.tabId, url.toString(), title)
            onTitleChanged: if (root.tabId.length) root.controller.updateWebTab(root.tabId, url.toString(), title)
            onNewWindowRequested: function(request) { root.controller.openWeb(request.requestedUrl.toString(), true) }
            onActiveFocusChanged: if (activeFocus) root.activated()
            MouseArea {
                id: captureArea
                objectName: "webCaptureArea"
                anchors.fill: parent
                visible: root.capturing
                cursorShape: Qt.CrossCursor
                property point start
                property point end
                onPressed: function(mouse) { start = Qt.point(mouse.x, mouse.y); end = start }
                onPositionChanged: function(mouse) { end = Qt.point(Math.max(0, Math.min(width, mouse.x)), Math.max(0, Math.min(height, mouse.y))) }
                onReleased: root.captureRegion(Qt.rect(Math.min(start.x, end.x), Math.min(start.y, end.y), Math.abs(end.x - start.x), Math.abs(end.y - start.y)))
                Rectangle {
                    visible: captureArea.pressed
                    x: Math.min(captureArea.start.x, captureArea.end.x); y: Math.min(captureArea.start.y, captureArea.end.y)
                    width: Math.abs(captureArea.end.x - captureArea.start.x); height: Math.abs(captureArea.end.y - captureArea.start.y)
                    color: "transparent"; border.color: Theme.accent; border.width: 2
                }
            }
        }
    }
}
