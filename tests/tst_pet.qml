import QtQuick
import QtQuick.Controls
import QtTest
import Owelk.Ui
import "../qml" as App

Item {
    width: 200; height: 100
    Component { id: petComponent; App.PetWindow {} }
    SignalSpy { id: openSpy; signalName: "openRequested" }
    SignalSpy { id: pokeSpy; signalName: "poked" }
    SignalSpy { id: threadSpy; signalName: "threadRequested" }
    SignalSpy { id: forYouSpy; signalName: "forYouRequested" }
    SignalSpy { id: pdfSpy; signalName: "pdfsDropped" }
    SignalSpy { id: explainSpy; signalName: "explainRequested" }
    SignalSpy { id: settingsSpy; signalName: "settingsRequested" }
    // Stand-ins for researchStore.ai and researchStore.forYou.
    QtObject {
        id: fakeAi
        signal started(int request, string threadId, string provider, string model, bool truncated)
        signal finished(int request, string text, var details)
        signal failed(int request, string error)
    }
    QtObject { id: fakeForYou; property var items: []; signal changed() }
    TestCase {
        name: "DesktopPet"
        when: windowShown
        function cleanup() {
            DesktopPet.enabled = false; DesktopPet.size = "medium"; DesktopPet.breakMinutes = 50
            researchStore.setSetting("pet.position", "")
            while (Theme.pictures.length) Theme.removePicture()
        }
        function test_petFloatsWhereItWasLeft() {
            verify(DesktopPet.supported, "only Wayland has no pet")
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            const pet = createTemporaryObject(petComponent, null)
            verify(pet.visible)
            compare(pet.height, 160 + pet.headroom)
            compare(pet.width, Math.round(160 * 400 / 1040))
            const first = DesktopPet.place(pet.width, pet.height)
            compare(pet.x, first.x); compare(pet.y, first.y)
            // Left somewhere, it comes back there.
            pet.x = first.x - 300; pet.y = first.y - 200
            tryVerify(function() { return researchStore.setting("pet.position") === (first.x - 300) + "," + (first.y - 200) })
            const again = createTemporaryObject(petComponent, null)
            compare(again.x, first.x - 300); compare(again.y, first.y - 200)
            // A place no screen shows any more falls back to the corner.
            researchStore.setSetting("pet.position", "-90000,-90000")
            verify(DesktopPet.place(60, 160).x > -90000)
            DesktopPet.size = "small"
            compare(pet.height, 120 + pet.headroom)
            compare(researchStore.setting("pet.size"), "small")
            // A click pokes it and leaves Owelk where it is; its menu opens Owelk.
            openSpy.target = pet; openSpy.clear(); pokeSpy.target = pet; pokeSpy.clear()
            mouseClick(pet.contentItem)
            compare(pokeSpy.count, 1)
            compare(openSpy.count, 0)
            findChild(pet, "openOwelk").triggered()
            compare(openSpy.count, 1)
            openSpy.clear()
            // Its menu has the app's colors, not the system's (white text in dark mode): the menu opens in
            // a window of its own, which does not take the pet window's colors.
            const menu = findChild(pet, "petMenu")
            menu.popup()
            tryCompare(menu, "opened", true)
            const row = findChild(menu, "hidePet")
            verify(Qt.colorEqual(row.contentItem.color, Theme.text), "menu text " + row.contentItem.color + ", theme text " + Theme.text)
            menu.close()
            DesktopPet.enabled = true
            findChild(pet, "hidePet").triggered()
            compare(DesktopPet.enabled, false)
            compare(researchStore.setting("pet.enabled"), "0")
        }
        function test_aBreakAfterAStretchOfReading() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            DesktopPet.breakMinutes = 25
            compare(researchStore.setting("pet.breakMinutes"), "25")
            // stretch: the reading clock's seconds read since the last break; Owelk in front.
            const pet = createTemporaryObject(petComponent, null, {ownerActive: true})
            waitForRendering(pet.contentItem)
            pet.stretch = 24 * 60
            compare(pet.message, null)
            pet.stretch = 25 * 60
            // Shown although Owelk is in front: that is where the reading happens.
            verify(pet.message !== null)
            compare(findChild(pet, "petBubbleText").text, "25 minutes of reading. Time for a short break?")
            // A click dismisses it and opens nothing.
            openSpy.target = pet; openSpy.clear()
            waitForRendering(pet.contentItem)
            mouseClick(pet.contentItem, pet.width / 2, pet.height - 10)
            compare(pet.message, null); compare(openSpy.count, 0)
            // Once every 25 minutes of the stretch.
            pet.stretch = 49 * 60
            compare(pet.message, null)
            pet.stretch = 50 * 60
            verify(pet.message !== null)
            // A break starts the stretch again and takes the reminder away.
            pet.stretch = 0
            compare(pet.message, null)
            pet.stretch = 25 * 60
            verify(pet.message !== null)
            pet.message = null
            // Off: no reminders.
            DesktopPet.breakMinutes = 0
            pet.stretch = 0; pet.stretch = 100 * 60
            compare(pet.message, null)
        }
        function test_facesForTalkingAndThinking() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            const pet = createTemporaryObject(petComponent, null, {ai: fakeAi, ownerActive: false})
            compare(String(pet.shown), String(Theme.picture))
            const narrow = pet.width
            // Without faces: the picture, also while talking.
            pet.say({text: "Hello"}, true)
            compare(String(pet.shown), String(Theme.picture))
            pet.message = null
            verify(Theme.setPictureMood("talk", testInput.pictureFile(1000, 1300, true)))
            verify(Theme.setPictureMood("think", testInput.pictureFile(500, 1300, true)))
            // As wide as the widest face, so each stands as tall.
            tryVerify(function() { return pet.width > narrow })
            pet.say({text: "Hello"}, true)
            compare(String(pet.shown), String(Theme.pictureMoods.talk.url))
            pet.message = null
            compare(String(pet.shown), String(Theme.picture))
            // Thinking while an answer is written, even with something to say.
            fakeAi.started(7, "thread", "p", "m", false)
            compare(String(pet.shown), String(Theme.pictureMoods.think.url))
            fakeAi.finished(7, "done", {})
            compare(String(pet.shown), String(Theme.pictureMoods.talk.url))
            pet.message = null
            verify(Theme.setPictureMood("talk", ""))
            verify(Theme.setPictureMood("think", ""))
        }
        function test_longWorkIsToldWhenItStartsAndEnds() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            // Owelk behind other apps; work told after 300 ms here (three seconds in the app).
            const pet = createTemporaryObject(petComponent, null, {ownerActive: false, workDelay: 300})
            // Quick work: nothing to say.
            pet.activities = [{id: "download:1", label: "Downloading a.pdf"}]
            pet.activities = []
            wait(500)
            compare(pet.message, null)
            // Long work: its start, then its end; a click goes to its settings.
            pet.activities = [{id: "sync", label: "Syncing…"}]
            tryVerify(function() { return pet.message !== null && pet.message.text === "Syncing…" })
            pet.message = null
            pet.activities = []
            tryVerify(function() { return pet.message !== null && pet.message.text === "Sync finished." })
            settingsSpy.target = pet; settingsSpy.clear()
            pet.act()
            compare(settingsSpy.count, 1)
            compare(settingsSpy.signalArguments[0][0], "sync")
            // Several at once: told together.
            pet.activities = [{id: "download:1", label: "Downloading a.pdf"}, {id: "download:2", label: "Downloading b.pdf"}, {id: "download:3", label: "Downloading c.pdf"}]
            tryVerify(function() { return pet.message !== null && pet.message.text === "Downloading a.pdf and 2 more" })
            pet.message = null
            pet.activities = []
            tryVerify(function() { return pet.message !== null && pet.message.text === "3 downloads finished." })
            pet.message = null
            // What Owelk says as one ends is the news ("Download failed: …").
            pet.activities = [{id: "download:4", label: "Downloading d.pdf"}]
            tryVerify(function() { return pet.message !== null })
            pet.message = null
            pet.activities = []
            researchStore.notify("Download failed: network error")
            tryVerify(function() { return pet.message !== null && pet.message.text === "Download failed: network error" })
            pet.message = null
            // Owelk in front: nothing is said.
            pet.ownerActive = true
            pet.activities = [{id: "index", label: "Indexing 1/3"}]
            wait(600)
            compare(pet.message, null)
            pet.activities = []
        }
        function test_aDragMovesItWithoutOpeningOwelk() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            const pet = createTemporaryObject(petComponent, null)
            waitForRendering(pet.contentItem)
            openSpy.target = pet; openSpy.clear()
            mouseDrag(pet.contentItem, pet.width / 2, pet.height - 20, 40, -30)
            verify(pet.moving)
            compare(openSpy.count, 0)
            // The system moved it (here by hand): a release just after is no click either.
            pet.x += 30
            tryVerify(function() { return pet.movedAt > 0 })
            mouseClick(pet.contentItem, pet.width / 2, pet.height - 20)
            compare(openSpy.count, 0)
            wait(650)
            // A click after it is a poke, and Owelk stays where it is.
            pokeSpy.target = pet; pokeSpy.clear()
            mouseClick(pet.contentItem, pet.width / 2, pet.height - 20)
            verify(!pet.moving)
            compare(pokeSpy.count, 1)
            compare(openSpy.count, 0)
        }
        function test_droppedPdfsOpenAndTextIsExplained() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            const pet = createTemporaryObject(petComponent, null)
            pdfSpy.target = pet; explainSpy.target = pet
            verify(pet.received(["file:///papers/a.PDF", "file:///papers/b.png"], ""))
            compare(pdfSpy.count, 1)
            compare(pdfSpy.signalArguments[0][0].map(String), ["file:///papers/a.PDF"])
            verify(pet.received([], "  The attention weights sum to one.  "))
            compare(explainSpy.signalArguments[0][0], "The attention weights sum to one.")
            verify(!pet.received(["file:///papers/b.png"], ""), "a picture alone is neither")
            verify(!pet.received([], "   "))
            compare(pdfSpy.count, 1); compare(explainSpy.count, 1)
        }
        function test_petSaysWhatHappenedWhileOwelkIsBehind() {
            verify(Theme.usePicture(testInput.pictureFile(500, 1300, true)))
            // Papers already waiting when the pet starts are not news.
            fakeForYou.items = [{id: "old"}]
            const pet = createTemporaryObject(petComponent, null, {ai: fakeAi, forYou: fakeForYou, ownerActive: false})
            fakeForYou.changed()
            compare(pet.message, null)
            fakeForYou.items = []
            fakeForYou.changed()
            const bubble = findChild(pet, "petBubble"), words = findChild(pet, "petBubbleText"), bob = findChild(pet, "petBob")
            compare(bubble.visible, false)
            // While a conversation is answered it says so and bobs; other AI work is not news.
            fakeAi.started(7, "thread-1", "codex", "model", false)
            verify(pet.writing); verify(bob.running)
            tryCompare(bubble, "visible", true)
            compare(words.text, "Writing your answer…")
            fakeAi.finished(8, "a gloss", {})
            compare(words.text, "Writing your answer…")
            fakeAi.finished(7, "the answer", {})
            verify(!bob.running)
            compare(words.text, "Your answer is ready.")
            threadSpy.target = pet
            waitForRendering(bubble.contentItem)
            mouseClick(bubble.contentItem)
            compare(threadSpy.count, 1)
            compare(threadSpy.signalArguments[0][0], "thread-1")
            tryCompare(bubble, "visible", false)
            fakeAi.started(9, "thread-2", "codex", "model", false)
            fakeAi.failed(9, "No key for this provider.\nDetails")
            compare(words.text, "The AI could not answer: No key for this provider.")
            // With Owelk in front there is nothing to say; behind again mid-answer, it says it is writing.
            pet.ownerActive = true
            compare(pet.message, null)
            fakeAi.started(10, "thread-3", "codex", "model", false)
            fakeAi.finished(10, "", {})
            compare(pet.message, null)
            fakeAi.started(11, "thread-4", "codex", "model", false)
            compare(pet.message, null)
            pet.ownerActive = false
            compare(words.text, "Writing your answer…")
            compare(pet.message.thread, "thread-4")
            fakeAi.finished(11, "", {})
            compare(words.text, "Your answer is ready.")
            pet.message = null
            // More papers in For You than before.
            fakeForYou.items = [{id: "a"}, {id: "b"}]
            fakeForYou.changed()
            compare(words.text, "New papers in For You: 2")
            // A click on the pet leaves it; a click on the bubble goes there.
            forYouSpy.target = pet; forYouSpy.clear()
            mouseClick(pet.contentItem, pet.width / 2, pet.height - 10)
            compare(forYouSpy.count, 0)
            verify(pet.message !== null)
            const card = findChild(pet, "petBubble")
            tryCompare(card, "visible", true)
            mouseClick(card.contentItem, card.width / 2, card.height / 2)
            compare(forYouSpy.count, 1)
            fakeForYou.items = [{id: "a"}]
            fakeForYou.changed()
            compare(pet.message, null, "fewer papers are not news")
        }
    }
}
