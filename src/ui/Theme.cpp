#include "Theme.h"
#include "ResearchStore.h"
#include <QFontDatabase>
#include <QFontDatabase>
#include <QJsonDocument>
#include <QJsonObject>

namespace {
struct Named {
    const char *id, *name;
};
// Built-in themes, in the order Settings shows them.
constexpr Named themeNames[] = {{"neutral", "Neutral"}, {"paper", "Paper"}, {"solarized", "Solarized Light"},
    {"dark", "Dark"}, {"nord", "Nord"}, {"onedark", "One Dark"}, {"dracula", "Dracula"}};
// Accents: light-theme value, dark-theme value. Red is reserved for errors.
struct Accent {
    const char *id, *name, *light, *dark;
};
constexpr Accent accentList[] = {{"blue", "Blue", "#426b9a", "#4d84c4"}, {"teal", "Teal", "#2f7f86", "#35939a"},
    {"green", "Green", "#3f7d4f", "#4b9461"}, {"orange", "Orange", "#b5651d", "#c77a33"},
    {"pink", "Pink", "#b44a7a", "#c45b8c"}, {"purple", "Purple", "#6b55a8", "#8167c4"},
    {"graphite", "Graphite", "#5f6670", "#7a818b"}};
constexpr Named inks[]
    = {{"#426b9a", "Blue"}, {"#e0b83f", "Yellow"}, {"#54a878", "Green"}, {"#d87797", "Pink"}, {"#9274c3", "Purple"}};

QColor alpha(QColor color, qreal a)
{
    color.setAlphaF(a);
    return color;
}
QColor blend(const QColor &a, const QColor &b, qreal t)
{
    return QColor::fromRgbF(a.redF() + (b.redF() - a.redF()) * t, a.greenF() + (b.greenF() - a.greenF()) * t,
        a.blueF() + (b.blueF() - a.blueF()) * t, a.alphaF() + (b.alphaF() - a.alphaF()) * t);
}
const Accent &accentFor(const QString &id)
{
    for (const auto &a : accentList)
        if (id == QLatin1String(a.id)) return a;
    return accentList[0];
}
bool knownTheme(const QString &id)
{
    if (id == "custom") return true;
    for (const auto &t : themeNames)
        if (id == QLatin1String(t.id)) return true;
    return false;
}
constexpr const char *seedKeys[] = {"window", "sidebar", "content", "raised", "text", "separator", "backdrop"};
}

Theme::Theme(ResearchStore *store, QObject *parent) : QObject(parent), m_store(store)
{
    const int font = QFontDatabase::addApplicationFont(":/owelk/icons/lucide.ttf");
    if (const auto families = QFontDatabase::applicationFontFamilies(font); !families.isEmpty())
        m_iconFont = families.first();
    if (m_store) {
        const auto theme = m_store->setting("appearance.theme");
        if (knownTheme(theme)) m_theme = theme;
        m_accentName = accentFor(m_store->setting("appearance.accent")).id;
        m_textSize = qBound(11, m_store->setting("appearance.textSize", "13").toInt(), 17);
        m_invertPages = m_store->setting("appearance.invertPages") == "1";
        m_verticalTabs = m_store->setting("appearance.verticalTabs") == "1";
    }
    apply();
}

Theme::Seeds Theme::preset(const QString &id)
{
    const auto s = [](bool dark, const char *window, const char *sidebar, const char *content, const char *raised,
                       const char *text, const char *separator, const char *backdrop) {
        return Seeds{dark, QColor(window), QColor(sidebar), QColor(content), QColor(raised), QColor(text),
            QColor(separator), QColor(backdrop)};
    };
    if (id == "paper") return s(false, "#ece6dc", "#f4efe6", "#fbf8f2", "#fffdf8", "#2b2620", "#e1d8c9", "#e4ddd0");
    if (id == "solarized") return s(false, "#eee8d5", "#f5efdc", "#fdf6e3", "#fdf6e3", "#3d5159", "#e2dbc5", "#e6dfca");
    if (id == "dark") return s(true, "#262626", "#2a2a2a", "#1f1f1f", "#323232", "#e8e8e8", "#3a3a3a", "#181818");
    if (id == "nord") return s(true, "#272c36", "#2b303b", "#2e3440", "#3b4252", "#e5e9f0", "#3b4252", "#232831");
    if (id == "onedark") return s(true, "#21252b", "#252930", "#282c34", "#30353f", "#d7dae0", "#363b46", "#1d2026");
    if (id == "dracula") return s(true, "#21222c", "#252731", "#282a36", "#343746", "#f8f8f2", "#393c4c", "#1c1d25");
    return s(false, "#efefef", "#f7f7f7", "#ffffff", "#ffffff", "#1f1f1f", "#e3e3e3", "#e6e6e6");
}

Theme::Seeds Theme::custom() const
{
    // A custom theme starts from Neutral; any stored seed that is a valid color replaces it.
    auto seeds = preset("neutral");
    if (!m_store) return seeds;
    const auto json = QJsonDocument::fromJson(m_store->setting("appearance.custom").toUtf8()).object();
    if (json.isEmpty()) return seeds;
    seeds.dark = json.value("dark").toBool();
    QColor *fields[] = {
        &seeds.window, &seeds.sidebar, &seeds.content, &seeds.raised, &seeds.text, &seeds.separator, &seeds.backdrop};
    for (int i = 0; i < 7; ++i)
        if (const QColor c(json.value(seedKeys[i]).toString()); c.isValid()) *fields[i] = c;
    return seeds;
}

