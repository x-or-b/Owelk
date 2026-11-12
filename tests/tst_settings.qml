import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui
import "../qml" as App
import "../qml/SettingsIndex.js" as SettingsIndex
import "../qml/ThemeGallery.js" as Gallery

Item {
    id: scene
    width: 1100; height: 760
    App.SettingsDialog { id: settings }
    Component { id: spyComponent; SignalSpy {} }
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
        // A page of the open Settings, once it is made.
        function show(id) {
            settings.page = id
            tryVerify(function() { return page() !== null && page().objectName === pageNames[id] })
            waitForPolish(settings.contentItem)
            return page()
        }
        readonly property var pageNames: ({general: "generalSettings", appearance: "appearanceSettings", picture: "pictureSettings",
            shortcuts: "shortcutSettings", reading: "readingSettings", library: "librarySettings", foryou: "forYouSettings",
            web: "webSettings", search: "searchSettings", ai: "aiSettings", sync: "syncSettings"})
        function cleanup() {
            settings.close(); tryCompare(settings, "visible", false)
            while (Theme.pictures.length) Theme.removePicture()
            Theme.pictureOn = true
            Theme.pictureInterval = 0
            Theme.matchSystem = false; Theme.lightTheme = "neutral"; Theme.darkTheme = "dark"
            Theme.theme = "neutral"; Theme.accentName = "blue"; Theme.textSize = 13; Theme.invertPages = false; Theme.appIcon = "paper"
            researchStore.setSetting("appearance.custom", "")
            Theme.myThemes.forEach(function(t) { Theme.removeTheme(t.id) })
        }
        function test_categoriesLoadOneAtATime() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            for (const id of ["general", "appearance", "shortcuts", "reading", "library", "foryou", "web", "search", "ai", "sync"]) {
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
            verify(findChild(settings, "settingsGroup-pdfNames").note.indexOf("2017 - Attention") >= 0)
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
        function test_homeSectionsChosenInGeneral() {
            settings.openPage("general#settingsGroup-home")
            tryVerify(function() { return visualChild(settings.contentItem, "settingsGroup-home") !== null })
            const group = visualChild(settings.contentItem, "settingsGroup-home")
            // Off: saved with a "-"; moved: saved in the new order; the sketch follows.
            const notes = visualChild(group, "homeSectionSwitch-notes")
            notes.toggle(); notes.toggled()
            compare(researchStore.setting("home.sections"), "foryou,reading,collections,recent,-notes,threads")
            visualChild(group, "homeSectionUp-reading").clicked()
            compare(researchStore.setting("home.sections"), "reading,foryou,collections,recent,-notes,threads")
            tryVerify(function() { return visualChild(group, "homeLayoutSketch").children.length === 4 + 1 })
            const reset = visualChild(group, "homeSectionsReset")
            verify(reset.enabled)
            mouseClick(reset)
            compare(researchStore.setting("home.sections"), "foryou,reading,collections,recent,notes,threads")
            verify(!reset.enabled)
            researchStore.setSetting("home.sections", "")
            settings.close()
        }
        function test_searchIndexPointsAtRealSettings() {
            // With a picture, so its page is listed too.
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            settings.openPage("general"); tryCompare(settings, "opened", true)
            const missing = []
            for (const entry of SettingsIndex.all()) {
                show(entry.page)
                if (!settings.findAnchor(page(), entry.anchor)) missing.push(entry.page + ":" + entry.anchor)
            }
            compare(missing, [])
        }
        // And the other way: every group and row on every page has a name, and is found by search, itself (named
        // settingsGroup-… or settingsRow-…) or through its group (rows a Repeater makes).
        function test_everySettingIsFoundBySearch() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            settings.openPage("general"); tryCompare(settings, "opened", true)
            const listed = {}
            SettingsIndex.all().forEach(function(e) { listed[e.page + ":" + e.anchor] = true })
            const indexed = function(name) { return name.indexOf("settingsRow-") === 0 || name.indexOf("settingsGroup-") === 0 }
            const problems = []
            let seen = 0
            for (const entry of settings.pages) {
                show(entry.id)
                const walk = function(item, group) {
                    const isGroup = "noteColor" in item && "rows" in item, isRow = "wide" in item && "detail" in item && "control" in item
                    if (isGroup || isRow) {
                        ++seen
                        const name = item.objectName, where = entry.id + ":" + (name || (isGroup ? item.title : item.label))
                        if (!name.length) problems.push("unnamed " + where)
                        else if (indexed(name)) { if (!listed[entry.id + ":" + name]) problems.push("not in search " + where) }
                        else if (isRow && !(group && indexed(group.objectName))) problems.push("in no listed group " + where)
                    }
                    const children = item.children || []
                    for (let i = 0; i < children.length; ++i) walk(children[i], isGroup ? item : group)
                }
                walk(page(), null)
            }
            compare(problems, [])
            verify(seen > 150, "every page's groups and rows were looked at: " + seen)
        }
        function test_searchOpensTheSetting() {
            settings.openPage("general"); tryCompare(settings, "opened", true)
            const field = visualChild(settings.contentItem, "settingsSearch")
            field.text = "dark pdf"; field.textEdited()
            verify(settings.results.length >= 1)
            compare(settings.results[0].anchor, "settingsRow-darkPages")
            compare(settings.results[0].where, "Reading \u203a PDF pages")
            verify(visualChild(settings.contentItem, "settingsPage-general") === null, "results take the place of the pages")
            mouseClick(visualChild(settings.contentItem, "settingsResult-0"))
            compare(settings.page, "reading")
            const flash = findChild(settings, "settingsFlash")
            tryVerify(function() { return flash.opacity > 0 })
            // Words people type for a setting find it too, and shortcuts are found by their action.
            field.text = "font"; field.textEdited()
            verify(settings.results.some(function(r) { return r.anchor === "settingsRow-textSize" }))
            field.text = "close tab"; field.textEdited()
            verify(settings.results.some(function(r) { return r.anchor === "settingsRow-shortcut-closeTab" }))
            // The picture's settings are found only while its page is listed.
            field.text = "pet"; field.textEdited()
            verify(!settings.results.some(function(r) { return r.page === "picture" }))
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            field.text = "pet"; field.textEdited()
            verify(settings.results.some(function(r) { return r.anchor === "settingsRow-petBreak" }))
            Theme.removePicture()
            field.text = "zzzz nothing"; field.textEdited()
            compare(settings.results.length, 0)
            settings.close(); tryCompare(settings, "visible", false)
            compare(settings.query, "")
        }
        function test_forYouSettingsLeadToFollowing() {
            const forYou = researchStore.forYou
            forYou.saveTopics([{words: "visual SLAM", categories: "cs.RO"}])
            settings.openPage("foryou"); tryCompare(settings, "opened", true)
            // What is followed is chosen in For You itself; Settings counts it and leads there.
            let row = null
            tryVerify(function() { row = visualChild(settings.contentItem, "settingsRow-following"); return row !== null })
            verify(row.label.indexOf("1 ") === 0, row.label)
            const asked = createTemporaryObject(spyComponent, scene, {target: forYou, signalName: "manageRequested"})
            visualChild(settings.contentItem, "forYouEditFollowing").clicked()
            compare(asked.count, 1)
            forYou.saveTopics([])
        }
        function test_forYouExplainWithAiAsksFirst() {
            const forYou = researchStore.forYou
            settings.openPage("foryou"); tryCompare(settings, "opened", true)
            // Explain with AI waits for an AI to be set up; turning it on is the OK to send papers to it.
            researchStore.ai.provider = "claude"
            researchStore.ai.clearApiKey("claude")
            researchStore.setSetting("ai.consent.claude", "")
            let explain = null
            tryVerify(function() { explain = visualChild(settings.contentItem, "forYouAi"); return explain !== null })
            tryVerify(function() { return !explain.enabled })
            verify(researchStore.ai.setApiKey("claude", "sk-settings-test"))
            tryVerify(function() { return explain.enabled && !explain.checked })
            explain.toggle(); explain.toggled()
            verify(researchStore.ai.consented("claude"))
            compare(researchStore.setting("forYou.ai"), "1")
            tryVerify(function() { return explain.checked })
            verify(forYou.aiReady())
            researchStore.ai.clearApiKey("claude")
            researchStore.setSetting("ai.consent.claude", "")
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
            // Any color of one's own, from the + after them.
            verify(visualChild(settings.contentItem, "accentAdd") !== null)
            const picker = findChild(page(), "accentColorDialog")
            picker.selectedColor = "#9ab8db"; picker.accepted()
            compare(Theme.accentName, "custom")
            compare(Theme.customAccent.toString(), "#9ab8db")
            tryVerify(function() { return visualChild(settings.contentItem, "accent-custom") !== null })
            waitForPolish(settings.contentItem); wait(50)
            mouseClick(visualChild(settings.contentItem, "accent-green"))
            compare(Theme.accentName, "green")
            const slider = visualChild(settings.contentItem, "textSizeSlider")
            slider.value = 15; slider.moved()
            compare(Theme.textSize, 15)
            compare(Theme.fontBody, 15)
        }
        function test_matchSystemChoosesAThemeForEachAppearance() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            let on = null
            tryVerify(function() { on = visualChild(settings.contentItem, "matchSystemSwitch"); return on !== null })
            const darkBox = visualChild(settings.contentItem, "matchSystem-dark")
            verify(!darkBox.visible, "the choices show only while it is on")
            on.toggle(); on.toggled()
            compare(Theme.matchSystem, true)
            tryVerify(function() { return darkBox.visible })
            darkBox.activated(darkBox.ids.indexOf("nord"))
            compare(Theme.darkTheme, "nord")
            compare(darkBox.currentIndex, darkBox.ids.indexOf("nord"))
            // With the picture theme in use it is for both appearances: no theme for each, its Dark switch follows.
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            tryVerify(function() { return !darkBox.visible })
            let darkSwitch = null
            tryVerify(function() { darkSwitch = visualChild(settings.contentItem, "customDarkSwitch"); return darkSwitch !== null && darkSwitch.visible })
            verify(!darkSwitch.enabled)
            on.toggle(); on.toggled()
            compare(Theme.matchSystem, false)
            verify(darkSwitch.enabled)
            Theme.removePicture()
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
        // + › Custom Theme: one of one's own from the colors in use, its colors shown to change; light or dark as made.
        function test_customThemeMadeWithPlus() {
            Theme.theme = "paper"
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "addTheme") !== null })
            verify(!visualChild(settings.contentItem, "themeTile-custom").visible, "no Custom tile without a picture")
            waitForPolish(settings.contentItem); wait(50)
            mouseClick(visualChild(settings.contentItem, "addTheme"), 40, 30)
            const menu = findChild(page(), "addThemeMenu")
            tryCompare(menu, "opened", true)
            verify(findChild(menu, "copyTheme") === null)
            findChild(menu, "customTheme").triggered()
            menu.close()
            verify(Theme.isMine(Theme.theme))
            compare(Theme.seeds(Theme.theme).window, Theme.seeds("paper").window)
            compare(Theme.myThemes[0].name, "Custom")
            // Its colors, scrolled to and lit; its name, Dark and Delete below; Match System offers it.
            const flash = findChild(settings, "settingsFlash")
            tryVerify(function() { return flash.opacity > 0 })
            const name = visualChild(settings.contentItem, "themeNameField")
            tryVerify(function() { return name.visible })
            name.text = "Evening paper"; name.editingFinished()
            compare(Theme.myThemes[0].name, "Evening paper")
            verify(visualChild(settings.contentItem, "seed-window") !== null)
            const dark = visualChild(settings.contentItem, "customDarkSwitch")
            verify(dark.visible && dark.enabled)
            dark.toggle(); dark.toggled()
            verify(Theme.dark)
            verify(Theme.seeds(Theme.theme).dark)
            verify(visualChild(settings.contentItem, "matchSystem-light").ids.indexOf(Theme.theme) >= 0)
            verify(visualChild(settings.contentItem, "themeTile-" + Theme.theme).current)
            // Another one is Custom 2.
            page().newCustom()
            compare(Theme.myThemes.map(function(t) { return t.name }), ["Evening paper", "Custom"])
            page().newCustom()
            compare(Theme.myThemes[2].name, "Custom 2")
            visualChild(settings.contentItem, "deleteTheme").clicked()
            compare(Theme.myThemes.length, 2)
        }
        // Well-known themes, pictured: narrowed by what is typed, added as one's own with their accent, once.
        function test_galleryAddsAWellKnownTheme() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return findChild(page(), "addThemeMenu") !== null })
            findChild(page(), "galleryTheme").triggered()
            const gallery = findChild(page(), "themeGallery")
            tryCompare(gallery, "opened", true)
            compare(gallery.shown.length, 25)
            compare(gallery.shown.filter(function(t) { return t.dark }).length, 15)
            const search = findChild(gallery.contentItem, "themeGallerySearch")
            search.text = "mocha"; search.textEdited()
            compare(gallery.shown.map(function(t) { return t.name }), ["Catppuccin Mocha"])
            search.text = "warm light"; search.textEdited()
            verify(gallery.shown.length >= 2 && gallery.shown.every(function(t) { return !t.dark }))
            search.text = "one dark"; search.textEdited()
            compare(gallery.shown[0].seeds.content, Theme.seeds("onedark").content, "One Dark keeps its built-in colors")
            search.text = "mocha"; search.textEdited()
            let tile = null
            tryVerify(function() { tile = visualChild(gallery.contentItem, "galleryTheme-Catppuccin Mocha"); return tile !== null && tile.visible })
            waitForPolish(gallery.contentItem); wait(50)
            mouseClick(tile, 40, 30)
            tryCompare(gallery, "opened", false)
            verify(Theme.isMine(Theme.theme))
            compare(Theme.myThemes.map(function(t) { return t.name }), ["Catppuccin Mocha"])
            verify(Theme.dark)
            compare(Theme.accentName, "custom")
            compare(Theme.customAccent.toString(), "#cba6f7")
            // Chosen again: the same theme, not a second copy.
            Theme.theme = "neutral"
            gallery.choose(Gallery.find("mocha", function(id) { return Theme.seeds(id) })[0])
            compare(Theme.myThemes.length, 1)
            compare(Theme.theme, Theme.myThemes[0].id)
        }
        // A photo's colors, the one chosen showing as much as asked, in a light and a dark version added as one's own.
        function test_aThemeFromAPhoto() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return findChild(page(), "themeMaker") !== null })
            const maker = findChild(page(), "themeMaker")
            maker.fromPhoto(testInput.pictureFile(400, 300, false, "#4f8fd9"))
            tryCompare(maker, "opened", true)
            verify(maker.colors.length >= 1)
            compare(maker.chosen.toString(), maker.colors[0])
            // Stronger, the light version's window holds more of the color.
            const subtle = Theme.tintedSeeds(maker.chosen, false, 1).window
            maker.strength = 3
            verify(maker.lightSeeds.window !== subtle)
            verify(maker.darkSeeds.dark && !maker.lightSeeds.dark)
            findChild(maker.contentItem, "makerName").text = "Sky"
            const wasDark = Theme.dark
            findChild(maker.footer, "makerAddBoth").clicked()
            tryCompare(maker, "opened", false)
            compare(Theme.myThemes.map(function(t) { return t.name }), ["Sky", "Sky Dark"])
            compare(Theme.dark, wasDark)
            compare(Theme.accentName, "custom")
            compare(Theme.customAccent.toString(), maker.chosen.toString())
            // With Match System, each version is the theme for its appearance.
            Theme.matchSystem = true
            maker.fromPhoto(testInput.pictureFile(400, 300, false, "#d98f4f"))
            tryCompare(maker, "opened", true)
            findChild(maker.contentItem, "makerName").text = "Dusk"
            findChild(maker.footer, "makerAddBoth").clicked()
            tryCompare(maker, "opened", false)
            const named = function(name) { return Theme.myThemes.find(function(t) { return t.name === name }).id }
            compare(Theme.lightTheme, named("Dusk"))
            compare(Theme.darkTheme, named("Dusk Dark"))
        }
        function test_fiveTapsOnTheThemeHeadingChooseAPicture() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return visualChild(settings.contentItem, "settingsGroup-theme") !== null })
            waitForPolish(settings.contentItem); wait(50)
            const group = visualChild(settings.contentItem, "settingsGroup-theme")
            const dialog = findChild(page(), "pictureDialog")
            verify(dialog !== null)
            for (let i = 0; i < 4; ++i) mouseClick(group, 20, 6)
            compare(dialog.visible, false)
            // A pause starts the count again.
            wait(1100)
            for (let i = 0; i < 4; ++i) mouseClick(group, 20, 6)
            compare(dialog.visible, false)
            mouseClick(group, 20, 6)
            tryCompare(dialog, "visible", true)
            dialog.reject()
            tryCompare(dialog, "visible", false)
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
        function test_answerTextChosenWithTheTextSize() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            tryVerify(function() { return findChild(settings, "answerSizeSlider") !== null })
            // A little larger than the rest by default; it follows the text size.
            compare(Theme.answerSize, Theme.textSize + 2)
            const slider = findChild(settings, "answerSizeSlider")
            slider.value = Theme.textSize + 4; slider.moved()
            compare(Theme.answerSize, 17)
            Theme.textSize = 14
            compare(Theme.answerSize, 18)
            Theme.textSize = 13
            // Line spacing changes the preview's height; the column and the drawing are switches.
            const preview = findChild(settings, "answerPreview")
            const comfortable = preview.contentHeight
            findChild(settings, "answerSpacingBox").activated(0)
            compare(Theme.answerSpacing, "compact")
            compare(researchStore.setting("ai.answerSpacing"), "compact")
            tryVerify(function() { return preview.contentHeight < comfortable })
            findChild(settings, "answerColumnSwitch").toggle(); findChild(settings, "answerColumnSwitch").toggled()
            compare(Theme.answerWidth, 0)
            findChild(settings, "answerNativeSwitch").toggle(); findChild(settings, "answerNativeSwitch").toggled()
            compare(preview.renderType, TextEdit.QtRendering)
            Theme.answerSize = 15; Theme.answerSpacing = "comfortable"; Theme.answerColumn = true; Theme.answerNative = true
            compare(preview.renderType, TextEdit.NativeRendering)
        }
        function test_picturePageOnlyWithAPicture() {
            settings.openPage("appearance"); tryCompare(settings, "opened", true)
            verify(visualChild(settings.contentItem, "settingsPage-picture") === null, "no Picture page without a picture")
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            tryVerify(function() { return visualChild(settings.contentItem, "settingsPage-picture") !== null })
            show("picture")
            verify(!visualChild(settings.contentItem, "pictureIntervalBox").visible)
            verify(visualChild(settings.contentItem, "pictureColor-" + Theme.pictureColors[0]).chosen, "the main color is the accent")
            // A color of the picture becomes the accent.
            const color = Theme.pictureColors[0]
            Theme.accentName = "green"
            wait(50)
            mouseClick(visualChild(settings.contentItem, "pictureColor-" + color))
            compare(Theme.accentName, "custom")
            verify(Qt.colorEqual(Theme.customAccent, color))
            // Dark (Appearance › Custom theme) tints the picture's colors again, for dark surfaces.
            show("appearance")
            tryVerify(function() { return visualChild(settings.contentItem, "customDarkSwitch") !== null })
            const darkSwitch = visualChild(settings.contentItem, "customDarkSwitch")
            darkSwitch.toggle(); darkSwitch.toggled()
            compare(Theme.dark, true)
            compare(Theme.seeds("custom").window, Theme.tintedSeeds(Theme.pictureColors[0], true).window)
            verify(Theme.seeds("custom").window !== Theme.tintedSeeds(Theme.pictureColors[0], false).window)
            darkSwitch.toggle(); darkSwitch.toggled()
            compare(Theme.dark, false)
            show("picture")
            const petSwitch = visualChild(settings.contentItem, "petSwitch")
            petSwitch.toggle(); petSwitch.toggled()
            compare(DesktopPet.enabled, true)
            verify(visualChild(settings.contentItem, "petSizeBox").visible)
            // The pet's faces, for each moment: shown as they are added, taking turns when chosen, gone when removed.
            const faces = visualChild(settings.contentItem, "settingsGroup-petFaces")
            verify(faces.visible)
            verify(visualChild(faces, "petMood-sleepy") !== null)
            verify(Theme.addPictureMood("think", testInput.pictureFile(500, 1300, true, "#a0c4f2")))
            verify(Theme.addPictureMood("think", testInput.pictureFile(500, 1300, true, "#a0f2c4")))
            let mode = null
            tryVerify(function() { mode = visualChild(faces, "petFaceMode-think"); return mode !== null && mode.visible })
            verify(visualChild(faces, "petFace-think-1") !== null)
            mode.activated(1)
            compare(Theme.pictureMoods.think.mode, "cycle")
            // Its menu (right-click) removes it.
            const faceMenu = findChild(page(), "petFaceMenu")
            faceMenu.mood = "think"; faceMenu.index = 1
            findChild(page(), "removePetFace").triggered()
            tryVerify(function() { return !mode.visible })
            Theme.removePictureMood("think", 0)
            compare(Theme.pictureMoods.think, undefined)
            // Left out of screen sharing only when chosen.
            const shared = visualChild(settings.contentItem, "petHideWhenShared")
            compare(shared.checked, false)
            shared.toggle(); shared.toggled()
            compare(DesktopPet.hiddenWhenShared, true)
            compare(researchStore.setting("pet.hideWhenShared"), "1")
            DesktopPet.hiddenWhenShared = false
            visualChild(settings.contentItem, "petBreakBox").activated(0)
            compare(DesktopPet.breakMinutes, 0)
            DesktopPet.breakMinutes = 50
            DesktopPet.enabled = false
            visualChild(settings.contentItem, "pictureAlignBox").activated(0)
            compare(Theme.pictureAlign, "left")
            Theme.pictureAlign = "right"
            // A cut-out's size, kept for each picture.
            const scale = visualChild(settings.contentItem, "pictureScaleSlider")
            verify(scale.visible)
            scale.value = 60; scale.moved()
            compare(Theme.pictureScale, 60)
            // Another theme keeps the picture; Custom goes back to it instead of copying that theme.
            const tinted = Theme.seeds("custom").window
            Theme.theme = "nord"
            compare(Theme.pictureShown, false)
            show("appearance")
            wait(50)
            mouseClick(visualChild(settings.contentItem, "themeTile-custom"), 40, 30)
            compare(Theme.theme, "custom")
            compare(Theme.seeds("custom").window, tinted)
            verify(Theme.pictureShown)
            // A second picture is kept beside the first; a thumbnail goes back to the first.
            show("picture")
            const first = String(Theme.picture)
            verify(Theme.usePicture(testInput.pictureFile(1000, 1000, true, "#6ec8f5")))
            verify(String(Theme.picture) !== first)
            compare(Theme.pictureScale, 100)
            const interval = visualChild(settings.contentItem, "pictureIntervalBox")
            verify(interval.visible)
            interval.activated(2)
            compare(Theme.pictureInterval, 60)
            Theme.pictureInterval = 0
            const secondWindow = Theme.seeds("custom").window
            wait(50)
            tryVerify(function() { return visualChild(settings.contentItem, "pictureThumb-1") !== null })
            verify(visualChild(settings.contentItem, "pictureThumb-1").modelData.current)
            mouseClick(visualChild(settings.contentItem, "pictureThumb-0"))
            compare(String(Theme.picture), first)
            compare(Theme.pictureScale, 60)
            verify(Theme.seeds("custom").window !== secondWindow)
            // The Custom theme's colors on Appearance follow the picture in use.
            show("appearance")
            tryVerify(function() { return Qt.colorEqual(visualChild(settings.contentItem, "seed-window").color, Theme.seeds("custom").window) })
            // Right-click removes one (once the thumbnails, made again for the new one in use, are laid out).
            show("picture")
            wait(50)
            mouseClick(visualChild(settings.contentItem, "pictureThumb-1"), 20, 20, Qt.RightButton)
            const menu = findChild(page(), "pictureMenu")
            tryCompare(menu, "opened", true)
            findChild(menu, "removePicture").triggered()
            compare(Theme.pictures.length, 1)
            compare(String(Theme.picture), first)
            // Off: the page goes and Settings shows Appearance; five taps there bring it back with the kept picture.
            const pictureOn = visualChild(settings.contentItem, "pictureOnSwitch")
            pictureOn.toggle(); pictureOn.toggled()
            compare(Theme.pictureOn, false)
            compare(String(Theme.picture), "")
            tryCompare(settings, "page", "appearance")
            verify(visualChild(settings.contentItem, "settingsPage-picture") === null)
            show("appearance")
            wait(50)
            const dialog = findChild(page(), "pictureDialog")
            const heading = visualChild(settings.contentItem, "settingsGroup-theme")
            for (let i = 0; i < 5; ++i) mouseClick(heading, 20, 6)
            compare(Theme.pictureOn, true)
            compare(dialog.visible, false)
            compare(String(Theme.picture), first)
            tryCompare(settings, "page", "picture")
            Theme.removePicture()
            compare(String(Theme.picture), "")
            tryCompare(settings, "page", "appearance")
            compare(Theme.theme, "neutral")
        }
        function test_pictureShowsThroughThePaper() {
            reader.visible = true
            const canvas = findChild(reader, "pdfCanvas0")
            canvas.openFile(fixtureSource, {page: 0, zoom: 1})
            tryCompare(canvas, "ready", true, 10000)
            tryVerify(function() { return findChild(canvas, "pagePicture0") !== null })
            const page = findChild(canvas, "pagePicture0"), around = findChild(canvas, "pdfPicture")
            compare(page.visible, false, "nothing while there is no picture")
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            verify(page.visible && around.visible)
            // As strong on the paper as around it.
            fuzzyCompare(findChild(page, "pictureImage").opacity, Theme.pictureStrength / 100, .001)
            fuzzyCompare(findChild(around, "pictureImage").opacity, Theme.pictureStrength / 100, .001)
            // The page shows the same part of the picture as around it, wherever it is scrolled to.
            const check = function() {
                const outer = findChild(around, "pictureImage"), inner = findChild(page, "pictureImage")
                const a = outer.mapToItem(canvas, 0, 0), b = inner.mapToItem(canvas, 0, 0)
                return Math.abs(a.x - b.x) < .5 && Math.abs(a.y - b.y) < .5 && Math.abs(outer.width - inner.width) < .5
            }
            verify(check())
            findChild(canvas, "pageList").contentY += 120
            verify(check())
            Theme.removePicture()
            compare(page.visible, false)
            reader.visible = false
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
            settings.openPage("reading"); tryCompare(settings, "opened", true)
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
