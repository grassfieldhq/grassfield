pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Qt.labs.qmlmodels

// The shapes of the document as scene items (slices B3 to B6: shapes, pen and highlighter strokes, text and counters): one item per layer, in picture pixels, inside one item scaled by
// the view's zoom. Zooming and scrolling therefore move the scene graph only; nothing is drawn again, and the shapes are
// aligned with the picture by construction (they are in the same content item). A drag changes one row of the model, so only that
// shape's path changes. Strokes are in picture pixels, so they grow with the zoom as the exported strokes do. The scene is
// clipped to the picture, as the export is. The geometry comes from the exporter's own (src/layermodel.cpp: shapeGeometry), so that
// the screen and the file agree; the curve renderer draws the paths resolution-independent, so no zoom shows facets.
//
// This item has the picture's size on screen (natural size times the zoom); it knows nothing of tokens or of the window, so a test
// can load it alone.
Item {
    id: root

    // The LayerModel of the backend.
    required property var model
    // Screen points per picture pixel.
    required property real viewScale
    // Pixelate and Blur (slice B7) show the exporter's own pixels, which the backend serves as image://screenshot/fx/<revision>/<layer id>
    // (the revision changes with every edit). Until an image is there for the layer, and whenever it is not, the area shows this opaque
    // colour: the screen never shows less redaction than the file.
    required property int regionRevision
    required property color regionPlaceholder

    clip: true

    Item {
        id: content
        objectName: "shapeContent"
        scale: root.viewScale
        transformOrigin: Item.TopLeft

        Repeater {
            id: repeater
            objectName: "shapeRepeater"
            model: root.model

            delegate: DelegateChooser {
                role: "gKind"

                DelegateChoice {
                    roleValue: "rect"
                    Shape {
                        id: rectItem
                        required property color gColor
                        required property real gStroke
                        required property bool gFill
                        required property real boxX
                        required property real boxY
                        required property real boxW
                        required property real boxH
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: rectItem.gColor
                            strokeWidth: rectItem.gStroke
                            fillColor: rectItem.gFill ? rectItem.gColor : "transparent"
                            joinStyle: ShapePath.MiterJoin
                            capStyle: ShapePath.RoundCap
                            // Four sides, the last ending exactly where the first began: the outline is closed, so Qt joins the
                            // first corner as it does the others (a path with open ends would cap it).
                            startX: rectItem.boxX
                            startY: rectItem.boxY
                            PathLine { x: rectItem.boxX + rectItem.boxW; y: rectItem.boxY }
                            PathLine { x: rectItem.boxX + rectItem.boxW; y: rectItem.boxY + rectItem.boxH }
                            PathLine { x: rectItem.boxX; y: rectItem.boxY + rectItem.boxH }
                            PathLine { x: rectItem.boxX; y: rectItem.boxY }
                        }
                    }
                }

                DelegateChoice {
                    roleValue: "ellipse"
                    Shape {
                        id: ellipseItem
                        required property color gColor
                        required property real gStroke
                        required property bool gFill
                        required property real boxX
                        required property real boxY
                        required property real boxW
                        required property real boxH
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: ellipseItem.gColor
                            strokeWidth: ellipseItem.gStroke
                            fillColor: ellipseItem.gFill ? ellipseItem.gColor : "transparent"
                            joinStyle: ShapePath.MiterJoin
                            capStyle: ShapePath.RoundCap
                            startX: ellipseItem.boxX + ellipseItem.boxW
                            startY: ellipseItem.boxY + ellipseItem.boxH / 2
                            PathAngleArc {
                                centerX: ellipseItem.boxX + ellipseItem.boxW / 2
                                centerY: ellipseItem.boxY + ellipseItem.boxH / 2
                                radiusX: ellipseItem.boxW / 2
                                radiusY: ellipseItem.boxH / 2
                                startAngle: 0
                                sweepAngle: 360
                            }
                        }
                    }
                }

                // Redact: an opaque fill of the area (whole pixels, as the exporter's), nothing blended along its border.
                DelegateChoice {
                    roleValue: "redact"
                    Rectangle {
                        id: redactItem
                        required property color gColor
                        required property real boxX
                        required property real boxY
                        required property real boxW
                        required property real boxH
                        // One device pixel more on every side: the picture under it is drawn with mipmaps, which blend a pixel or so of what
                        // it hides across the border; the screen covers that, so it never shows less than the file.
                        readonly property real grow: 1 / Math.max(root.viewScale, 0.01)
                        x: redactItem.boxX - grow
                        y: redactItem.boxY - grow
                        width: redactItem.boxW + 2 * grow
                        height: redactItem.boxH + 2 * grow
                        antialiasing: false
                        color: Qt.rgba(redactItem.gColor.r, redactItem.gColor.g, redactItem.gColor.b, 1)
                    }
                }

                // Pixelate and Blur: the opaque placeholder first, the exporter's pixels over it as soon as they are loaded.
                DelegateChoice {
                    roleValue: "pixelate"
                    Item {
                        id: pixelateItem
                        required property int gId
                        required property real boxX
                        required property real boxY
                        required property real boxW
                        required property real boxH
                        Rectangle {
                            x: pixelateItem.boxX
                            y: pixelateItem.boxY
                            width: pixelateItem.boxW
                            height: pixelateItem.boxH
                            antialiasing: false
                            color: root.regionPlaceholder
                        }
                        Image {
                            x: Math.max(0, pixelateItem.boxX)
                            y: Math.max(0, pixelateItem.boxY)
                            source: "image://screenshot/fx/" + root.regionRevision + "/" + pixelateItem.gId
                            asynchronous: true
                            cache: false
                            smooth: false
                            mipmap: false
                        }
                    }
                }

                DelegateChoice {
                    roleValue: "blur"
                    Item {
                        id: blurItem
                        required property int gId
                        required property real boxX
                        required property real boxY
                        required property real boxW
                        required property real boxH
                        Rectangle {
                            x: blurItem.boxX
                            y: blurItem.boxY
                            width: blurItem.boxW
                            height: blurItem.boxH
                            antialiasing: false
                            color: root.regionPlaceholder
                        }
                        Image {
                            x: Math.max(0, blurItem.boxX)
                            y: Math.max(0, blurItem.boxY)
                            source: "image://screenshot/fx/" + root.regionRevision + "/" + blurItem.gId
                            asynchronous: true
                            cache: false
                            smooth: false
                            mipmap: false
                        }
                    }
                }

                // Spotlight: a veil over everything but the area (the exporter's own path, odd-even filled).
                DelegateChoice {
                    roleValue: "spotlight"
                    Shape {
                        id: spotlightItem
                        required property color gColor
                        required property string pathSvg
                        ShapePath {
                            strokeColor: "transparent"
                            strokeWidth: 0
                            fillColor: spotlightItem.gColor
                            fillRule: ShapePath.OddEvenFill
                            PathSvg { path: spotlightItem.pathSvg }
                        }
                    }
                }

                DelegateChoice {
                    roleValue: "line"
                    Shape {
                        id: lineItem
                        required property color gColor
                        required property real gStroke
                        required property point startPt
                        required property point endPt
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: lineItem.gColor
                            strokeWidth: lineItem.gStroke
                            fillColor: "transparent"
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            startX: lineItem.startPt.x
                            startY: lineItem.startPt.y
                            PathLine { x: lineItem.endPt.x; y: lineItem.endPt.y }
                        }
                    }
                }

                DelegateChoice {
                    roleValue: "arrow"
                    Shape {
                        id: arrowItem
                        required property color gColor
                        required property real gStroke
                        required property real headStroke
                        required property point startPt
                        required property point endPt
                        required property var endHead
                        required property var startHead
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: arrowItem.gColor
                            strokeWidth: arrowItem.gStroke
                            fillColor: "transparent"
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            startX: arrowItem.startPt.x
                            startY: arrowItem.startPt.y
                            PathLine { x: arrowItem.endPt.x; y: arrowItem.endPt.y }
                        }
                        ShapePath {
                            strokeColor: arrowItem.gColor
                            strokeWidth: arrowItem.headStroke
                            fillColor: arrowItem.gColor
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            // The path starts at the head's first point and ends on it again: a closed outline, joined at every corner.
                            startX: arrowItem.endHead.length > 0 ? arrowItem.endHead[0].x : 0
                            startY: arrowItem.endHead.length > 0 ? arrowItem.endHead[0].y : 0
                            PathPolyline { path: arrowItem.endHead }
                        }
                        ShapePath {
                            strokeColor: arrowItem.gColor
                            strokeWidth: arrowItem.headStroke
                            fillColor: arrowItem.gColor
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            // The path starts at the head's first point and ends on it again: a closed outline, joined at every corner.
                            startX: arrowItem.startHead.length > 0 ? arrowItem.startHead[0].x : 0
                            startY: arrowItem.startHead.length > 0 ? arrowItem.startHead[0].y : 0
                            PathPolyline { path: arrowItem.startHead }
                        }
                    }
                }

                // A pen's or a highlighter's stroke: the smoothed centre line as the exporter's own path (SVG path data).
                DelegateChoice {
                    roleValue: "stroke"
                    Shape {
                        id: strokeItem
                        required property color gColor
                        required property real gStroke
                        required property bool flatCap
                        required property string pathSvg
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: strokeItem.gColor
                            strokeWidth: strokeItem.gStroke
                            fillColor: "transparent"
                            joinStyle: ShapePath.RoundJoin
                            capStyle: strokeItem.flatCap ? ShapePath.FlatCap : ShapePath.RoundCap
                            PathSvg { path: strokeItem.pathSvg }
                        }
                    }
                }

                // Text and a counter's number: glyph outlines (the exporter's own), over a plate for a pill and for the counter's disc.
                DelegateChoice {
                    roleValue: "glyphs"
                    Shape {
                        id: glyphItem
                        required property string pathSvg
                        required property string plateSvg
                        required property color plateColor
                        required property color inkColor
                        required property color outlineColor
                        required property real outlineWidth
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: "transparent"
                            strokeWidth: 0
                            fillColor: glyphItem.plateSvg !== "" ? glyphItem.plateColor : "transparent"
                            PathSvg { path: glyphItem.plateSvg }
                        }
                        ShapePath {
                            strokeColor: glyphItem.outlineWidth > 0 ? glyphItem.outlineColor : "transparent"
                            strokeWidth: glyphItem.outlineWidth > 0 ? glyphItem.outlineWidth : 0
                            fillColor: "transparent"
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            PathSvg { path: glyphItem.pathSvg }
                        }
                        ShapePath {
                            strokeColor: "transparent"
                            strokeWidth: 0
                            fillColor: glyphItem.inkColor
                            PathSvg { path: glyphItem.pathSvg }
                        }
                    }
                }

                DelegateChoice {
                    roleValue: "arrowCurved"
                    Shape {
                        id: curvedItem
                        required property color gColor
                        required property real gStroke
                        required property real headStroke
                        required property point startPt
                        required property point endPt
                        required property point ctrlPt
                        required property var endHead
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeColor: curvedItem.gColor
                            strokeWidth: curvedItem.gStroke
                            fillColor: "transparent"
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            startX: curvedItem.startPt.x
                            startY: curvedItem.startPt.y
                            PathQuad {
                                x: curvedItem.endPt.x
                                y: curvedItem.endPt.y
                                controlX: curvedItem.ctrlPt.x
                                controlY: curvedItem.ctrlPt.y
                            }
                        }
                        ShapePath {
                            strokeColor: curvedItem.gColor
                            strokeWidth: curvedItem.headStroke
                            fillColor: curvedItem.gColor
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            // The path starts at the head's first point and ends on it again: a closed outline, joined at every corner.
                            startX: curvedItem.endHead.length > 0 ? curvedItem.endHead[0].x : 0
                            startY: curvedItem.endHead.length > 0 ? curvedItem.endHead[0].y : 0
                            PathPolyline { path: curvedItem.endHead }
                        }
                    }
                }
            }
        }
    }
}
