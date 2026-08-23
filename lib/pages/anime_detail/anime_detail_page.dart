import 'package:flutter/material.dart';

import 'package:baka/instance.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/platform/tv/tv_anime_detail.dart';

/// A detail-only route that does not create playback controllers or start the
/// player data pipeline before the user explicitly chooses to watch.
class AnimeDetailPage extends StatelessWidget {
  const AnimeDetailPage({required this.data, super.key});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    return buildAnimeDetailSurface(data, isTv: Instances.isTV);
  }
}

@visibleForTesting
Widget buildAnimeDetailSurface(
  Map<String, dynamic> data, {
  required bool isTv,
}) {
  return isTv
      ? TvAnimeDetailPlaceholder(data: data)
      : AnimeDetailPlaceholder(data: data);
}
