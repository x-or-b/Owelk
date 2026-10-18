import QtQuick
import Owelk.Ui

// The picture theme's picture laid out on an area (Home, the PDF view), never stretched: a cut-out
// character stands at the bottom at the area's height, or the part of it chosen as its size (a wide one
// no wider than 45% of the area, or that part of it), on the right unless chosen otherwise; a full
// picture covers the area, cropped. A layer on part of the area (a PDF page) shows the same part of the
// picture: origin is where the layer is in the area. Nothing is loaded unless the theme is on.
Item {
    id: root
    property real areaWidth: width
    property real areaHeight: height
    property point origin: Qt.point(0, 0)
    // How much of the picture shows, 0..1.
    property real strength: Theme.pictureStrength / 100
    // How tall a cut-out stands, 0.4..1 of the area's height (its width limit shrinks alike).
    property real share: Theme.pictureScale / 100
    readonly property real aspect: Theme.pictureSize.height > 0 ? Theme.pictureSize.width / Theme.pictureSize.height : 1
    visible: Theme.pictureShown && strength > 0
    clip: true
    Image {
        objectName: "pictureImage"
        readonly property bool cutout: Theme.pictureCutout
        width: cutout ? Math.min(root.areaWidth * .45, root.areaHeight * root.aspect) * root.share : root.areaWidth
        height: cutout ? width / root.aspect : root.areaHeight
        readonly property real free: root.areaWidth - width
        x: (Theme.pictureAlign === "left" ? 0 : Theme.pictureAlign === "center" ? free / 2 : free) - root.origin.x
        y: root.areaHeight - height - root.origin.y
        // Not before the screen is known: a 0×0 size would decode the whole picture first.
        source: root.visible && Screen.width > 0 ? Theme.picture : ""
        // Decoded once at the screen's size (shared by every layer), not again on each resize.
        sourceSize: Qt.size(Math.ceil(Screen.width * Screen.devicePixelRatio), Math.ceil(Screen.height * Screen.devicePixelRatio))
        fillMode: cutout ? Image.PreserveAspectFit : Image.PreserveAspectCrop
        horizontalAlignment: Theme.pictureAlign === "left" ? Image.AlignLeft : Theme.pictureAlign === "center" ? Image.AlignHCenter : Image.AlignRight
        asynchronous: true
        opacity: root.strength
    }
}
