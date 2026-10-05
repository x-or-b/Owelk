import QtQuick
import QtQuick.Templates as T
import Owelk.Ui

T.Dialog {
    id: control
    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, contentWidth + leftPadding + rightPadding,
                            implicitHeaderWidth, implicitFooterWidth)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset,
                             contentHeight + topPadding + bottomPadding + (implicitHeaderHeight > 0 ? implicitHeaderHeight + spacing : 0)
                             + (implicitFooterHeight > 0 ? implicitFooterHeight + spacing : 0))
    padding: 16
    topPadding: 4
    background: Rectangle {
        radius: Theme.radiusLarge
        color: Theme.raised
        border.color: Theme.border
    }
    header: Label {
        text: control.title
        visible: control.title
        elide: Label.ElideRight
        font.pixelSize: Theme.fontHeadline
        font.weight: Font.DemiBold
        padding: 16
        bottomPadding: 8
        background: Item {}
    }
    footer: DialogButtonBox { visible: count > 0 }
    T.Overlay.modal: Rectangle { color: Theme.overlay }
    T.Overlay.modeless: Rectangle { color: "transparent" }
}
