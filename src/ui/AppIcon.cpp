#include "AppIcon.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>

QString AppIcon::bundlePath()
{
#ifdef Q_OS_MACOS
    // …/Owelk.app/Contents/MacOS/owelk
    QDir dir(QCoreApplication::applicationDirPath());
    if (dir.dirName() != "MacOS" || !dir.cdUp() || dir.dirName() != "Contents" || !dir.cdUp()) return {};
    return dir.absolutePath().endsWith(".app") ? dir.absolutePath() : QString();
#else
    return {};
#endif
}

bool AppIcon::hasCustomIcon(const QString &bundle)
{
    // Finder keeps a custom folder icon in a file named "Icon\r" inside it.
    return QFileInfo::exists(bundle + "/Icon\r");
}

#ifndef Q_OS_MACOS
void AppIcon::setBundleIcon(const QString &, const QString &) { }
#endif
