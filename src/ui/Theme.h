#pragma once

#include <QColor>
#include <QDateTime>
#include <QList>
#include <QObject>
#include <QSize>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <optional>

class ResearchStore;

// Colors, shapes and type sizes for every QML surface (import Owelk.Ui; Theme.x).
// A theme is a handful of seed colors; every other token is derived from them, so the
// built-in themes and a custom one follow the same rules. Changing a setting re-evaluates
// the bindings once; nothing here runs per frame.
class Theme : public QObject {
    Q_OBJECT
    // Choices (persisted under appearance.* in the settings table).
    Q_PROPERTY(QString theme READ theme WRITE setTheme NOTIFY changed)
    // Match System: the theme follows the system's light or dark appearance, with a theme chosen for each.
    // Choosing a theme while it is on chooses it for the appearance the system has now.
    Q_PROPERTY(bool matchSystem READ matchSystem WRITE setMatchSystem NOTIFY changed)
    Q_PROPERTY(QString lightTheme READ lightTheme WRITE setLightTheme NOTIFY changed)
    Q_PROPERTY(QString darkTheme READ darkTheme WRITE setDarkTheme NOTIFY changed)
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
    // The custom accent as it was given (before its lightness is fitted); invalid when there is none.
    Q_PROPERTY(QColor customAccent READ customAccent NOTIFY changed)
    // The named accents, then "custom" once a custom accent color is stored.
    Q_PROPERTY(QVariantList accents READ accents NOTIFY changed)

    // The picture theme (hidden in Settings › Appearance): a picture behind the window and the PDF paper,
    // its colors as the Custom theme and the accent. An empty URL when there is none.
    Q_PROPERTY(QUrl picture READ picture NOTIFY changed)
    // A cut-out (transparent around a character, trimmed to it) rather than a full picture.
    Q_PROPERTY(bool pictureCutout READ pictureCutout NOTIFY changed)
    // Its distinct vivid colors, most prominent first, to pick the accent from.
    Q_PROPERTY(QStringList pictureColors READ pictureColors NOTIFY changed)
    // Every picture kept, oldest first: {id, url, cutout, current}.
    Q_PROPERTY(QVariantList pictures READ pictures NOTIFY picturesChanged)
    // Its size in pixels (as kept), for laying it out without stretching.
    Q_PROPERTY(QSize pictureSize READ pictureSize NOTIFY changed)
    // Minutes between changes to another kept picture: 0 keeps this one, -1 changes it at each launch. A change
    // that is due waits until it is allowed (Home, or Owelk in the background), so colors never change mid-page.
    Q_PROPERTY(int pictureInterval READ pictureInterval WRITE setPictureInterval NOTIFY rotationChanged)
    Q_PROPERTY(
        bool pictureRotationAllowed READ pictureRotationAllowed WRITE setPictureRotationAllowed NOTIFY rotationChanged)
    // Put away for now (a shortcut), without forgetting the picture.
    Q_PROPERTY(bool pictureHidden MEMBER m_pictureHidden NOTIFY changed)
    // Shown while the Custom theme is in use (another theme keeps the picture but does not show it).
    Q_PROPERTY(bool pictureShown READ pictureShown NOTIFY changed)
    // The picture theme can be turned off: Custom is the reader's own colors again, the kept pictures stay
    // for when it is turned on (five taps on Theme). Off, picture is empty.
    Q_PROPERTY(bool pictureOn READ pictureOn WRITE setPictureOn NOTIFY changed)
    // How much of the picture shows (percent, 0–100): the same over Home, around PDF pages and through the paper,
    // so the picture looks alike on a page and beside it.
    Q_PROPERTY(int pictureStrength READ pictureStrength WRITE setPictureStrength NOTIFY changed)
    // Where a cut-out stands, or which part of a full picture is kept: "left", "center" or "right".
    Q_PROPERTY(QString pictureAlign READ pictureAlign WRITE setPictureAlign NOTIFY changed)
    // How tall a cut-out stands, in percent of the area's height (40–100); kept for each picture.
    Q_PROPERTY(int pictureScale READ pictureScale WRITE setPictureScale NOTIFY changed)
    // The desktop pet's other faces for the picture in use, each kept like it, by mood (petMoods()): {talk: {frames:
    // [{url, aspect (width over height)}], mode: "random" (one picked each time) or "cycle" (one after another while
    // the mood lasts)}, …}, for the moods it has faces for.
    Q_PROPERTY(QVariantMap pictureMoods READ pictureMoods NOTIFY changed)
    // The picture files this build opens, as a file dialog filter ("*.png *.jpg …").
    Q_PROPERTY(QString pictureFilter READ pictureFilter CONSTANT)

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
    // Text drawn on a page-coloured surface (reference previews): dark ink on paper, light ink on an
    // inverted page, whatever the app theme.
    Q_PROPERTY(QColor paperInk MEMBER m_paperInk CONSTANT)
    Q_PROPERTY(QColor paperInkInverted MEMBER m_paperInkInverted CONSTANT)
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
    // Text boxes start in navy, readable on the page whatever the highlight ink.
    Q_PROPERTY(QString defaultTextInk READ defaultTextInk CONSTANT)
    // The icon font family (qml/Icons.js maps names to glyphs).
    Q_PROPERTY(QString iconFont MEMBER m_iconFont CONSTANT)

public:
    explicit Theme(ResearchStore *store = nullptr, QObject *parent = nullptr);

