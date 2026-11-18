import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const _forwardDuration = Duration(milliseconds: 320);
const _reverseDuration = Duration(milliseconds: 280);

/// The visible rounded surface within a tile that opens a page.
class TransitionOriginClip extends ClipRRect {
  const TransitionOriginClip({
    required super.borderRadius,
    required super.child,
  });

  @override
  RenderClipRRect createRenderObject(BuildContext context) =>
      _RenderTransitionOriginClip(
        borderRadius: borderRadius,
        textDirection: Directionality.maybeOf(context),
      );
}

class _RenderTransitionOriginClip extends RenderClipRRect {
  _RenderTransitionOriginClip({
    required super.borderRadius,
    required super.textDirection,
  });
}

/// Uses the existing pointer hit test to find the surface opening a mobile route.
class MobileRouteBinding extends WidgetsFlutterBinding {
  static WeakReference<RenderBox>? _pressed;

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    if (event is PointerDownEvent && hitTestResult != null) {
      _pressed = null;
      for (final entry in hitTestResult.path) {
        if (entry.target case final RenderPointerListener box) {
          _pressed = WeakReference(box);
          break;
        }
      }
    }
    super.dispatchEvent(event, hitTestResult);
  }

  @override
  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) _pressed = null;
    super.handleAppLifecycleStateChanged(state);
  }

  /// Uses the marked surface even when the user taps the tile's caption.
  static void useClip(BuildContext context) {
    final clip =
        context.findAncestorRenderObjectOfType<_RenderTransitionOriginClip>() ??
        _findClip(context.findRenderObject());
    if (clip != null) _pressed = WeakReference(clip);
  }

  static _RenderTransitionOriginClip? _findClip(RenderObject? node) {
    if (node is _RenderTransitionOriginClip) return node;
    _RenderTransitionOriginClip? clip;
    node?.visitChildren((child) => clip ??= _findClip(child));
    return clip;
  }
}

/// [box]'s rect in [navigator]'s overlay; null once it is detached, outside
/// the overlay or off screen.
Rect? _rectIn(NavigatorState navigator, RenderBox box) {
  final overlay = navigator.overlay?.context.findRenderObject();
  if (!box.attached ||
      !box.hasSize ||
      overlay is! RenderBox ||
      !overlay.hasSize) {
    return null;
  }
  final path = <RenderObject>[];
  RenderObject? node = box;
  while (node != null && node != overlay) {
    path.add(node);
    node = node.parent;
  }
  if (node == null) return null;
  final transform = Matrix4.identity();
  Rect? visible;
  RenderObject parent = overlay;
  for (final child in path.reversed) {
    if (box is _RenderTransitionOriginClip) {
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        final bounds = MatrixUtils.transformRect(transform, clip);
        visible = visible?.intersect(bounds) ?? bounds;
      }
    }
    parent.applyPaintTransform(child, transform);
    parent = child;
  }
  var rect = MatrixUtils.transformRect(transform, Offset.zero & box.size);
  if (visible != null) rect = rect.intersect(visible);
  return rect.isFinite &&
          !rect.isEmpty &&
          (Offset.zero & overlay.size).overlaps(rect)
      ? rect
      : null;
}

/// Completes once the transition of [context]'s page is at rest.
Future<void> pageSettled(BuildContext context) {
  final route = context.getInheritedWidgetOfExactType<_PageMotion>()?.route;
  // A pushed route's first frame is built offstage at its end state.
  if (route == null || (!route.offstage && !route.animation!.isAnimating)) {
    return Future.value();
  }
  final animation = route.animation!;
  final settled = Completer<void>();
  void onStatus(AnimationStatus status) {
    if (status.isAnimating) return;
    animation.removeStatusListener(onStatus);
    settled.complete();
  }

  animation.addStatusListener(onStatus);
  return settled.future;
}

/// Exposes the page's route without creating a dependency on it.
class _PageMotion extends InheritedWidget {
  const _PageMotion({required this.route, required super.child});

  final PageRoute<dynamic> route;

  @override
  bool updateShouldNotify(_PageMotion oldWidget) => false;
}

/// Where an Android predictive back gesture released the route: its
/// animation value then, and whether the route pops. Null while dragging.
typedef _Release = ({double value, bool commit});

/// Mobile pages grow out of the component that opened them and collapse back
/// into it: on pop, along an Android predictive back gesture and along the
/// iOS edge swipe.
class ContainerPageTransitionsBuilder extends PageTransitionsBuilder {
  const ContainerPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _forwardDuration;

  @override
  Duration get reverseTransitionDuration => _reverseDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    final page = _ContainerTransition(route: route, ios: ios, child: child);
    return ios
        ? CupertinoRouteTransitionMixin.buildPageTransitions<T>(
            route,
            context,
            kAlwaysCompleteAnimation,
            kAlwaysDismissedAnimation,
            page,
          )
        : page;
  }
}

