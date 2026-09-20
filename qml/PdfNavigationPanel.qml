import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Pdf

Item {
    id: root
    objectName: "pdfNavigationPanel"
    property var reader: null
    property int mode: 0
    signal modeChosen(int mode)
    readonly property bool ready: !!reader && reader.pdfReady
    PdfDocument { id: emptyDocument }
    // A blank document also avoids passing null to an active Qt PDF image/model during tab removal.
    readonly property var navigationDocument: reader && reader.pdfDocument ? reader.pdfDocument : emptyDocument
    function go(page, location) {
        if (!ready || page < 0 || page >= reader.pageCount) return
        const size = reader.pdfDocument.pagePointSize(page)
        reader.jumpToPage(page, location ? Math.max(0, location.y / size.height) : 0)
    }
    PdfBookmarkModel { id: bookmarks; document: root.navigationDocument }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8
        Label {
            Layout.fillWidth: true
            text: root.reader && root.reader.source.toString().length ? researchStore.fileName(root.reader.source) : "No active PDF"
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            font.pixelSize: 12
            color: "#555555"
        }
        TabBar {
            objectName: "navigationMode"
            Layout.fillWidth: true
            currentIndex: root.mode
            TabButton {
                id: outlineTab
                objectName: "outlineTab"
                text: "Outline"
                background: Rectangle { color: outlineTab.checked ? "#d8d8d8" : "#f5f5f5"; border.color: "#cccccc" }
                onClicked: root.modeChosen(0)
            }
            TabButton {
                id: thumbnailsTab
                objectName: "thumbnailsTab"
                text: "Thumbnails"
                background: Rectangle { color: thumbnailsTab.checked ? "#d8d8d8" : "#f5f5f5"; border.color: "#cccccc" }
                onClicked: root.modeChosen(1)
            }
        }
        TreeView {
            id: outline
            objectName: "pdfOutline"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 0 && root.ready
            model: bookmarks
            clip: true
            columnWidthProvider: function(column) { return width }
            ScrollBar.vertical: ScrollBar {}
            delegate: TreeViewDelegate {
                required property string title
                required property int page
                required property point location
                implicitHeight: 34
                implicitWidth: outline.width
                text: title
                onClicked: root.go(page, location)
                ToolTip.visible: hovered
                ToolTip.text: title + " · Page " + (page + 1)
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: outline.rows === 0
                text: "This PDF has no embedded outline.\nUse Thumbnails to navigate."
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                color: "#777777"
            }
        }
        ListView {
            id: thumbs
            objectName: "pdfThumbnails"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === 1 && root.ready
            model: visible ? root.reader.pageCount : 0
            currentIndex: root.ready ? root.reader.currentPage : -1
            onCurrentIndexChanged: if (visible && currentIndex >= 0) Qt.callLater(function() { thumbs.positionViewAtIndex(thumbs.currentIndex, ListView.Contain) })
            onVisibleChanged: if (visible && currentIndex >= 0) Qt.callLater(function() { thumbs.positionViewAtIndex(thumbs.currentIndex, ListView.Contain) })
            clip: true
            cacheBuffer: 180
            reuseItems: true
            spacing: 10
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                id: thumb
                required property int index
                objectName: "thumbnail-" + index
                width: thumbs.width
                height: preview.height + 30
                padding: 6
                onClicked: root.go(index, null)
                background: Rectangle { color: "#f5f5f5"; border.color: root.reader && root.reader.currentPage === thumb.index ? "#777777" : "#dddddd"; radius: 2 }
                contentItem: Column {
                    spacing: 4
                    PdfPageImage {
                        id: preview
                        objectName: "thumbnailImage-" + thumb.index
                        readonly property size points: root.ready ? root.reader.pdfDocument.pagePointSize(thumb.index) : Qt.size(595, 842)
                        width: thumb.width - 12
                        height: Math.min(250, width * points.height / Math.max(1, points.width))
                        document: root.navigationDocument
                        currentFrame: thumb.index
                        asynchronous: true
                        cache: false
                        sourceSize.width: Math.min(440, Math.ceil(width * Screen.devicePixelRatio))
                        fillMode: Image.PreserveAspectFit
                    }
                    Label { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: thumb.index + 1; font.pixelSize: 11; color: "#666666" }
                }
            }
        }
        Label {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.ready
            text: root.reader && root.reader.source.toString().length ? "PDF is unavailable or still loading." : "Open a PDF to see its outline and pages."
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: "#777777"
        }
    }
}
