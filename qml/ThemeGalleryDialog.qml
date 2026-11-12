import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "ThemeGallery.js" as Gallery

// Well-known themes, each as a small picture, to add as one's own: type to narrow them by name, light or dark, or a
// word such as warm or blue; a click adds the theme (or goes back to it, once added) and uses it.
Dialog {
    id: root
    objectName: "themeGallery"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(700, parent ? parent.width - 48 : 700)
    height: Math.min(560, parent ? parent.height - 48 : 560)
    modal: true
    title: qsTr("Theme Gallery")
    property string query: ""
    readonly property var shown: Gallery.find(query, function(id) { return Theme.seeds(id) })
    // A theme from the gallery: the one of one's own of that name, else a new one.
    function choose(entry) {
        const added = Theme.myThemes.find(function(t) { return t.name === entry.name })
        if (added) Theme.theme = added.id
        else Theme.addTheme(entry.name, entry.seeds, entry.accent)
        close()
    }
    onAboutToShow: { query = ""; search.text = ""; search.forceActiveFocus() }
    contentItem: ColumnLayout {
        spacing: 12
        TextField {
            id: search
            objectName: "themeGallerySearch"
            Layout.fillWidth: true
            placeholderText: qsTr("Search themes: a name, light or dark, warm, blue…")
            onTextEdited: root.query = text
            Keys.onReturnPressed: if (root.shown.length === 1) root.choose(root.shown[0])
        }
        Label {
            visible: root.shown.length === 0
            text: qsTr("No theme matches.")
            color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
        }
        ScrollView {
            id: scroller
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true
            Column {
                width: scroller.availableWidth
                spacing: 14
                Repeater {
                    model: [{dark: false, label: qsTr("Light")}, {dark: true, label: qsTr("Dark")}]
                    delegate: Column {
                        id: section
                        required property var modelData
                        readonly property var list: root.shown.filter(function(t) { return t.dark === section.modelData.dark })
                        visible: list.length > 0
                        width: parent.width
                        spacing: 8
                        Label { text: section.modelData.label; font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary }
                        Flow {
                            width: parent.width
                            spacing: 12
                            Repeater {
                                model: section.list
                                delegate: ThemePreview {
                                    required property var modelData
                                    objectName: "galleryTheme-" + modelData.name
                                    seeds: modelData.seeds
                                    accent: modelData.accent
                                    name: modelData.name
                                    current: Theme.myThemes.some(function(t) { return t.name === modelData.name && t.id === Theme.theme })
                                    onTapped: root.choose(modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    footer: DialogButtonBox {
        Button { text: qsTr("Close"); DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
    }
}
