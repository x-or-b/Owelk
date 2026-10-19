.pragma library
.import "Shortcuts.js" as Shortcuts

// What the search in Settings finds: each setting's page, the named group or row it opens to, the
// words it is listed under, and other words people may type for it. Texts are shown through
// qsTranslate("SettingsIndex", …) (QT_TR_NOOP marks them for tools/hangul.py). A test checks that
// every anchor is on its page.
const entries = [
    {page: "general", anchor: "settingsRow-launch", text: QT_TR_NOOP("On launch"), words: "start startup open home last tabs restore"},
    {page: "general", anchor: "settingsRow-openAtLogin", text: QT_TR_NOOP("Open at login"), words: "start startup login boot automatically launch run computer turns on autostart"},
    {page: "general", anchor: "settingsGroup-home", text: QT_TR_NOOP("Home"), words: "home sections order layout customize hide show reading for you collections recent papers notes ai conversations"},
    {page: "general", anchor: "settingsGroup-focus", text: QT_TR_NOOP("Focus mode"), words: "distraction free zen full screen hide bars toolbar reading"},
    {page: "general", anchor: "settingsRow-tabLayout", text: QT_TR_NOOP("Tab layout"), words: "vertical horizontal tabs sidebar"},
    {page: "general", anchor: "settingsRow-controlTab", text: QT_TR_NOOP("Ctrl+Tab"), words: "control tab switch next last used recent"},
    {page: "general", anchor: "settingsRow-language", text: QT_TR_NOOP("Language"), words: "english korean hangul interface"},
    {page: "appearance", anchor: "settingsGroup-theme", text: QT_TR_NOOP("Theme"), words: "dark light mode colors"},
    {page: "appearance", anchor: "settingsRow-matchSystem", text: QT_TR_NOOP("Match System"), words: "dark light mode automatic system appearance night"},
    {page: "appearance", anchor: "settingsGroup-accent", text: QT_TR_NOOP("Accent color"), words: "highlight selection color blue"},
    {page: "appearance", anchor: "settingsGroup-appIcon", text: QT_TR_NOOP("App icon"), words: "dock taskbar icon"},
    {page: "appearance", anchor: "settingsRow-textSize", text: QT_TR_NOOP("Text size"), words: "font bigger smaller scale zoom"},
    {page: "appearance", anchor: "settingsRow-darkPages", text: QT_TR_NOOP("Dark pages"), words: "invert pdf night black"},
    {page: "library", anchor: "settingsRow-insights", text: QT_TR_NOOP("Summaries and citation counts"), words: "tldr semantic scholar paper insights summary citations privacy"},
    {page: "library", anchor: "settingsRow-arxivVersions", text: QT_TR_NOOP("Newer arXiv versions"), words: "arxiv version update revision v2 v3 preprint privacy"},
    {page: "library", anchor: "settingsRow-keepPdfs", text: QT_TR_NOOP("Keep PDFs in Owelk"), words: "copy store files pdf storage"},
    {page: "library", anchor: "settingsRow-pdfFolder", text: QT_TR_NOOP("PDF folder"), words: "papers location finder show where"},
    {page: "library", anchor: "pdfNameGroup", text: QT_TR_NOOP("Paper names"), words: "file name rename title author year arxiv format order"},
    {page: "library", anchor: "settingsRow-renamePdfs", text: QT_TR_NOOP("Rename kept PDFs"), words: "rename files now"},
    {page: "library", anchor: "settingsRow-trash", text: QT_TR_NOOP("Empty the Trash"), words: "delete days trash bin"},
    {page: "foryou", anchor: "settingsGroup-following", text: QT_TR_NOOP("What For You follows"), words: "recommend new papers follow topics arxiv words categories researchers authors professors institutions universities collections semantic scholar openalex feed"},
    {page: "foryou", anchor: "settingsRow-openAlexKey", text: QT_TR_NOOP("OpenAlex key"), words: "for you researchers institutions api key allowance limit"},
    {page: "foryou", anchor: "settingsRow-forYouCount", text: QT_TR_NOOP("Papers from each source"), words: "for you count number how many per topic collection researcher"},
    {page: "foryou", anchor: "settingsRow-forYouDaily", text: QT_TR_NOOP("Check for new papers once a day"), words: "for you daily automatic recommend"},
    {page: "foryou", anchor: "settingsRow-forYouAi", text: QT_TR_NOOP("Explain new papers with AI"), words: "for you rank relevance reason why ai recommend"},
    {page: "foryou", anchor: "settingsRow-forYouKeep", text: QT_TR_NOOP("Keep For You papers"), words: "for you keep days expire old remove permanent always"},
    {page: "foryou", anchor: "settingsRow-forYouDays", text: QT_TR_NOOP("New papers from the last"), words: "for you period days week month"},
    {page: "web", anchor: "settingsRow-downloadFolder", text: QT_TR_NOOP("Download folder"), words: "downloads save location"},
    {page: "web", anchor: "settingsRow-namePdfs", text: QT_TR_NOOP("Name PDFs"), words: "download file name website"},
    {page: "web", anchor: "settingsRow-pdfLinks", text: QT_TR_NOOP("PDF links"), words: "open reader web tab browser"},
    {page: "web", anchor: "settingsGroup-engines", text: QT_TR_NOOP("Search engines"), words: "google scholar arxiv duckduckgo default web search site"},
    {page: "search", anchor: "settingsRow-indexStatus", text: QT_TR_NOOP("PDF text index"), words: "index full text search status"},
    {page: "search", anchor: "settingsGroup-meaning", text: QT_TR_NOOP("Meaning search"), words: "semantic embeddings similar ollama openai"},
    {page: "search", anchor: "settingsRow-ocr", text: QT_TR_NOOP("Read text with OCR"), words: "scanned ocr image text recognition"},
    {page: "ai", anchor: "settingsRow-aiLanguage", text: QT_TR_NOOP("Preferred language"), words: "answer language korean english translate"},
    {page: "ai", anchor: "settingsRow-explanations", text: QT_TR_NOOP("Explanations"), words: "easy brief level student"},
    {page: "ai", anchor: "settingsRow-instructions", text: QT_TR_NOOP("Instructions"), words: "custom prompt system"},
    {page: "ai", anchor: "settingsRow-symbolHints", text: QT_TR_NOOP("Symbol hints"), words: "math notation symbols"},
    {page: "ai", anchor: "settingsRow-showThinking", text: QT_TR_NOOP("Show thinking"), words: "reasoning summary"},
    {page: "ai", anchor: "settingsRow-provider", text: QT_TR_NOOP("AI provider"), words: "claude openai chatgpt codex ollama account api key sign in model"},
    {page: "ai", anchor: "settingsRow-reasoning", text: QT_TR_NOOP("Reasoning"), words: "effort thinking"},
    {page: "ai", anchor: "settingsRow-glossModel", text: QT_TR_NOOP("Gloss model"), words: "gloss hover word meaning"},
    {page: "sync", anchor: "settingsGroup-sync", text: QT_TR_NOOP("Sync"), words: "google drive dropbox syncthing other computers share"},
    {page: "sync", anchor: "settingsGroup-backup", text: QT_TR_NOOP("Backup"), words: "back up restore automatic"},
    {page: "sync", anchor: "settingsGroup-export", text: QT_TR_NOOP("Export notes as Markdown"), words: "notes markdown export"}
]

