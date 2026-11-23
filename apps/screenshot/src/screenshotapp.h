#pragma once

#include "appearance.h"
#include "capturehistory.h"
#include "document.h"
#include "layermodel.h"
#include "toolcontroller.h"
#include "undostack.h"

#include <QImage>
#include <QMutex>
#include <QQuickImageProvider>
#include <QRectF>
#include <QString>
#include <QStringList>
#include <QVariantList>

// The backend of the editor window: one open document, its state for the toolbar and the menus, and Done and Revert. The
// window itself is qml/Editor.qml; everything it may do to a file goes through the two invokables below.
class ScreenshotApp : public AppearanceSettings
{
    Q_OBJECT
    // The picture file, "" when none opened. main.cpp then prints the errors on stderr and exits 2 before any window exists.
    Q_PROPERTY(QString path READ path NOTIFY documentChanged)
    Q_PROPERTY(QString fileName READ fileName NOTIFY documentChanged)
    // The picture's size in device pixels, 0 x 0 without a document.
    Q_PROPERTY(int imageWidth READ imageWidth NOTIFY documentChanged)
    Q_PROPERTY(int imageHeight READ imageHeight NOTIFY documentChanged)
    // image://screenshot/<revision>: the original picture (the provider below); the revision changes when it does.
    Q_PROPERTY(QString imageSource READ imageSource NOTIFY documentChanged)
    // Unsaved changes, and whether Revert has an original to put back.
    Q_PROPERTY(bool dirty READ dirty NOTIFY documentChanged)
    Q_PROPERTY(bool canRevert READ canRevert NOTIFY documentChanged)
    // The messages of the command line's rejected arguments, and the last failure of Done or Revert ("" when none).
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    // The editing state (slices B3, B4): the layers' drawing, the tool and its style, the selection, undo and redo.
    // The shapes as a model for the scene items of qml/ShapeScene.qml (layermodel.h).
    Q_PROPERTY(QObject *layerModel READ layerModel CONSTANT)
    Q_PROPERTY(QString tool READ tool WRITE setTool NOTIFY toolChanged)
    // The style new shapes get: "#rrggbb" colour, stroke in picture pixels, fill, arrow style (straight, curved, double).
    Q_PROPERTY(QString toolColor READ toolColor WRITE setToolColor NOTIFY toolChanged)
    Q_PROPERTY(qreal toolWidth READ toolWidth WRITE setToolWidth NOTIFY toolChanged)
    Q_PROPERTY(bool toolFill READ toolFill WRITE setToolFill NOTIFY toolChanged)
    Q_PROPERTY(QString arrowStyle READ arrowStyle WRITE setArrowStyle NOTIFY toolChanged)
    Q_PROPERTY(int selectedId READ selectedId NOTIFY layersChanged)
    // The selected layer's handles as [{x, y}] and its box, in picture pixels (empty and null without a selection).
    Q_PROPERTY(QVariantList handles READ handles NOTIFY layersChanged)
    Q_PROPERTY(QRectF selectionBounds READ selectionBounds NOTIFY layersChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY layersChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY layersChanged)

public:
    // `path` empty with `errors` set: nothing to edit. `historyRoot` empty: the user's own (CaptureHistory::defaultRoot()).
    ScreenshotApp(const QString &path, const QStringList &errors, const QString &historyRoot = QString(), QObject *parent = nullptr);

    QString path() const { return m_document.path(); }
    QString fileName() const;
    int imageWidth() const { return m_document.original().width(); }
    int imageHeight() const { return m_document.original().height(); }
    QString imageSource() const;
    bool dirty() const { return m_document.dirty(); }
    bool canRevert() const { return m_document.canRevert(); }
    QStringList errors() const { return m_errors; }
    QString lastError() const { return m_lastError; }

    QObject *layerModel() { return &m_layerModel; }
    QString tool() const { return m_tools.tool(); }
    void setTool(const QString &tool);
    QString toolColor() const { return m_tools.style().color; }
    void setToolColor(const QString &color);
    qreal toolWidth() const { return m_tools.style().width; }
    void setToolWidth(qreal width);
    bool toolFill() const { return m_tools.style().fill; }
    void setToolFill(bool fill);
    QString arrowStyle() const { return m_tools.style().arrow; }
    void setArrowStyle(const QString &style);
    int selectedId() const { return m_tools.selected(); }
    QVariantList handles() const;
    QRectF selectionBounds() const { return m_tools.selectionBounds(); }
    bool canUndo() const { return m_undo.canUndo(); }
    bool canRedo() const { return m_undo.canRedo(); }

    // The scale of the display the capture was taken on, "Grassfield-Scale" in the PNG; 0 when the file does not say.
    qreal captureScale() const;

    // The picture the provider serves (a copy: the document stays on the GUI thread).
    QImage currentImage() const;

    // Done: replaces the file with the edited picture, keeping the original in the history. True when the window may close.
    Q_INVOKABLE bool done();
    // Revert: puts the captured picture back in the file.
    Q_INVOKABLE bool revert();

    // The pointer, in picture pixels (`tolerance`: the picking reach, in picture pixels). The view calls press on a press, move
    // while it is held, release at its end; Shift (`constrain`) keeps angles and squares.
    Q_INVOKABLE bool toolPress(qreal x, qreal y, qreal tolerance);
    Q_INVOKABLE void toolMove(qreal x, qreal y, bool constrain);
    Q_INVOKABLE void toolRelease(qreal x, qreal y, bool constrain);
    Q_INVOKABLE void toolCancel();
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();
    // The selected layer: removed, or moved by (dx, dy) picture pixels.
    Q_INVOKABLE void deleteSelected();
    Q_INVOKABLE void nudgeSelected(qreal dx, qreal dy);
    Q_INVOKABLE void selectNone();

signals:
    void documentChanged();
    void lastErrorChanged();
    void layersChanged();
    void toolChanged();

private:
    void setLastError(const QString &error);
    void publish();
    // The layers changed (a step, an undo, a preview): the document, the view and the state follow.
    void layersEdited();

    QStringList m_errors;
    screenshot::CaptureHistory m_history;
    screenshot::Document m_document;
    screenshot::UndoStack m_undo;
    screenshot::ToolController m_tools;
    LayerModel m_layerModel;
    mutable QMutex m_imageLock;
    QImage m_image;
    int m_revision = 0;
    QString m_lastError;
};

// image://screenshot/<revision>: the document's original picture at its own size (the Image's sourceSize decides what is
// decoded by the scene graph; the picture itself is already in memory).
class ScreenshotImageProvider : public QQuickImageProvider
{
public:
    explicit ScreenshotImageProvider(ScreenshotApp *app);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    ScreenshotApp *m_app;
};
