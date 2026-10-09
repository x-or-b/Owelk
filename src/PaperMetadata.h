#pragma once

#include <QString>
#include <QStringList>
#include <QVariantMap>

// Bibliographic details read locally from a PDF: its document info first, then the first page.
// Nothing is fetched from the network. Empty fields mean "unknown"; callers fall back to the file name.
struct PaperMetadata {
    QString title, authors, year, doi, arxiv;
    bool isEmpty() const
    {
        return title.isEmpty() && authors.isEmpty() && year.isEmpty() && doi.isEmpty() && arxiv.isEmpty();
    }
    QVariantMap toMap() const
    {
        return {{"title", title}, {"authors", authors}, {"year", year}, {"doi", doi}, {"arxiv", arxiv}};
    }
};

// Must run off the UI thread; it loads the PDF.
PaperMetadata extractPaperMetadata(const QString &path);

namespace PaperMetadataText {
// Exposed for tests: pure text heuristics.
bool usableTitle(const QString &title, const QString &fileName);
QString findDoi(const QString &text);
QString findArxiv(const QString &text);
// Person names from the lines between a title and its abstract; affiliations and footnote marks are dropped.
QStringList authorNames(const QStringList &lines);
// A readable file name (without .pdf) for a paper: its title, safe on every system.
// Empty when the title is unknown.
QString fileStem(const PaperMetadata &paper);
}