void Theme::apply()
{
    const auto s = m_theme == "custom" ? custom() : preset(m_theme);
    m_dark = s.dark;
    const auto &a = accentFor(m_accentName);
    m_accent = QColor(m_dark ? a.dark : a.light);
    m_window = s.window;
    m_sidebar = s.sidebar;
    m_content = s.content;
    m_raised = s.raised;
    m_pdfBackdrop = s.backdrop;
    m_text = s.text;
    m_separator = s.separator;
    m_field = m_dark ? blend(s.content, s.text, .06) : s.content;
    m_control = blend(s.content, s.text, m_dark ? .10 : .06);
    m_textSecondary = blend(s.text, s.content, .30);
    m_textTertiary = blend(s.text, s.content, .48);
    m_textDisabled = blend(s.text, s.content, .62);
    m_icon = m_textSecondary;
    m_onAccent = Qt::white;
    m_border = blend(s.separator, s.text, m_dark ? .14 : .20);
    m_hover = alpha(s.text, m_dark ? .08 : .06);
    m_pressed = alpha(s.text, m_dark ? .14 : .11);
    m_selected = blend(s.content, m_accent, m_dark ? .28 : .16);
    m_selectedText = blend(m_accent, s.text, m_dark ? .45 : .30);
    m_focus = alpha(m_accent, .55);
    m_accentHover = m_dark ? m_accent.lighter(112) : m_accent.darker(112);
    m_accentBorder = blend(s.content, m_accent, .50);
    m_danger = QColor(m_dark ? "#ff6b61" : "#b42323");
    m_overlay = alpha(s.text, .12);
    m_overlayBorder = m_textSecondary;
    m_shadow = alpha(Qt::black, m_dark ? .45 : .16);
    // On the white page, whatever the theme.
    m_pageSelection = alpha(QColor(a.light), .30);
    m_searchMatch = alpha(QColor("#f2c94c"), .45);
    m_scrollHandle = alpha(s.text, .26);
    m_scrollHandleHover = alpha(s.text, .40);
    m_scrollHandlePressed = alpha(s.text, .52);
    emit changed();
}

void Theme::save(const QString &key, const QString &value)
{
    if (m_store) m_store->setSetting(key, value);
}

void Theme::setTheme(const QString &id)
{
    if (!knownTheme(id) || id == m_theme) return;
    m_theme = id;
    save("appearance.theme", id);
    apply();
}

void Theme::setAccentName(const QString &id)
{
    const QString known = accentFor(id).id;
    if (known != id || id == m_accentName) return;
    m_accentName = id;
    save("appearance.accent", id);
    apply();
}

void Theme::setTextSize(int size)
{
    size = qBound(11, size, 17);
    if (size == m_textSize) return;
    m_textSize = size;
    save("appearance.textSize", QString::number(size));
    emit changed();
}

void Theme::setInvertPages(bool on)
{
    if (on == m_invertPages) return;
    m_invertPages = on;
    save("appearance.invertPages", on ? "1" : "0");
    emit changed();
}

void Theme::setVerticalTabs(bool on)
{
    if (on == m_verticalTabs) return;
    m_verticalTabs = on;
    save("appearance.verticalTabs", on ? "1" : "0");
    emit changed();
}

QVariantList Theme::themes() const
{
    QVariantList list;
    for (const auto &t : themeNames)
        list.append(QVariantMap{{"id", t.id}, {"name", t.name}, {"dark", preset(t.id).dark}});
    return list;
}

QVariantList Theme::accents() const
{
    QVariantList list;
    for (const auto &a : accentList)
        list.append(QVariantMap{{"id", a.id}, {"name", a.name}, {"light", a.light}, {"dark", a.dark}});
    return list;
}

QVariantMap Theme::seeds(const QString &id) const
{
    const auto s = id == "custom" ? custom() : preset(id);
    const QColor *fields[] = {&s.window, &s.sidebar, &s.content, &s.raised, &s.text, &s.separator, &s.backdrop};
    QVariantMap map{{"dark", s.dark}};
    for (int i = 0; i < 7; ++i) map.insert(seedKeys[i], fields[i]->name());
    return map;
}

bool Theme::setCustomSeeds(const QVariantMap &seeds)
{
    QJsonObject json{{"dark", seeds.value("dark").toBool()}};
    for (const auto *key : seedKeys) {
        const QColor c(seeds.value(key).toString());
        if (!c.isValid()) return false;
        json.insert(key, c.name());
    }
    save("appearance.custom", QString::fromUtf8(QJsonDocument(json).toJson(QJsonDocument::Compact)));
    if (m_theme == "custom")
        apply();
    else
        setTheme("custom");
    return true;
}

QColor Theme::mix(const QColor &a, const QColor &b, qreal t) const
{
    return blend(a, b, qBound<qreal>(0, t, 1));
}

QVariantList Theme::annotationInks() const
{
    QVariantList list;
    for (const auto &ink : inks) list.append(QVariantMap{{"name", ink.name}, {"value", ink.id}});
    return list;
}

QString Theme::defaultInk() const
{
    return inks[0].id;
}
