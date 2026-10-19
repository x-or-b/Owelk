#pragma once

#include <QObject>

// Owelk opening by itself when the user logs in: a login item on macOS 13 and later (System Settings › General ›
// Login Items), the Run key on Windows (Task Manager's Startup apps), an XDG autostart entry on Linux. The system
// keeps it and lets the user turn it off there too, so it is asked each time, never saved with the settings.
class LoginItem final : public QObject {
    Q_OBJECT
    // False where Owelk cannot be one (macOS 12, a binary outside its bundle, offscreen runs): the option is hidden.
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(bool enabled READ enabled NOTIFY changed)
    // macOS: asked for, but the user has to allow it in System Settings.
    Q_PROPERTY(bool needsApproval READ needsApproval NOTIFY changed)
public:
    using QObject::QObject;
    static bool supported();
    bool enabled() const;
    bool needsApproval() const;
    // Turns it on or off; changed() then tells how the system has it (unchanged when it refused).
    Q_INVOKABLE void setEnabled(bool on);
    // Asks the system again (after the user may have changed it there).
    Q_INVOKABLE void refresh() { emit changed(); }

signals:
    void changed();
};
