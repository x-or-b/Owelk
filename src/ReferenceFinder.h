#pragma once

#include <QDateTime>
#include <QHash>
#include <QMutex>
#include <QObject>
#include <QPointF>
#include <QStringList>
#include <QThreadPool>
#include <QUrl>
#include <QVariantMap>
#include <atomic>
#include <memory>

class QPdfDocument;

// Where a reference in the text points, for PDFs without working links (most publisher downloads):
// "[12]" to its entry under References, "Fig. 3" / "Table II" to the caption, "Eq. (4)" to the numbered
// equation, "Vaswani et al. (2017)" to the matching entry. Runs only for a spot the reader rests on,
// one request at a time on a low-priority thread, and waits while the reader zooms or scrolls.
class ReferenceFinder final : public QObject {
    Q_OBJECT
public:
    ReferenceFinder(std::shared_ptr<std::atomic_bool> readerBusy, QObject *parent = nullptr);
    ~ReferenceFinder() override;
    // point is in PDF points on that page. Answered by resolved(request, target) with
    // {kind, label, text (the target's text), page, x, y, width, height (PDF points), top (0..1 of the
    // page)}, or {} for no reference.
    Q_INVOKABLE int resolve(const QUrl &source, int page, const QPointF &point);
    // The reference-list entry at a point (a link's destination): {kind: "citation", label, text, page, x,
    // y, width, height, top}, or {} when no entry ("[n] …" or "n. …") starts around there.
    Q_INVOKABLE int entryAt(const QUrl &source, int page, const QPointF &point);
    static QVariantMap entryAround(const QString &text, qsizetype index);

    // The text-only steps, also used by tests. referenceAt: {kind, key, label, start} for the reference
    // covering index in text, or {}. locate: {page, start, length} of its target among the pages, or {}.
    static QVariantMap referenceAt(const QString &text, qsizetype index);
    static QVariantMap locate(
        const QStringList &pages, const QVariantMap &reference, int fromPage, qsizetype fromIndex);
    // A figure or table around its caption's first line (PDF points): the whole caption, and the figure
    // above it (a table: below it) up to the nearest paragraph of body text. {x, y, width, height,
    // caption (its text)}, or {} when the page has no text to go by. Figure and table previews show
    // this area, and Ask AI sends it.
    static QVariantMap floatRegion(QPdfDocument &pdf, int page, const QRectF &captionLine, bool table);

signals:
    void resolved(int request, const QVariantMap &target);

private:
    QVariantMap find(const QString &path, int page, const QPointF &point, int request);
    QVariantMap findEntry(const QString &path, int page, const QPointF &point, int request);
    QStringList pageTexts(QPdfDocument &pdf, const QString &path, int request);
    static QVariantMap describe(QPdfDocument &pdf, const QStringList &texts, const QVariantMap &target);
    std::shared_ptr<std::atomic_bool> m_readerBusy;
    std::atomic_int m_latest{0};
    int m_next = 0;
    QThreadPool m_pool;
    QMutex m_mutex;
    // Page texts of the last two documents, dropped when the file changes.
    struct Texts {
        QDateTime modified;
        QStringList pages;
    };
    QHash<QString, Texts> m_texts;
    QStringList m_order;
};
