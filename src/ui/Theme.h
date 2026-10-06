#pragma once

#include <QColor>
#include <QObject>
#include <QVariantList>
#include <QVariantMap>

class ResearchStore;

// Colors, shapes and type sizes for every QML surface (import Owelk.Ui; Theme.x).
// A theme is a handful of seed colors; every other token is derived from them, so the
// built-in themes and a custom one follow the same rules. Changing a setting re-evaluates
// the bindings once; nothing here runs per frame.
class Theme : public QObject {
    Q_OBJECT
    // Choices (persisted under appearance.* in the settings table).
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY changed)
    Q_PROPERTY(QString accentName READ accentName WRITE setAccentName NOTIFY changed)
    Q_PROPERTY(int textSize READ textSize WRITE setTextSize NOTIFY changed)
    Q_PROPERTY(bool invertPages READ invertPages WRITE setInvertPages NOTIFY changed)
    // Tabs listed beside the window instead of a bar above each split.
    Q_PROPERTY(bool verticalTabs READ verticalTabs WRITE setVerticalTabs NOTIFY changed)
    // The app's icon in the Dock and taskbar (and, on macOS, in Finder): paper, white or navy.
    Q_PROPERTY(QString appIcon READ appIcon WRITE setAppIcon NOTIFY changed)
    Q_PROPERTY(QVariantList appIcons READ appIcons CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY changed)
    // Whether this build can invert PDF pages (compiled with Qt ShaderTools).
    Q_PROPERTY(bool canInvertPages READ canInvertPages CONSTANT)
    Q_PROPERTY(QVariantList themes READ themes CONSTANT)
    Q_PROPERTY(QVariantList accents READ accents CONSTANT)

    // Surfaces.
    Q_PROPERTY(QColor window MEMBER m_window NOTIFY changed) // window chrome, toolbars, tab bar
    Q_PROPERTY(QColor sidebar MEMBER m_sidebar NOTIFY changed) // dock panels, sidebars
    Q_PROPERTY(QColor content MEMBER m_content NOTIFY changed) // documents, lists, active tab
    Q_PROPERTY(QColor raised MEMBER m_raised NOTIFY changed) // menus, popovers, dialogs
    Q_PROPERTY(QColor field MEMBER m_field NOTIFY changed) // text inputs
    Q_PROPERTY(QColor control MEMBER m_control NOTIFY changed) // push buttons, chips at rest
    Q_PROPERTY(QColor pdfBackdrop MEMBER m_pdfBackdrop NOTIFY changed)
    Q_PROPERTY(QColor paper MEMBER m_paper CONSTANT) // the PDF page itself
    Q_PROPERTY(QColor paperInverted MEMBER m_paperInverted CONSTANT) // a white page with Invert pages on
    // Text and glyphs.
    Q_PROPERTY(QColor text MEMBER m_text NOTIFY changed)
    Q_PROPERTY(QColor textSecondary MEMBER m_textSecondary NOTIFY changed)
    Q_PROPERTY(QColor textTertiary MEMBER m_textTertiary NOTIFY changed)
    Q_PROPERTY(QColor textDisabled MEMBER m_textDisabled NOTIFY changed)
    Q_PROPERTY(QColor icon MEMBER m_icon NOTIFY changed)
    Q_PROPERTY(QColor onAccent MEMBER m_onAccent NOTIFY changed)
    // Lines.
    Q_PROPERTY(QColor separator MEMBER m_separator NOTIFY changed) // hairlines between rows and areas
    Q_PROPERTY(QColor border MEMBER m_border NOTIFY changed) // control and popover outlines
    // States: one look each, everywhere.
    Q_PROPERTY(QColor hover MEMBER m_hover NOTIFY changed)
    Q_PROPERTY(QColor pressed MEMBER m_pressed NOTIFY changed)
    Q_PROPERTY(QColor selected MEMBER m_selected NOTIFY changed)
    Q_PROPERTY(QColor selectedText MEMBER m_selectedText NOTIFY changed)
    Q_PROPERTY(QColor focus MEMBER m_focus NOTIFY changed)
    // Accent and danger.
    Q_PROPERTY(QColor accent MEMBER m_accent NOTIFY changed)
    Q_PROPERTY(QColor accentHover MEMBER m_accentHover NOTIFY changed)
    Q_PROPERTY(QColor accentBorder MEMBER m_accentBorder NOTIFY changed)
    Q_PROPERTY(QColor danger MEMBER m_danger NOTIFY changed)
    // Overlays.
    Q_PROPERTY(QColor overlay MEMBER m_overlay NOTIFY changed) // drop targets, capture box fill
    Q_PROPERTY(QColor overlayBorder MEMBER m_overlayBorder NOTIFY changed)
    Q_PROPERTY(QColor shadow MEMBER m_shadow NOTIFY changed)
    Q_PROPERTY(QColor pageSelection MEMBER m_pageSelection NOTIFY changed)
    Q_PROPERTY(QColor searchMatch MEMBER m_searchMatch NOTIFY changed)
    Q_PROPERTY(QColor scrollHandle MEMBER m_scrollHandle NOTIFY changed)
    Q_PROPERTY(QColor scrollHandleHover MEMBER m_scrollHandleHover NOTIFY changed)
    Q_PROPERTY(QColor scrollHandlePressed MEMBER m_scrollHandlePressed NOTIFY changed)
    Q_PROPERTY(QColor captureBorder MEMBER m_accent NOTIFY changed)
    Q_PROPERTY(int captureFadeDuration MEMBER m_captureFadeDuration CONSTANT)

    // Shapes and sizes.
    Q_PROPERTY(int radiusSmall MEMBER m_radiusSmall CONSTANT) // chips, menu rows, swatches
    Q_PROPERTY(int radius MEMBER m_radius CONSTANT) // controls, cards, tabs
    Q_PROPERTY(int radiusLarge MEMBER m_radiusLarge CONSTANT) // popovers, dialogs, grouped lists
    Q_PROPERTY(int controlHeight READ controlHeight NOTIFY changed)
    Q_PROPERTY(int controlHeightSmall READ controlHeightSmall NOTIFY changed)
    Q_PROPERTY(int iconButton READ iconButton NOTIFY changed)
    Q_PROPERTY(int iconSize READ iconSize NOTIFY changed)
    Q_PROPERTY(int barHeight READ barHeight NOTIFY changed)
    Q_PROPERTY(int rowHeight READ rowHeight NOTIFY changed)
    Q_PROPERTY(int rowHeightTall READ rowHeightTall NOTIFY changed)
    // Type scale, from the text size setting.
    Q_PROPERTY(int fontCaption READ fontCaption NOTIFY changed)
    Q_PROPERTY(int fontSmall READ fontSmall NOTIFY changed)
    Q_PROPERTY(int fontBody READ fontBody NOTIFY changed)
    Q_PROPERTY(int fontHeadline READ fontHeadline NOTIFY changed)
    Q_PROPERTY(int fontTitle READ fontTitle NOTIFY changed)

    // Annotation inks are document data, not theme: they never follow the accent.
    Q_PROPERTY(QVariantList annotationInks READ annotationInks CONSTANT)
    Q_PROPERTY(QString defaultInk READ defaultInk CONSTANT)
    // The icon font family (qml/Icons.js maps names to glyphs).
    Q_PROPERTY(QString iconFont MEMBER m_iconFont CONSTANT)

