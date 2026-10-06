#include "ReferenceFinder.h"
#include "PdfAccess.h"

#include <QFileInfo>
#include <QPdfDocument>
#include <QPdfSelection>
#include <QRegularExpression>
#include <QThread>

#include <algorithm>

namespace {
// TABLE IV and Table 4 are the same table.
int tableNumber(const QString &text)
{
    bool ok = false;
    const int arabic = text.toInt(&ok);
    if (ok) return arabic;
    const QHash<QChar, int> values{{'I', 1}, {'V', 5}, {'X', 10}, {'L', 50}, {'C', 100}};
    int total = 0;
    for (qsizetype i = 0; i < text.size(); ++i) {
        const int value = values.value(text[i].toUpper(), -1);
        if (value < 0) return -1;
        const int next = i + 1 < text.size() ? values.value(text[i + 1].toUpper(), 0) : 0;
        total += value < next ? -value : value;
    }
    return total;
}

// Up to the end of the line (and `lines` more), at most `limit` characters.
qsizetype lineLength(const QString &text, qsizetype start, int lines = 0, qsizetype limit = 240)
{
    qsizetype end = start;
    for (int line = 0; line <= lines; ++line) {
        end = text.indexOf(QRegularExpression("[\\r\\n]"), end + 1);
        if (end < 0) {
            end = text.size();
            break;
        }
        if (line < lines)
            while (end + 1 < text.size() && (text[end + 1] == '\r' || text[end + 1] == '\n')) ++end;
    }
    return std::clamp<qsizetype>(end - start, 1, limit);
}

bool lineStart(const QString &text, qsizetype index)
{
    while (index > 0 && (text[index - 1] == ' ' || text[index - 1] == '\t')) --index;
    return index == 0 || text[index - 1] == '\n' || text[index - 1] == '\r';
}
} // namespace

ReferenceFinder::ReferenceFinder(std::shared_ptr<std::atomic_bool> readerBusy, QObject *parent)
    : QObject(parent), m_readerBusy(std::move(readerBusy))
{
    m_pool.setMaxThreadCount(1);
    m_pool.setThreadPriority(QThread::LowPriority);
}

ReferenceFinder::~ReferenceFinder()
{
    m_latest = INT_MAX;
    m_pool.waitForDone();
}

int ReferenceFinder::resolve(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    m_latest = request;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        // Only the newest spot matters; older ones the pointer has already left.
        const auto target = request < m_latest ? QVariantMap() : find(path, page, point, request);
        QMetaObject::invokeMethod(
            this, [this, request, target] { emit resolved(request, target); }, Qt::QueuedConnection);
    });
    return request;
}

int ReferenceFinder::entryAt(const QUrl &source, int page, const QPointF &point)
{
    const int request = ++m_next;
    m_latest = request;
    const auto path = source.toLocalFile();
    m_pool.start([this, request, path, page, point] {
        const auto target = request < m_latest ? QVariantMap() : findEntry(path, page, point, request);
        QMetaObject::invokeMethod(
            this, [this, request, target] { emit resolved(request, target); }, Qt::QueuedConnection);
    });
    return request;
}

// An entry starts a line with "[n]" or "n."; it runs to the next one (or 400 characters).
QVariantMap ReferenceFinder::entryAround(const QString &text, qsizetype index)
{
    static const QRegularExpression entryStart(R"((?:^|[\r\n])[ \t]*(\[(\d{1,3})\]|(\d{1,3})\.[ \t]))");
    qsizetype start = -1;
    QString number;
    for (auto it = entryStart.globalMatch(text); it.hasNext();) {
        const auto m = it.next();
        if (m.capturedStart(1) > index + 2) break;
        start = m.capturedStart(1);
        number = m.captured(2).isEmpty() ? m.captured(3) : m.captured(2);
    }
    // Too far back to be the entry the point is on.
    if (start < 0 || index - start > 400) return {};
    const auto next = entryStart.match(text, start + 2);
    const auto end = next.hasMatch() ? next.capturedStart(1) : text.size();
    return {{"start", start}, {"length", std::clamp<qsizetype>(end - start, 1, 400)}, {"label", "[" + number + "]"}};
}

