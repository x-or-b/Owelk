import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform

ColumnLayout {
    id: root
    spacing: 22
    // The custom theme's seeds, edited one color at a time.
    property var custom: Theme.seeds("custom")
    readonly property var seedNames: [{key: "window", name: "Window and toolbars"}, {key: "sidebar", name: "Sidebars"},
        {key: "content", name: "Documents and lists"}, {key: "raised", name: "Menus and popovers"},
        {key: "text", name: "Text"}, {key: "separator", name: "Lines"}, {key: "backdrop", name: "Around PDF pages"}]
    property string editing: ""
    function startCustom() {
        // A custom theme starts as a copy of the theme in use.
        if (Theme.theme !== "custom") { custom = Theme.seeds(Theme.theme); Theme.setCustomSeeds(custom) }
    }
    // A small picture of a theme: toolbar, sidebar, page with lines of text and an accent mark.
    component ThemeTile: Item {
        id: tile
        required property string themeId
        required property string name
        readonly property var seeds: Theme.seeds(themeId)
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
        Accessible.name: tile.name + " theme"
    }
    SettingsGroup {
        title: "Theme"
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
                    delegate: ThemeTile { required property var modelData; themeId: modelData.id; name: modelData.name }
                }
            }
        }
    }
    SettingsGroup {
        title: "Accent color"
        note: "Used for selection, the main button of each area, focus and links. Annotation inks keep their own colors."
        SettingsRow {
            label: Theme.accents.find(function(a) { return a.id === Theme.accentName }).name
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
                    ToolTip.visible: dotHover.hovered; ToolTip.delay: 500; ToolTip.text: modelData.name
                }
            }
        }
    }
    SettingsGroup {
        title: "App icon"
        note: Qt.platform.os === "osx" ? "Changes the icon in the Dock and on the app in Finder. If the Dock keeps the old one, it updates after Owelk restarts."
                                       : "Changes the icon in the taskbar and title bars."
        SettingsRow {
            label: (Theme.appIcons.find(function(i) { return i.id === Theme.appIcon }) || {name: ""}).name
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
                    ToolTip.visible: choiceHover.hovered; ToolTip.delay: 500; ToolTip.text: modelData.name
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.name + " icon"
                }
            }
        }
    }
    SettingsGroup {
        title: "Tabs"
        note: "Vertical tabs list every tab beside the window, with full titles; the panel opens and closes from its button at the top left (" + Platform.keys("Ctrl+Shift+B") + ")."
        SettingsRow {
            label: "Tab layout"
            TabBar {
                objectName: "tabLayout"
                currentIndex: Theme.verticalTabs ? 1 : 0
                TabButton { text: "Horizontal"; width: 96; onClicked: Theme.verticalTabs = false }
                TabButton { objectName: "verticalTabsOption"; text: "Vertical"; width: 96; onClicked: Theme.verticalTabs = true }
            }
        }
        // What a new launch shows: Home (the tabs wait behind it) or the tabs as they were left.
        SettingsRow {
            label: "On launch"
            TabBar {
                id: startupBar
                objectName: "startupView"
                property string chosen: researchStore.setting("startup.view", "home")
                currentIndex: chosen === "tabs" ? 1 : 0
                TabButton { text: "Home"; width: 96; onClicked: { startupBar.chosen = "home"; researchStore.setSetting("startup.view", "home") } }
                TabButton { objectName: "startupTabsOption"; text: "Last Tabs"; width: 96; onClicked: { startupBar.chosen = "tabs"; researchStore.setSetting("startup.view", "tabs") } }
            }
        }
    }
    SettingsGroup {
        title: "Text"
        note: "Scales all text and the controls around it. PDF pages keep their own zoom."
        SettingsRow {
            label: "Text size"
            Icon { name: "text"; size: Theme.fontCaption; color: Theme.textTertiary }
            Slider {
                objectName: "textSizeSlider"
                Layout.preferredWidth: 180
                from: 11; to: 17; stepSize: 1; snapMode: Slider.SnapAlways
                value: Theme.textSize
                onMoved: Theme.textSize = value
            }
            Icon { name: "text"; size: Theme.fontTitle; color: Theme.textTertiary }
            Label { text: Theme.textSize + " pt"; color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
    }
    SettingsGroup {
        visible: Theme.canInvertPages
        title: "PDF pages"
        note: "Dark pages invert lightness and keep hues, so figures stay recognizable. Exports and printing use the original colors."
        SettingsRow {
            label: "Dark pages"
            Switch { objectName: "invertPagesSwitch"; checked: Theme.invertPages; onToggled: Theme.invertPages = checked }
        }
    }
    SettingsGroup {
        visible: Theme.theme === "custom"
        title: "Custom theme"
        note: "Hover, selection and secondary text are worked out from these colors, so the theme stays consistent."
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
            label: "Dark"
            detail: "Use light text and dark controls"
            Switch {
                objectName: "customDarkSwitch"
                checked: !!root.custom.dark
                onToggled: { const next = Object.assign({}, root.custom); next.dark = checked; root.custom = next; Theme.setCustomSeeds(next) }
            }
        }
    }
    Native.ColorDialog {
        id: seedDialog
        title: "Theme color"
        onAccepted: {
            const next = Object.assign({}, root.custom)
            next[root.editing] = selectedColor.toString()
            root.custom = next
            Theme.setCustomSeeds(next)
        }
    }
}
