import QtQuick

// Tells the window where the link under the pointer goes, so it shows at the bottom as a browser shows it (Main.qml's
// hoverLink): AI answers, notes, links on PDF pages, web tabs. `link` is "" when the pointer is on none; `label`, when
// set, is shown in place of what the link itself would say (a page of the same PDF).
Item {
    id: root
    property string link
    property string label
    visible: false
    function report(value) {
        const window = root.Window.window
        if (window && typeof window.hoverLink === "function") window.hoverLink(value, root, root.label)
    }
    onLinkChanged: report(link)
    onLabelChanged: if (link.length) report(link)
    // Gone while the pointer was on a link (scrolled away, closed): the link goes too.
    Component.onDestruction: if (link.length) report("")
}
