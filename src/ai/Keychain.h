#pragma once

#include <QString>

// API keys live in the macOS Keychain (generic passwords), never in SQLite or logs.
// Elsewhere they fall back to a file readable only by the user in the data folder.
namespace Keychain {
// The service name; tests set OWELK_KEYCHAIN_SERVICE to keep their items apart.
QString service();
bool write(const QString &account, const QString &secret, const QString &fallbackDirectory);
QString read(const QString &account, const QString &fallbackDirectory);
bool remove(const QString &account, const QString &fallbackDirectory);
}
