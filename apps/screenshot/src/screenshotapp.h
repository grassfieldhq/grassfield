#pragma once

#include "appearance.h"
#include "capturehistory.h"
#include "document.h"
#include "framing.h"
#include "layermodel.h"
#include "toolcontroller.h"
#include "undostack.h"

#include <QImage>
#include <QPointF>
#include <functional>
#include <QMutex>
#include <QQuickImageProvider>
#include <QRectF>
#include <QString>
#include <QTimer>
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
    // This is the picture as framed (cropped, turned, mirrored: slice B8), which is the one the layers are in; pictureChanged tells
    // when the document, a revert or an edit of the frame makes another.
    Q_PROPERTY(int imageWidth READ imageWidth NOTIFY pictureChanged)
    Q_PROPERTY(int imageHeight READ imageHeight NOTIFY pictureChanged)
    // image://screenshot/<revision>: the framed picture (the provider below); the revision changes when it does.
    Q_PROPERTY(QString imageSource READ imageSource NOTIFY pictureChanged)
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
    // With the Redact tool at hand (or a Redact layer selected) the colour is the redaction's own fill, black until changed.
    Q_PROPERTY(QString toolColor READ toolColor WRITE setToolColor NOTIFY toolChanged)
    Q_PROPERTY(qreal toolWidth READ toolWidth WRITE setToolWidth NOTIFY toolChanged)
    Q_PROPERTY(bool toolFill READ toolFill WRITE setToolFill NOTIFY toolChanged)
    Q_PROPERTY(QString arrowStyle READ arrowStyle WRITE setArrowStyle NOTIFY toolChanged)
    // Text and counters (slice B6): the text style (plain, outlined, pill), the font's pixel size and family, the counter's diameter;
    // the highlighter (slice B5): how many times the pen's width it is, and its alpha. All in the style new layers get.
    Q_PROPERTY(QString textStyle READ textStyle WRITE setTextStyle NOTIFY toolChanged)
    Q_PROPERTY(qreal textSize READ textSize WRITE setTextSize NOTIFY toolChanged)
    Q_PROPERTY(QString textFamily READ textFamily WRITE setTextFamily NOTIFY toolChanged)
    Q_PROPERTY(qreal counterSize READ counterSize WRITE setCounterSize NOTIFY toolChanged)
    Q_PROPERTY(qreal highlightFactor READ highlightFactor WRITE setHighlightFactor NOTIFY toolChanged)
    Q_PROPERTY(qreal highlightOpacity READ highlightOpacity WRITE setHighlightOpacity NOTIFY toolChanged)
    // The region tools (slice B7): a pixelate's block side and a blur's sigma in device pixels, a spotlight's veil alpha (the style new layers get).
    Q_PROPERTY(qreal pixelateBlock READ pixelateBlock WRITE setPixelateBlock NOTIFY toolChanged)
    Q_PROPERTY(qreal blurRadius READ blurRadius WRITE setBlurRadius NOTIFY toolChanged)
    Q_PROPERTY(qreal spotlightDim READ spotlightDim WRITE setSpotlightDim NOTIFY toolChanged)
    // Changes whenever what a Pixelate or Blur shows may have changed (any edit of the layers or the picture): the scene asks for each region's
    // image again (image://screenshot/fx/<revision>/<layer id>).
    Q_PROPERTY(int regionRevision READ regionRevision NOTIFY layersChanged)
    // The text being typed (the Text tool): whether an editor is open, the layer it edits (0 for a new text), the picture point of
    // its top left and its text. The view puts its editor there and answers with commitText or cancelText.
    Q_PROPERTY(bool textEditing READ textEditing NOTIFY textEditChanged)
    Q_PROPERTY(int textEditId READ textEditId NOTIFY textEditChanged)
    Q_PROPERTY(QPointF textEditPos READ textEditPos NOTIFY textEditChanged)
    Q_PROPERTY(QString textEditText READ textEditText NOTIFY textEditChanged)
    // The most characters a text holds (the editor stops there; a longer one handed to commitText is cut).
    Q_PROPERTY(int textMaxLength READ textMaxLength CONSTANT)
    // The type of the selected layer ("" for none): the style controls follow it.
    Q_PROPERTY(QString selectedType READ selectedType NOTIFY layersChanged)
    // The Crop tool's rectangle in picture pixels (null when the tool is not at hand), its aspect preset ("free", "original", "1:1",
    // "4:3", "3:2", "16:9", "9:16") and whether Apply would change the picture.
    Q_PROPERTY(QRectF cropRect READ cropRect NOTIFY cropChanged)
    Q_PROPERTY(QString cropAspect READ cropAspect NOTIFY cropChanged)
    Q_PROPERTY(bool cropChanges READ cropChanges NOTIFY cropChanged)
    Q_PROPERTY(QStringList cropAspects READ cropAspects CONSTANT)
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
    int imageWidth() const { return m_image.width(); }
    int imageHeight() const { return m_image.height(); }
    QString imageSource() const;
    qreal pixelateBlock() const { return m_tools.style().pixelateBlock; }
    void setPixelateBlock(qreal block);
    qreal blurRadius() const { return m_tools.style().blurRadius; }
    void setBlurRadius(qreal radius);
    qreal spotlightDim() const { return m_tools.style().spotlightDim; }
    void setSpotlightDim(qreal dim);
    int regionRevision() const { return m_regionRevision; }
    QString textStyle() const { return m_tools.style().textStyle; }
    void setTextStyle(const QString &style);
    qreal textSize() const { return m_tools.style().textSize; }
    void setTextSize(qreal size);
    QString textFamily() const { return m_tools.style().family; }
    void setTextFamily(const QString &family);
    qreal counterSize() const { return m_tools.style().counterSize; }
    void setCounterSize(qreal size);
    qreal highlightFactor() const { return m_tools.style().highlightFactor; }
    void setHighlightFactor(qreal factor);
    qreal highlightOpacity() const { return m_tools.style().highlightOpacity; }
    void setHighlightOpacity(qreal opacity);
    bool textEditing() const { return m_textEditing; }
    int textEditId() const { return m_textEditId; }
    QPointF textEditPos() const { return m_textEditPos; }
    QString textEditText() const { return m_textEditText; }
    int textMaxLength() const { return screenshot::kMaxTextLength; }
    QString selectedType() const { return m_tools.selectedLayer().type; }
    QRectF cropRect() const { return m_tools.tool() == QLatin1String("crop") ? m_crop.rect() : QRectF(); }
    QString cropAspect() const { return m_crop.aspect(); }
    bool cropChanges() const { return m_tools.tool() == QLatin1String("crop") && m_crop.changes(); }
    QStringList cropAspects() const { return screenshot::cropAspects(); }
    bool dirty() const { return m_document.dirty(); }
    bool canRevert() const { return m_document.canRevert(); }
    QStringList errors() const { return m_errors; }
    QString lastError() const { return m_lastError; }

    QObject *layerModel() { return &m_layerModel; }
    QString tool() const { return m_tools.tool(); }
    void setTool(const QString &tool);
    QString toolColor() const { return colorSlot(); }
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
    // What a Pixelate or Blur layer shows over its area (the exporter's own pixels; regionPatch), for the provider's thread. Null for any other id.
    QImage regionImage(int id) const;

    // Where a redacted export puts the picture: wl-copy's arguments and the PNG on its stdin; true when it was taken. The app's own runs
    // wl-copy; the tests replace it. After a Done that hid pixels the clipboard holds the exported picture, never the capture (ADR-0066 D-9).
    using ClipboardWriter = std::function<bool(const QStringList &arguments, const QByteArray &png)>;
    void setClipboardWriter(const ClipboardWriter &writer) { m_clipboardWriter = writer; }
    // What the clipboard holds as a PNG, to see whether it is still this capture's own automatic copy: 0 and the bytes when it offers image/png,
    // 1 when it is empty or holds something else, 2 when it cannot be read (no wl-paste). The app's own runs wl-paste; the tests replace it.
    using ClipboardReader = std::function<int(QByteArray *png)>;
    void setClipboardReader(const ClipboardReader &reader) { m_clipboardReader = reader; }

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

    // The style controls (slices B5 and B6): the style new layers get and, when a layer of a type it applies to is selected, that
    // layer too (one undo step). A colour is "#rrggbb"; a highlighter keeps its see-through.
    Q_INVOKABLE void applyColor(const QString &color);
    Q_INVOKABLE void applyWidth(qreal width);
    Q_INVOKABLE void applyFill(bool fill);
    Q_INVOKABLE void applyTextStyle(const QString &style);
    Q_INVOKABLE void applyTextSize(qreal size);
    Q_INVOKABLE void applyCounterSize(qreal size);
    // The Eyedropper: the colour of the picture's pixel under (x, y) in picture pixels, "#rrggbb" ("" outside the picture). It
    // becomes the colour of new layers and of the selection. The pixel is the framed picture's, not the layers over it.
    Q_INVOKABLE QString pickColor(qreal x, qreal y);

    // The Text tool: Return on a selected text edits it. commitText puts the typed text in (a new layer, or the edited one; an empty
    // text removes the edited one), cancelText leaves the layers as they were.
    Q_INVOKABLE void editSelectedText();
    // The text as typed so far, shown as the layer it will be (the same geometry as the file: size, style, outline, pill), as a
    // preview of the edit; commitText makes it one undo step, cancelText takes it away. Done and a change of tool commit it too.
    Q_INVOKABLE void previewText(const QString &text);
    Q_INVOKABLE void commitText(const QString &text);
    Q_INVOKABLE void cancelText();

    // Crop, rotate, flip (slice B8): each is one undo step that moves the picture and its layers together.
    Q_INVOKABLE void setCropAspect(const QString &name);
    Q_INVOKABLE void applyCrop();
    Q_INVOKABLE void cancelCrop();
    Q_INVOKABLE void rotateLeft();
    Q_INVOKABLE void rotateRight();
    Q_INVOKABLE void flipHorizontal();
    Q_INVOKABLE void flipVertical();

