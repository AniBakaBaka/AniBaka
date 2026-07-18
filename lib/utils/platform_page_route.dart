import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Builds a custom route without losing iOS's interactive edge-swipe back
/// gesture.
///
/// Custom [PageRouteBuilder] transitions bypass [PageTransitionsTheme], so
/// they do not inherit the Cupertino back gesture automatically.
PageRoute<T> platformPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  Duration transitionDuration = const Duration(milliseconds: 300),
  Duration? reverseTransitionDuration,
  RouteTransitionsBuilder? transitionsBuilder,
  bool maintainState = true,
  bool fullscreenDialog = false,
  bool allowSnapshotting = true,
  bool opaque = true,
  Color? barrierColor,
  String? barrierLabel,
  bool barrierDismissible = false,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      barrierDismissible: barrierDismissible,
    );
  }

  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: transitionDuration,
    reverseTransitionDuration: reverseTransitionDuration ?? transitionDuration,
    transitionsBuilder:
        transitionsBuilder ??
        (context, animation, secondaryAnimation, child) => child,
    maintainState: maintainState,
    fullscreenDialog: fullscreenDialog,
    allowSnapshotting: allowSnapshotting,
    opaque: opaque,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    barrierDismissible: barrierDismissible,
  );
}