/// Morphs the page between the component it was opened from and the full
/// screen. The page stays laid out at its final size throughout the motion.
class _ContainerTransition extends StatefulWidget {
  const _ContainerTransition({
    required this.route,
    required this.ios,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final bool ios;
  final Widget child;

  @override
  State<_ContainerTransition> createState() => _ContainerTransitionState();
}

typedef _OriginGeometry = ({Rect rect, BorderRadius? clipRadius});

class _ContainerTransitionState extends State<_ContainerTransition>
    with WidgetsBindingObserver {
  static const _curve = Curves.easeOut;
  static const _originRadius = BorderRadius.all(Radius.circular(12));
  static final _identity = Matrix4.identity();

  final _snapshot = SnapshotController();
  late final CurvedAnimation _motion;
  _Release? _release;
  WeakReference<RenderBox>? _origin;

  /// The component's geometry; null grows the page from the screen center.
  _OriginGeometry? _geometry;

  PageRoute<dynamic> get _route => widget.route;
  Animation<double> get _animation => _route.animation!;

  @override
  void initState() {
    super.initState();
    // Built in the frame of the push, while the pressed component is still
    // laid out on the previous page.
    _origin = MobileRouteBinding._pressed;
    MobileRouteBinding._pressed = null;
    _geometry = _locate();
    _motion = CurvedAnimation(
      parent: _animation,
      curve: _curve,
      reverseCurve: _curve.flipped,
    );
    if (!widget.ios) WidgetsBinding.instance.addObserver(this);
    _animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _animation.removeStatusListener(_onStatus);
    _motion.dispose();
    _snapshot.dispose();
    if (!widget.ios) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  _OriginGeometry? _locate() {
    final box = _origin?.target;
    final navigator = _route.navigator;
    if (box == null || navigator == null) return null;
    final rect = _rectIn(navigator, box);
    if (rect == null) return null;
    return (
      rect: rect,
      clipRadius: box is _RenderTransitionOriginClip
          ? box.borderRadius.resolve(box.textDirection)
          : null,
    );
  }

  void _onStatus(AnimationStatus status) {
    if (!status.isAnimating) return;
    // Pops and gestures leave the completed state: aim at where the component
    // is now, since the list behind the page may have scrolled.
    _geometry = _locate() ?? _geometry;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent event) {
    final route = widget.route;
    if (event.isButtonEvent || !route.isCurrent || !route.popGestureEnabled) {
      return false;
    }
    _release = null;
    route.handleStartBackGesture(progress: 1 - event.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent event) => widget
      .route
      .handleUpdateBackGestureProgress(progress: 1 - event.progress);

  @override
  void handleCancelBackGesture() => _settle(commit: false);

  @override
  void handleCommitBackGesture() => _settle(commit: true);

  /// After a cancel the route animates forward from where it was; after a
  /// commit it pops and reverses from 1.0
  /// ([TransitionRoute.handleCommitBackGesture]). The release value lets the
  /// transition continue from the finger instead of jumping.
  void _settle({required bool commit}) {
    final route = widget.route;
    _release = (value: route.animation!.value, commit: commit);
    commit ? route.handleCommitBackGesture() : route.handleCancelBackGesture();
    // A swipe released where it started settles without another tick.
    if (!route.popGestureInProgress && mounted) setState(() => _release = null);
  }

  /// 0 is the component, 1 the full page.
  double get _progress {
    final value = _animation.value;
    final release = _release;
    if (release != null) {
      final from = release.value;
      if (release.commit) return from * (1 - _curve.transform(1 - value));
      if (from >= 1) return 1;
      final t = ((value - from) / (1 - from)).clamp(0.0, 1.0);
      return from + (1 - from) * _curve.transform(t);
    }
    // The finger drives the page directly.
    if (_route.popGestureInProgress) return value;
    return _motion.value;
  }

  @override
  Widget build(BuildContext context) {
    if (!_route.popGestureInProgress) _release = null;
    final progress = MediaQuery.disableAnimationsOf(context) ? 1.0 : _progress;
    final fullRadius =
        MediaQuery.displayCornerRadiiOf(context) ?? BorderRadius.zero;
    // A back gesture belongs to the navigator. Only snapshot the moving route.
    _snapshot.allowSnapshotting = progress < 1 && _route.allowSnapshotting;
    final content = SnapshotWidget(
      controller: _snapshot,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: HeroMode(
        enabled: false,
        child: _PageMotion(route: _route, child: widget.child),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final window = Offset.zero & constraints.biggest;
        var transform = _identity;
        _ContainerClipper? clipper;
        if (progress < 1 && !window.isEmpty) {
          final origin = _geometry?.rect.intersect(window);
          final start = origin != null && !origin.isEmpty
              ? origin
              : Rect.fromCenter(
                  center: window.center,
                  width: window.width * 0.85,
                  height: window.height * 0.85,
                );
          final rect = Rect.lerp(start, window, progress)!;
          final scale = math.max(
            rect.width / window.width,
            rect.height / window.height,
          );
          transform = Matrix4.diagonal3Values(scale, scale, 1)
            ..setTranslationRaw(
              rect.center.dx - window.center.dx * scale,
              rect.top,
              0,
            );
          final radius = BorderRadius.lerp(
            _geometry?.clipRadius ?? _originRadius,
            fullRadius,
            progress,
          )!;
          clipper = _ContainerClipper(radius.toRRect(rect));
        }
        return ClipRRect(
          clipBehavior: clipper == null ? Clip.none : Clip.antiAlias,
          clipper: clipper,
          child: Transform(transform: transform, child: content),
        );
      },
    );
  }
}

class _ContainerClipper extends CustomClipper<RRect> {
  const _ContainerClipper(this.bounds);

  final RRect bounds;

  @override
  RRect getClip(Size size) => bounds;

  @override
  Rect getApproximateClipRect(Size size) => bounds.outerRect;

  @override
  bool shouldReclip(_ContainerClipper oldClipper) =>
      bounds != oldClipper.bounds;
}
