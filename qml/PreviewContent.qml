import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import Owelk.Ui

// A page of the PDF scrolled to what spec points at (a figure, table, equation or reference entry): the page
// view of a reference preview and of a pinned card (PdfCanvas). It scrolls on its own (wheel, trackpad, drag);
// pinch and Ctrl+wheel (also Cmd+wheel on macOS) zoom it; a click asks to go to the place it shows.
Flickable {
    id: view
    property var document: null
    // {page, y, kind, rect (the entry, caption or equation, in points), float (a figure or table with its
    // caption, ReferenceFinder::floatRegion)}.
    property var spec: ({page: 0, y: 0})
    property bool inverted: false
    // How far inside its card the view sits (the card's rounded outline).
    property int inset: 4
    signal goRequested(int page, real top)
    readonly property bool showsFloat: spec.kind === "figure" || spec.kind === "table"
    // A figure or table found with its caption: shown whole, fitted to the card's width, with no outline.
    readonly property var area: showsFloat && spec.float ? spec.float : null
    readonly property real fitScale: area ? (width + 2 * inset - 16) / Math.max(1, area.width) : 1
    // The reader's zoom, on top of the fit (40% to 500%).
    property real zoom: 1
    onSpecChanged: { zoom = 1; Qt.callLater(place) }
    function setZoom(next) {
        const fx = (contentX + width / 2) / Math.max(1, contentWidth), fy = (contentY + height / 2) / Math.max(1, contentHeight)
        zoom = Math.max(.4, Math.min(5, next))
        // The middle of the view stays on the same spot of the page.
        Qt.callLater(function() {
            contentX = Math.max(0, Math.min(contentWidth - width, fx * contentWidth - width / 2))
            contentY = Math.max(0, Math.min(contentHeight - height, fy * contentHeight - height / 2))
        })
    }
    readonly property size points: document ? document.pagePointSize(spec.page) : Qt.size(0, 0)
    readonly property rect target: spec.rect || Qt.rect(0, 0, 0, 0)
    // A found figure or table fills the width; otherwise a caption line is about as wide as its column, so
    // that column fills the view.
    readonly property real pageZoom: (area ? points.width * fitScale / Math.max(1, width)
        : showsFloat && target.width > 0 && points.width > 0
        ? Math.max(1, Math.min(2.2, points.width / (Math.max(target.width, points.width * .42) + 28))) : 1) * zoom
    readonly property real scale: width * pageZoom / Math.max(1, points.width)
    contentWidth: page.width; contentHeight: page.height
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    // Figures: caption at the bottom, the figure above it. Tables: caption at the top, the table below.
    // Anything else: the target a little below the top, with context above.
    function place() {
        const s = scale, a = target
        // 8 from the card's edges.
        if (area) {
            const room = 8 - inset
            contentX = Math.max(0, Math.min(contentWidth - width, area.x * s - room))
            contentY = Math.max(0, Math.min(contentHeight - height, area.y * s - room))
            return
        }
        const x = showsFloat && a.width > 0 ? a.x * s - 14 : 0
        const y = spec.kind === "figure" && a.height > 0 ? (a.y + a.height) * s + 18 - height
                : spec.kind === "table" && a.height > 0 ? a.y * s - 14
                : spec.y * page.height - 28
        contentX = Math.max(0, Math.min(contentWidth - width, x))
        contentY = Math.max(0, Math.min(contentHeight - height, y))
    }
    Component.onCompleted: place()
    PinchHandler {
        target: null
        acceptedDevices: PointerDevice.TouchPad | PointerDevice.TouchScreen
        rotationAxis.enabled: false
        property real startZoom: 1
        onActiveChanged: if (active) startZoom = view.zoom
        onActiveScaleChanged: if (active) view.setZoom(startZoom * activeScale)
    }
    WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        acceptedModifiers: Qt.platform.os === "osx" ? Qt.MetaModifier : Qt.ControlModifier
        onWheel: function(event) { view.setZoom(view.zoom * Math.pow(1.0015, event.angleDelta.y)) }
    }
    WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        acceptedModifiers: Qt.ControlModifier
        enabled: Qt.platform.os === "osx"
        onWheel: function(event) { view.setZoom(view.zoom * Math.pow(1.0015, event.angleDelta.y)) }
    }
    PdfPageImage {
        id: page
        objectName: "linkPreviewPage"
        document: view.document
        currentFrame: view.spec.page
        width: view.width * view.pageZoom
        height: view.points.width > 0 ? width * view.points.height / view.points.width : width
        // While zooming, the drawn image is scaled (no blank while it redraws); once the zoom rests it is drawn
        // again at the new size.
        property real drawnWidth: 0
        onWidthChanged: if (drawnWidth <= 0) drawnWidth = width; else zoomSettle.restart()
        Timer { id: zoomSettle; interval: 160; onTriggered: page.drawnWidth = page.width }
        sourceSize.width: Math.ceil(Math.max(1, drawnWidth) * Screen.devicePixelRatio)
        retainWhileLoading: true
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        layer.enabled: view.inverted
        layer.effect: ShaderEffect { fragmentShader: "qrc:/owelk/shaders/invert.frag.qsb" }
        // The found entry, caption or equation, outlined.
        Rectangle {
            objectName: "linkPreviewTarget"
            visible: view.target.width > 0 && !view.area
            x: view.target.x * view.scale - 3; y: view.target.y * view.scale - 2
            width: view.target.width * view.scale + 6; height: view.target.height * view.scale + 4
            radius: Theme.radiusSmall
            color: "transparent"
            border.color: Theme.accent
            border.width: 1.5
        }
        // Click: go to what the view shows.
        TapHandler {
            onTapped: view.goRequested(view.spec.page, view.contentY / Math.max(1, view.contentHeight) + .03)
        }
    }
}