QVariantMap ReferenceFinder::findEntry(const QString &path, int page, const QPointF &point, int request)
{
    QPdfDocument pdf;
    if (path.isEmpty() || PdfAccess::load(pdf, path) != QPdfDocument::Error::None) return {};
    if (page < 0 || page >= pdf.pageCount()) return {};
    // Destinations point at the line's start or the margin: probe along the line for its first character.
    const auto width = pdf.pagePointSize(page).width();
    const qreal y = point.y() + 4;
    auto hit = pdf.getSelection(page, QPointF(point.x() + 2, y), QPointF(point.x() + 5, y));
    for (qreal x = 2; hit.text().isEmpty() && x < width; x += 10)
        hit = pdf.getSelection(page, QPointF(x, y), QPointF(x + 3, y));
    if (hit.text().isEmpty()) return {};
    const auto texts = pageTexts(pdf, path, request);
    if (page >= texts.size()) return {};
    const auto entry = entryAround(texts[page], hit.startIndex());
    if (entry.isEmpty()) return {};
    auto found = describe(pdf, texts, {{"page", page}, {"start", entry["start"]}, {"length", entry["length"]}});
    if (found.isEmpty()) return {};
    found.insert("kind", "citation");
    found.insert("label", entry["label"]);
    return found;
}

QVariantMap ReferenceFinder::find(const QString &path, int page, const QPointF &point, int request)
{
    QPdfDocument pdf;
    if (path.isEmpty() || PdfAccess::load(pdf, path) != QPdfDocument::Error::None) return {};
    if (page < 0 || page >= pdf.pageCount()) return {};
    for (int waited = 0; m_readerBusy && m_readerBusy->load() && waited < 100; ++waited) QThread::msleep(20);
    // The character under the pointer.
    auto hit = pdf.getSelection(page, point - QPointF(2, 0), point + QPointF(2, 0));
    if (hit.text().isEmpty()) hit = pdf.getSelection(page, point - QPointF(5, 0), point + QPointF(5, 0));
    if (hit.text().isEmpty()) return {};
    const auto texts = pageTexts(pdf, path, request);
    if (page >= texts.size()) return {};
    const auto reference = referenceAt(texts[page], hit.startIndex() + hit.text().size() / 2);
    if (reference.isEmpty()) return {};
    auto found = describe(pdf, texts, locate(texts, reference, page, reference["start"].toLongLong()));
    if (found.isEmpty()) return {};
    found.insert("kind", reference["kind"]);
    found.insert("label", reference["label"]);
    // Several papers cited together ([3, 5], [12–14]): each one's entry, in order.
    const auto numbers = reference["numbers"].toStringList();
    if (numbers.size() > 1) {
        QVariantList entries;
        for (const auto &number : numbers) {
            auto one = reference;
            one.insert("key", number);
            auto entry = describe(pdf, texts, locate(texts, one, page, reference["start"].toLongLong()));
            if (entry.isEmpty()) continue;
            entry.insert("label", "[" + number + "]");
            entry.insert("current", number == reference["key"].toString());
            entries << entry;
        }
        if (entries.size() > 1) found.insert("entries", entries);
    }
    return found;
}

// Where a located target is on its page, and its text (line breaks and hyphenation undone).
QVariantMap ReferenceFinder::describe(QPdfDocument &pdf, const QStringList &texts, const QVariantMap &target)
{
    if (target.isEmpty()) return {};
    const int page = target["page"].toInt();
    const auto box
        = pdf.getSelectionAtIndex(page, target["start"].toInt(), target["length"].toInt()).boundingRectangle();
    const auto size = pdf.pagePointSize(page);
    if (box.isEmpty() || size.height() <= 0) return {};
    auto text = texts[page].mid(target["start"].toInt(), target["length"].toInt());
    text.replace(QRegularExpression("-\\s*[\\r\\n]+\\s*"), "").replace(QRegularExpression("\\s+"), " ");
    return {{"text", text.trimmed()}, {"page", page}, {"x", box.x()}, {"y", box.y()}, {"width", box.width()},
        {"height", box.height()}, {"top", box.y() / size.height()}};
}

