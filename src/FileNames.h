#pragma once

#include <QRegularExpression>
#include <QString>

// A file name every system accepts (Windows is the strictest), so a paper named on a Mac also reaches a Windows
// computer: no folder parts, none of the characters Windows refuses (\ / : * ? " < > | and control characters),
// not a name Windows keeps for devices (CON, NUL, COM1, … with any extension), and no dot or space at the end of
// the name or before its extension. Empty when nothing usable is left.
inline QString portableFileName(QString name)
{
    static const QRegularExpression refused(R"([\\/:*?"<>|\x00-\x1f])");
    static const QRegularExpression extension(R"(\.[A-Za-z0-9]{1,8}$)");
    static const QRegularExpression reserved(
        "^(con|prn|aux|nul|com[0-9]|lpt[0-9])$", QRegularExpression::CaseInsensitiveOption);
    name = name.remove(refused).simplified();
    const auto match = extension.match(name);
    QString stem = match.hasMatch() ? name.left(match.capturedStart()) : name;
    const QString suffix = match.hasMatch() ? match.captured() : QString();
    while (stem.endsWith('.') || stem.endsWith(' ')) stem.chop(1);
    if (stem.isEmpty()) return {};
    if (reserved.match(stem.section('.', 0, 0)).hasMatch())
        stem.insert(stem.indexOf('.') < 0 ? stem.size() : stem.indexOf('.'), '_');
    return stem + suffix;
}
