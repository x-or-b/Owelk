#include "Theme.h"
#include "ImagePalette.h"
#include "ResearchStore.h"
#include "AppIcon.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QIcon>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QStyleHints>
#include <algorithm>
#include <cmath>

namespace {
// Names are English here and translated where they are shown (qsTranslate("Owelk", …)), so a change of
// interface language reaches them too.
struct Named {
    const char *id, *name;
};
// Built-in themes, in the order Settings shows them.
constexpr Named themeNames[] = {{"neutral", QT_TRANSLATE_NOOP("Owelk", "Neutral")},
    {"paper", QT_TRANSLATE_NOOP("Owelk", "Paper")}, {"solarized", QT_TRANSLATE_NOOP("Owelk", "Solarized Light")},
    {"dark", QT_TRANSLATE_NOOP("Owelk", "Dark")}, {"nord", QT_TRANSLATE_NOOP("Owelk", "Nord")},
    {"onedark", QT_TRANSLATE_NOOP("Owelk", "One Dark")}, {"dracula", QT_TRANSLATE_NOOP("Owelk", "Dracula")}};
// Accents: light-theme value, dark-theme value. Red is reserved for errors.
struct Accent {
    const char *id, *name, *light, *dark;
};
constexpr Accent accentList[] = {{"blue", QT_TRANSLATE_NOOP("Owelk", "Blue"), "#426b9a", "#4d84c4"},
    {"teal", QT_TRANSLATE_NOOP("Owelk", "Teal"), "#2f7f86", "#35939a"},
    {"green", QT_TRANSLATE_NOOP("Owelk", "Green"), "#3f7d4f", "#4b9461"},
    {"orange", QT_TRANSLATE_NOOP("Owelk", "Orange"), "#b5651d", "#c77a33"},
    {"pink", QT_TRANSLATE_NOOP("Owelk", "Pink"), "#b44a7a", "#c45b8c"},
    {"purple", QT_TRANSLATE_NOOP("Owelk", "Purple"), "#6b55a8", "#8167c4"},
    {"graphite", QT_TRANSLATE_NOOP("Owelk", "Graphite"), "#5f6670", "#7a818b"}};
constexpr Named inks[]
    = {{"#426b9a", QT_TRANSLATE_NOOP("Owelk", "Blue")}, {"#e0b83f", QT_TRANSLATE_NOOP("Owelk", "Yellow")},
        {"#54a878", QT_TRANSLATE_NOOP("Owelk", "Green")}, {"#d87797", QT_TRANSLATE_NOOP("Owelk", "Pink")},
        {"#9274c3", QT_TRANSLATE_NOOP("Owelk", "Purple")}, {"#1d3a5c", QT_TRANSLATE_NOOP("Owelk", "Navy")}};

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
// Relative luminance (WCAG): 0 is black, 1 white.
qreal luminance(const QColor &c)
{
    const auto linear = [](qreal v) { return v <= .03928 ? v / 12.92 : std::pow((v + .055) / 1.055, 2.4); };
    return .2126 * linear(c.redF()) + .7152 * linear(c.greenF()) + .0722 * linear(c.blueF());
}
// The color with only its lightness moved until its luminance is within [low, high]; hue and saturation
// stay. A color already in range is returned as it is.
QColor withLuminance(const QColor &color, qreal low, qreal high)
{
    const qreal now = luminance(color);
    if (now >= low && now <= high) return color;
    const bool darken = now > high;
    const qreal target = darken ? high : low;
    const auto hsl = color.toHsl();
    const qreal hue = hsl.hslHueF(), saturation = hsl.hslSaturationF();
    // Luminance grows with lightness, so halve the interval toward the target.
    qreal below = darken ? 0 : hsl.lightnessF(), above = darken ? hsl.lightnessF() : 1;
    for (int i = 0; i < 24; ++i) {
        const qreal mid = (below + above) / 2;
        (luminance(QColor::fromHslF(hue, saturation, mid)) < target ? below : above) = mid;
    }
    return QColor::fromHslF(hue, saturation, darken ? below : above).toRgb();
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
// Settings › Appearance › Picture › Change picture, in minutes (-1: at each launch, 0: never).
bool knownInterval(int minutes)
{
    return QList<int>{-1, 0, 30, 60, 360, 720, 1440}.contains(minutes);
}
constexpr const char *seedKeys[] = {"window", "sidebar", "content", "raised", "text", "separator", "backdrop"};
// Pictures are kept no larger than this on their long side: enough for a window on a large screen, where
// a full illustration would decode to tens of megabytes.
constexpr int pictureSide = 2560;
// The share of a picture's border that is transparent: most of it for a cut-out character.
qreal transparentBorder(const QImage &image)
{
    int clear = 0, all = 0;
    const auto count = [&](int x, int y) {
        ++all;
        if (qAlpha(image.pixel(x, y)) < 16) ++clear;
    };
    for (int x = 0; x < image.width(); ++x) count(x, 0), count(x, image.height() - 1);
    for (int y = 1; y < image.height() - 1; ++y) count(0, y), count(image.width() - 1, y);
    return all ? qreal(clear) / all : 0;
}
// The smallest rectangle holding everything visible in a picture.
QRect visibleBounds(const QImage &image)
{
    int left = image.width(), right = -1, top = image.height(), bottom = -1;
    for (int y = 0; y < image.height(); ++y) {
        const auto *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
        for (int x = 0; x < image.width(); ++x)
            if (qAlpha(line[x]) >= 16) {
                left = std::min(left, x), right = std::max(right, x);
                top = std::min(top, y), bottom = y;
            }
    }
    return right < 0 ? image.rect() : QRect(QPoint(left, top), QPoint(right, bottom));
}
// A picture file as kept: upright, no larger than pictureSide, a cut-out trimmed to what is drawn. Null if this
// build cannot read it.
QImage keptPicture(const QString &path, bool *cutout)
{
    QImageReader reader(path);
    reader.setAutoTransform(true);
    if (const auto size = reader.size(); size.isValid() && std::max(size.width(), size.height()) > pictureSide)
        reader.setScaledSize(size.scaled(pictureSide, pictureSide, Qt::KeepAspectRatio));
    auto image = reader.read();
    if (image.isNull()) return {};
    image = image.convertToFormat(image.hasAlphaChannel() ? QImage::Format_ARGB32 : QImage::Format_RGB32);
    *cutout = image.hasAlphaChannel() && transparentBorder(image) > .5;
    if (*cutout) image = image.copy(visibleBounds(image));
    // Some readers ignore the scaled size.
    if (std::max(image.width(), image.height()) > pictureSide)
        image = image.scaled(pictureSide, pictureSide, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}
}

Theme::Theme(ResearchStore *store, QObject *parent) : QObject(parent), m_store(store)
{
    const int font = QFontDatabase::addApplicationFont(":/owelk/icons/lucide.ttf");
    if (const auto families = QFontDatabase::applicationFontFamilies(font); !families.isEmpty())
        m_iconFont = families.first();
    if (m_store) {
        const auto theme = m_store->setting("appearance.theme");
        if (knownTheme(theme)) m_theme = theme;
        m_customAccent = QColor(m_store->setting("appearance.customAccent"));
        const auto accent = m_store->setting("appearance.accent");
        m_accentName = accent == "custom" && m_customAccent.isValid() ? accent : QString(accentFor(accent).id);
        m_textSize = qBound(11, m_store->setting("appearance.textSize", "13").toInt(), 17);
        m_invertPages = m_store->setting("appearance.invertPages") == "1";
        m_verticalTabs = m_store->setting("appearance.verticalTabs") == "1";
        const auto icon = m_store->setting("appearance.appIcon", "paper");
        if (icon == "white" || icon == "navy") m_appIcon = icon;
        const QDir folder(pictureFolder());
        for (const auto &value : QJsonDocument::fromJson(m_store->setting("appearance.pictures").toUtf8()).array()) {
            const auto o = value.toObject();
            Picture kept{o.value("file").toString(), o.value("cutout").toBool(),
                o.value("colors").toVariant().toStringList(), o.value("accent").toString(),
                qBound(40, o.value("scale").toInt(100), 100)};
            for (const auto &[key, mood] : {std::pair{"talk", &kept.talk}, std::pair{"think", &kept.think}}) {
                *mood = o.value(key).toString();
                if (!mood->isEmpty() && !QFile::exists(folder.filePath(*mood))) mood->clear();
            }
            if (!kept.file.isEmpty() && QFile::exists(folder.filePath(kept.file))) m_pictures.append(kept);
        }
        const auto current = m_store->setting("appearance.picture");
        // The one picture kept before there could be several.
        if (m_store->setting("appearance.pictures").isEmpty() && !current.isEmpty()
            && QFile::exists(folder.filePath(current)))
            m_pictures.append({current, m_store->setting("appearance.pictureCutout") == "1",
                m_store->setting("appearance.pictureColors").split(',', Qt::SkipEmptyParts),
                m_store->setting("appearance.customAccent")});
        const Picture *shown = m_pictures.isEmpty() ? nullptr : &m_pictures.last();
        for (const auto &kept : std::as_const(m_pictures))
            if (kept.file == current) shown = &kept;
        mirror(shown);
        m_pictureOn = m_store->setting("appearance.pictureOn") != "0";
        m_pictureStrength = qBound(0, m_store->setting("appearance.pictureStrength", "35").toInt(), 60);
        m_paperStrength = qBound(0, m_store->setting("appearance.paperStrength", "15").toInt(), 50);
        if (const auto align = m_store->setting("appearance.pictureAlign"); align == "left" || align == "center")
            m_pictureAlign = align;
        m_matchSystem = m_store->setting("appearance.matchSystem") == "1";
        if (const auto light = m_store->setting("appearance.lightTheme"); knownTheme(light)) m_lightTheme = light;
        if (const auto dark = m_store->setting("appearance.darkTheme"); knownTheme(dark)) m_darkTheme = dark;
        if (const int interval = m_store->setting("appearance.pictureInterval", "0").toInt(); knownInterval(interval))
            m_pictureInterval = interval;
        m_pictureNext = QDateTime::fromString(m_store->setting("appearance.pictureNext"), Qt::ISODate);
    }
    if (const auto *app = qobject_cast<QGuiApplication *>(QCoreApplication::instance())) {
        if (const auto scheme = app->styleHints()->colorScheme(); scheme != Qt::ColorScheme::Unknown)
            m_systemDark = scheme == Qt::ColorScheme::Dark;
        connect(app->styleHints(), &QStyleHints::colorSchemeChanged, this, [this](Qt::ColorScheme scheme) {
            if (scheme != Qt::ColorScheme::Unknown) followAppearance(scheme == Qt::ColorScheme::Dark);
        });
    }
    // Before the first paint, so a window never opens in the other appearance's theme.
    if (m_matchSystem && m_systemDark) useThemeFor(*m_systemDark);
    apply();
    showAppIcon(false);
    m_pictureTimer.setSingleShot(true);
    connect(&m_pictureTimer, &QTimer::timeout, this, &Theme::schedulePicture);
    connect(this, &Theme::changed, this, &Theme::schedulePicture);
    connect(this, &Theme::picturesChanged, this, &Theme::schedulePicture);
    // At each launch: another picture before the window opens.
    if (m_pictureInterval == -1) rotatePicture();
    schedulePicture();
}

QVariantList Theme::appIcons() const
{
    return {QVariantMap{{"id", "paper"}, {"name", QT_TRANSLATE_NOOP("Owelk", "Ink on paper")},
                {"source", "qrc" + appIconPath("paper")}},
        QVariantMap{{"id", "white"}, {"name", QT_TRANSLATE_NOOP("Owelk", "Navy on white")},
            {"source", "qrc" + appIconPath("white")}},
        QVariantMap{{"id", "navy"}, {"name", QT_TRANSLATE_NOOP("Owelk", "Paper on navy")},
            {"source", "qrc" + appIconPath("navy")}}};
}

QString Theme::appIconPath(const QString &id)
{
    return id == "white" || id == "navy" ? ":/owelk/app/owelk-" + id + ".png" : QStringLiteral(":/owelk/app/owelk.png");
}

void Theme::setAppIcon(const QString &id)
{
    const auto next = id == "white" || id == "navy" ? id : QStringLiteral("paper");
    if (next == m_appIcon) return;
    m_appIcon = next;
    save("appearance.appIcon", next);
    showAppIcon(true);
    emit changed();
}

// The running app's icon (Dock, taskbar, title bars). In a macOS bundle the chosen icon is also set
// on the app in Finder, and cleared again for the default; at startup only if it went missing.
void Theme::showAppIcon(bool finderToo)
{
    if (qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        QGuiApplication::setWindowIcon(QIcon(appIconPath(m_appIcon)));
    const auto bundle = AppIcon::bundlePath();
    if (bundle.isEmpty()) return;
    if (finderToo || (m_appIcon != "paper" && !AppIcon::hasCustomIcon(bundle)))
        AppIcon::setBundleIcon(bundle, m_appIcon == "paper" ? QString() : appIconPath(m_appIcon));
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

// The named accents span these luminances: white labels stay readable on them, and they stand out from
// the surfaces of a light or a dark theme. A custom accent is brought into the same range.
Theme::AccentPair Theme::derivedAccent(const QColor &base)
{
    return {withLuminance(base, .10, .19), withLuminance(base, .17, .26)};
}

Theme::AccentPair Theme::accentPair() const
{
    if (m_accentName == "custom" && m_customAccent.isValid()) return derivedAccent(m_customAccent);
    const auto &a = accentFor(m_accentName);
    return {QColor(a.light), QColor(a.dark)};
}

void Theme::apply()
{
    const auto s = m_theme == "custom" ? custom() : preset(m_theme);
    m_dark = s.dark;
    const auto accent = accentPair();
    m_accent = m_dark ? accent.dark : accent.light;
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
    m_pageSelection = alpha(accent.light, .30);
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
    // With Match System, the choice is for the appearance the system has now.
    if (m_matchSystem && m_systemDark) {
        (*m_systemDark ? m_darkTheme : m_lightTheme) = id;
        save(*m_systemDark ? "appearance.darkTheme" : "appearance.lightTheme", id);
    }
    apply();
}

void Theme::setMatchSystem(bool on)
{
    if (on == m_matchSystem) return;
    m_matchSystem = on;
    save("appearance.matchSystem", on ? "1" : "0");
    if (on) {
        // The theme in use stays the one for its kind of appearance.
        const bool dark = m_theme == "custom" ? custom().dark : preset(m_theme).dark;
        (dark ? m_darkTheme : m_lightTheme) = m_theme;
        save(dark ? "appearance.darkTheme" : "appearance.lightTheme", m_theme);
        if (m_systemDark) useThemeFor(*m_systemDark);
    }
    apply();
}

void Theme::setLightTheme(const QString &id)
{
    if (!knownTheme(id) || id == m_lightTheme) return;
    m_lightTheme = id;
    save("appearance.lightTheme", id);
    if (m_matchSystem && m_systemDark && !*m_systemDark) useThemeFor(false);
    apply();
}

void Theme::setDarkTheme(const QString &id)
{
    if (!knownTheme(id) || id == m_darkTheme) return;
    m_darkTheme = id;
    save("appearance.darkTheme", id);
    if (m_matchSystem && m_systemDark && *m_systemDark) useThemeFor(true);
    apply();
}

void Theme::followAppearance(bool dark)
{
    m_systemDark = dark;
    if (!m_matchSystem) return;
    useThemeFor(dark);
    apply();
}

void Theme::useThemeFor(bool dark)
{
    const auto id = dark ? m_darkTheme : m_lightTheme;
    // A picture's theme in the other brightness: its colors tinted again, as its Dark switch does.
    if (id == "custom" && showing() && custom().dark != dark)
        writeCustomSeeds(tintedSeeds(m_pictureColors.isEmpty() ? QColor() : QColor(m_pictureColors.first()), dark));
    if (id == m_theme) return;
    m_theme = id;
    save("appearance.theme", id);
}

void Theme::setAccentName(const QString &id)
{
    const bool known = id == "custom" ? m_customAccent.isValid() : id == QLatin1String(accentFor(id).id);
    if (!known || id == m_accentName) return;
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

void Theme::setPictureStrength(int percent)
{
    percent = qBound(0, percent, 60);
    if (percent == m_pictureStrength) return;
    m_pictureStrength = percent;
    save("appearance.pictureStrength", QString::number(percent));
    emit changed();
}

void Theme::setPictureAlign(const QString &align)
{
    if ((align != "left" && align != "center" && align != "right") || align == m_pictureAlign) return;
    m_pictureAlign = align;
    save("appearance.pictureAlign", align);
    emit changed();
}

void Theme::setPictureScale(int percent)
{
    percent = qBound(40, percent, 100);
    if (percent == m_pictureScale || m_picture.isEmpty()) return;
    for (auto &picture : m_pictures)
        if (picture.file == m_picture) picture.scale = percent;
    m_pictureScale = percent;
    savePictures(false);
    emit changed();
}

void Theme::setPaperStrength(int percent)
{
    percent = qBound(0, percent, 50);
    if (percent == m_paperStrength) return;
    m_paperStrength = percent;
    save("appearance.paperStrength", QString::number(percent));
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
    if (m_customAccent.isValid()) {
        const auto pair = derivedAccent(m_customAccent);
        list.append(QVariantMap{{"id", "custom"}, {"name", QT_TRANSLATE_NOOP("Owelk", "Custom")},
            {"light", pair.light.name()}, {"dark", pair.dark.name()}});
    }
    return list;
}

bool Theme::setCustomAccent(const QVariant &color)
{
    const auto given = color.value<QColor>();
    if (!given.isValid()) return false;
    // As stored (#rrggbb), so it compares equal to the same color named anywhere else.
    const QColor c(given.name(QColor::HexRgb));
    m_customAccent = c;
    m_accentName = "custom";
    save("appearance.customAccent", c.name());
    // The picture in use remembers it, for when it is chosen again.
    for (auto &picture : m_pictures)
        if (showing() && picture.file == m_picture && picture.accent != c.name()) {
            picture.accent = c.name();
            savePictures();
        }
    save("appearance.accent", m_accentName);
    apply();
    return true;
}

void Theme::clearCustomAccent()
{
    if (!m_customAccent.isValid()) return;
    m_customAccent = QColor();
    save("appearance.customAccent", QString());
    if (m_accentName == "custom") {
        m_accentName = "blue";
        save("appearance.accent", m_accentName);
    }
    apply();
}

QVariantMap Theme::seeds(const QString &id) const
{
    const auto s = id == "custom" ? custom() : preset(id);
    const QColor *fields[] = {&s.window, &s.sidebar, &s.content, &s.raised, &s.text, &s.separator, &s.backdrop};
    QVariantMap map{{"dark", s.dark}};
    for (int i = 0; i < 7; ++i) map.insert(seedKeys[i], fields[i]->name());
    return map;
}

QVariantMap Theme::tintedSeeds(const QVariant &color, bool dark) const
{
    const auto s = preset(dark ? "dark" : "neutral");
    const auto hue = color.value<QColor>();
    // OKLCH chroma per seed (window, sidebar, content, raised, text, separator, backdrop): the page
    // surfaces barely tinted, the chrome, lines and the space around PDF pages a little more.
    constexpr qreal lightChroma[] = {.022, .016, .007, .004, .03, .028, .032};
    constexpr qreal darkChroma[] = {.02, .02, .018, .022, .012, .025, .018};
    const QColor *fields[] = {&s.window, &s.sidebar, &s.content, &s.raised, &s.text, &s.separator, &s.backdrop};
    QVariantMap map{{"dark", dark}};
    for (int i = 0; i < 7; ++i)
        map.insert(seedKeys[i],
            (hue.isValid() ? ImagePalette::tint(*fields[i], hue, (dark ? darkChroma : lightChroma)[i]) : *fields[i])
                .name());
    return map;
}

bool Theme::writeCustomSeeds(const QVariantMap &seeds)
{
    QJsonObject json{{"dark", seeds.value("dark").toBool()}};
    for (const auto *key : seedKeys) {
        const QColor c(seeds.value(key).toString());
        if (!c.isValid()) return false;
        json.insert(key, c.name());
    }
    save("appearance.custom", QString::fromUtf8(QJsonDocument(json).toJson(QJsonDocument::Compact)));
    return true;
}

bool Theme::setCustomSeeds(const QVariantMap &seeds)
{
    if (!writeCustomSeeds(seeds)) return false;
    if (m_theme == "custom")
        apply();
    else
        setTheme("custom");
    return true;
}

QString Theme::keepPictureFile(const QImage &image, bool cutout, const QString &mood) const
{
    QDir folder(pictureFolder());
    if (!folder.mkpath(".")) return {};
    // A new name each time, so no image cache shows another picture. A cut-out keeps its transparency; a
    // photo is smaller as JPEG.
    const auto name = QString("picture-%1%2.%3")
                          .arg(QDateTime::currentMSecsSinceEpoch())
                          .arg(mood.isEmpty() ? QString() : "-" + mood)
                          .arg(cutout ? "png" : "jpg");
    return image.save(folder.filePath(name), nullptr, cutout ? -1 : 90) ? name : QString();
}

bool Theme::setPictureMood(const QString &mood, const QUrl &file)
{
    if (mood != "talk" && mood != "think") return false;
    for (auto &picture : m_pictures) {
        if (picture.file != m_picture) continue;
        auto &kept = mood == "talk" ? picture.talk : picture.think;
        QString name;
        if (!file.isEmpty()) {
            bool cutout = false;
            const auto image = file.isLocalFile() ? keptPicture(file.toLocalFile(), &cutout) : QImage();
            name = image.isNull() ? QString() : keepPictureFile(image, cutout, mood);
            if (name.isEmpty()) return false;
        }
        if (!kept.isEmpty()) QFile::remove(QDir(pictureFolder()).filePath(kept));
        kept = name;
        mirror(&picture);
        savePictures(false);
        emit changed();
        return true;
    }
    return false;
}

QVariantMap Theme::pictureMoods() const
{
    const QDir folder(pictureFolder());
    QVariantMap moods;
    for (const auto &picture : m_pictures) {
        if (picture.file != m_picture) continue;
        for (const auto &[mood, file] : {std::pair{"talk", picture.talk}, std::pair{"think", picture.think}}) {
            if (file.isEmpty()) continue;
            const auto size = QImageReader(folder.filePath(file)).size();
            moods.insert(mood,
                QVariantMap{{"url", QUrl::fromLocalFile(folder.filePath(file))},
                    {"aspect", size.height() > 0 ? qreal(size.width()) / size.height() : 1.}});
        }
    }
    return moods;
}

QString Theme::pictureFolder() const
{
    return m_store ? QDir(m_store->dataDirectory()).filePath("picture") : QString();
}

QUrl Theme::picture() const
{
    return showing() ? QUrl::fromLocalFile(QDir(pictureFolder()).filePath(m_picture)) : QUrl();
}

QString Theme::pictureFilter()
{
    QStringList patterns;
    const auto supported = QImageReader::supportedImageFormats();
    for (const char *format : {"png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "heic", "avif"})
        if (supported.contains(format)) patterns.append(QStringLiteral("*.") + QLatin1String(format));
    return patterns.join(' ');
}

bool Theme::usePicture(const QUrl &file)
{
    if (!m_store || !file.isLocalFile()) return false;
    bool cutout = false;
    const auto image = keptPicture(file.toLocalFile(), &cutout);
    const auto name = image.isNull() ? QString() : keepPictureFile(image, cutout, QString());
    if (name.isEmpty()) return false;
    if (!showing()) keepBeforePicture();
    if (!m_pictureOn) {
        m_pictureOn = true;
        save("appearance.pictureOn", "1");
    }
    const auto colors = ImagePalette::extract(image);
    Picture picture{name, cutout, {}, colors.main.isValid() ? colors.main.name() : QString()};
    for (const auto &color : colors.swatches) picture.colors.append(color.name());
    m_pictures.append(picture);
    // Light or dark like the theme in use; the Custom theme's Dark switch changes it afterwards.
    showPicture(picture, m_dark, true);
    return true;
}

bool Theme::choosePicture(const QString &id)
{
    const auto file = id.isEmpty() ? m_picture : id;
    for (const auto &picture : std::as_const(m_pictures))
        if (picture.file == file) {
            // Another picture, the same brightness as the picture theme had; turned on, the theme in use's.
            const bool dark = showing() ? custom().dark : m_dark;
            if (!m_pictureOn) {
                keepBeforePicture();
                m_pictureOn = true;
                save("appearance.pictureOn", "1");
            }
            showPicture(picture, dark, true);
            return true;
        }
    return false;
}

void Theme::setPictureOn(bool on)
{
    if (on == m_pictureOn) return;
    if (on) {
        if (!m_pictures.isEmpty()) {
            choosePicture(m_picture);
            return;
        }
        m_pictureOn = true;
        save("appearance.pictureOn", "1");
        emit changed();
        return;
    }
    const bool shown = showing();
    m_pictureOn = false;
    save("appearance.pictureOn", "0");
    if (shown)
        restoreBeforePicture();
    else
        emit changed();
    emit picturesChanged();
}

void Theme::keepBeforePicture()
{
    if (!m_store) return;
    save("appearance.beforePicture",
        QString::fromUtf8(QJsonDocument(QJsonObject{{"theme", m_theme}, {"accent", m_accentName},
                                            {"custom", m_store->setting("appearance.custom")}})
                .toJson(QJsonDocument::Compact)));
}

void Theme::restoreBeforePicture()
{
    const auto before = m_store
        ? QJsonDocument::fromJson(m_store->setting("appearance.beforePicture").toUtf8()).object()
        : QJsonObject();
    save("appearance.beforePicture", QString());
    save("appearance.custom", before.value("custom").toString());
    m_customAccent = QColor();
    save("appearance.customAccent", QString());
    const auto theme = before.value("theme").toString(), accent = before.value("accent").toString();
    m_theme = knownTheme(theme) ? theme : QStringLiteral("neutral");
    m_accentName = accentFor(accent).id;
    save("appearance.theme", m_theme);
    save("appearance.accent", m_accentName);
    apply();
}

void Theme::removePicture(const QString &id)
{
    const auto file = id.isEmpty() ? m_picture : id;
    qsizetype at = -1;
    for (qsizetype i = 0; i < m_pictures.size(); ++i)
        if (m_pictures[i].file == file) at = i;
    if (at < 0) return;
    for (const auto &kept : {file, m_pictures[at].talk, m_pictures[at].think})
        if (!kept.isEmpty()) QFile::remove(QDir(pictureFolder()).filePath(kept));
    m_pictures.removeAt(at);
    const bool shown = showing();
    if (file != m_picture) {
        savePictures();
        emit changed();
        return;
    }
    if (!m_pictures.isEmpty()) {
        const auto &next = m_pictures[std::min(at, m_pictures.size() - 1)];
        // The next one (or the one before, after the last): shown if the picture theme was.
        if (shown) {
            showPicture(next, custom().dark, m_theme == "custom");
        } else {
            mirror(&next);
            savePictures();
            emit changed();
        }
        return;
    }
    mirror(nullptr);
    savePictures();
    if (shown)
        restoreBeforePicture();
    else
        emit changed();
}

QVariantList Theme::pictures() const
{
    const QDir folder(pictureFolder());
    QVariantList list;
    for (const auto &picture : m_pictures)
        list.append(QVariantMap{{"id", picture.file}, {"url", QUrl::fromLocalFile(folder.filePath(picture.file))},
            {"cutout", picture.cutout}, {"current", picture.file == m_picture}});
    return list;
}

void Theme::mirror(const Picture *picture)
{
    m_picture = picture ? picture->file : QString();
    m_pictureCutout = picture && picture->cutout;
    m_pictureColors = picture ? picture->colors : QStringList();
    m_pictureScale = picture ? picture->scale : 100;
    m_pictureSize = picture ? QImageReader(QDir(pictureFolder()).filePath(picture->file)).size() : QSize();
}

void Theme::savePictures(bool listChanged)
{
    QJsonArray list;
    for (const auto &picture : std::as_const(m_pictures))
        list.append(QJsonObject{{"file", picture.file}, {"cutout", picture.cutout},
            {"colors", QJsonArray::fromStringList(picture.colors)}, {"accent", picture.accent},
            {"scale", picture.scale}, {"talk", picture.talk}, {"think", picture.think}});
    save("appearance.pictures", QString::fromUtf8(QJsonDocument(list).toJson(QJsonDocument::Compact)));
    save("appearance.picture", m_picture);
    // Read only by the step that made one picture into a list.
    save("appearance.pictureCutout", QString());
    save("appearance.pictureColors", QString());
    if (listChanged) emit picturesChanged();
}

void Theme::showPicture(const Picture &picture, bool dark, bool show)
{
    mirror(&picture);
    savePictures();
    const auto seeds = tintedSeeds(picture.colors.isEmpty() ? QColor() : QColor(picture.colors.first()), dark);
    if (!show) {
        // Ready for when the Custom theme is chosen again; the theme in use stays.
        writeCustomSeeds(seeds);
        emit changed();
        return;
    }
    setCustomSeeds(seeds);
    if (!picture.accent.isEmpty()) {
        setCustomAccent(picture.accent);
    } else {
        clearCustomAccent();
        setAccentName("graphite");
    }
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

QString Theme::defaultTextInk() const
{
    return inks[std::size(inks) - 1].id;
}

void Theme::setPictureInterval(int minutes)
{
    if (!knownInterval(minutes) || minutes == m_pictureInterval) return;
    m_pictureInterval = minutes;
    save("appearance.pictureInterval", QString::number(minutes));
    m_pictureNext = minutes > 0 ? QDateTime::currentDateTimeUtc().addSecs(minutes * 60) : QDateTime();
    save("appearance.pictureNext", m_pictureNext.toString(Qt::ISODate));
    emit rotationChanged();
    schedulePicture();
}

void Theme::setPictureRotationAllowed(bool allowed)
{
    if (m_pictureRotationAllowed == allowed) return;
    m_pictureRotationAllowed = allowed;
    emit rotationChanged();
    schedulePicture();
}

void Theme::rotatePicture()
{
    if (m_pictures.size() < 2 || !pictureShown()) return;
    QStringList choices;
    for (const auto &picture : std::as_const(m_pictures))
        if (picture.file != m_picture) choices << picture.file;
    if (choices.isEmpty()) return;
    choosePicture(choices[QRandomGenerator::global()->bounded(int(choices.size()))]);
}

void Theme::schedulePicture()
{
    if (m_rotating) return;
    m_pictureTimer.stop();
    if (m_pictureInterval <= 0 || m_pictures.size() < 2 || !pictureShown()) return;
    const auto now = QDateTime::currentDateTimeUtc();
    if (!m_pictureNext.isValid()) {
        m_pictureNext = now.addSecs(m_pictureInterval * 60);
        save("appearance.pictureNext", m_pictureNext.toString(Qt::ISODate));
    }
    const qint64 remaining = now.msecsTo(m_pictureNext);
    if (remaining > 0) {
        m_pictureTimer.start(int(qMin<qint64>(remaining, 24 * 60 * 60 * 1000)));
        return;
    }
    // A due change waits for Home or the application to leave the foreground, without polling.
    if (!m_pictureRotationAllowed) return;
    m_rotating = true;
    m_pictureNext = now.addSecs(m_pictureInterval * 60);
    save("appearance.pictureNext", m_pictureNext.toString(Qt::ISODate));
    rotatePicture();
    m_rotating = false;
    schedulePicture();
}
