#pragma once

#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QString>
#include <QWindow>

// Apple Pencil's own gestures on iPadOS: a double tap (Pencil 2, Pro) and a squeeze (Pencil Pro), each with the
// action the reader chose for it in Settings › Apple Pencil. Nothing reports them elsewhere.
class Pencil final : public QObject {
    Q_OBJECT
    // What the reader set the gesture to do: "previous" (switch to the last tool), "eraser", "colors" (show the
    // colour palette), "ink" (ink attributes), "palette" (a tool palette at the Pencil), "shortcut" (the system's,
    // not the app's) or "ignore".
    Q_PROPERTY(QString tapAction READ tapAction NOTIFY preferencesChanged)
    Q_PROPERTY(QString squeezeAction READ squeezeAction NOTIFY preferencesChanged)
public:
    explicit Pencil(QObject *parent = nullptr);
    ~Pencil() override;
    // Listens on this window's view.
    void attach(QWindow *window);
    QString tapAction() const;
    QString squeezeAction() const;

signals:
    // position: where the Pencil hovers, in the window (hovering false: it is too far from the screen to say).
    void tapped(QPointF position, bool hovering);
    void squeezed(QPointF position, bool hovering);
    void preferencesChanged();

private:
    QPointer<QWindow> m_window;
    void *m_native = nullptr;
};
