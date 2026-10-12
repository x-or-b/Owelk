#pragma once

#include <QCoreApplication>
#include <QString>

// Text shown to the reader, in the chosen interface language (translations/, tools/hangul.py).
inline QString ui(const char *text)
{
    return QCoreApplication::translate("Owelk", text);
}
