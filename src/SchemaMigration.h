#pragma once

#include <QList>
#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QStringList>
#include <functional>

// Ordered, transactional schema steps recorded in PRAGMA user_version.
// Step 1 of each database is the idempotent baseline, so files created before versioning upgrade in place.
struct SchemaStep {
    int version = 0;
    QStringList statements;
    std::function<bool(QSqlDatabase &, QString *)> apply = {};
};

inline bool migrateSchema(QSqlDatabase &db, const QList<SchemaStep> &steps, QString *error)
{
    QSqlQuery query(db);
    if (!query.exec("PRAGMA user_version") || !query.next()) {
        *error = query.lastError().text();
        return false;
    }
    const int current = query.value(0).toInt();
    query.finish();
    if (!steps.isEmpty() && current > steps.last().version) {
        // Never let an older build rewrite data it does not understand.
        *error = QStringLiteral("This data was created by a newer Owelk version (schema %1). Update Owelk to open it.")
                     .arg(current);
        return false;
    }
    for (const auto &step : steps) {
        if (step.version <= current) continue;
        if (!db.transaction()) {
            *error = db.lastError().text();
            return false;
        }
        bool ok = true;
        for (const auto &sql : step.statements) {
            QSqlQuery statement(db);
            if (!statement.exec(sql)) {
                *error = statement.lastError().text();
                ok = false;
                break;
            }
        }
        if (ok && step.apply) ok = step.apply(db, error);
        QSqlQuery version(db);
        if (ok && !version.exec(QStringLiteral("PRAGMA user_version=%1").arg(step.version))) {
            *error = version.lastError().text();
            ok = false;
        }
        if (!ok || !db.commit()) {
            if (ok) *error = db.lastError().text();
            db.rollback();
            return false;
        }
    }
    return true;
}
