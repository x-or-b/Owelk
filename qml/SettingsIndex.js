.pragma library
.import "Shortcuts.js" as Shortcuts

// What the search in Settings finds: each setting's page, the group or row it opens to, the group it is in, the words
// it is listed under, and other words people may type for it. Texts are shown through qsTranslate("SettingsIndex", …)
// (QT_TR_NOOP marks them for tools/hangul.py). Entries marked `when: "picture"` are on a page listed only while a
// picture is in use, and are found only then.
//
// Every SettingsGroup and SettingsRow has an objectName. Those named settingsGroup-… or settingsRow-… are listed here
// (a test checks both ways: every entry is on its page, and every such name on a page is here); others, such as rows a
// Repeater makes (homeSection-…, pdfNamePart-…, seedRow-…, petMood-…, engineRow-…), are found through their group,
// and a group not named settingsGroup-… has only listed rows.
const entries = [
    {page: "general", anchor: "settingsGroup-launch", text: QT_TR_NOOP("Launch"), words: "start startup open"},
    {page: "general", anchor: "settingsRow-launch", group: QT_TR_NOOP("Launch"), text: QT_TR_NOOP("On launch"), words: "start startup open home last tabs restore"},
    {page: "general", anchor: "settingsRow-openAtLogin", group: QT_TR_NOOP("Launch"), text: QT_TR_NOOP("Open at login"), words: "start startup login boot automatically launch run computer turns on autostart"},
    {page: "general", anchor: "settingsGroup-home", text: QT_TR_NOOP("Home"), words: "home sections order customize hide show reading for you collections recent papers notes ai conversations"},
    {page: "general", anchor: "settingsRow-homeLayout", group: QT_TR_NOOP("Home"), text: QT_TR_NOOP("Home layout"), words: "sketch rows reset"},
    {page: "general", anchor: "settingsGroup-tabs", text: QT_TR_NOOP("Tabs"), words: "tab strip"},
    {page: "general", anchor: "settingsRow-tabLayout", group: QT_TR_NOOP("Tabs"), text: QT_TR_NOOP("Tab layout"), words: "vertical horizontal tabs sidebar"},
    {page: "general", anchor: "settingsRow-topBar", group: QT_TR_NOOP("Tabs"), text: QT_TR_NOOP("Top bar"), words: "back forward search menu bar windows linux"},
    {page: "general", anchor: "settingsRow-controlTab", group: QT_TR_NOOP("Tabs"), text: QT_TR_NOOP("Ctrl+Tab"), words: "control tab switch next last used recent"},
    {page: "general", anchor: "settingsGroup-language", text: QT_TR_NOOP("Language"), words: "english korean hangul"},
    {page: "general", anchor: "settingsRow-language", group: QT_TR_NOOP("Language"), text: QT_TR_NOOP("Interface language"), words: "english korean hangul interface menus"},
    {page: "general", anchor: "settingsRow-aiLanguage", group: QT_TR_NOOP("Language"), text: QT_TR_NOOP("AI answer language"), words: "preferred answer language korean english japanese chinese translate"},
    {page: "appearance", anchor: "settingsGroup-theme", text: QT_TR_NOOP("Theme"), words: "dark light mode colors"},
    {page: "appearance", anchor: "settingsRow-matchSystem", group: QT_TR_NOOP("Theme"), text: QT_TR_NOOP("Match System"), words: "dark light mode automatic system appearance night"},
    {page: "appearance", anchor: "settingsGroup-customTheme", text: QT_TR_NOOP("Custom theme"), words: "own colors window sidebar documents menus text lines"},
    {page: "appearance", anchor: "settingsRow-customDark", group: QT_TR_NOOP("Custom theme"), text: QT_TR_NOOP("Dark custom theme"), words: "dark light text controls"},
    {page: "appearance", anchor: "settingsGroup-accent", text: QT_TR_NOOP("Accent color"), words: "highlight selection color blue"},
    {page: "appearance", anchor: "settingsGroup-text", text: QT_TR_NOOP("Text"), words: "font letters"},
    {page: "appearance", anchor: "settingsRow-textSize", group: QT_TR_NOOP("Text"), text: QT_TR_NOOP("Text size"), words: "font bigger smaller scale zoom"},
    {page: "appearance", anchor: "settingsRow-answerSize", group: QT_TR_NOOP("Text"), text: QT_TR_NOOP("AI answer size"), words: "answer text font bigger smaller readable reading chat"},
    {page: "appearance", anchor: "settingsRow-answerSpacing", group: QT_TR_NOOP("Text"), text: QT_TR_NOOP("Line spacing"), words: "line height paragraph readable reading ai answers"},
    {page: "appearance", anchor: "settingsRow-answerColumn", group: QT_TR_NOOP("Text"), text: QT_TR_NOOP("Limit line length"), words: "width column wide readable reading ai answers chat tab"},
    {page: "appearance", anchor: "settingsRow-answerNative", group: QT_TR_NOOP("Text"), text: QT_TR_NOOP("Sharp text"), words: "blurry crisp font rendering native readable ai answers"},
    {page: "appearance", anchor: "settingsGroup-appIcon", text: QT_TR_NOOP("App icon"), words: "dock taskbar icon"},
    {page: "picture", when: "picture", anchor: "settingsGroup-picture", text: QT_TR_NOOP("Picture"), words: "picture background image wallpaper theme"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureOn", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Picture theme"), words: "on off picture background"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureColors", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Picture colors"), words: "colors custom theme"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictures", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Pictures"), words: "add remove choose images"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureAccent", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Accent from the picture"), words: "accent color"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureAlign", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Picture position"), words: "left center right align"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureScale", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Picture size"), words: "size scale height"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureStrength", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Picture opacity"), words: "opacity strength transparent faint"},
    {page: "picture", when: "picture", anchor: "settingsRow-pictureInterval", group: QT_TR_NOOP("Picture"), text: QT_TR_NOOP("Change picture"), words: "rotate every hour day launch automatic"},
    {page: "picture", when: "picture", anchor: "settingsGroup-pet", text: QT_TR_NOOP("Desktop pet"), words: "pet character float desktop companion"},
    {page: "picture", when: "picture", anchor: "settingsRow-pet", group: QT_TR_NOOP("Desktop pet"), text: QT_TR_NOOP("Pet on the desktop"), words: "pet on off float"},
    {page: "picture", when: "picture", anchor: "settingsRow-petSize", group: QT_TR_NOOP("Desktop pet"), text: QT_TR_NOOP("Pet size"), words: "small medium large"},
    {page: "picture", when: "picture", anchor: "settingsRow-petBreak", group: QT_TR_NOOP("Desktop pet"), text: QT_TR_NOOP("Break reminder"), words: "break rest minutes pomodoro"},
    {page: "picture", when: "picture", anchor: "settingsRow-petGoal", group: QT_TR_NOOP("Desktop pet"), text: QT_TR_NOOP("Daily reading goal"), words: "goal minutes streak days cheer"},
    {page: "picture", when: "picture", anchor: "settingsRow-petHidden", group: QT_TR_NOOP("Desktop pet"), text: QT_TR_NOOP("Hide in screen sharing"), words: "screen share recording hide"},
    {page: "picture", when: "picture", anchor: "settingsGroup-petFaces", text: QT_TR_NOOP("Pet faces"), words: "faces moods expressions talking thinking happy worried sleepy"},
    {page: "reading", anchor: "settingsGroup-pdfPages", text: QT_TR_NOOP("PDF pages"), words: "pages pdf"},
    {page: "reading", anchor: "settingsRow-darkPages", group: QT_TR_NOOP("PDF pages"), text: QT_TR_NOOP("Dark pages"), words: "invert pdf night black"},
    {page: "reading", anchor: "settingsGroup-focus", text: QT_TR_NOOP("Focus mode"), words: "distraction free zen hide bars toolbar reading"},
    {page: "reading", anchor: "settingsRow-focusFullScreen", group: QT_TR_NOOP("Focus mode"), text: QT_TR_NOOP("Full screen"), words: "full screen window focus"},
    {page: "reading", anchor: "settingsGroup-symbols", text: QT_TR_NOOP("Symbols"), words: "math notation"},
    {page: "reading", anchor: "settingsRow-symbolHints", group: QT_TR_NOOP("Symbols"), text: QT_TR_NOOP("Symbol hints"), words: "math notation symbols meaning pointing"},
    {page: "library", anchor: "settingsGroup-pdfFiles", text: QT_TR_NOOP("Files"), words: "pdf files storage folder"},
    {page: "library", anchor: "settingsRow-keepPdfs", group: QT_TR_NOOP("Files"), text: QT_TR_NOOP("Keep PDFs in Owelk"), words: "copy store files pdf storage"},
    {page: "library", anchor: "settingsRow-copyPdfs", group: QT_TR_NOOP("Files"), text: QT_TR_NOOP("Copy PDFs into Owelk"), words: "copy outside elsewhere"},
    {page: "library", anchor: "settingsRow-pdfFolder", group: QT_TR_NOOP("Files"), text: QT_TR_NOOP("PDF folder"), words: "papers location finder show where"},
    {page: "library", anchor: "settingsRow-downloadFolder", group: QT_TR_NOOP("Files"), text: QT_TR_NOOP("Download folder"), words: "downloads save location other files web"},
    {page: "library", anchor: "settingsGroup-pdfNames", text: QT_TR_NOOP("Paper names"), words: "file name rename title author year arxiv format order"},
    {page: "library", anchor: "settingsRow-renamePdfs", group: QT_TR_NOOP("Paper names"), text: QT_TR_NOOP("Rename kept PDFs"), words: "rename files now"},
    {page: "library", anchor: "settingsRow-namePdfs", group: QT_TR_NOOP("Paper names"), text: QT_TR_NOOP("Downloaded PDF names"), words: "download file name website web"},
    {page: "library", anchor: "settingsGroup-insights", text: QT_TR_NOOP("Paper insights"), words: "semantic scholar arxiv privacy online"},
    {page: "library", anchor: "settingsRow-insights", group: QT_TR_NOOP("Paper insights"), text: QT_TR_NOOP("Summaries and citation counts"), words: "tldr semantic scholar paper insights summary citations privacy"},
    {page: "library", anchor: "settingsRow-arxivVersions", group: QT_TR_NOOP("Paper insights"), text: QT_TR_NOOP("Newer arXiv versions"), words: "arxiv version update revision v2 v3 preprint privacy"},
    {page: "library", anchor: "settingsGroup-trash", text: QT_TR_NOOP("Trash"), words: "delete bin"},
    {page: "library", anchor: "settingsRow-trash", group: QT_TR_NOOP("Trash"), text: QT_TR_NOOP("Empty the Trash"), words: "delete days trash bin"},
    {page: "foryou", anchor: "settingsRow-following", text: QT_TR_NOOP("What For You follows"), words: "recommend new papers follow topics arxiv words categories researchers authors professors institutions universities collections semantic scholar openalex feed"},
    {page: "foryou", anchor: "settingsGroup-forYouChecking", text: QT_TR_NOOP("Checking for new papers"), words: "for you check recommend"},
    {page: "foryou", anchor: "settingsRow-forYouDaily", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("Check for new papers once a day"), words: "for you daily automatic recommend"},
    {page: "foryou", anchor: "settingsRow-forYouAi", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("Explain new papers with AI"), words: "for you rank relevance reason why ai recommend"},
    {page: "foryou", anchor: "settingsRow-forYouDays", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("How far back For You looks"), words: "for you period days week month look back"},
    {page: "foryou", anchor: "settingsRow-forYouKeep", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("Keep For You papers"), words: "for you keep days expire old remove permanent always"},
    {page: "foryou", anchor: "settingsRow-forYouCheck", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("Check for new papers now"), words: "for you check now refresh last checked"},
    {page: "foryou", anchor: "settingsRow-openAlexKey", group: QT_TR_NOOP("Checking"), text: QT_TR_NOOP("OpenAlex key"), words: "for you researchers institutions api key allowance limit"},
    {page: "web", anchor: "settingsGroup-links", text: QT_TR_NOOP("Links"), words: "pdf links web tab"},
    {page: "web", anchor: "settingsRow-pdfLinks", group: QT_TR_NOOP("Links"), text: QT_TR_NOOP("PDF links"), words: "open reader web tab browser download"},
    {page: "web", anchor: "settingsGroup-engines", text: QT_TR_NOOP("Search engines"), words: "google scholar arxiv duckduckgo default web search site"},
    {page: "web", anchor: "settingsRow-addEngine", group: QT_TR_NOOP("Search engines"), text: QT_TR_NOOP("Add a search engine"), words: "add site address custom engine"},
    {page: "search", anchor: "settingsGroup-textIndex", text: QT_TR_NOOP("PDF text index"), words: "index full text search"},
    {page: "search", anchor: "settingsRow-indexStatus", group: QT_TR_NOOP("PDF text index"), text: QT_TR_NOOP("Index status"), words: "status pause retry"},
    {page: "search", anchor: "settingsGroup-meaning", text: QT_TR_NOOP("Meaning search"), words: "semantic embeddings similar ollama openai"},
    {page: "search", anchor: "settingsRow-meaningEngine", group: QT_TR_NOOP("Meaning search"), text: QT_TR_NOOP("Meaning search engine"), words: "engine ollama openai off semantic"},
    {page: "search", anchor: "settingsRow-meaningModel", group: QT_TR_NOOP("Meaning search"), text: QT_TR_NOOP("Embedding model"), words: "model nomic embed semantic"},
    {page: "search", anchor: "settingsRow-meaningIndex", group: QT_TR_NOOP("Meaning search"), text: QT_TR_NOOP("Meaning index"), words: "vectors delete update passages semantic"},
    {page: "search", anchor: "settingsGroup-ocr", text: QT_TR_NOOP("Scanned pages"), words: "scanned ocr tesseract image"},
    {page: "search", anchor: "settingsRow-ocr", group: QT_TR_NOOP("Scanned pages"), text: QT_TR_NOOP("Read text with OCR"), words: "scanned ocr image text recognition"},
    {page: "search", anchor: "settingsRow-ocrLanguages", group: QT_TR_NOOP("Scanned pages"), text: QT_TR_NOOP("OCR languages"), words: "eng kor tesseract languages"},
    {page: "ai", anchor: "settingsRow-provider", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("AI provider"), words: "claude openai chatgpt codex ollama account sign in continue plan usage"},
    {page: "ai", anchor: "settingsRow-apiKey", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("API key"), words: "key secret paste claude openai"},
    {page: "ai", anchor: "settingsRow-account", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("Codex account"), words: "codex sign in chatgpt"},
    {page: "ai", anchor: "settingsRow-chatGptAccount", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("ChatGPT account"), words: "sign in chatgpt plan usage"},
    {page: "ai", anchor: "settingsRow-host", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("Ollama host"), words: "ollama address local server"},
    {page: "ai", anchor: "settingsRow-model", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("AI model"), words: "model claude gpt"},
    {page: "ai", anchor: "settingsRow-modelName", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("Model name"), words: "other custom model"},
    {page: "ai", anchor: "settingsRow-reasoning", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("Reasoning"), words: "effort thinking"},
    {page: "ai", anchor: "settingsRow-connection", group: QT_TR_NOOP("Provider"), text: QT_TR_NOOP("Test the connection"), words: "test connection check"},
    {page: "ai", anchor: "settingsGroup-gloss", text: QT_TR_NOOP("Gloss"), words: "gloss hover word meaning translation selection"},
    {page: "ai", anchor: "settingsRow-glossModel", group: QT_TR_NOOP("Gloss"), text: QT_TR_NOOP("Gloss model"), words: "gloss hover word meaning model"},
    {page: "ai", anchor: "settingsRow-glossReasoning", group: QT_TR_NOOP("Gloss"), text: QT_TR_NOOP("Gloss reasoning"), words: "gloss effort thinking"},
    {page: "ai", anchor: "settingsGroup-answers", text: QT_TR_NOOP("Answers"), words: "ai answers"},
    {page: "ai", anchor: "settingsRow-explanations", group: QT_TR_NOOP("Answers"), text: QT_TR_NOOP("Explanations"), words: "easy brief level student"},
    {page: "ai", anchor: "settingsRow-instructions", group: QT_TR_NOOP("Answers"), text: QT_TR_NOOP("Instructions"), words: "custom prompt system"},
    {page: "ai", anchor: "settingsRow-followUps", group: QT_TR_NOOP("Answers"), text: QT_TR_NOOP("Suggest next questions"), words: "follow-up suggestions"},
    {page: "ai", anchor: "settingsRow-showThinking", group: QT_TR_NOOP("Answers"), text: QT_TR_NOOP("Show thinking"), words: "reasoning summary"},
    {page: "sync", anchor: "settingsGroup-sync", text: QT_TR_NOOP("Sync"), words: "google drive dropbox syncthing other computers share"},
    {page: "sync", anchor: "settingsRow-syncFolder", group: QT_TR_NOOP("Sync"), text: QT_TR_NOOP("Sync folder"), words: "folder shared turn off"},
    {page: "sync", anchor: "settingsRow-syncStatus", group: QT_TR_NOOP("Sync"), text: QT_TR_NOOP("Sync now"), words: "status computers"},
    {page: "sync", anchor: "settingsGroup-backup", text: QT_TR_NOOP("Backup"), words: "back up restore"},
    {page: "sync", anchor: "settingsRow-autoBackup", group: QT_TR_NOOP("Backup"), text: QT_TR_NOOP("Back up automatically"), words: "daily automatic"},
    {page: "sync", anchor: "settingsRow-backUpNow", group: QT_TR_NOOP("Backup"), text: QT_TR_NOOP("Back up now"), words: "copy folder"},
    {page: "sync", anchor: "settingsRow-restoreBackup", group: QT_TR_NOOP("Backup"), text: QT_TR_NOOP("Restore from a backup"), words: "restore"},
    {page: "sync", anchor: "settingsGroup-export", text: QT_TR_NOOP("Export"), words: "export"},
    {page: "sync", anchor: "settingsRow-exportNotes", group: QT_TR_NOOP("Export"), text: QT_TR_NOOP("Export notes as Markdown"), words: "notes markdown export"}
]

