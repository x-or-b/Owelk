#include "ResearchStore.h"
#include <QDateTime>
#include <QSqlQuery>

// Undo history. An annotation step stores the row before and after a change (a new annotation's
// "before" is the same row, deleted), so undo and redo are one UPDATE each and nothing is lost:
// annotations are only soft-deleted. A capture step moves the capture to or from the trash.

namespace {
constexpr int historyLimit = 100;
QString kindName(const QString &kind)
{
    if (kind == "draw") return "Drawing";
    if (kind == "text") return "Text Box";
    if (kind == "image") return "Image";
    if (kind == "comment") return "Comment";
    return "Highlight";
}
}

QVariantMap ResearchStore::annotationState(const QString &id) const
{
    QSqlQuery query(m_database);
    query.prepare("SELECT document_id,kind,rectangles,body,color,image,drawing,deleted_at FROM highlights WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return {};
    return {{"document", query.value(0)}, {"kind", query.value(1)}, {"rectangles", query.value(2)},
        {"body", query.value(3)}, {"color", query.value(4)}, {"image", query.value(5)}, {"drawing", query.value(6)},
        {"deleted", query.value(7)}};
}

bool ResearchStore::applyAnnotationState(const QString &id, const QVariantMap &state)
{
    QSqlQuery query(m_database);
    query.prepare("UPDATE highlights SET rectangles=?,body=?,color=?,image=?,drawing=?,deleted_at=? WHERE id=?");
    for (const auto *key : {"rectangles", "body", "color", "image", "drawing"})
        query.addBindValue(state.value(key).toString());
    const auto deleted = state.value("deleted").toString();
    query.addBindValue(deleted.isEmpty() ? QVariant(QMetaType(QMetaType::QString)) : QVariant(deleted));
    query.addBindValue(id);
    if (!query.exec() || query.numRowsAffected() != 1) return false;
    emit highlightsChanged();
    emit homeChanged();
    return true;
}

void ResearchStore::pushHistory(const QString &document, const HistoryStep &step)
{
    if (m_replaying || document.isEmpty()) return;
    auto &list = m_undo[document];
    list.append(step);
    if (list.size() > historyLimit) list.removeFirst();
    m_redo.remove(document); // A new change ends the redo trail.
    ++m_historyRevision;
    emit historyChanged();
}

void ResearchStore::recordAnnotation(const QString &id, const QVariantMap &before, const QString &label)
{
    if (m_replaying) return;
    const auto after = annotationState(id);
    if (after.isEmpty()) return;
    auto previous = before;
    if (previous.isEmpty()) {
        previous = after;
        previous.insert("deleted", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    }
    if (previous == after) return;
    pushHistory(after.value("document").toString(),
        {"annotation", id, label.isEmpty() ? kindName(after.value("kind").toString()) : label, previous, after});
}

void ResearchStore::recordCapture(const QString &id, bool trashed)
{
    if (m_replaying) return;
    QSqlQuery query(m_database);
    query.prepare("SELECT document_id FROM captures WHERE id=?");
    query.addBindValue(id);
    if (!query.exec() || !query.next()) return;
    const auto document = query.value(0).toString();
    pushHistory(document,
        {"capture", id, trashed ? "Delete Capture" : "Capture", {{"trashed", !trashed}}, {{"trashed", trashed}}});
}

bool ResearchStore::canUndo(const QUrl &source) const
{
    return !m_undo.value(findDocument(source)).isEmpty();
}

bool ResearchStore::canRedo(const QUrl &source) const
{
    return !m_redo.value(findDocument(source)).isEmpty();
}

bool ResearchStore::replay(const QUrl &source, bool forward)
{
    const auto document = findDocument(source);
    auto &from = forward ? m_redo[document] : m_undo[document];
    if (document.isEmpty() || from.isEmpty()) {
        emit message(forward ? "Nothing to redo." : "Nothing to undo.");
        return false;
    }
    const auto step = from.takeLast();
    const auto &state = forward ? step.after : step.before;
    m_replaying = true;
    bool ok = false;
    if (step.type == "annotation")
        ok = applyAnnotationState(step.id, state);
    else if (step.type == "capture")
        ok = state.value("trashed").toBool() ? deleteCapture(step.id) : restoreCapture(step.id);
    m_replaying = false;
    if (ok) (forward ? m_undo : m_redo)[document].append(step);
    ++m_historyRevision;
    emit historyChanged();
    emit message(ok ? (forward ? "Redo " : "Undo ") + step.label
                    : "Cannot " + QString(forward ? "redo" : "undo") + " that change.");
    return ok;
}
