import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui
import "Platform.js" as Platform

ColumnLayout {
    id: root
    objectName: "appearanceSettings"
    spacing: 22
    // Another page to show (the Picture page, once five taps have chosen a picture).
    signal pageRequested(string page)
    // The colors of the theme in use, edited one at a time when it is Custom or one's own; read again whenever the
    // theme changes (choosing, adding or removing a picture changes them too).
    readonly property var custom: (Theme.window, Theme.seeds(Theme.theme))
    readonly property bool editable: Theme.theme === "custom" || Theme.isMine(Theme.theme)
    readonly property var mine: Theme.myThemes.find(function(t) { return t.id === Theme.theme }) || null
    // Every theme for Match System's lists: the built-in ones, Custom while kept, then one's own.
    readonly property var allThemes: Theme.themes.map(function(t) { return {id: t.id, name: qsTranslate("Owelk", t.name)} })
        .concat(Theme.customKept ? [{id: "custom", name: qsTr("Custom")}] : []).concat(Theme.myThemes)
    function accentOf(dark) {
        const a = Theme.accents.find(function(x) { return x.id === Theme.accentName })
        return a ? (dark ? a.dark : a.light) : Theme.accent
    }
    // The theme in use as a theme of one's own, to change from there.
    function copyTheme() {
        const current = root.allThemes.find(function(t) { return t.id === Theme.theme })
        Theme.addTheme(qsTr("%1 copy").arg(current ? current.name : qsTr("Theme")), Theme.seeds(Theme.theme), "")
    }
    readonly property var seedNames: [{key: "window", name: qsTr("Window and toolbars")}, {key: "sidebar", name: qsTr("Sidebars")},
        {key: "content", name: qsTr("Documents and lists")}, {key: "raised", name: qsTr("Menus and popovers")},
        {key: "text", name: qsTr("Text")}, {key: "separator", name: qsTr("Lines")}, {key: "backdrop", name: qsTr("Around PDF pages")}]
    property string editing: ""
    // The picture theme is in use: with Match System it is the theme for both appearances, light or dark with the
    // system, so no theme for each appearance applies. With Match System on, Custom's Dark is the system's to set
    // (the picture's colors are tinted for it); turning Match System off leaves it to the reader.
    readonly property bool pictureTheme: Theme.picture.toString().length > 0 && Theme.usePictureColors && Theme.theme === "custom"
    function startCustom() {
        if (Theme.theme === "custom") return
        // With a picture, Custom is the picture's theme; otherwise it starts as a copy of the theme in use.
        if (Theme.picture.toString().length && Theme.usePictureColors) { Theme.theme = "custom"; return }
        Theme.setCustomSeeds(Theme.seeds(Theme.theme))
    }
    // A theme in Settings: the built-in ones, Custom and one's own.
    component ThemeTile: ThemePreview {
        required property string themeId
        // Read again whenever the theme changes (the Custom colors can change under it).
        seeds: (Theme.window, Theme.seeds(themeId))
        // One's own theme shows the accent it brings.
        readonly property var own: Theme.myThemes.find(function(t) { return t.id === themeId }) || null
        accent: own && own.accent.length ? own.accent : root.accentOf(!!seeds.dark)
        current: Theme.theme === themeId
        objectName: "themeTile-" + themeId
        // Custom made from a picture shows it.
        picture: themeId === "custom" && Theme.picture.toString().length > 0 && Theme.usePictureColors ? Theme.picture : ""
        onTapped: { if (themeId === "custom") root.startCustom(); else Theme.theme = themeId }
        onMenuRequested: if (Theme.isMine(themeId)) { themeMenu.themeId = themeId; themeMenu.popup() }
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
            if (!Theme.pictureOn && Theme.pictures.length) { Theme.pictureOn = true; root.pageRequested("picture") }
            else pictureDialog.open()
        }
        // Four light, four dark, then the reader's own and + to add one.
        Item {
            width: parent.width
            implicitHeight: themes.implicitHeight + 24
            Column {
                id: themes
                x: 12; y: 12
                width: parent.width - 24
                spacing: 12
                Repeater {
                    model: [false, true]
                    delegate: Flow {
                        id: kind
                        required property bool modelData
                        width: themes.width
                        spacing: 12
                        Repeater {
                            model: Theme.themes.filter(function(t) { return t.dark === kind.modelData })
                            delegate: ThemeTile { required property var modelData; themeId: modelData.id; name: qsTranslate("Owelk", modelData.name) }
                        }
                    }
                }
                Flow {
                    objectName: "yourThemes"
                    width: themes.width
                    spacing: 12
                    ThemeTile { visible: Theme.customKept; themeId: "custom"; name: qsTr("Custom") }
                    Repeater {
                        model: Theme.myThemes
                        delegate: ThemeTile { required property var modelData; themeId: modelData.id; name: modelData.name }
                    }
                    ThemePreview {
                        id: addTile
                        objectName: "addTheme"
                        adding: true
                        name: qsTr("Add")
                        onTapped: addMenu.popup(addTile, 0, addTile.height)
                    }
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-matchSystem"
            label: qsTr("Match System")
            detail: root.pictureTheme ? qsTr("Light or dark with your system. The picture theme stays and turns light or dark with it.")
                                      : qsTr("Light or dark with your system. A theme chosen above is for the appearance it has now.")
            Switch { objectName: "matchSystemSwitch"; checked: Theme.matchSystem; onToggled: Theme.matchSystem = checked }
        }
        // The theme for each appearance.
        Repeater {
            model: [{key: "light", label: qsTr("Light appearance")}, {key: "dark", label: qsTr("Dark appearance")}]
            delegate: SettingsRow {
                id: appearanceRow
                required property var modelData
                objectName: "appearanceTheme-" + modelData.key
                visible: Theme.matchSystem && !root.pictureTheme
                label: modelData.label
                ComboBox {
                    objectName: "matchSystem-" + appearanceRow.modelData.key
                    Layout.preferredWidth: 180
                    readonly property var ids: root.allThemes.map(function(t) { return t.id })
                    model: root.allThemes.map(function(t) { return t.name })
                    currentIndex: Math.max(0, ids.indexOf(appearanceRow.modelData.key === "dark" ? Theme.darkTheme : Theme.lightTheme))
                    onActivated: function(index) {
                        if (appearanceRow.modelData.key === "dark") Theme.darkTheme = ids[index]
                        else Theme.lightTheme = ids[index]
                    }
                }
            }
        }
    }
    // The colors of Custom or of a theme of one's own, its name and Delete.
    SettingsGroup {
        visible: root.editable
        objectName: "settingsGroup-themeColors"
        title: root.mine ? root.mine.name : qsTr("Custom theme")
        note: qsTr("Hover, selection and secondary text are worked out from these colors, so the theme stays consistent.")
        SettingsRow {
            objectName: "settingsRow-themeName"
            visible: !!root.mine
            label: qsTr("Name")
            wide: true
            TextField {
                id: themeName
                objectName: "themeNameField"
                Layout.fillWidth: true
                text: root.mine ? root.mine.name : ""
                onEditingFinished: if (root.mine && text.trim().length) Theme.renameTheme(root.mine.id, text)
            }
            Button {
                objectName: "deleteTheme"
                text: qsTr("Delete")
                palette.buttonText: Theme.danger
                onClicked: Theme.removeTheme(root.mine.id)
            }
        }
        Repeater {
            model: root.seedNames
            delegate: SettingsRow {
                id: seedRow
                required property var modelData
                objectName: "seedRow-" + modelData.key
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
            objectName: "settingsRow-customDark"
            visible: Theme.theme === "custom"
            label: qsTr("Dark")
            detail: Theme.matchSystem ? qsTr("Set by Match System. Turn it off to change this.") : qsTr("Use light text and dark controls")
            Switch {
                objectName: "customDarkSwitch"
                enabled: !Theme.matchSystem
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
    SettingsGroup {
        objectName: "settingsGroup-accent"
        title: qsTr("Accent color")
        note: qsTr("Used for selection, the main button of each area, focus and links. Annotation inks keep their own colors.")
        SettingsRow {
            objectName: "accentRow"
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
            // Any color: it becomes the accent (as light or dark as white labels on it need).
            AddColorButton {
                objectName: "accentAdd"
                description: qsTr("Choose a color…")
                onClicked: { accentDialog.selectedColor = Theme.accent; accentDialog.open() }
            }
        }
    }
    SettingsGroup {
        objectName: "settingsGroup-text"
        title: qsTr("Text")
        note: qsTr("Text size scales all text and the controls around it; PDF pages keep their own zoom. The rest is how AI answers read.")
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
        SettingsRow {
            objectName: "settingsRow-answerSize"
            label: qsTr("AI answers")
            detail: qsTr("In the AI panel and chat tabs")
            Icon { name: "text"; size: Theme.fontCaption; color: Theme.textTertiary }
            Slider {
                objectName: "answerSizeSlider"
                Layout.preferredWidth: 180
                from: Theme.textSize - 1; to: Theme.textSize + 5; stepSize: 1; snapMode: Slider.SnapAlways
                value: Theme.answerSize
                onMoved: Theme.answerSize = value
            }
            Icon { name: "text"; size: Theme.fontTitle; color: Theme.textTertiary }
            Label { text: Theme.answerSize + qsTr(" pt"); color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
        SettingsRow {
            objectName: "settingsRow-answerSpacing"
            label: qsTr("Line spacing")
            detail: qsTr("In AI answers, between lines and between paragraphs")
            ComboBox {
                readonly property var spacings: ["compact", "comfortable", "relaxed"]
                objectName: "answerSpacingBox"
                Layout.preferredWidth: 200
                model: [qsTr("Compact"), qsTr("Comfortable"), qsTr("Relaxed")]
                currentIndex: Math.max(0, spacings.indexOf(Theme.answerSpacing))
                onActivated: function(index) { Theme.answerSpacing = spacings[index] }
            }
        }
        SettingsRow {
            objectName: "settingsRow-answerColumn"
            label: qsTr("Limit line length")
            detail: qsTr("In a wide chat tab, the conversation stays a readable width in the middle")
            Switch { objectName: "answerColumnSwitch"; checked: Theme.answerColumn; onToggled: Theme.answerColumn = checked }
        }
        SettingsRow {
            objectName: "settingsRow-answerNative"
            label: qsTr("Sharp text")
            detail: qsTr("AI answers' letters drawn by the system, as in other apps; turn off if they look blurry")
            Switch { objectName: "answerNativeSwitch"; checked: Theme.answerNative; onToggled: Theme.answerNative = checked }
        }
        SettingsRow {
            objectName: "answerPreviewRow"
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: preview.implicitHeight + 20
                radius: Theme.radius; color: Theme.content; border.color: Theme.separator
                TextEdit {
                    id: preview
                    objectName: "answerPreview"
                    x: 12; y: 10; width: Math.min(parent.width - 24, Theme.answerWidth || parent.width)
                    readOnly: true; activeFocusOnPress: false
                    textFormat: TextEdit.RichText; wrapMode: TextEdit.Wrap
                    renderType: Theme.answerNative ? TextEdit.NativeRendering : TextEdit.QtRendering
                    color: Theme.text; font.pixelSize: Theme.answerSize
                    text: researchStore.markdownHtml(qsTr("**Attention** lets each word look at the others and weigh which matter here.\n\n- Each word asks a question.\n- The others answer, and the closest answers count most.\n\nThe result is a new meaning for every word, read in its sentence."),
                                                     Theme.accent, Theme.text, Theme.answerSize, Theme.textTertiary, Theme.answerLineHeight)
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
            objectName: "appIconRow"
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
    Timer { id: tapPause; interval: 1000; onTriggered: themeGroup.taps = 0 }
    Menu {
        id: addMenu
        objectName: "addThemeMenu"
        MenuItem { objectName: "galleryTheme"; text: qsTr("From the Gallery…"); onTriggered: gallery.open() }
        MenuItem { objectName: "photoTheme"; text: qsTr("From a Photo…"); onTriggered: photoDialog.open() }
        MenuItem { objectName: "colorTheme"; text: qsTr("From a Color…"); onTriggered: maker.fromColor() }
        MenuSeparator {}
        MenuItem { objectName: "copyTheme"; text: qsTr("Copy This Theme"); onTriggered: root.copyTheme() }
    }
    ThemeGalleryDialog { id: gallery }
    ThemeMakerDialog { id: maker }
    Native.FileDialog {
        id: photoDialog
        objectName: "themePhotoDialog"
        title: qsTr("Choose a Photo")
        nameFilters: [qsTr("Pictures") + " (" + Theme.pictureFilter + ")"]
        onAccepted: maker.fromPhoto(selectedFile)
    }
    Menu {
        id: themeMenu
        objectName: "themeMenu"
        property string themeId: ""
        MenuItem {
            objectName: "removeTheme"
            text: qsTr("Delete Theme")
            palette.windowText: Theme.danger
            onTriggered: Theme.removeTheme(themeMenu.themeId)
        }
    }
    Native.FileDialog {
        id: pictureDialog
        objectName: "pictureDialog"
        title: qsTr("Choose a Picture")
        nameFilters: [qsTr("Pictures") + " (" + Theme.pictureFilter + ")"]
        onAccepted: {
            if (Theme.usePicture(selectedFile)) root.pageRequested("picture")
            else themeGroup.note = qsTr("This picture could not be opened.")
        }
    }
    Native.ColorDialog {
        id: accentDialog
        objectName: "accentColorDialog"
        title: qsTr("Accent color")
        onAccepted: Theme.setCustomAccent(selectedColor)
    }
    Native.ColorDialog {
        id: seedDialog
        title: qsTr("Theme color")
        onAccepted: {
            const next = Object.assign({}, root.custom)
            next[root.editing] = selectedColor.toString()
            Theme.setThemeSeeds(Theme.theme, next)
        }
    }
}
