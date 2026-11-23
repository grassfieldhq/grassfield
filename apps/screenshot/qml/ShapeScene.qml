pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Qt.labs.qmlmodels

// The shapes of the document as scene items (slices B3 and B4): one item per layer, in picture pixels, inside one item scaled by
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
                            PathPolyline { path: arrowItem.endHead }
                        }
                        ShapePath {
                            strokeColor: arrowItem.gColor
                            strokeWidth: arrowItem.headStroke
                            fillColor: arrowItem.gColor
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap
                            PathPolyline { path: arrowItem.startHead }
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
                            PathPolyline { path: curvedItem.endHead }
                        }
                    }
                }
            }
        }
    }
}
