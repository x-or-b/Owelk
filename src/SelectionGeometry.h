#pragma once
#include <QObject>
#include <QPolygonF>
#include <QVariantList>

class SelectionGeometry final : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE QVariantList lineRectangles(const QList<QPolygonF> &polygons) const;
    Q_INVOKABLE QVariantList stableRectangles(const QList<QPolygonF> &selection, const QVariantList &pageLines) const;
};