// Every entry, with each shortcut as one more (found by its action's name).
function all() {
    return entries.concat(Shortcuts.actions.map(function(a) {
        return {page: "shortcuts", anchor: "settingsRow-shortcut-" + a.id, text: a.name, context: "Shortcuts", words: "shortcut keys keyboard"}
    }))
}

// The entries whose words hold every word of the query (in English or as shown), best first: those
// whose name starts with the query, then those whose name holds it.
function find(query, translate, pageName) {
    const terms = query.toLowerCase().split(/\s+/).filter(function(t) { return t.length })
    if (!terms.length) return []
    const scored = []
    all().forEach(function(entry) {
        const shown = translate(entry.context || "SettingsIndex", entry.text)
        const name = (entry.text + " " + shown).toLowerCase()
        const haystack = name + " " + entry.words + " " + pageName(entry.page).toLowerCase()
        if (!terms.every(function(t) { return haystack.indexOf(t) >= 0 })) return
        const q = terms.join(" ")
        const score = shown.toLowerCase().indexOf(q) === 0 || entry.text.toLowerCase().indexOf(q) === 0 ? 0 : name.indexOf(q) >= 0 ? 1 : 2
        scored.push({entry: entry, shown: shown, score: score})
    })
    scored.sort(function(a, b) { return a.score - b.score })
    return scored.slice(0, 30).map(function(s) { return Object.assign({shown: s.shown}, s.entry) })
}
