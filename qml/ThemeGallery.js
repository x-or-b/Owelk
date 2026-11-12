.pragma library

// Well-known themes to add as one's own (Settings › Appearance › + › From the Gallery…), light first. Their colors
// follow each theme's published palette, laid out as Owelk's seeds: window and toolbars, sidebars, documents and
// lists, menus, text, lines and the space around PDF pages; the accent is the theme's own. `words`: what people may
// search for besides the name. One Dark was built in and keeps its colors there (Theme::preset).
const themes = [
    {name: "Catppuccin Latte", words: "pastel soft lavender", accent: "#8839ef",
        seeds: {window: "#e6e9ef", sidebar: "#eceef3", content: "#eff1f5", raised: "#f6f7fa", text: "#4c4f69", separator: "#d4d8e1", backdrop: "#dce0e8"}},
    {name: "Rosé Pine Dawn", words: "rose pine warm pink cream", accent: "#286983",
        seeds: {window: "#f2e9e1", sidebar: "#f6efe8", content: "#faf4ed", raised: "#fffaf3", text: "#575279", separator: "#dfdad9", backdrop: "#ebe2d9"}},
    {name: "Gruvbox Light", words: "retro warm yellow cream", accent: "#076678",
        seeds: {window: "#f2e5bc", sidebar: "#f5ebc6", content: "#fbf1c7", raised: "#f9f5d7", text: "#3c3836", separator: "#e2d3a9", backdrop: "#ebdbb2"}},
    {name: "GitHub Light", words: "clean white blue", accent: "#0969da",
        seeds: {window: "#eff2f5", sidebar: "#f6f8fa", content: "#ffffff", raised: "#ffffff", text: "#1f2328", separator: "#d8dee4", backdrop: "#eaeef2"}},
    {name: "One Light", words: "atom clean gray blue", accent: "#4078f2",
        seeds: {window: "#eaeaeb", sidebar: "#f0f0f1", content: "#fafafa", raised: "#ffffff", text: "#383a42", separator: "#dbdbdc", backdrop: "#e5e5e6"}},
    {name: "Everforest Light", words: "green forest calm cream", accent: "#35a77c",
        seeds: {window: "#efebd4", sidebar: "#f4f0d9", content: "#fdf6e3", raised: "#fffbef", text: "#5c6a72", separator: "#e0dcc7", backdrop: "#e6e2cc"}},
    {name: "Tokyo Night Day", words: "tokyo blue cool", accent: "#2e7de9",
        seeds: {window: "#d0d5e3", sidebar: "#d8dae3", content: "#e1e2e7", raised: "#eaebf0", text: "#2f53a6", separator: "#c4c8da", backdrop: "#c8ccdc"}},
    {name: "Ayu Light", words: "orange bright clean", accent: "#fa8d3e",
        seeds: {window: "#eef0f2", sidebar: "#f3f4f5", content: "#fcfcfc", raised: "#ffffff", text: "#5c6166", separator: "#e1e3e5", backdrop: "#e7e9eb"}},
    {name: "Kanagawa Lotus", words: "japanese wave cream ink", accent: "#4d699b",
        seeds: {window: "#e5ddb0", sidebar: "#ebe3b5", content: "#f2ecbc", raised: "#f6f1cb", text: "#545464", separator: "#dcd3a6", backdrop: "#e1d9ac"}},
    {name: "Mist", words: "owelk sky blue gray cool", accent: "#3f72a8",
        seeds: {window: "#e6ebf1", sidebar: "#eef2f7", content: "#f9fbfd", raised: "#ffffff", text: "#1e2a38", separator: "#d6dee8", backdrop: "#dce4ee"}},
    {name: "Catppuccin Mocha", words: "pastel purple mauve", dark: true, accent: "#cba6f7",
        seeds: {window: "#181825", sidebar: "#1b1b29", content: "#1e1e2e", raised: "#313244", text: "#cdd6f4", separator: "#313244", backdrop: "#11111b"}},
    {name: "Catppuccin Macchiato", words: "pastel blue", dark: true, accent: "#8aadf4",
        seeds: {window: "#1e2030", sidebar: "#212335", content: "#24273a", raised: "#363a4f", text: "#cad3f5", separator: "#363a4f", backdrop: "#181926"}},
    {name: "Catppuccin Frappé", words: "frappe pastel purple soft", dark: true, accent: "#ca9ee6",
        seeds: {window: "#292c3c", sidebar: "#2c3041", content: "#303446", raised: "#414559", text: "#c6d0f5", separator: "#414559", backdrop: "#232634"}},
    {name: "Rosé Pine", words: "rose pine purple iris", dark: true, accent: "#c4a7e7",
        seeds: {window: "#1f1d2e", sidebar: "#1c1a29", content: "#191724", raised: "#26233a", text: "#e0def4", separator: "#2a2739", backdrop: "#13111c"}},
    {name: "Rosé Pine Moon", words: "rose pine teal foam", dark: true, accent: "#9ccfd8",
        seeds: {window: "#2a273f", sidebar: "#27243b", content: "#232136", raised: "#393552", text: "#e0def4", separator: "#393552", backdrop: "#1c1a2d"}},
    {name: "Gruvbox Dark", words: "retro warm orange brown", dark: true, accent: "#fe8019",
        seeds: {window: "#32302f", sidebar: "#2e2c2b", content: "#282828", raised: "#3c3836", text: "#ebdbb2", separator: "#3c3836", backdrop: "#1d2021"}},
    {name: "Tokyo Night", words: "tokyo blue neon", dark: true, accent: "#7aa2f7",
        seeds: {window: "#16161e", sidebar: "#181924", content: "#1a1b26", raised: "#24283b", text: "#c0caf5", separator: "#292e42", backdrop: "#13131a"}},
    {name: "One Dark", words: "atom gray blue", dark: true, accent: "#61afef", builtin: "onedark"},
    {name: "Solarized Dark", words: "teal blue classic", dark: true, accent: "#268bd2",
        seeds: {window: "#00252e", sidebar: "#002f3b", content: "#002b36", raised: "#073642", text: "#93a1a1", separator: "#0a3d4a", backdrop: "#00212a"}},
    {name: "Everforest Dark", words: "green forest calm", dark: true, accent: "#a7c080",
        seeds: {window: "#232a2e", sidebar: "#293136", content: "#2d353b", raised: "#343f44", text: "#d3c6aa", separator: "#3d484d", backdrop: "#1e2326"}},
    {name: "Kanagawa Wave", words: "japanese wave ink blue", dark: true, accent: "#7e9cd8",
        seeds: {window: "#1a1a22", sidebar: "#1c1c25", content: "#1f1f28", raised: "#2a2a37", text: "#dcd7ba", separator: "#2a2a37", backdrop: "#16161d"}},
    {name: "GitHub Dark", words: "black blue", dark: true, accent: "#2f81f7",
        seeds: {window: "#161b22", sidebar: "#12171e", content: "#0d1117", raised: "#1c2128", text: "#e6edf3", separator: "#21262d", backdrop: "#010409"}},
    {name: "Ayu Mirage", words: "orange yellow blue gray", dark: true, accent: "#ffcc66",
        seeds: {window: "#1c212b", sidebar: "#1f2430", content: "#242936", raised: "#2d3340", text: "#cccac2", separator: "#2d3340", backdrop: "#191e2a"}},
    {name: "Monokai", words: "pink green classic", dark: true, accent: "#f92672",
        seeds: {window: "#1e1f1c", sidebar: "#22231e", content: "#272822", raised: "#3e3d32", text: "#f8f8f2", separator: "#3e3d32", backdrop: "#1a1b17"}},
    {name: "Midnight", words: "owelk navy blue deep night", dark: true, accent: "#7aa7d9",
        seeds: {window: "#151b26", sidebar: "#18202c", content: "#1b2330", raised: "#232d3c", text: "#dfe6ef", separator: "#2a3545", backdrop: "#10151d"}}
]

// The themes whose name or words hold every word typed (light or dark too), as {name, dark, accent, seeds};
// `builtin(id)` gives the seeds of one kept with the built-in themes.
function find(query, builtin) {
    const terms = query.toLowerCase().split(/\s+/).filter(function(t) { return t.length })
    return themes.filter(function(t) {
        const haystack = (t.name + " " + t.words + " " + (t.dark ? "dark" : "light")).toLowerCase()
        return terms.every(function(term) { return haystack.indexOf(term) >= 0 })
    }).map(function(t) {
        return {name: t.name, dark: !!t.dark, accent: t.accent, seeds: Object.assign({dark: !!t.dark}, t.builtin ? builtin(t.builtin) : t.seeds)}
    })
}
