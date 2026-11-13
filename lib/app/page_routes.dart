import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const _forwardDuration = Duration(milliseconds: 320);
const _reverseDuration = Duration(milliseconds: 280);

/// The component under the latest press. The page that press opens grows out
/// of it and collapses back into it.
abstract final class TapOrigin {
  static WeakReference<RenderBox>? _pressed;
  static AppLifecycleListener? _lifecycle;

  static void install() {
    if (_lifecycle != null) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    // A press made before the app was hidden cannot open what comes after.
    _lifecycle = AppLifecycleListener(onHide: () => _pressed = null);
  }

  static void uninstall() {
    if (_lifecycle == null) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _lifecycle!.dispose();
    _lifecycle = null;
    _pressed = null;
  }

  static void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    // The path runs from the most specific target outwards, so the first
    // gesture detector is the pressed button, tile or card.
    for (final entry in result.path) {
      if (entry.target case final RenderPointerListener box) {
        _pressed = WeakReference(box);
        return;
      }
    }
    _pressed = null;
  }

  /// Hands the pressed component to one page only.
  static RenderBox? take() {
    final box = _pressed?.target;
    _pressed = null;
    return box;
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
  RenderObject? node = box;
  while (node != null && node != overlay) {
    node = node.parent;
  }
  if (node == null) return null;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return rect.isFinite &&
          !rect.isEmpty &&
          (Offset.zero & overlay.size).overlaps(rect)
      ? rect
      : null;
}

/// Completes once the transition of [context]'s page is at rest.
///
/// A page in a container transition is drawn from a snapshot while it moves,
/// so rebuilding it then only costs frames. Data arriving mid-transition can
/// wait for this; pages of other routes complete at once.
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

/// Hands Android predictive back gestures to [route].
///
/// A route rebuilds its transitions on every animation tick and the gesture
/// moves the route animation, so [builder] runs once per gesture frame.
class _PredictiveBack extends StatefulWidget {
  const _PredictiveBack({required this.route, required this.builder});

  final PageRoute<dynamic> route;
  final Widget Function(BuildContext context, _Release? release) builder;

  @override
  State<_PredictiveBack> createState() => _PredictiveBackState();
}

class _PredictiveBackState extends State<_PredictiveBack>
    with WidgetsBindingObserver {
  _Release? _release;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    if (!widget.route.popGestureInProgress) _release = null;
    return widget.builder(context, _release);
  }
}

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
    if (Theme.of(context).platform != TargetPlatform.iOS) {
      return _PredictiveBack(
        route: route,
        builder: (context, release) =>
            _ContainerTransition(route: route, release: release, child: child),
      );
    }
    // Keep the iOS edge swipe. With settled animations Cupertino's own slide
    // stays out of the way and only its gesture detector is added.
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      route,
      context,
      kAlwaysCompleteAnimation,
      kAlwaysDismissedAnimation,
      _ContainerTransition(route: route, release: null, child: child),
    );
  }
}

/// Morphs the page between the component it was opened from and the full
/// screen, fading through the page background. The page is animated from a
/// snapshot, and heroes stay grounded so the container is the only motion.
class _ContainerTransition extends StatefulWidget {
  const _ContainerTransition({
    required this.route,
    required this.release,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final _Release? release;
  final Widget child;

  @override
  State<_ContainerTransition> createState() => _ContainerTransitionState();
}

class _ContainerTransitionState extends State<_ContainerTransition> {
  static const _curve = Curves.easeOutCubic;
  static const _containerFade = Interval(0, 0.1);
  static const _contentFade = Interval(0.1, 0.45);
  static const _originRadius = BorderRadius.all(Radius.circular(12));

  final _snapshot = SnapshotController();
  WeakReference<RenderBox>? _origin;

  /// The component's rect; null grows the page from the screen center.
  Rect? _rect;

  /// Where the page was when a pop interrupted the push.
  ({double visual, double value})? _fold;

  PageRoute<dynamic> get _route => widget.route;
  Animation<double> get _animation => _route.animation!;

  @override
  void initState() {
    super.initState();
    // Built in the frame of the push, while the pressed component is still
    // laid out on the previous page.
    final box = TapOrigin.take();
    if (box != null) _origin = WeakReference(box);
    _rect = _locate();
    _animation.addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _animation.removeStatusListener(_onStatus);
    _snapshot.dispose();
    super.dispose();
  }

  Rect? _locate() {
    final box = _origin?.target;
    final navigator = _route.navigator;
    return box == null || navigator == null ? null : _rectIn(navigator, box);
  }

  void _onStatus(AnimationStatus status) {
    if (!status.isAnimating) return;
    // Pops and gestures leave the completed state: aim at where the component
    // is now, since the list behind the page may have scrolled.
    _rect = _locate() ?? _rect;
    final value = _animation.value;
    _fold =
        status == AnimationStatus.reverse &&
            !_route.popGestureInProgress &&
            value < 1
        ? (visual: _curve.transform(value), value: value)
        : null;
  }

  /// 0 is the component, 1 the full page.
  double get _progress {
    final value = _animation.value;
    final release = widget.release;
    if (release != null) {
      final from = release.value;
      if (release.commit) return from * (1 - _curve.transform(1 - value));
      if (from >= 1) return 1;
      final t = ((value - from) / (1 - from)).clamp(0.0, 1.0);
      return from + (1 - from) * _curve.transform(t);
    }
    // The finger drives the page directly.
    if (_route.popGestureInProgress) return value;
    final fold = _fold;
    if (fold != null) {
      return fold.visual * (1 - _curve.transform(1 - value / fold.value));
    }
    return _animation.status == AnimationStatus.reverse
        ? 1 - _curve.transform(1 - value)
        : _curve.transform(value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final progress = reduceMotion ? 1.0 : _progress;
    _snapshot.allowSnapshotting = !reduceMotion && _animation.isAnimating;
    final surfaceOpacity = 1 - _contentFade.transform(progress);
    final fullRadius =
        MediaQuery.displayCornerRadiiOf(context) ?? BorderRadius.zero;
    final background = Theme.of(context).scaffoldBackgroundColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        final window = Offset.zero & constraints.biggest;
        final origin =
            _rect ??
            Rect.fromCenter(
              center: window.center,
              width: window.width * 0.85,
              height: window.height * 0.85,
            );
        return Stack(
          children: [
            Positioned.fromRect(
              rect: Rect.lerp(origin, window, progress)!,
              child: ClipRRect(
                borderRadius: BorderRadius.lerp(
                  _originRadius,
                  fullRadius,
                  progress,
                )!,
                // A settled page must not keep a clip layer while scrolling.
                clipBehavior: progress < 1 ? Clip.antiAlias : Clip.none,
                child: Opacity(
                  opacity: _containerFade.transform(progress),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FittedBox(
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        child: SizedBox.fromSize(
                          size: window.size,
                          child: SnapshotWidget(
                            controller: _snapshot,
                            mode: SnapshotMode.permissive,
                            autoresize: true,
                            child: HeroMode(
                              enabled: false,
                              child: _PageMotion(
                                route: _route,
                                child: widget.child,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (surfaceOpacity > 0)
                        Opacity(
                          opacity: surfaceOpacity,
                          child: ColoredBox(color: background),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
