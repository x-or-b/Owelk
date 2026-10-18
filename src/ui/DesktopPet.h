#pragma once

#include <QObject>
#include <QPoint>
#include <QRegion>
#include <QSize>
#include <QUrl>

class QWindow;
class ResearchStore;

// The desktop pet (QML: DesktopPet): the picture theme's picture in a small window that floats above
// other apps while Owelk runs. Its switch, size and place are kept with the settings.
class DesktopPet : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY changed)
    // "small", "medium" or "large"; height is the pet's height in points for it.
    Q_PROPERTY(QString size READ size WRITE setSize NOTIFY changed)
    Q_PROPERTY(int height READ height NOTIFY changed)
    // After this many minutes of reading in Owelk the pet suggests a break: 0 (never), 25, 50 or 90.
    Q_PROPERTY(int breakMinutes READ breakMinutes WRITE setBreakMinutes NOTIFY changed)
    // Minutes of reading a day the pet cheers once they are reached: 0 (none), 15, 30, 60 or 90.
    Q_PROPERTY(int dailyGoal READ dailyGoal WRITE setDailyGoal NOTIFY changed)
    // Not on Wayland, where a window can neither stay above others nor say where it goes.
    Q_PROPERTY(bool supported READ supported CONSTANT)

public:
    explicit DesktopPet(ResearchStore *store = nullptr, QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QString size() const { return m_size; }
    void setSize(const QString &size);
    int height() const;
    int breakMinutes() const { return m_breakMinutes; }
    int dailyGoal() const { return m_dailyGoal; }
    void setDailyGoal(int minutes);
    void setBreakMinutes(int minutes);
    static bool supported();

    // Where a pet window of this size goes: where it was left while that is still on a screen, else the
    // bottom right of the main screen.
    Q_INVOKABLE QPoint place(int width, int height) const;
    Q_INVOKABLE void remember(int x, int y);
    // Before a pet window (or its speech bubble) is first shown: a transparent surface, and on macOS
    // kept on screen while another app is in front.
    Q_INVOKABLE void prepare(QWindow *window);
    // Once shown, on macOS: on every desktop (Space) and beside full-screen apps, left out of window
    // cycling. Elsewhere staying on top is all there is.
    Q_INVOKABLE void floatEverywhere(QWindow *window);
    // Clicks on the transparent parts of a pet window go to whatever is behind it. The picture is drawn
    // fitted and centred in area, top points down; it hops up to rise points.
    Q_INVOKABLE void letClicksThrough(QWindow *window, const QUrl &picture, const QSize &area, int top, int rise);
    // The same for a pet with several faces (pictures): the part that takes clicks is what any of them draws, worked
    // out once rather than at each change of face.
    Q_INVOKABLE void letClicksThroughAll(
        QWindow *window, const QVariantList &pictures, const QSize &area, int top, int rise);
    // The part that takes clicks, in window points: where the picture is drawn, a little around it and up
    // as far as it hops. Empty for a picture with no transparency (all of the window takes them).
    static QRegion pictureRegion(const QString &file, const QSize &area, int top, int rise);

signals:
    void changed();

private:
    void save(const QString &key, const QString &value);
    ResearchStore *m_store = nullptr;
    bool m_enabled = false;
    QString m_size = "medium";
    int m_breakMinutes = 50;
    int m_dailyGoal = 0;
};
