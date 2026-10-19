#include "LoginItem.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>

#ifdef Q_OS_MACOS
// LoginItemMac.mm
int loginItemState();
void loginItemSet(bool on);
#elif defined(Q_OS_WIN)
#include <qt_windows.h>
#endif

namespace {
#ifdef Q_OS_WIN
// The programs Windows starts at login, and Task Manager's Startup apps turning them off without removing them.
const char runKey[] = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const wchar_t approvedKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";
#elif !defined(Q_OS_MACOS)
QString autostartFile()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/autostart/owelk.desktop";
}

// A program path as an Exec= argument (Desktop Entry spec): quoted with its \ " ` $ escaped, % doubled, and then
// every backslash escaped again for the string the line is.
QString execArgument(QString path)
{
    for (const char c : {'\\', '"', '`', '$'}) path.replace(QChar(c), QString("\\") + QChar(c));
    path.replace("%", "%%").replace("\\", "\\\\");
    return "\"" + path + "\"";
}
#endif
}

bool LoginItem::supported()
{
    const auto platform = QGuiApplication::platformName();
#ifdef Q_OS_MACOS
    return platform == "cocoa" && loginItemState() >= 0;
#elif defined(Q_OS_WIN)
    return platform == "windows";
#else
    return platform == "xcb" || platform.startsWith("wayland");
#endif
}

bool LoginItem::enabled() const
{
#ifdef Q_OS_MACOS
    return loginItemState() == 1;
#elif defined(Q_OS_WIN)
    if (!QSettings(runKey, QSettings::NativeFormat).contains("Owelk")) return false;
    // Turned off in Task Manager: its entry there starts with an odd byte.
    BYTE state[64];
    DWORD size = sizeof state;
    return RegGetValueW(HKEY_CURRENT_USER, approvedKey, L"Owelk", RRF_RT_REG_BINARY, nullptr, state, &size)
        != ERROR_SUCCESS
        || size == 0 || !(state[0] & 1);
#else
    QFile file(autostartFile());
    if (!file.open(QIODevice::ReadOnly)) return false;
    // The desktop's own settings turn it off by keeping the file with one of these.
    const auto entry = file.readAll();
    return !entry.contains("\nHidden=true") && !entry.contains("\nX-GNOME-Autostart-enabled=false");
#endif
}

bool LoginItem::needsApproval() const
{
#ifdef Q_OS_MACOS
    return loginItemState() == 2;
#else
    return false;
#endif
}

void LoginItem::setEnabled(bool on)
{
#ifdef Q_OS_MACOS
    loginItemSet(on);
#elif defined(Q_OS_WIN)
    QSettings run(runKey, QSettings::NativeFormat);
    if (on) {
        const QString program = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
        run.setValue("Owelk", QString("\"" + program + "\""));
        // On again after Task Manager turned it off.
        RegDeleteKeyValueW(HKEY_CURRENT_USER, approvedKey, L"Owelk");
    } else {
        run.remove("Owelk");
    }
#else
    const auto path = autostartFile();
    if (on) {
        // An AppImage by its own file, not the folder it is mounted at while it runs.
        const auto program = qEnvironmentVariable("APPIMAGE", QCoreApplication::applicationFilePath());
        QDir().mkpath(QFileInfo(path).absolutePath());
        QSaveFile file(path);
        if (file.open(QIODevice::WriteOnly)) {
            file.write("[Desktop Entry]\nType=Application\nName=Owelk\nExec=" + execArgument(program).toUtf8()
                + "\nIcon=owelk\nTerminal=false\nX-GNOME-Autostart-enabled=true\n");
            file.commit();
        }
    } else {
        QFile::remove(path);
    }
#endif
    emit changed();
}
