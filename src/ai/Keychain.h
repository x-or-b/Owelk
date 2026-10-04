#pragma once

#include <QString>

// API keys live in the system keyring, never in SQLite or logs: the macOS Keychain, the Windows
// Credential Manager, or the Linux Secret Service (libsecret). Without a keyring they fall back to a
// file readable only by the user in the data folder.
namespace Keychain {
// Where keys are kept, for Settings: "macOS Keychain", "Windows Credential Manager", …
QString storageName();
// The service name; tests set OWELK_KEYCHAIN_SERVICE to keep their items apart.
QString service();
bool write(const QString &account, const QString &secret, const QString &fallbackDirectory);
QString read(const QString &account, const QString &fallbackDirectory);
bool remove(const QString &account, const QString &fallbackDirectory);
}