QStringList ReferenceFinder::pageTexts(QPdfDocument &pdf, const QString &path, int)
{
    const auto modified = QFileInfo(path).lastModified();
    {
        QMutexLocker lock(&m_mutex);
        const auto cached = m_texts.constFind(path);
        if (cached != m_texts.constEnd() && cached->modified == modified) return cached->pages;
    }
    QStringList pages;
    for (int page = 0; page < pdf.pageCount(); ++page) {
        // Reading comes first: the viewer draws with the same PDF library.
        for (int waited = 0; m_readerBusy && m_readerBusy->load() && waited < 100; ++waited) QThread::msleep(20);
        pages << pdf.getAllText(page).text();
    }
    QMutexLocker lock(&m_mutex);
    m_texts.insert(path, {modified, pages});
    m_order.removeAll(path);
    m_order << path;
    while (m_order.size() > 2) m_texts.remove(m_order.takeFirst());
    return pages;
}

QVariantMap ReferenceFinder::referenceAt(const QString &text, qsizetype index)
{
    if (index < 0 || index >= text.size()) return {};
    const qsizetype from = qMax<qsizetype>(0, index - 80);
    const auto window = text.mid(from, 160);
    const auto at = index - from;
    const auto covers
        = [at](const QRegularExpressionMatch &m) { return m.capturedStart() <= at && at < m.capturedEnd(); };
    const auto result = [from](const QString &kind, const QString &key, const QString &label, qsizetype start) {
        return QVariantMap{{"kind", kind}, {"key", key}, {"label", label}, {"start", from + start}};
    };
    // [12], [3, 5], [2–4], and IEEE's [3]–[5]: every number cited (ranges spelled out, at most 8);
    // the key is the number under the pointer, else the first.
    static const QRegularExpression bracketRange(R"(\[(\d{1,3})\]\s*[–—‒\-]\s*\[(\d{1,3})\])");
    static const QRegularExpression cite(R"(\[(\s*\d{1,3}(?:\s*[,;–—‒\-]\s*\d{1,3})*\s*)\])");
    static const QRegularExpression item(R"((\d{1,3})(?:\s*[–—‒\-]\s*(\d{1,3}))?)");
    const auto citation = [&](const QRegularExpressionMatch &m, const QString &numbersText, qsizetype numbersStart) {
        QString key;
        QStringList numbers;
        for (auto n = item.globalMatch(numbersText); n.hasNext();) {
            const auto x = n.next();
            const int first = x.captured(1).toInt(), last = x.captured(2).isEmpty() ? first : x.captured(2).toInt();
            for (int value = first; value <= last && value - first < 20 && numbers.size() < 8; ++value)
                numbers << QString::number(value);
            // The number under the pointer (a range's ends count as themselves).
            for (const int group : {1, 2}) {
                const auto start = numbersStart + x.capturedStart(group);
                if (x.capturedStart(group) >= 0 && start <= at && at < start + x.capturedLength(group))
                    key = x.captured(group);
            }
        }
        if (numbers.isEmpty()) return QVariantMap();
        if (key.isEmpty()) key = numbers.first();
        auto found = result("citation", key, "[" + key + "]", m.capturedStart());
        found.insert("numbers", numbers);
        return found;
    };
    for (auto it = bracketRange.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (!covers(m)) continue;
        auto found = citation(m, m.captured(1) + "-" + m.captured(2), -window.size());
        if (found.isEmpty()) return {};
        // The key is whichever bracket the pointer is on.
        const auto key = at < m.capturedStart(2) - 1 ? m.captured(1) : m.captured(2);
        found.insert("key", key);
        found.insert("label", "[" + key + "]");
        return found;
    }
    for (auto it = cite.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m)) return citation(m, m.captured(1), m.capturedStart(1));
    }
    // A caption is the target itself, not a reference to follow.
    const auto caption = [&window](const QRegularExpressionMatch &m) {
        return lineStart(window, m.capturedStart())
            && QRegularExpression(R"(^\s*[:.|])").match(window.mid(m.capturedEnd())).hasMatch();
    };
    static const QRegularExpression figure(R"(\b(?:Figs?\.|Figures?|FIGS?\.?|FIGURES?|Fig)\s*(\d+))");
    for (auto it = figure.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m) && !caption(m))
            return result("figure", m.captured(1), "Figure " + m.captured(1), m.capturedStart());
    }
    static const QRegularExpression table(R"(\b(?:Tables?|TABLES?|Tab\.)\s*([IVXLC]+|\d+)\b)");
    for (auto it = table.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m) && !caption(m))
            return result("table", m.captured(1), "Table " + m.captured(1), m.capturedStart());
    }
    static const QRegularExpression equation(R"(\b(?:Eqs?\.|Equations?|eq\.)\s*\(?(\d+)\)?)");
    for (auto it = equation.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        if (covers(m)) return result("equation", m.captured(1), "Eq. (" + m.captured(1) + ")", m.capturedStart());
    }
    // Vaswani et al. (2017), (Graves and Schmidhuber, 2005), (Hochreiter, 1997).
    static const QRegularExpression authorYear(
        R"(([A-Z][\w'’\-]+)(\s+et\s+al\.?|\s+(?:and|&)\s+[A-Z][\w'’\-]+)?,?\s*\(?((?:19|20)\d{2})[a-z]?)",
        QRegularExpression::UseUnicodePropertiesOption);
    for (auto it = authorYear.globalMatch(window); it.hasNext();) {
        const auto m = it.next();
        const bool cited = !m.captured(2).isEmpty() || (m.capturedStart() > 0 && window[m.capturedStart() - 1] == '(');
        if (covers(m) && cited)
            return result("author", m.captured(1) + "|" + m.captured(3),
                m.captured(1) + (m.captured(2).trimmed().startsWith("et") ? " et al. " : " ") + m.captured(3),
                m.capturedStart());
    }
    return {};
}