    QString theme() const { return m_theme; }
    void setTheme(const QString &id);
    bool matchSystem() const { return m_matchSystem; }
    void setMatchSystem(bool on);
    QString lightTheme() const { return m_lightTheme; }
    void setLightTheme(const QString &id);
    QString darkTheme() const { return m_darkTheme; }
    void setDarkTheme(const QString &id);
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
    QUrl picture() const;
    bool pictureCutout() const { return m_pictureCutout; }
    QStringList pictureColors() const { return m_pictureColors; }
    QVariantList pictures() const;
    QColor customAccent() const { return m_customAccent; }
    QSize pictureSize() const { return m_pictureSize; }
    int pictureInterval() const { return m_pictureInterval; }
    void setPictureInterval(int minutes);
    bool pictureRotationAllowed() const { return m_pictureRotationAllowed; }
    void setPictureRotationAllowed(bool allowed);
    bool pictureShown() const { return !m_pictureHidden && showing() && m_theme == "custom"; }
    bool pictureOn() const { return m_pictureOn; }
    void setPictureOn(bool on);
    int pictureStrength() const { return m_pictureStrength; }
    void setPictureStrength(int percent);
    QString pictureAlign() const { return m_pictureAlign; }
    void setPictureAlign(const QString &align);
    int pictureScale() const { return m_pictureScale; }
    void setPictureScale(int percent);
    QVariantMap pictureMoods() const;
    static QString pictureFilter();
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
    // The seeds of Neutral (or Dark) tinted toward a color's hue at the same lightness: the picture
    // theme's surfaces. An invalid color gives the untinted seeds.
    Q_INVOKABLE QVariantMap tintedSeeds(const QVariant &color, bool dark) const;
    // Saves a custom accent and switches to it. The color keeps its hue and saturation; only its
    // lightness moves, as far as white labels on it need. Invalid colors are rejected.
    Q_INVOKABLE bool setCustomAccent(const QVariant &color);
    // Forgets the custom accent; Blue takes over if it was in use.
    Q_INVOKABLE void clearCustomAccent();
    // Takes a picture for the picture theme, kept beside the others: a copy no larger than a window shows
    // it is kept with the data, and its main color becomes the accent and the tint of the Custom theme
    // (light or dark as the theme in use). False if the file is not a picture this build reads.
    Q_INVOKABLE bool usePicture(const QUrl &file);
    // The system's appearance is now dark or light (called when it changes, and by tests).
    Q_INVOKABLE void followAppearance(bool dark);
    // Uses a kept picture again (id from pictures; empty: the one in use), with the accent last chosen
    // for it and the Custom theme's brightness.
    Q_INVOKABLE bool choosePicture(const QString &id);
    // Drops a kept picture (empty id: the one in use). Another one takes the place of the one in use;
    // after the last, the theme, accent and Custom colors from before the first picture come back.
    Q_INVOKABLE void removePicture(const QString &id = QString());
    // The moods the pet has faces for: talk (a bubble), think (an answer being written), happy (good news), worried
    // (something failed), rest (time for a break), sleepy (nothing for a while), held (dragged), poke (clicked).
    static QStringList petMoods();
    // Adds a face for a mood with the picture in use, kept like a picture (its colors are not taken); up to six
    // each. False if it cannot be read or there is no room.
    Q_INVOKABLE bool addPictureMood(const QString &mood, const QUrl &file);
    // Drops a mood's face (index in its frames).
    Q_INVOKABLE void removePictureMood(const QString &mood, int index);
    // "random" or "cycle", for a mood with several faces.
    Q_INVOKABLE void setPictureMoodMode(const QString &mood, const QString &mode);
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
    QString defaultTextInk() const;

signals:
    void changed();
    // The kept pictures or the one in use (not on every theme change, so lists of them stay put).
    void picturesChanged();
    // How often the picture changes, or whether it may change now.
    void rotationChanged();

private:
    struct Seeds {
        bool dark = false;
        QColor window, sidebar, content, raised, text, separator, backdrop;
    };
    struct AccentPair {
        QColor light, dark;
    };
    static Seeds preset(const QString &id);
    Seeds custom() const;
    AccentPair accentPair() const;
    static AccentPair derivedAccent(const QColor &base);
    void apply();
    void save(const QString &key, const QString &value);
    // Uses the theme chosen for an appearance; a picture's theme is tinted again for it.
    void useThemeFor(bool dark);

