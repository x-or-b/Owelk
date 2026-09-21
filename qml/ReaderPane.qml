import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Rectangle {
    id: root
    property int paneIndex: 0
    property bool isActive: false
    property bool managed: false
    property alias source: canvas.source
    property alias pdfDocument: canvas.document
    readonly property bool pdfReady: canvas.ready
    readonly property int currentPage: canvas.currentPage
    readonly property int pageCount: canvas.pageCount
    property alias selectedText: canvas.selectedText
    property var sourceToReveal: null
    property bool searchVisible: false
    signal activated()
    signal changed()
    signal documentAboutToOpen()
    signal documentOpened()
    signal fileChosen(url source)
    color: "#e8e8e8"
    border.color: isActive ? "#888888" : "#d6d6d6"

    function chooseFile() { fileDialog.open() }
    function cancelReveal() { revealTimer.stop(); sourceToReveal = null }
    function openFile(url, position) {
        if (!researchStore.rememberDocument(url)) return false
        cancelReveal()
        documentAboutToOpen()
        hideSearch()
        canvas.openFile(url, position || researchStore.readingPosition(url))
        activated()
        changed()
        documentOpened()
        return true
    }
    function restore(state) {
        cancelReveal()
        hideSearch()
        if (state && state.source) canvas.openFile(state.source, state.position)
        else canvas.openFile("", {page: 0, y: 0, x: 0, zoom: 1})
    }
    function state() {
        return {source: source.toString(), position: canvas.position()}
    }
    function find() {
        if (!canvas.ready) return
        activated()
        searchVisible = true
        Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
    }
    function hideSearch() {
        searchDelay.stop()
        searchField.clear()
        canvas.searchString = ""
        searchVisible = false
        canvas.forceActiveFocus()
    }
    function zoom(multiplier) { canvas.zoom(multiplier) }
    function fitWidth() { canvas.fitWidth() }
    function jumpToPage(page, y) { activated(); canvas.jump(page, y || 0, 0) }
    function copySelection() { canvas.copySelection() }
    function captureSelection() { canvas.captureSelection() }
    function toggleCapture() { if (canvas.ready) canvas.captureMode = !canvas.captureMode }
    function reveal(url, page, region) {
        cancelReveal()
        if (!researchStore.sameSource(source, url)) {
            // Managed readers belong to a tab: never replace its PDF behind the controller's back.
            if (managed || !openFile(url, {page: page, y: Math.max(0, region.y - .08), x: 0, zoom: 1})) return
        }
        hideSearch()
        sourceToReveal = {source: url.toString(), page: page, region: region}
        revealTimer.restart()
    }

    Timer {
        id: revealTimer
        interval: 180
        repeat: true
        onTriggered: {
            if (!root.sourceToReveal || canvas.error.length
                || !researchStore.sameSource(root.sourceToReveal.source, canvas.source)) { root.cancelReveal(); return }
            if (canvas.ready && !canvas.restoring) {
                canvas.showSource(root.sourceToReveal.page, root.sourceToReveal.region)
                root.sourceToReveal = null
                stop()
            }
        }
    }

    FileDialog {
        id: fileDialog
        title: "Open PDF"
        nameFilters: ["PDF documents (*.pdf)"]
        onAccepted: { if (root.managed) root.fileChosen(selectedFile); else root.openFile(selectedFile) }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0

        Rectangle {
            visible: !root.managed
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 48 : 0
            color: "#ffffff"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 10
                spacing: 8
                Label {
                    text: root.paneIndex === 0 ? "A" : "B"
                    color: "#555555"
                    font.bold: true
                    font.pixelSize: 12
                }
                Label {
                    Layout.fillWidth: true
                    text: root.source.toString().length ? researchStore.fileName(root.source) : "No document"
                    elide: Text.ElideMiddle
                    color: "#242424"
                    font.weight: Font.Medium
                }
                Button { text: "Open"; onClicked: root.chooseFile() }
            }
        }

        Rectangle {
            visible: canvas.ready
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 43 : 0
            color: "#f5f5f5"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: 4
                TextField {
                    id: pageField
                    Layout.preferredWidth: 42
                    horizontalAlignment: Text.AlignHCenter
                    text: (canvas.currentPage + 1).toString()
                    onActiveFocusChanged: if (activeFocus) root.activated()
                    validator: IntValidator { bottom: 1; top: Math.max(1, canvas.pageCount) }
                    onAccepted: {
                        canvas.jump(Number(text) - 1, 0, 0)
                        focus = false
                    }
                }
                Label { text: "/ " + canvas.pageCount; color: "#666666" }
                Item { Layout.fillWidth: true }
                ToolButton { text: "−"; onClicked: { root.activated(); canvas.zoom(1 / 1.2) } }
                ToolButton {
                    text: Math.round(canvas.zoomFactor * 100) + "%"
                    onClicked: { root.activated(); canvas.fitWidth() }
                    ToolTip.visible: hovered
                    ToolTip.text: "Click to fit width · Ctrl+wheel to zoom"
                }
                ToolButton { text: "+"; onClicked: { root.activated(); canvas.zoom(1.2) } }
                Button {
                    text: "Capture region"
                    checkable: true
                    checked: canvas.captureMode
                    onClicked: { root.activated(); canvas.captureMode = checked }
                }
                ToolButton {
                    objectName: "saveExcerptButton"
                    text: "Save excerpt"
                    visible: canvas.selectedText.length > 0
                    enabled: canvas.selectedAnchor !== null && !canvas.selecting && !researchStore.busy
                    onClicked: { root.activated(); canvas.captureSelection() }
                    ToolTip.visible: hovered
                    ToolTip.text: "Save selected text with its source location"
                }
                ToolButton {
                    text: "Copy"
                    enabled: canvas.selectedText.length > 0
                    onClicked: { root.activated(); canvas.copySelection() }
                }
            }
        }

        RowLayout {
            objectName: "searchBar"
            visible: canvas.ready && root.searchVisible
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.topMargin: visible ? 6 : 0
            Layout.bottomMargin: visible ? 6 : 0
            spacing: 4
            TextField {
                id: searchField
                objectName: "searchField"
                Layout.fillWidth: true
                placeholderText: "Find in document"
                selectByMouse: true
                onTextEdited: searchDelay.restart()
                onActiveFocusChanged: if (activeFocus) root.activated()
                onAccepted: {
                    searchDelay.stop()
                    if (canvas.searchString !== text) canvas.searchString = text
                    else canvas.nextMatch(1)
                }
                Keys.onEscapePressed: root.hideSearch()
            }
            Label {
                text: canvas.searchString.length ? (canvas.matchCount ? (canvas.currentMatch + 1) + "/" + canvas.matchCount : "0") : ""
                color: "#666666"
            }
            ToolButton { text: "↑"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(-1) }
            ToolButton { text: "↓"; enabled: canvas.matchCount > 0; onClicked: canvas.nextMatch(1) }
            ToolButton {
                text: "×"
                onClicked: root.hideSearch()
                ToolTip.visible: hovered
                ToolTip.text: "Close search (Esc)"
                Accessible.name: "Close search"
            }
        }

        Label {
            visible: canvas.captureMode
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.bottomMargin: 6
            text: "Drag a region to capture · Esc to cancel"
            color: "#444444"
            font.pixelSize: 11
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            PdfCanvas {
                id: canvas
                objectName: "pdfCanvas" + root.paneIndex
                anchors.fill: parent
                onActivated: root.activated()
                onPositionChanged: root.changed()
                onRegionSelected: function(page, rect) {
                    researchStore.captureRegion(source, page, rect)
                    captureMode = false
                }
                onSourceChanged: {
                    searchDelay.stop()
                    searchField.clear()
                    root.searchVisible = false
                }
            }

            ColumnLayout {
                visible: !canvas.source.toString().length || canvas.error.length > 0
                anchors.centerIn: parent
                width: Math.min(parent.width - 48, 320)
                spacing: 14
                Label {
                    Layout.fillWidth: true
                    text: canvas.error.length ? "Cannot open document" : "Open PDF"
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 16
                    font.weight: Font.Medium
                    color: "#333333"
                }
                Label {
                    Layout.fillWidth: true
                    text: canvas.error.length ? canvas.error : (root.paneIndex === 0 ? "Drop a PDF here or choose a file." : "Open another PDF to compare.\nYou can open the same document twice.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: "#666666"
                    lineHeight: 1.4
                }
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Open PDF"
                    onClicked: root.chooseFile()
                }
                Button {
                    Layout.alignment: Qt.AlignHCenter
                    visible: canvas.error.length > 0 && root.source.toString().length > 0
                    text: "Locate Original PDF…"
                    onClicked: researchStore.requestRelink(root.source)
                }
            }

            DropArea {
                anchors.fill: parent
                onDropped: function(drop) {
                    if (drop.hasUrls && /\.pdf$/i.test(drop.urls[0].toString())) {
                        if (root.managed) root.fileChosen(drop.urls[0]); else root.openFile(drop.urls[0])
                        drop.acceptProposedAction()
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    visible: parent.containsDrag
                    color: "#22555555"
                    border.color: "#555555"
                    border.width: 2
                }
            }
        }
    }
    Timer { id: searchDelay; interval: 220; onTriggered: canvas.searchString = searchField.text }
    Shortcut {
        sequences: [StandardKey.Copy]
        enabled: root.isActive && canvas.selectedText.length > 0 && !searchField.activeFocus && !pageField.activeFocus
        onActivated: canvas.copySelection()
    }
    Shortcut {
        sequence: "Escape"
        enabled: root.isActive && canvas.captureMode
        onActivated: canvas.captureMode = false
    }
}
