import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import Owelk.Ui

// The picture theme and the desktop pet that comes with it. Listed in Settings only while a picture is in use
// (five quick taps on Appearance › Theme's heading choose the first one).
ColumnLayout {
    id: root
    objectName: "pictureSettings"
    spacing: 22
    // A picture or faces that could not be added, said under their group.
    property string problem: ""
    property string faceProblem: ""
    SettingsGroup {
        objectName: "settingsGroup-picture"
        title: qsTr("Picture")
        note: root.problem.length ? root.problem : qsTr("Shown behind Home and PDF pages while the Custom theme is in use. Exports and printing keep the original pages.")
        noteColor: root.problem.length ? Theme.danger : Theme.textTertiary
        SettingsRow {
            objectName: "settingsRow-pictureOn"
            label: qsTr("Picture theme")
            detail: qsTr("Off, Custom has your own colors again and the pet goes away. The pictures are kept.")
            Switch {
                objectName: "pictureOnSwitch"
                checked: Theme.pictureOn
                onToggled: Theme.pictureOn = checked
            }
        }
        SettingsRow {
            objectName: "settingsRow-pictureColors"
            label: qsTr("Picture colors")
            detail: qsTr("On, Custom takes the picture's colors and the picture shows behind Home and pages. Off, the themes above are as they are; the picture is the pet's.")
            Switch {
                objectName: "pictureColorsSwitch"
                checked: Theme.usePictureColors
                onToggled: Theme.usePictureColors = checked
            }
        }
        SettingsRow {
            objectName: "settingsRow-pictures"
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
                        ContextTap { onRequested: { pictureMenu.pictureId = thumb.modelData.id; pictureMenu.popup() } }
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: qsTr("Picture") + " " + (index + 1)
                    }
                }
            }
        }
        SettingsRow {
            objectName: "settingsRow-pictureAccent"
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
            objectName: "settingsRow-pictureAlign"
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
            objectName: "settingsRow-pictureScale"
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
            // One strength for Home, around the pages and through the paper alike.
            objectName: "settingsRow-pictureStrength"
            label: qsTr("Opacity")
            Slider {
                objectName: "pictureStrengthSlider"
                Layout.preferredWidth: 180
                from: 0; to: 100; stepSize: 5; snapMode: Slider.SnapAlways
                value: Theme.pictureStrength
                onMoved: Theme.pictureStrength = value
            }
            Label { text: Theme.pictureStrength + "%"; color: Theme.textSecondary; Layout.preferredWidth: 40; horizontalAlignment: Text.AlignRight }
        }
        SettingsRow {
            objectName: "settingsRow-pictureInterval"
            visible: Theme.pictures.length > 1
            label: qsTr("Change picture")
            ComboBox {
                objectName: "pictureIntervalBox"
                Layout.preferredWidth: 180
                readonly property var intervals: [0, 30, 60, 360, 720, 1440, -1]
                model: [qsTr("Keep this picture"), qsTr("Every 30 minutes"), qsTr("Every hour"), qsTr("Every 6 hours"), qsTr("Every 12 hours"), qsTr("Every day"), qsTr("Each launch")]
                currentIndex: Math.max(0, intervals.indexOf(Theme.pictureInterval))
                onActivated: function(index) { Theme.pictureInterval = intervals[index] }
            }
        }
    }
    // The pet: the picture (or its faces) above other apps while Owelk is open.
    SettingsGroup {
        visible: DesktopPet.supported
        objectName: "settingsGroup-pet"
        title: qsTr("Desktop pet")
        SettingsRow {
            objectName: "settingsRow-pet"
            label: qsTr("On the desktop")
            detail: qsTr("The picture floats above other apps while Owelk is open. Click it to come back here.")
            Switch { objectName: "petSwitch"; checked: DesktopPet.enabled; onToggled: DesktopPet.enabled = checked }
        }
        SettingsRow {
            objectName: "settingsRow-petSize"
            visible: DesktopPet.enabled
            label: qsTr("Size")
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
            objectName: "settingsRow-petBreak"
            visible: DesktopPet.enabled
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
        SettingsRow {
            objectName: "settingsRow-petGoal"
            visible: DesktopPet.enabled
            label: qsTr("Daily reading goal")
            detail: qsTr("The pet cheers once you have read this much in a day, and at 7, 30 and 100 days in a row")
            ComboBox {
                objectName: "petGoalBox"
                Layout.preferredWidth: 140
                readonly property var values: [0, 15, 30, 60, 90]
                model: [qsTr("Off"), qsTr("15 minutes"), qsTr("30 minutes"), qsTr("60 minutes"), qsTr("90 minutes")]
                currentIndex: Math.max(0, values.indexOf(DesktopPet.dailyGoal))
                onActivated: function(index) { DesktopPet.dailyGoal = values[index] }
            }
        }
        SettingsRow {
            objectName: "settingsRow-petHidden"
            visible: DesktopPet.enabled && (Qt.platform.os === "osx" || Qt.platform.os === "windows")
            label: qsTr("Hide in screen sharing")
            detail: qsTr("Screen sharing and recordings leave out the pet. Some recorders on recent macOS show it anyway, stuck in place.")
            Switch { objectName: "petHideWhenShared"; checked: DesktopPet.hiddenWhenShared; onToggled: DesktopPet.hiddenWhenShared = checked }
        }
    }
    // The pet's faces with the picture in use, for each moment: up to six, one picked each time or one after
    // another while it lasts. A moment without faces shows talking's for news, else the picture.
    SettingsGroup {
        visible: DesktopPet.supported && DesktopPet.enabled
        objectName: "settingsGroup-petFaces"
        title: qsTr("Pet faces")
        noteColor: root.faceProblem.length ? Theme.danger : Theme.textTertiary
        note: root.faceProblem.length ? root.faceProblem : qsTr("Up to six for each moment, a different one each time or one after another; right-click one to remove it. Without any, the pet shows its usual face, else the picture (for news, its talking face).")
        Repeater {
            model: [{mood: "usual", name: qsTr("Usual"), detail: qsTr("The rest of the time, in place of the picture")},
                {mood: "talk", name: qsTr("Talking"), detail: qsTr("Saying something")},
                {mood: "think", name: qsTr("Thinking"), detail: qsTr("An answer is being written")},
                {mood: "happy", name: qsTr("Happy"), detail: qsTr("An answer is ready, work is done")},
                {mood: "worried", name: qsTr("Worried"), detail: qsTr("Something failed")},
                {mood: "rest", name: qsTr("Break"), detail: qsTr("Time for a break")},
                {mood: "sleepy", name: qsTr("Sleepy"), detail: qsTr("Nothing for a while")},
                {mood: "held", name: qsTr("Held"), detail: qsTr("Being dragged")},
                {mood: "poke", name: qsTr("Poked"), detail: qsTr("Clicked")}]
            delegate: SettingsRow {
                id: moodRow
                required property var modelData
                readonly property var faces: Theme.pictureMoods[modelData.mood] || null
                readonly property int count: faces ? faces.frames.length : 0
                objectName: "petMood-" + modelData.mood
                label: modelData.name
                detail: modelData.detail
                Repeater {
                    model: moodRow.faces ? moodRow.faces.frames : []
                    delegate: Rectangle {
                        id: faceTile
                        required property var modelData
                        required property int index
                        objectName: "petFace-" + moodRow.modelData.mood + "-" + index
                        width: 40; height: 40; radius: Theme.radiusSmall
                        color: "transparent"
                        border.width: 1
                        border.color: tileHover.hovered ? Theme.border : Theme.separator
                        Image {
                            anchors.fill: parent; anchors.margins: 3
                            source: faceTile.modelData.url
                            fillMode: Image.PreserveAspectFit
                            sourceSize: Qt.size(80, 80)
                            asynchronous: true
                        }
                        HoverHandler { id: tileHover }
                        ContextTap { onRequested: { faceMenu.mood = moodRow.modelData.mood; faceMenu.index = faceTile.index; faceMenu.popup() } }
                        Accessible.role: Accessible.Graphic
                        Accessible.name: moodRow.modelData.name + " " + (index + 1)
                    }
                }
                IconButton {
                    objectName: "petFaceAdd-" + moodRow.modelData.mood
                    visible: moodRow.count < 6
                    icon.name: "add"; description: qsTr("Add faces")
                    onClicked: { faceDialog.mood = moodRow.modelData.mood; faceDialog.open() }
                }
                ComboBox {
                    objectName: "petFaceMode-" + moodRow.modelData.mood
                    visible: moodRow.count > 1
                    Layout.preferredWidth: 110
                    model: [qsTr("Random"), qsTr("In turn")]
                    currentIndex: moodRow.faces && moodRow.faces.mode === "cycle" ? 1 : 0
                    onActivated: function(index) { Theme.setPictureMoodMode(moodRow.modelData.mood, index ? "cycle" : "random") }
                }
            }
        }
    }
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
    Menu {
        id: faceMenu
        objectName: "petFaceMenu"
        property string mood: ""
        property int index: -1
        MenuItem {
            objectName: "removePetFace"
            text: qsTr("Remove Face")
            palette.windowText: Theme.danger
            onTriggered: Theme.removePictureMood(faceMenu.mood, faceMenu.index)
        }
    }
    Native.FileDialog {
        id: pictureDialog
        objectName: "pictureDialog"
        title: qsTr("Choose a Picture")
        nameFilters: [qsTr("Pictures") + " (" + Theme.pictureFilter + ")"]
        onAccepted: {
            root.problem = Theme.usePicture(selectedFile) ? "" : qsTr("This picture could not be opened.")
        }
    }
    Native.FileDialog {
        id: faceDialog
        objectName: "petFaceDialog"
        property string mood: "talk"
        title: qsTr("Choose Faces for the Pet")
        fileMode: Native.FileDialog.OpenFiles
        nameFilters: [qsTr("Pictures") + " (" + Theme.pictureFilter + ")"]
        // Each one that can be read, while there is room.
        onAccepted: {
            const failed = selectedFiles.filter(function(file) { return !Theme.addPictureMood(mood, file) })
            root.faceProblem = failed.length ? qsTr("Some pictures could not be added (unreadable, or six already).") : ""
        }
    }
}
