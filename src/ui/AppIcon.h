#pragma once

#include <QString>

// The app's icon in Finder (macOS): a custom icon on the bundle, or none for the bundle's own.
namespace AppIcon {
// The .app this process runs from; empty outside a macOS bundle (tests, Linux, Windows).
QString bundlePath();
bool hasCustomIcon(const QString &bundle);
// image: a PNG (resource or file path); empty restores the bundle's own icon.
void setBundleIcon(const QString &bundle, const QString &image);
}
