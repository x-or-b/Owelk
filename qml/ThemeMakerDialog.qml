import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui

// A theme from a photo's colors or from one color: the color, how much it shows and a name; a light and a dark version
// are pictured, and either or both become themes of one's own, with that color as their accent.
Dialog {
    id: root
    objectName: "themeMaker"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(520, parent ? parent.width - 48 : 520)
    modal: true
    title: qsTr("New Theme")
    // The photo's colors, most prominent first (none for a theme from one color).
    property var colors: []
    property color chosen: Theme.accent
    property real strength: 2
    property string problem: ""
    readonly property var lightSeeds: Theme.tintedSeeds(chosen, false, strength)
    readonly property var darkSeeds: Theme.tintedSeeds(chosen, true, strength)
    function fromPhoto(file) {
        colors = Theme.photoColors(file)
        problem = colors.length ? "" : qsTr("This photo has no colors to take; choose one with +.")
        if (colors.length) chosen = colors[0]
        nameField.text = decodeURIComponent(file.toString().split("/").pop()).replace(/\.[^.]*$/, "")
        open()
    }
    function fromColor() {
        colors = []; problem = ""
        chosen = Theme.accent
        nameField.text = qsTr("My color")
        open()
        colorDialog.open()
    }
    // The light version, the dark one or both; with both, the one like the theme in use is used.
    function add(light, dark) {
        const name = nameField.text.trim().length ? nameField.text.trim() : qsTr("My theme")
        const wasDark = Theme.dark
        const lightId = light ? Theme.addTheme(name, lightSeeds, chosen.toString()) : ""
        const darkId = dark ? Theme.addTheme(light ? qsTr("%1 Dark").arg(name) : name, darkSeeds, chosen.toString()) : ""
        if (light && dark) Theme.theme = wasDark ? darkId : lightId
        close()
    }
    contentItem: ColumnLayout {
        spacing: 14
        // The colors to choose from; + for any other.
        RowLayout {
            spacing: 8
            Repeater {
                model: root.colors
                delegate: Rectangle {
                    id: swatch
                    required property string modelData
                    required property int index
                    objectName: "makerColor-" + index
                    width: Theme.iconButton + 4; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: Qt.colorEqual(root.chosen, modelData) ? Theme.text : swatchHover.hovered ? Theme.border : "transparent"
                    Rectangle { anchors.fill: parent; anchors.margins: 4; radius: width / 2; color: swatch.modelData }
                    HoverHandler { id: swatchHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.chosen = swatch.modelData }
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: qsTr("Color") + " " + modelData
                }
            }
            AddColorButton { objectName: "makerOtherColor"; description: qsTr("Another color…"); onClicked: colorDialog.open() }
            Item { Layout.fillWidth: true }
        }
        Label {
            visible: root.problem.length > 0
            Layout.fillWidth: true
            text: root.problem
            wrapMode: Text.Wrap; color: Theme.danger; font.pixelSize: Theme.fontSmall
        }
        RowLayout {
            spacing: 10
            Label { text: qsTr("Color strength"); color: Theme.text }
            Label { text: qsTr("Subtle"); color: Theme.textTertiary; font.pixelSize: Theme.fontSmall }
            Slider {
                objectName: "makerStrength"
                Layout.fillWidth: true
                from: 1; to: 3; stepSize: .5; snapMode: Slider.SnapAlways
                value: root.strength
                onMoved: root.strength = value
            }
            Label { text: qsTr("Vivid"); color: Theme.textTertiary; font.pixelSize: Theme.fontSmall }
        }
        TextField {
            id: nameField
            objectName: "makerName"
            Layout.fillWidth: true
            placeholderText: qsTr("Theme name")
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 28
            Repeater {
                model: [{dark: false, label: qsTr("Add Light")}, {dark: true, label: qsTr("Add Dark")}]
                delegate: ColumnLayout {
                    id: version
                    required property var modelData
                    spacing: 8
                    ThemePreview {
                        Layout.alignment: Qt.AlignHCenter
                        objectName: "makerPreview-" + (version.modelData.dark ? "dark" : "light")
                        width: 150; height: 120
                        seeds: version.modelData.dark ? root.darkSeeds : root.lightSeeds
                        accent: root.chosen
                        name: version.modelData.dark ? qsTr("Dark") : qsTr("Light")
                        onTapped: root.add(!version.modelData.dark, version.modelData.dark)
                    }
                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        objectName: "makerAdd-" + (version.modelData.dark ? "dark" : "light")
                        text: version.modelData.label
                        onClicked: root.add(!version.modelData.dark, version.modelData.dark)
                    }
                }
            }
        }
    }
    footer: DialogButtonBox {
        Button { objectName: "makerAddBoth"; text: qsTr("Add Both"); primary: true; onClicked: root.add(true, true) }
        Button { text: qsTr("Cancel"); DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
    }
    Native.ColorDialog {
        id: colorDialog
        title: qsTr("Theme color")
        selectedColor: root.chosen
        onAccepted: { root.chosen = selectedColor; root.problem = "" }
    }
}