    bool m_matchSystem = false;
    QString m_lightTheme = "neutral", m_darkTheme = "dark";
    // The system's appearance, once known (some Linux desktops never tell).
    std::optional<bool> m_systemDark;

    ResearchStore *m_store = nullptr;
    QString m_theme = "neutral", m_accentName = "blue";
    int m_textSize = 13;
    bool m_invertPages = false, m_dark = false, m_verticalTabs = false;
    QString m_appIcon = "paper";
    void showAppIcon(bool finderToo);
    QColor m_window, m_sidebar, m_content, m_raised, m_field, m_control, m_pdfBackdrop, m_paper{Qt::white},
        m_paperInverted{"#121212"}, m_paperInk{"#1f1f1f"}, m_paperInkInverted{"#e6e6e6"};
    QColor m_text, m_textSecondary, m_textTertiary, m_textDisabled, m_icon, m_onAccent;
    QColor m_separator, m_border, m_hover, m_pressed, m_selected, m_selectedText, m_focus;
    struct Picture {
        QString file; // in pictureFolder()
        bool cutout = false;
        QStringList colors; // most prominent first
        QString accent; // the accent last chosen for it
        int scale = 100; // how tall it stands (a cut-out), percent of the area's height
        // The pet's faces by mood (files beside it), and the moods whose faces take turns ("cycle").
        QHash<QString, QStringList> moods;
        QHash<QString, QString> moodModes;
    };
    Picture *currentPicture();
    void savePictureMoods(Picture &picture);
    // Faces' width over height, read once per file.
    mutable QHash<QString, qreal> m_faceAspects;
    QString pictureFolder() const;
    // Saves a picture into pictureFolder() under a new name (with "-mood" for a pet face); empty on failure.
    QString keepPictureFile(const QImage &image, bool cutout, const QString &mood) const;
    // The one in use (nullptr: none) into the fields QML reads.
    void mirror(const Picture *picture);
    // listChanged: the kept pictures or the one in use changed, not only something about one.
    void savePictures(bool listChanged = true);
    // Uses a kept picture: tints the Custom theme for it and, when shown, switches to it with its accent.
    void showPicture(const Picture &picture, bool dark, bool show);
    bool writeCustomSeeds(const QVariantMap &seeds);
    // A picture is in use and the picture theme is on.
    bool showing() const { return m_pictureOn && !m_picture.isEmpty(); }
    // The picture theme is the theme in use. It comes before Match System's theme for each appearance (which it
    // leaves as they were): it turns light or dark with the system itself.
    bool pictureInUse() const { return showing() && m_theme == "custom"; }
    void tintPictureFor(bool dark);
    // How bright a theme starting now should be: the system's with Match System, else the theme in use's.
    bool wantedDark() const { return m_matchSystem && m_systemDark ? *m_systemDark : m_dark; }
    // The theme, accent and Custom colors to come back to when the picture theme goes; and coming back.
    void keepBeforePicture();
    void restoreBeforePicture();
    // One single-shot timer waits for the next change; a change that is due is made once it is allowed.
    void schedulePicture();
    // Another kept picture, chosen at random.
    void rotatePicture();
    int m_pictureInterval = 0;
    QDateTime m_pictureNext; // kept, so quitting does not put the next change off
    QTimer m_pictureTimer;
    bool m_pictureRotationAllowed = false, m_rotating = false;
    bool m_pictureOn = true, m_pictureHidden = false;
    QList<Picture> m_pictures;
    QString m_picture; // the one in use
    bool m_pictureCutout = false;
    QSize m_pictureSize;
    int m_pictureStrength = 25;
    QString m_pictureAlign = "right";
    int m_pictureScale = 100;
    QStringList m_pictureColors;
    QColor m_customAccent; // the color as given; accentPair() derives the shown ones
    QColor m_accent, m_accentHover, m_accentBorder, m_danger;
    QColor m_overlay, m_overlayBorder, m_shadow, m_pageSelection, m_searchMatch;
    QColor m_scrollHandle, m_scrollHandleHover, m_scrollHandlePressed;
    QString m_iconFont;
    int m_captureFadeDuration = 300, m_radiusSmall = 5, m_radius = 7, m_radiusLarge = 10;
};