signals:
    void documentChanged();
    void lastErrorChanged();
    void layersChanged();
    void toolChanged();
    void pictureChanged();
    void textEditChanged();
    void cropChanged();

private:
    void setLastError(const QString &error);
    // The colour of the tool at hand (or the selected layer's tool): the redaction's own fill for Redact, else the style's colour.
    QString &colorSlot();
    QString colorSlot() const;
    // Puts the exported picture on the clipboard in place of the automatic copy; false (and the clipboard cleared, if it can be) when it cannot.
    bool replaceClipboard(const QByteArray &png);
    // Whether the clipboard still holds the capture as it was taken (its automatic copy): only then does a redacted export replace it.
    bool clipboardHoldsCapture();
    void publish();
    // The layers changed (a step, an undo, a preview): the document, the view and the state follow.
    void layersEdited();
    // The framed picture again from the original and the frame layer (publish, an edit of the frame, an undo of one).
    void refreshPicture();
    void commitFrame(const screenshot::Layers &next);
    // The Eyedropper: the pixel's colour name at (x, y), "" outside the picture.
    QString pixelColorAt(qreal x, qreal y) const;
    // The colour as the style and, as a preview, the selection's (one step when the drag ends, none when nothing changed).
    void previewPick(const QString &color);
    // Puts in the text being typed, if any.
    void finishText();
    // Selecting a layer makes its style the style of the next one (macOS: the style well shows the selection's).
    void adoptStyle(const screenshot::Layer &layer);
    void beginText(int id, const QPointF &pos, const QString &text);
    // The style change `edit` makes to the selection, as one step.
    void restyleSelection(const std::function<screenshot::Layer(const screenshot::Layer &)> &edit);

    QStringList m_errors;
    screenshot::CaptureHistory m_history;
    screenshot::Document m_document;
    screenshot::UndoStack m_undo;
    screenshot::ToolController m_tools;
    LayerModel m_layerModel;
    bool m_lastDirty = false; // what documentChanged last told about
    mutable QMutex m_imageLock;
    QImage m_image;
    int m_revision = 0;
    screenshot::Frame m_frame;
    screenshot::CropEditor m_crop;
    bool m_picking = false;
    QTimer m_flushTimer; // one preview of a stroke per frame
    QString m_textPreview;
    // The text being typed: where a new one begins (the click), and the style changes made to an edited one while typing (they are
    // part of the same edit, so they are kept and applied to the layer at every preview).
    QPointF m_textAnchor;
    QList<std::function<screenshot::Layer(const screenshot::Layer &)>> m_textRestyles;
    int m_lastSelected = 0;
    bool m_textEditing = false;
    int m_textEditId = 0;
    QPointF m_textEditPos;
    QString m_textEditText;
    QString m_lastError;
    // Region previews (the provider's thread reads them): the layers the scene shows, under m_imageLock with m_image.
    screenshot::Layers m_regionLayers;
    int m_regionRevision = 0;
    ClipboardWriter m_clipboardWriter;
    ClipboardReader m_clipboardReader;
    bool m_clipboardForce = false; // a replacement failed and the clipboard was cleared: the retry writes without asking what it holds
    QByteArray m_clipboardPng; // the exported picture of a Done that hid pixels, until the clipboard has taken it
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