QVariantMap ReferenceFinder::locate(
    const QStringList &pages, const QVariantMap &reference, int fromPage, qsizetype fromIndex)
{
    const auto kind = reference["kind"].toString(), key = reference["key"].toString();
    const auto elsewhere
        = [fromPage, fromIndex](int page, qsizetype start) { return page != fromPage || qAbs(start - fromIndex) > 24; };
    const auto at = [](int page, qsizetype start, qsizetype length) {
        return QVariantMap{{"page", page}, {"start", start}, {"length", length}};
    };
    // The reference list: after the last "References" heading.
    static const QRegularExpression heading(
        R"((?:^|[\r\n])[ \t]*(?:[IVX\d]+\.?[ \t]*)?(?:References|REFERENCES|R EFERENCES|Bibliography|BIBLIOGRAPHY|Literature Cited)[ \t]*(?=[\r\n]|$))");
    int listPage = -1;
    qsizetype listStart = 0;
    for (int page = pages.size() - 1; page >= 0 && listPage < 0; --page) {
        for (auto it = heading.globalMatch(pages[page]); it.hasNext();) {
            listPage = page;
            listStart = it.next().capturedEnd();
        }
    }
    if (kind == "citation") {
        const auto escaped = QRegularExpression::escape(key);
        const QRegularExpression bracket(R"((?:^|[\r\n])[ \t]*(\[)" + escaped + R"(\]))");
        const QRegularExpression dotted(R"((?:^|[\r\n])[ \t]*()" + escaped + R"(\.)[ \t]+\S)");
        static const QRegularExpression nextEntry(R"([\r\n][ \t]*(?:\[\d{1,3}\]|\d{1,3}\.[ \t]))");
        // "[12] A. Author…", or "12. A. Author…" only inside a reference list.
        for (const auto *pattern : {&bracket, &dotted}) {
            if (pattern == &dotted && listPage < 0) break;
            for (int page = qMax(0, listPage); page < pages.size(); ++page) {
                const auto &text = pages[page];
                for (auto it = pattern->globalMatch(text, page == listPage ? listStart : 0); it.hasNext();) {
                    const auto m = it.next();
                    const auto start = m.capturedStart(1);
                    if (!elsewhere(page, start)) continue;
                    const auto next = nextEntry.match(text, start + 2);
                    const auto end = next.hasMatch() ? next.capturedStart() : text.size();
                    return at(page, start, std::clamp<qsizetype>(end - start, 1, 400));
                }
            }
        }
        return {};
    }
    if (kind == "author") {
        if (listPage < 0) return {};
        const auto parts = key.split('|');
        const QRegularExpression surname("\\b" + QRegularExpression::escape(parts.value(0)) + "\\b");
        for (int page = listPage; page < pages.size(); ++page) {
            const auto &text = pages[page];
            qsizetype line = page == listPage ? listStart : 0;
            while (line < text.size()) {
                while (line < text.size() && (text[line] == '\r' || text[line] == '\n')) ++line;
                // The name early on the entry's first line, the year within the entry.
                const auto entry = text.mid(line, 300);
                const auto firstLine = entry.left(entry.indexOf(QRegularExpression("[\\r\\n]")));
                const auto name = surname.match(firstLine);
                if (name.hasMatch() && name.capturedStart() < 80
                    && entry.left(lineLength(text, line, 2, 300)).contains(parts.value(1)))
                    return at(page, line, lineLength(text, line, 2, 300));
                const auto next = text.indexOf(QRegularExpression("[\\r\\n]"), line);
                if (next < 0) break;
                line = next + 1;
            }
        }
        return {};
    }
    if (kind == "figure" || kind == "table") {
        const auto escaped = QRegularExpression::escape(key);
        // Captions start a line: "Fig. 3." / "Figure 3:" / "TABLE II", or a magazine's "FIG 3 Text…".
        const QRegularExpression caption = kind == "figure"
            ? QRegularExpression(R"((?:^|[\r\n])[ \t]*((?:Fig\.|Figure|FIG\.|FIGURE|Fig)[ \t]*)" + escaped
                  + R"()(?!\d)[ \t]*[:.|]|(?:^|[\r\n])[ \t]*((?:FIG|FIGURE)[ \t]+)" + escaped + R"()[ \t]+(?=[A-Z(]))")
            : QRegularExpression(R"((?:^|[\r\n])[ \t]*((?:TABLE|Table)[ \t]+([IVXLC]+|\d+))(?![\dA-Za-z]))");
        const QRegularExpression anywhere(R"(((?:Fig\.|Figure|FIG\.|FIGURE)[ \t]*)" + escaped + R"()(?!\d)[ \t]*[:.])");
        const int wanted = tableNumber(key);
        for (const auto *pattern : {&caption, &anywhere}) {
            if (pattern == &anywhere && kind != "figure") break;
            for (int page = 0; page < pages.size(); ++page) {
                for (auto it = pattern->globalMatch(pages[page]); it.hasNext();) {
                    const auto m = it.next();
                    if (kind == "table" && tableNumber(m.captured(2)) != wanted) continue;
                    // A figure caption matched either form; its start is the first group that took part.
                    const auto start = m.capturedStart(1) >= 0 ? m.capturedStart(1) : m.capturedStart(2);
                    if (elsewhere(page, start))
                        return at(page, start, lineLength(pages[page], start, kind == "table" ? 1 : 0));
                }
            }
        }
        return {};
    }
    if (kind == "equation") {
        // The number at the end of the equation's line.
        const QRegularExpression numbered(R"((\()" + QRegularExpression::escape(key) + R"(\))(?=[ \t]*(?:[\r\n]|$)))");
        for (int page = 0; page < pages.size(); ++page) {
            for (auto it = numbered.globalMatch(pages[page]); it.hasNext();) {
                const auto m = it.next();
                if (elsewhere(page, m.capturedStart(1))) return at(page, m.capturedStart(1), m.capturedLength(1));
            }
        }
    }
    return {};
}
