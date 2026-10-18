import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform

ColumnLayout {
    id: root
    spacing: 22
    // The custom theme's seeds, edited one color at a time; read again whenever the theme changes (choosing,
    // adding or removing a picture changes them too).
    readonly property var custom: (Theme.window, Theme.seeds("custom"))
    readonly property var seedNames: [{key: "window", name: qsTr("Window and toolbars")}, {key: "sidebar", name: qsTr("Sidebars")},
        {key: "content", name: qsTr("Documents and lists")}, {key: "raised", name: qsTr("Menus and popovers")},
        {key: "text", name: qsTr("Text")}, {key: "separator", name: qsTr("Lines")}, {key: "backdrop", name: qsTr("Around PDF pages")}]
    property string editing: ""
    function startCustom() {
        if (Theme.theme === "custom") return
        // With a picture, Custom is the picture's theme; otherwise it starts as a copy of the theme in use.
        if (Theme.picture.toString().length) { Theme.theme = "custom"; return }
        Theme.setCustomSeeds(Theme.seeds(Theme.theme))
    }
    // A small picture of a theme: toolbar, sidebar, page with lines of text and an accent mark.
    component ThemeTile: Item {
        id: tile
        required property string themeId
        required property string name
        // Read again whenever the theme changes (the Custom colors can change under it).
        readonly property var seeds: (Theme.window, Theme.seeds(themeId))
        readonly property bool current: Theme.theme === themeId
        width: 104; height: 92
        objectName: "themeTile-" + themeId
        Rectangle {
            id: preview
            width: parent.width; height: 64
            radius: Theme.radius
            color: tile.seeds.window
            border.width: tile.current ? 2 : 1
            border.color: tile.current ? Theme.accent : hover.hovered ? Theme.border : Theme.separator
            clip: true
            Rectangle { x: 6; y: 12; width: 24; height: parent.height - 18; radius: 3; color: tile.seeds.sidebar }
            Rectangle {
                x: 34; y: 12; width: parent.width - 40; height: parent.height - 18; radius: 3; color: tile.seeds.content
                Column {
                    x: 6; y: 7; spacing: 4
                    Repeater { model: [44, 52, 30]; Rectangle { width: modelData; height: 3; radius: 1.5; color: tile.seeds.text; opacity: index === 0 ? .9 : .45 } }
                }
                Rectangle { anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6; width: 14; height: 6; radius: 3; color: tile.seeds.dark ? Theme.accents.find(function(a) { return a.id === Theme.accentName }).dark : Theme.accents.find(function(a) { return a.id === Theme.accentName }).light }
            }
            Row { x: 6; y: 4; spacing: 3; Repeater { model: 3; Rectangle { width: 4; height: 4; radius: 2; color: tile.seeds.text; opacity: .25 } } }
            // Custom made from a picture shows it.
            Image {
                visible: tile.themeId === "custom" && Theme.picture.toString().length > 0
                source: visible ? Theme.picture : ""
                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 2
                width: parent.height - 8; height: width
                fillMode: Image.PreserveAspectFit
                horizontalAlignment: Image.AlignRight; verticalAlignment: Image.AlignBottom
                sourceSize: Qt.size(128, 128)
                asynchronous: true
            }
        }
        Label {
            anchors.top: preview.bottom; anchors.topMargin: 5
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: tile.name
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSmall
            font.weight: tile.current ? Font.DemiBold : Font.Normal
            color: tile.current ? Theme.text : Theme.textSecondary
        }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { if (tile.themeId === "custom") root.startCustom(); else Theme.theme = tile.themeId } }
        Accessible.role: Accessible.RadioButton
        Accessible.name: tile.name + qsTr(" theme")
    }
    SettingsGroup {
        id: themeGroup
        objectName: "settingsGroup-theme"
        title: qsTr("Theme")
        noteColor: Theme.danger
        // Five quick taps on the heading choose a picture to make a theme from. Nothing hints at it.
        property int taps: 0
        onTitleTapped: {
            taps = taps + 1
            tapPause.restart()
            if (taps < 5) return
            taps = 0
            note = ""
            // Turned off with pictures kept: on again with them; otherwise a picture to start from.
            if (!Theme.pictureOn && Theme.pictures.length) Theme.pictureOn = true
            else pictureDialog.open()
        }
        Item {
            width: parent.width
            implicitHeight: themes.implicitHeight + 24
            Flow {
                id: themes
                x: 12; y: 12
                width: parent.width - 24
                spacing: 12
                Repeater {
                    model: Theme.themes.concat([{id: "custom", name: "Custom"}])
                    delegate: ThemeTile { required property var modelData; themeId: modelData.id; name: modelData.id === "custom" ? qsTr("Custom") : qsTranslate("Owelk", modelData.name) }
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-matchSystem"
            label: qsTr("Match System")
            detail: qsTr("Light or dark with your system. A theme chosen above is for the appearance it has now.")
            Switch { objectName: "matchSystemSwitch"; checked: Theme.matchSystem; onToggled: Theme.matchSystem = checked }
        }
        // The theme for each appearance.
        Repeater {
            model: [{key: "light", label: qsTr("Light appearance")}, {key: "dark", label: qsTr("Dark appearance")}]
            delegate: SettingsRow {
                id: appearanceRow
                required property var modelData
                visible: Theme.matchSystem
                label: modelData.label
                ComboBox {
                    objectName: "matchSystem-" + appearanceRow.modelData.key
                    Layout.preferredWidth: 160
                    readonly property var ids: Theme.themes.map(function(t) { return t.id }).concat(["custom"])
                    model: Theme.themes.map(function(t) { return qsTranslate("Owelk", t.name) }).concat([qsTr("Custom")])
                    currentIndex: Math.max(0, ids.indexOf(appearanceRow.modelData.key === "dark" ? Theme.darkTheme : Theme.lightTheme))
                    onActivated: function(index) {
                        if (appearanceRow.modelData.key === "dark") Theme.darkTheme = ids[index]
                        else Theme.lightTheme = ids[index]
                    }
                }
            }
        }
    }
    SettingsGroup {
        visible: Theme.picture.toString().length > 0
        objectName: "settingsGroup-picture"
        title: qsTr("Picture")
        note: qsTr("Shown behind Home and PDF pages while the Custom theme is in use. Exports and printing keep the original pages.")
        SettingsRow {
            label: qsTr("Picture theme")
            detail: qsTr("Off, Custom has your own colors again and the pet goes away. The pictures are kept.")
            Switch {
                objectName: "pictureOnSwitch"
                checked: Theme.pictureOn
                onToggled: Theme.pictureOn = checked
            }
        }
        SettingsRow {
            label: qsTr("Pictures")
            detail: qsTr("Click one to use it. Right-click to remove it.")
            Button { objectName: "addPicture"; text: qsTr("Add…"); onClicked: pictureDialog.open() }
        }
        // Every kept picture; the one in use has the accent border.
        Item {
            width: parent.width
            implicitHeight: pictureFlow.implicitHeight + 12
            Flow {
                id: pictureFlow
                x: 12; width: parent.width - 24
                spacing: 8
                Repeater {
                    model: Theme.pictures
                    delegate: Rectangle {
                        id: thumb
                        required property var modelData
                        required property int index
                        objectName: "pictureThumb-" + index
                        width: 56; height: 56; radius: Theme.radius
                        color: "transparent"
                        border.width: 2
                        border.color: modelData.current ? Theme.accent : thumbHover.hovered ? Theme.border : Theme.separator
                        Image {
                            anchors.fill: parent; anchors.margins: 5
                            source: thumb.modelData.url
                            fillMode: Image.PreserveAspectFit
                            sourceSize: Qt.size(112, 112)
                            asynchronous: true
                        }
                        HoverHandler { id: thumbHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: Theme.choosePicture(thumb.modelData.id) }
                        TapHandler { acceptedButtons: Qt.RightButton; onTapped: { pictureMenu.pictureId = thumb.modelData.id; pictureMenu.popup() } }
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: qsTr("Picture") + " " + (index + 1)
                    }
                }
            }
        }
        SettingsRow {
            visible: Theme.pictureColors.length > 0
            label: qsTr("Accent from the picture")
            Repeater {
                model: Theme.pictureColors
                delegate: Rectangle {
                    id: swatch
                    required property string modelData
                    readonly property bool chosen: Theme.accentName === "custom" && Qt.colorEqual(Theme.customAccent, modelData)
                    objectName: "pictureColor-" + modelData
                    width: Theme.iconButton; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: chosen ? Theme.text : swatchHover.hovered ? Theme.border : "transparent"
                    Rectangle { anchors.fill: parent; anchors.margins: 4; radius: width / 2; color: swatch.modelData }
                    HoverHandler { id: swatchHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Theme.setCustomAccent(swatch.modelData) }
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: qsTr("Accent color") + " " + modelData
                }
            }
        }
        SettingsRow {
            label: qsTr("Position")
            ComboBox {
                objectName: "pictureAlignBox"
                Layout.preferredWidth: 140
                readonly property var values: ["left", "center", "right"]
                model: [qsTr("Left"), qsTr("Center"), qsTr("Right")]
                currentIndex: Math.max(0, values.indexOf(Theme.pictureAlign))
                onActivated: function(index) { Theme.pictureAlign = values[index] }
            }
        }
        SettingsRow {
            // A cut-out's height, for each picture (a full picture covers the area).
            visible: Theme.pictureCutout
            label: qsTr("Size")
            Slider {
                objectName: "pictureScaleSlider"
                Layout.preferredWidth: 180
                from: 40; to: 100; stepSize: 5; snapMode: Slider.SnapAlways
                value: Theme.pictureScale
                onMoved: Theme.pictureScale = value
            }
            Label { text: Theme.pictureScale + "%"; color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
        SettingsRow {
            label: qsTr("Behind Home and pages")
            Slider {
                objectName: "pictureStrengthSlider"
                Layout.preferredWidth: 180
                from: 0; to: 60; stepSize: 5; snapMode: Slider.SnapAlways
                value: Theme.pictureStrength
                onMoved: Theme.pictureStrength = value
            }
            Label { text: Theme.pictureStrength + "%"; color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
        SettingsRow {
            label: qsTr("Through the paper")
            Slider {
                objectName: "paperStrengthSlider"
                Layout.preferredWidth: 180
                from: 0; to: 50; stepSize: 5; snapMode: Slider.SnapAlways
                value: Theme.paperStrength
                onMoved: Theme.paperStrength = value
            }
            Label { text: Theme.paperStrength + "%"; color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
        SettingsRow {
            visible: DesktopPet.supported
            label: qsTr("Desktop pet")
            detail: qsTr("The picture floats above other apps while Owelk is open. Click it to come back here.")
            Switch { objectName: "petSwitch"; checked: DesktopPet.enabled; onToggled: DesktopPet.enabled = checked }
        }
        SettingsRow {
            visible: DesktopPet.supported && DesktopPet.enabled
            label: qsTr("Pet size")
            ComboBox {
                objectName: "petSizeBox"
                Layout.preferredWidth: 140
                readonly property var values: ["small", "medium", "large"]
                model: [qsTr("Small"), qsTr("Medium"), qsTr("Large")]
                currentIndex: Math.max(0, values.indexOf(DesktopPet.size))
                onActivated: function(index) { DesktopPet.size = values[index] }
            }
        }
        SettingsRow {
            visible: DesktopPet.supported && DesktopPet.enabled
            label: qsTr("Break reminder")
            detail: qsTr("The pet suggests a short break after this much reading in Owelk")
            ComboBox {
                objectName: "petBreakBox"
                Layout.preferredWidth: 140
                readonly property var values: [0, 25, 50, 90]
                model: [qsTr("Off"), qsTr("25 minutes"), qsTr("50 minutes"), qsTr("90 minutes")]
                currentIndex: Math.max(0, values.indexOf(DesktopPet.breakMinutes))
                onActivated: function(index) { DesktopPet.breakMinutes = values[index] }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-accent"
        title: qsTr("Accent color")
        note: qsTr("Used for selection, the main button of each area, focus and links. Annotation inks keep their own colors.")
        SettingsRow {
            label: qsTranslate("Owelk", Theme.accents.find(function(a) { return a.id === Theme.accentName }).name)
            Repeater {
                model: Theme.accents
                delegate: Rectangle {
                    id: dot
                    required property var modelData
                    objectName: "accent-" + modelData.id
                    width: Theme.iconButton; height: width; radius: width / 2
                    color: "transparent"
                    border.width: 2
                    border.color: Theme.accentName === modelData.id ? Theme.text : dotHover.hovered ? Theme.border : "transparent"
                    Rectangle { anchors.fill: parent; anchors.margins: 4; radius: width / 2; color: Theme.dark ? dot.modelData.dark : dot.modelData.light }
                    HoverHandler { id: dotHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Theme.accentName = dot.modelData.id }
                    ToolTip.visible: dotHover.hovered; ToolTip.delay: 500; ToolTip.text: qsTranslate("Owelk", modelData.name)
                }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-appIcon"
        title: qsTr("App icon")
        note: Qt.platform.os === "osx" ? qsTr("Changes the icon in the Dock and on the app in Finder. If the Dock keeps the old one, it updates after Owelk restarts.")
                                       : qsTr("Changes the icon in the taskbar and title bars.")
        SettingsRow {
            label: qsTranslate("Owelk", (Theme.appIcons.find(function(i) { return i.id === Theme.appIcon }) || {name: ""}).name)
            Repeater {
                model: Theme.appIcons
                delegate: Rectangle {
                    id: choice
                    required property var modelData
                    objectName: "appIcon-" + modelData.id
                    width: 52; height: 52; radius: Theme.radius
                    color: "transparent"
                    border.width: 2
                    border.color: Theme.appIcon === modelData.id ? Theme.accent : choiceHover.hovered ? Theme.border : "transparent"
                    Image { anchors.fill: parent; anchors.margins: 3; source: choice.modelData.source; sourceSize: Qt.size(96, 96); smooth: true; mipmap: true }
                    HoverHandler { id: choiceHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Theme.appIcon = choice.modelData.id }
                    ToolTip.visible: choiceHover.hovered; ToolTip.delay: 500; ToolTip.text: qsTranslate("Owelk", modelData.name)
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: qsTranslate("Owelk", modelData.name) + qsTr(" icon")
                }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-text"
        title: qsTr("Text")
        note: qsTr("Scales all text and the controls around it. PDF pages keep their own zoom.")
        SettingsRow {
            objectName: "settingsRow-textSize"
            label: qsTr("Text size")
            Icon { name: "text"; size: Theme.fontCaption; color: Theme.textTertiary }
            Slider {
                objectName: "textSizeSlider"
                Layout.preferredWidth: 180
                from: 11; to: 17; stepSize: 1; snapMode: Slider.SnapAlways
                value: Theme.textSize
                onMoved: Theme.textSize = value
            }
            Icon { name: "text"; size: Theme.fontTitle; color: Theme.textTertiary }
            Label { text: Theme.textSize + qsTr(" pt"); color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
    }
    SettingsGroup {
        visible: Theme.canInvertPages
        objectName: "settingsGroup-pdfPages"
        title: qsTr("PDF pages")
        note: qsTr("Dark pages invert lightness and keep hues, so figures stay recognizable. Exports and printing use the original colors.")
        SettingsRow {
            objectName: "settingsRow-darkPages"
            label: qsTr("Dark pages")
            Switch { objectName: "invertPagesSwitch"; checked: Theme.invertPages; onToggled: Theme.invertPages = checked }
        }
    }
    SettingsGroup {
        visible: Theme.theme === "custom"
        objectName: "settingsGroup-customTheme"
        title: qsTr("Custom theme")
        note: qsTr("Hover, selection and secondary text are worked out from these colors, so the theme stays consistent.")
        Repeater {
            model: root.seedNames
            delegate: SettingsRow {
                id: seedRow
                required property var modelData
                label: modelData.name
                Rectangle {
                    objectName: "seed-" + seedRow.modelData.key
                    width: 44; height: Theme.controlHeightSmall; radius: Theme.radiusSmall
                    color: root.custom[seedRow.modelData.key] || "transparent"
                    border.color: Theme.border
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.editing = seedRow.modelData.key; seedDialog.selectedColor = root.custom[seedRow.modelData.key]; seedDialog.open() } }
                }
            }
        }
        SettingsRow {
            label: qsTr("Dark")
            detail: qsTr("Use light text and dark controls")
            Switch {
                objectName: "customDarkSwitch"
                checked: !!root.custom.dark
                onToggled: {
                    // A picture's theme is tinted again for the other brightness; other custom colors are kept.
                    const next = Theme.picture.toString().length ? Theme.tintedSeeds(Theme.pictureColors.length ? Theme.pictureColors[0] : "", checked)
                                                                 : Object.assign({}, root.custom, {dark: checked})
                    Theme.setCustomSeeds(next)
                }
            }
        }
    }
    Timer { id: tapPause; interval: 1000; onTriggered: themeGroup.taps = 0 }
    Menu {
        id: pictureMenu
        objectName: "pictureMenu"
        property string pictureId: ""
        MenuItem {
            objectName: "removePicture"
            text: qsTr("Remove Picture")
            palette.windowText: Theme.danger
            onTriggered: Theme.removePicture(pictureMenu.pictureId)
        }
    }
    Native.FileDialog {
        id: pictureDialog
        objectName: "pictureDialog"
        title: qsTr("Choose a Picture")
        nameFilters: [qsTr("Pictures") + " (" + Theme.pictureFilter + ")"]
        onAccepted: {
            if (!Theme.usePicture(selectedFile)) themeGroup.note = qsTr("This picture could not be opened.")
        }
    }
    Native.ColorDialog {
        id: seedDialog
        title: qsTr("Theme color")
        onAccepted: {
            const next = Object.assign({}, root.custom)
            next[root.editing] = selectedColor.toString()
            Theme.setCustomSeeds(next)
        }
    }
}
