import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Smooths subpixel movement in the vertical mobile home feed.
class HomePosterGrid extends SliverGrid {
  const HomePosterGrid({
    required super.delegate,
    required super.gridDelegate,
    super.key,
  });

  @override
  RenderSliverGrid createRenderObject(BuildContext context) {
    return _RenderHomePosterGrid(
      MediaQuery.devicePixelRatioOf(context),
      childManager: context as SliverMultiBoxAdaptorElement,
      gridDelegate: gridDelegate,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderSliverGrid renderObject) {
    super.updateRenderObject(context, renderObject);
    (renderObject as _RenderHomePosterGrid).devicePixelRatio =
        MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderHomePosterGrid extends RenderSliverGrid {
  _RenderHomePosterGrid(
    this._devicePixelRatio, {
    required super.childManager,
    required super.gridDelegate,
  });

  double _devicePixelRatio;
  double? _lastPhysicalTop;
  late ui.ImageFilter _verticalBlur = _blurAt(_devicePixelRatio);

  static ui.ImageFilter _blurAt(double devicePixelRatio) =>
      ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0.8 / devicePixelRatio);

  @override
  bool get alwaysNeedsCompositing => true;

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    _lastPhysicalTop = null;
    _verticalBlur = _blurAt(value);
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final origin = MatrixUtils.getAsTranslation(getTransformTo(null));
    final physicalTop = origin == null
        ? null
        : (origin.dy - constraints.scrollOffset) * _devicePixelRatio;
    final previousTop = _lastPhysicalTop;
    _lastPhysicalTop = physicalTop;
    // Keep the fast path direct so the raster thread has time to draw each
    // frame when dragging or flinging through several rows.
    if (physicalTop == null ||
        (previousTop != null && (physicalTop - previousTop).abs() > 1)) {
      layer = null;
      super.paint(context, offset);
      return;
    }

    // Align all rows before filtering fine strokes, then translate the
    // result back to the exact position used by layout and hit testing.
    final shift =
        (physicalTop.roundToDouble() - physicalTop) / _devicePixelRatio;
    final matrix = Matrix4.translationValues(0, -shift, 0);
    final filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.matrix(
        matrix.storage,
        filterQuality: ui.FilterQuality.low,
      ),
      inner: _verticalBlur,
    );
    if (layer case final ImageFilterLayer filterLayer) {
      filterLayer.imageFilter = filter;
    } else {
      layer = ImageFilterLayer(imageFilter: filter);
    }
    context.pushLayer(layer!, super.paint, offset.translate(0, shift));
  }
}
