import QtQuick
import QtTest
import Owelk.Ui
import "../qml" as App

Item {
    width: 200; height: 100
    Rectangle { id: swatch; anchors.fill: parent; color: Theme.window }
    Text { id: label; text: "Aa"; font.pixelSize: Theme.fontBody }
    App.PictureLayer { id: wholeArea; width: 1000; height: 800; visible: false }
    // A part of the same area, like a PDF page: it shows the same part of the picture.
    App.PictureLayer { id: partOfArea; width: 200; height: 100; areaWidth: 1000; areaHeight: 800; origin: Qt.point(700, 600) }
    TestCase {
        name: "Theme"
        when: windowShown
        function cleanup() {
            while (Theme.pictures.length) Theme.removePicture()
            Theme.pictureStrength = 35
            Theme.clearCustomAccent()
            Theme.theme = "neutral"; Theme.accentName = "blue"; Theme.textSize = 13
            researchStore.setSetting("appearance.custom", "")
        }
        // WCAG relative luminance.
        function luminance(c) {
            const linear = function(v) { return v <= .03928 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4) }
            return .2126 * linear(c.r) + .7152 * linear(c.g) + .0722 * linear(c.b)
        }
        function test_themesSwitchLiveAndPersist() {
            compare(Theme.themes.map(function(t) { return t.id }), ["neutral", "paper", "solarized", "dark", "nord", "onedark", "dracula"])
            compare(Theme.dark, false)
            const light = Qt.color(Theme.window)
            Theme.theme = "dark"
            compare(Theme.dark, true)
            compare(researchStore.setting("appearance.theme"), "dark")
            verify(!Qt.colorEqual(Theme.window, light))
            verify(Qt.colorEqual(swatch.color, Theme.window), "bindings follow the theme")
            // Text stays readable: it is far from its background in every theme.
            for (const t of Theme.themes) {
                Theme.theme = t.id
                const a = Theme.text, b = Theme.content
                verify(Math.abs((a.r + a.g + a.b) - (b.r + b.g + b.b)) > 1.6, t.id)
            }
            Theme.theme = "nonsense"
            compare(Theme.theme, "dracula", "unknown themes are ignored")
        }
        function test_accentNeverChangesInks() {
            const inks = JSON.stringify(Theme.annotationInks)
            compare(Theme.accents.length, 7)
            const blue = Qt.color(Theme.accent)
            Theme.accentName = "green"
            verify(!Qt.colorEqual(Theme.accent, blue))
            verify(Qt.colorEqual(Theme.captureBorder, Theme.accent))
            compare(JSON.stringify(Theme.annotationInks), inks)
            compare(Theme.annotationInks.map(function(ink) { return ink.value }), researchStore.annotationColors)
            compare(researchStore.setting("appearance.accent"), "green")
        }
        function test_customAccentKeepsHueAndSaturation() {
            verify(!Theme.setCustomAccent("not a color"))
            Theme.accentName = "custom"
            compare(Theme.accentName, "blue", "no custom accent stored yet")
            // A pale yellow is too light for white labels: only its lightness moves.
            const yellow = Qt.color("#f5dc6e")
            verify(Theme.setCustomAccent("#f5dc6e"))
            compare(Theme.accentName, "custom")
            compare(researchStore.setting("appearance.customAccent"), "#f5dc6e")
            compare(Theme.accents.length, 8)
            for (const dark of [false, true]) {
                Theme.theme = dark ? "dark" : "neutral"
                const a = Theme.accent
                fuzzyCompare(a.hslHue, yellow.hslHue, .01)
                fuzzyCompare(a.hslSaturation, yellow.hslSaturation, .02)
                verify(a.hslLightness < yellow.hslLightness)
                verify(luminance(a) <= (dark ? .26 : .19) + .002, "white labels stay readable")
            }
            // A color already like the named accents is used as it is.
            verify(Theme.setCustomAccent("#426b9a"))
            Theme.theme = "neutral"
            verify(Qt.colorEqual(Theme.accent, "#426b9a"))
            // A very dark navy is lifted in a dark theme so it stands out from the surfaces.
            verify(Theme.setCustomAccent("#101c33"))
            Theme.theme = "dark"
            verify(luminance(Theme.accent) >= .16)
            Theme.accentName = "green"
            compare(Theme.accentName, "green")
            Theme.accentName = "custom"
            compare(Theme.accentName, "custom", "the stored custom accent can be picked again")
            Theme.clearCustomAccent()
            compare(Theme.accentName, "blue")
            compare(Theme.accents.length, 7)
        }
        function test_pictureIsLaidOutWithoutStretching() {
            const image = findChild(wholeArea, "pictureImage"), part = findChild(partOfArea, "pictureImage")
            verify(!partOfArea.visible, "no picture, nothing shown")
            compare(String(image.source), "")
            // A tall cut-out stands at the bottom right at the area's height.
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            compare(Theme.pictureSize, Qt.size(400, 1040))
            verify(Theme.pictureShown)
            verify(partOfArea.visible)
            tryCompare(part, "status", Image.Ready)
            fuzzyCompare(image.height, 800, .5)
            fuzzyCompare(image.width, 800 * 400 / 1040, .5)
            fuzzyCompare(image.x, 1000 - image.width, .5)
            compare(image.y, 0)
            compare(image.fillMode, Image.PreserveAspectFit)
            compare(part.x, image.x - 700); compare(part.y, image.y - 600); compare(part.width, image.width)
            fuzzyCompare(part.opacity, .35, .001)
            // A wide one is no wider than 45% of the area.
            verify(Theme.usePicture(testInput.pictureFile(1000, 1000, true)))
            fuzzyCompare(image.width, 450, .5); fuzzyCompare(image.height, 450, .5); fuzzyCompare(image.y, 350, .5)
            // A full picture covers the area, cropped.
            verify(Theme.usePicture(testInput.pictureFile(1600, 900, false)))
            verify(!Theme.pictureCutout)
            compare(image.width, 1000); compare(image.height, 800)
            compare(image.fillMode, Image.PreserveAspectCrop)
            Theme.pictureStrength = 0
            verify(!partOfArea.visible)
            Theme.pictureStrength = 35
            // Another theme keeps the picture without showing it.
            Theme.theme = "nord"
            verify(!Theme.pictureShown)
            verify(!partOfArea.visible)
            compare(String(part.source), "")
        }
        function test_textSizeScalesTypeAndControls() {
            compare(Theme.fontBody, 13); compare(Theme.controlHeight, 26); compare(Theme.rowHeight, 28)
            Theme.textSize = 15
            compare(label.font.pixelSize, 15)
            compare(Theme.fontCaption, 13); compare(Theme.controlHeight, 30)
            Theme.textSize = 40
            compare(Theme.textSize, 17, "clamped")
        }
        function test_customSeeds() {
            const seeds = Theme.seeds("paper")
            seeds.window = "#123456"
            verify(Theme.setCustomSeeds(seeds))
            compare(Theme.theme, "custom")
            verify(Qt.colorEqual(Theme.window, "#123456"))
            seeds.text = "not a color"
            verify(!Theme.setCustomSeeds(seeds))
            // Broken stored JSON falls back to Neutral's seeds.
            researchStore.setSetting("appearance.custom", "{broken")
            compare(Theme.seeds("custom").window, Theme.seeds("neutral").window)
        }
    }
}