// Every entry, with each shortcut as one more (found by its action's name, in its section).
function all() {
    return entries.concat(Shortcuts.actions.map(function(a) {
        return {page: "shortcuts", anchor: "settingsRow-shortcut-" + a.id, text: a.name, group: a.group, context: "Shortcuts", words: "shortcut keys keyboard"}
    }))
}

// The entries whose words hold every word of the query (in English or as shown), best first: those whose name starts
// with the query, then those whose name holds it. `pictureListed`: the picture page is in the list.
function find(query, translate, pageName, pictureListed) {
    const terms = query.toLowerCase().split(/\s+/).filter(function(t) { return t.length })
    if (!terms.length) return []
    const scored = []
    all().forEach(function(entry) {
        if (entry.when === "picture" && !pictureListed) return
        const context = entry.context || "SettingsIndex"
        const shown = translate(context, entry.text)
        const group = entry.group ? translate(context, entry.group) : ""
        const name = (entry.text + " " + shown).toLowerCase()
        const haystack = name + " " + entry.words + " " + pageName(entry.page).toLowerCase() + " " + (entry.group || "").toLowerCase() + " " + group.toLowerCase()
        if (!terms.every(function(t) { return haystack.indexOf(t) >= 0 })) return
        const q = terms.join(" ")
        const score = shown.toLowerCase().indexOf(q) === 0 || entry.text.toLowerCase().indexOf(q) === 0 ? 0 : name.indexOf(q) >= 0 ? 1 : 2
        // Where it is: the page, and the group when it is a row.
        scored.push({entry: entry, shown: shown, where: pageName(entry.page) + (group.length ? " › " + group : ""), score: score})
    })
    scored.sort(function(a, b) { return a.score - b.score })
    return scored.slice(0, 30).map(function(s) { return Object.assign({shown: s.shown, where: s.where}, s.entry) })
}
