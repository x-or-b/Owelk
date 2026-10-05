import QtQuick
import QtTest
import Owelk.Ui

Item {
    width: 200; height: 100
    Rectangle { id: swatch; anchors.fill: parent; color: Theme.window }
    Text { id: label; text: "Aa"; font.pixelSize: Theme.fontBody }
    TestCase {
        name: "Theme"
        when: windowShown
        function cleanup() {
            Theme.theme = "neutral"; Theme.accentName = "blue"; Theme.textSize = 13
            researchStore.setSetting("appearance.custom", "")
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
