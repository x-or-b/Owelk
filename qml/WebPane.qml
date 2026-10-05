import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine
import "WorkspaceTree.js" as Tree
import Owelk.Ui

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
    // A PDF shown inside the page (e.g. IEEE's getPDF.jsp frames it); found after each load.
    property string embeddedPdf: ""
    readonly property string pdfAddress: showsPdf ? view.url.toString() : embeddedPdf
    function detectEmbeddedPdf() {
        view.runJavaScript("(function(){var e=document.querySelector('embed[type=\"application/pdf\"],object[type=\"application/pdf\"],iframe[src*=\"pdf\" i],embed[src*=\"pdf\" i],object[data*=\"pdf\" i],frame[src*=\"pdf\" i]');return e?(e.src||e.data||''):'';})()",
            function(result) { root.embeddedPdf = typeof result === "string" && /^https?:/i.test(result) ? result : "" })
    }
    // Send the shown PDF to the reader: downloaded through this tab's session, opened beside it.
    function openPdfInReader() {
        if (!pdfAddress.length) return
        fetchPdf = true
        if (showsPdf) view.reload()
        else view.url = embeddedPdf
    }
    // The download in progress for this tab (WebEngineDownloadRequest), shown under the toolbar.
    property var download: null
    property bool downloadOpening: false
    signal downloadStarted(string fileName)
    signal activated()
    color: Theme.content
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
            color: Theme.window
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 4; anchors.rightMargin: 4
                spacing: 2
                IconButton { objectName: "webBack"; icon.name: "back"; implicitWidth: 24; description: "Back"; enabled: view.canGoBack; onClicked: view.goBack() }
                IconButton { objectName: "webForward"; icon.name: "forward"; implicitWidth: 24; description: "Forward"; enabled: view.canGoForward; onClicked: view.goForward() }
                IconButton {
                    objectName: "webReload"; icon.name: view.loading ? "close" : "reload"; implicitWidth: 24
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
                IconButton {
                    objectName: "webCapture"; icon.name: "capture"; implicitWidth: 24; checkable: true
                    checked: root.capturing
                    description: "Capture a region of this page"
                    onClicked: root.capturing = !root.capturing
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
                IconButton { icon.name: "more";
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
        // A page that shows a PDF: choose where to read it.
        Rectangle {
            objectName: "webPdfNotice"
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            visible: root.pdfAddress.length > 0 && root.download === null && !root.downloadOpening
            color: Theme.sidebar
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 4
                spacing: 6
                Label {
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    elide: Text.ElideRight; font.pixelSize: 12; color: Theme.text
                    text: root.browserPdf ? "Reading the PDF in this tab. Highlights, captures and notes work in the reader."
                                          : "This page shows a PDF."
                }
                UiControls.Button {
                    objectName: "webOpenInReader"
                    text: "Open in Reader"; highlighted: true
                    implicitHeight: 26
                    onClicked: root.openPdfInReader()
                }
                UiControls.Button {
                    objectName: "webShowPdfHere"
                    visible: !root.browserPdf
                    text: "Show Here"
                    implicitHeight: 26
                    ToolTip.visible: hovered; ToolTip.delay: 450
                    ToolTip.text: "Read PDFs in this web tab (More → Show PDFs in This Tab)"
                    onClicked: root.browserPdf = true
                }
            }
        }
        // Download progress: name, file size and a bar that fills with the bytes received. A server that
        // does not send the size gets no bar (only the size so far): a sliding bar would say nothing.
        Rectangle {
            id: downloadBar
            objectName: "webDownloadBar"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            visible: root.download !== null || root.downloadOpening
            color: Theme.sidebar
            readonly property real received: root.download ? root.download.receivedBytes : 0
            readonly property real total: root.download ? root.download.totalBytes : 0
            function size(bytes) { return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(bytes / 1024)) + " KB" }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 4
                spacing: 8
                BusyIndicator { visible: !fill.known; running: visible && downloadBar.visible; implicitWidth: 16; implicitHeight: 16 }
                Label {
                    objectName: "webDownloadLabel"
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    elide: Text.ElideMiddle; font.pixelSize: 12; color: Theme.text; textFormat: Text.PlainText
                    text: root.downloadOpening ? "Opening in the reader…"
                        : root.download ? "Downloading " + root.download.downloadFileName
                          + (downloadBar.total > 0 ? " · " + downloadBar.size(downloadBar.total)
                             : downloadBar.received > 0 ? " · " + downloadBar.size(downloadBar.received) : "")
                        : ""
                }
                Rectangle {
                    id: track
                    objectName: "webDownloadProgress"
                    visible: fill.known
                    readonly property real progress: fill.known ? Math.min(1, downloadBar.received / downloadBar.total) : 0
                    Layout.preferredWidth: Math.min(220, downloadBar.width / 3); Layout.preferredHeight: 5
                    radius: 2; color: Theme.separator
                    clip: true
                    Rectangle {
                        id: fill
                        height: parent.height; radius: 2; color: Theme.accent
                        readonly property bool known: downloadBar.total > 0
                        width: parent.width * track.progress
                        Behavior on width { NumberAnimation { duration: 150 } }
                    }
                }
                IconButton {
                    objectName: "webDownloadCancel"
                    visible: root.download !== null
                    icon.name: "close"; description: "Cancel download"
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
            onLoadingChanged: function(request) {
                if (request.status === WebEngineView.LoadStartedStatus) root.embeddedPdf = ""
                else if (request.status === WebEngineView.LoadSucceededStatus) root.detectEmbeddedPdf()
            }
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