public:
    explicit Theme(ResearchStore *store = nullptr, QObject *parent = nullptr);

    QString theme() const { return m_theme; }
    void setTheme(const QString &id);
    QString accentName() const { return m_accentName; }
    void setAccentName(const QString &id);
    int textSize() const { return m_textSize; }
    void setTextSize(int size);
    bool invertPages() const { return m_invertPages; }
    bool verticalTabs() const { return m_verticalTabs; }
    QString appIcon() const { return m_appIcon; }
    void setAppIcon(const QString &id);
    QVariantList appIcons() const;
    // The image for an icon choice (a resource path).
    static QString appIconPath(const QString &id);
    void setVerticalTabs(bool on);
    void setInvertPages(bool on);
    bool dark() const { return m_dark; }
    bool canInvertPages() const
    {
#ifdef OWELK_HAVE_SHADERS
        return true;
#else
        return false;
#endif
    }
    QVariantList themes() const;
    QVariantList accents() const;

    // The seed colors of a theme ("custom" included), for previews and the custom editor.
    Q_INVOKABLE QVariantMap seeds(const QString &id) const;
    // Saves a custom theme from seeds and switches to it. Invalid colors are rejected.
    Q_INVOKABLE bool setCustomSeeds(const QVariantMap &seeds);
    // a → b by t (0..1), for the rare place that needs an in-between color.
    Q_INVOKABLE QColor mix(const QColor &a, const QColor &b, qreal t) const;

    int controlHeight() const { return m_textSize * 2; }
    int controlHeightSmall() const { return m_textSize + 9; }
    int iconButton() const { return m_textSize + 11; }
    int iconSize() const { return m_textSize + 3; }
    int barHeight() const { return m_textSize * 2 + 8; }
    int rowHeight() const { return m_textSize * 2 + 2; }
    int rowHeightTall() const { return m_textSize * 3 + 5; }
    int fontCaption() const { return m_textSize - 2; }
    int fontSmall() const { return m_textSize - 1; }
    int fontBody() const { return m_textSize; }
    int fontHeadline() const { return m_textSize + 2; }
    int fontTitle() const { return m_textSize + 7; }
    QVariantList annotationInks() const;
    QString defaultInk() const;

signals:
    void changed();

private:
    struct Seeds {
        bool dark = false;
        QColor window, sidebar, content, raised, text, separator, backdrop;
    };
    static Seeds preset(const QString &id);
    Seeds custom() const;
    void apply();
    void save(const QString &key, const QString &value);

    ResearchStore *m_store = nullptr;
    QString m_theme = "neutral", m_accentName = "blue";
    int m_textSize = 13;
    bool m_invertPages = false, m_dark = false, m_verticalTabs = false;
    QString m_appIcon = "paper";
    void showAppIcon(bool finderToo);
    QColor m_window, m_sidebar, m_content, m_raised, m_field, m_control, m_pdfBackdrop, m_paper{Qt::white},
        m_paperInverted{"#121212"};
    QColor m_text, m_textSecondary, m_textTertiary, m_textDisabled, m_icon, m_onAccent;
    QColor m_separator, m_border, m_hover, m_pressed, m_selected, m_selectedText, m_focus;
    QColor m_accent, m_accentHover, m_accentBorder, m_danger;
    QColor m_overlay, m_overlayBorder, m_shadow, m_pageSelection, m_searchMatch;
    QColor m_scrollHandle, m_scrollHandleHover, m_scrollHandlePressed;
    QString m_iconFont;
    int m_captureFadeDuration = 300, m_radiusSmall = 5, m_radius = 7, m_radiusLarge = 10;
};
