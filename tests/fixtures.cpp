#include "PdfFixture.h"
#include <QDir>
#include <QGuiApplication>
#include <cstdio>

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    if (app.arguments().size() != 2) return 1;
    QDir directory(app.arguments()[1]);
    if (!directory.mkpath(".")) return 1;
    writeFixture(directory.filePath("Paper A.pdf"), "Reading with Context");
    writeFixture(directory.filePath("Paper B.pdf"), "Comparing the Evidence", 12);
    printf("%s\n", qPrintable(directory.absolutePath()));
}

