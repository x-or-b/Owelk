import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui
import "../qml" as App
import "../qml/SettingsIndex.js" as SettingsIndex

Item {
    id: scene
    width: 1100; height: 760
    App.SettingsDialog { id: settings }
    App.ReaderPane { id: reader; x: 0; y: 0; width: 500; height: 600; paneIndex: 0; isActive: true; visible: false }
    TestCase {
        name: "Settings"
        when: windowShown
        function visualChild(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            const children = item.children || []
            for (let i = 0; i < children.length; ++i) { const found = visualChild(children[i], name); if (found) return found }
            return null
        }
        function page() { return findChild(settings, "settingsPageLoader").item }
        function cleanup() {
            settings.close(); tryCompare(settings, "visible", false)
            Theme.theme = "neutral"; Theme.accentName = "blue"; Theme.textSize = 13; Theme.invertPages = false; Theme.appIcon = "paper"
            researchStore.setSetting("appearance.custom", "")
        }
        function test_categoriesLoadOneAtATime() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            for (const id of ["general", "appearance", "shortcuts", "library", "web", "search", "ai", "sync"]) {
                mouseClick(visualChild(settings.contentItem, "settingsPage-" + id))
                compare(settings.page, id)
                tryVerify(function() { return page() !== null })
            }
            // Only the shown page exists.
            verify(visualChild(settings.contentItem, "themeTile-dark") === null)
            verify(visualChild(settings.contentItem, "backUpNow") !== null)
            verify(visualChild(settings.contentItem, "syncFolder") !== null)
        }
        function test_fileNamePartsTurnOnAndMove() {
            researchStore.setSetting("pdfNames.parts", "")
            settings.openPage("library"); tryCompare(settings, "opened", true)
            let year = null
            tryVerify(function() { year = visualChild(settings.contentItem, "pdfNameSwitch-year"); return year !== null })
            const p = page()
            compare(p.namesOn, ["title"])
            verify(!visualChild(settings.contentItem, "pdfNameSwitch-title").enabled, "the last part on stays on")
            year.toggle(); year.toggled()
            compare(researchStore.setting("pdfNames.parts"), "title,-author,year,-arxiv")
            // Year moves up, above the title.
            tryVerify(function() { return visualChild(settings.contentItem, "pdfNameUp-year") !== null })
            visualChild(settings.contentItem, "pdfNameUp-year").clicked()
            visualChild(settings.contentItem, "pdfNameUp-year").clicked()
            compare(p.namesOn, ["year", "title"])
            compare(researchStore.sampleFileName(p.namesOn), "2017 - Attention Is All You Need.pdf")
            verify(findChild(settings, "pdfNameGroup").note.indexOf("2017 - Attention") >= 0)
            researchStore.setSetting("pdfNames.parts", "")
        }
        function test_hiddenEngineShowsCrossedEye() {
            settings.openPage("web"); tryCompare(settings, "opened", true)
            let eye = null
            tryVerify(function() { eye = visualChild(settings.contentItem, "showEngine-DuckDuckGo"); return eye !== null })
            compare(eye.icon.name, "preview")
            eye.clicked()
            tryVerify(function() { return eye.icon.name === "hidden" })
            eye.clicked()
            tryVerify(function() { return eye.icon.name === "preview" })
        }
        // The search index names real places: every anchor is on its page.
        function test_searchIndexPointsAtRealSettings() {
            settings.openPage("general"); tryCompare(settings, "opened", true)
            const missing = []
            for (const entry of SettingsIndex.all()) {
                settings.page = entry.page
                tryVerify(function() { return page() !== null })
                if (!settings.findAnchor(page(), entry.anchor)) missing.push(entry.page + ":" + entry.anchor)
            }
            compare(missing, [])
        }
        function test_searchOpensTheSetting() {
            settings.openPage("general"); tryCompare(settings, "opened", true)
            const field = visualChild(settings.contentItem, "settingsSearch")
            field.text = "dark pdf"; field.textEdited()
            verify(settings.results.length >= 1)
            compare(settings.results[0].anchor, "settingsRow-darkPages")
            verify(visualChild(settings.contentItem, "settingsPage-general") === null, "results take the place of the pages")
            mouseClick(visualChild(settings.contentItem, "settingsResult-0"))
            compare(settings.page, "appearance")
            const flash = findChild(settings, "settingsFlash")
            tryVerify(function() { return flash.opacity > 0 })
            // Words people type for a setting find it too, and shortcuts are found by their action.
            field.text = "font"; field.textEdited()
            verify(settings.results.some(function(r) { return r.anchor === "settingsRow-textSize" }))
            field.text = "close tab"; field.textEdited()
            verify(settings.results.some(function(r) { return r.anchor === "settingsRow-shortcut-closeTab" }))
            field.text = "zzzz nothing"; field.textEdited()
            compare(settings.results.length, 0)
            settings.close(); tryCompare(settings, "visible", false)
            compare(settings.query, "")
        }
        function test_themeAccentAndTextSizeApplyAtOnce() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "themeTile-dark") !== null })
            waitForPolish(settings.contentItem); wait(50)
            mouseClick(visualChild(settings.contentItem, "themeTile-dark"), 40, 30)
            compare(Theme.theme, "dark")
            compare(researchStore.setting("appearance.theme"), "dark")
            mouseClick(visualChild(settings.contentItem, "accent-green"))
            compare(Theme.accentName, "green")
            const slider = visualChild(settings.contentItem, "textSizeSlider")
            slider.value = 15; slider.moved()
            compare(Theme.textSize, 15)
            compare(Theme.fontBody, 15)
        }
        function test_appIconChoice() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            let navy = null
            tryVerify(function() { navy = visualChild(settings.contentItem, "appIcon-navy"); return navy !== null })
            compare(Theme.appIcons.length, 3)
            // Scroll the page to the choice before clicking it.
            let flick = navy.parent
            while (flick && flick.contentItem === undefined) flick = flick.parent
            if (flick) flick.contentY = Math.max(0, navy.mapToItem(flick.contentItem, 0, 0).y - 40)
            waitForPolish(settings.contentItem); wait(50)
            mouseClick(navy)
            compare(Theme.appIcon, "navy")
            compare(researchStore.setting("appearance.appIcon"), "navy")
            Theme.appIcon = "unknown"
            compare(Theme.appIcon, "paper")
        }
        function test_customThemeStartsFromTheCurrentOne() {
            Theme.theme = "paper"
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "themeTile-custom") !== null })
            waitForPolish(settings.contentItem); wait(50)
            mouseClick(visualChild(settings.contentItem, "themeTile-custom"), 40, 30)
            compare(Theme.theme, "custom")
            compare(Theme.seeds("custom").window, Theme.seeds("paper").window)
            tryVerify(function() { return visualChild(settings.contentItem, "seed-window") !== null })
            mouseClick(visualChild(settings.contentItem, "customDarkSwitch"))
            compare(Theme.dark, true)
        }
        function test_aiPageAsksForTheAccountOnce() {
            // Reading the ChatGPT account refreshes the provider list; that must not ask again (a loop
            // that kept the CPU busy while Settings existed).
            const before = researchStore.ai.provider
            researchStore.ai.provider = "codex"
            const spy = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "codexAccountChanged" }', scene)
            spy.target = researchStore.ai
            settings.openPage("ai"); tryCompare(settings, "opened", true)
            wait(1500)
            const settled = spy.count
            wait(3000)
            // Late answers to earlier requests can still arrive in a busy run; the old loop read the
            // account dozens of times a second.
            verify(spy.count - settled < 5, "the account is not read again and again: " + (spy.count - settled) + " more reads in 3 s")
            settings.close()
            researchStore.ai.provider = before
            spy.destroy()
        }
        function test_aiInstructionsAndGlossModelAreKept() {
            settings.openPage("ai"); tryCompare(settings, "opened", true)
            tryVerify(function() { return findChild(settings, "aiInstructions") !== null })
            const instructions = findChild(settings, "aiInstructions")
            instructions.text = "  Put English terms in brackets.  "
            instructions.editingFinished()
            compare(researchStore.setting("ai.instructions"), "Put English terms in brackets.")
            // Models are chosen from the provider's list, as in the AI panel: the chat model and its
            // reasoning, and Gloss's own.
            const before = researchStore.ai.provider, chatModel = researchStore.ai.model("claude")
            researchStore.ai.provider = "claude"
            const models = findChild(settings, "aiModelBox")
            tryVerify(function() { return models.count > 2 })
            models.activated(1)
            compare(researchStore.ai.model("claude"), "claude-sonnet-5-5")
            const effort = findChild(settings, "aiEffortBox")
            tryCompare(effort, "visible", true)
            effort.activated(effort.model.indexOf("High"))
            compare(researchStore.setting("ai.effort.claude"), "high")
            // Other… takes a model name.
            models.activated(models.count - 1)
            tryCompare(findChild(settings, "aiModelField"), "visible", true)
            const gloss = findChild(settings, "aiGlossModelBox")
            compare(gloss.currentIndex, 0)
            compare(findChild(settings, "aiGlossEffortBox").visible, false) // Haiku has no effort levels.
            gloss.activated(2)
            compare(researchStore.ai.glossChoice("claude"), "claude-sonnet-5-5")
            tryCompare(findChild(settings, "aiGlossEffortBox"), "visible", true)
            gloss.activated(0)
            compare(researchStore.ai.glossChoice("claude"), "auto")
            researchStore.ai.setModel("claude", chatModel)
            researchStore.setSetting("ai.effort.claude", "")
            researchStore.ai.provider = before
            researchStore.setSetting("ai.instructions", "")
            settings.close()
        }
        function test_darkPagesOnlyWhileOn() {
            if (!Theme.canInvertPages) skip("built without Qt ShaderTools")
            reader.visible = true
            const canvas = findChild(reader, "pdfCanvas0")
            canvas.openFile(fixtureSource, {page: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
            tryVerify(function() { return findChild(canvas, "pageImage0") !== null })
            const image = findChild(canvas, "pageImage0")
            compare(image.layer.enabled, false, "no effect costs while the option is off")
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "invertPagesSwitch") !== null })
            visualChild(settings.contentItem, "invertPagesSwitch").toggle()
            visualChild(settings.contentItem, "invertPagesSwitch").toggled()
            compare(Theme.invertPages, true)
            compare(image.layer.enabled, true)
            settings.close()
            // The software renderer used for tests cannot run shaders; with a GPU, the page turns dark.
            if (reader.GraphicsInfo.api !== GraphicsInfo.Software) {
                wait(300); waitForRendering(image)
                const pixels = grabImage(image)
                verify(pixels.red(4, 4) < 60, "page corner should be dark, got " + pixels.red(4, 4))
            }
            Theme.invertPages = false
            compare(image.layer.enabled, false)
            reader.visible = false
        }
    }
}
