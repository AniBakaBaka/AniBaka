import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Reuse the card's decoded cover until the route enables the desktop backdrop.
class AnimeDetailBackground extends StatelessWidget {
  const AnimeDetailBackground({
    required this.coverUrl,
    required this.backgroundUrl,
    required this.loadBackground,
    required this.cacheWidth,
    super.key,
  });

  final String coverUrl;
  final String backgroundUrl;
  final bool loadBackground;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final url = loadBackground && backgroundUrl.isNotEmpty
        ? backgroundUrl
        : coverUrl;
    if (url.isEmpty) return const SizedBox.shrink();

    return RepaintBoundary(
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          loadBackground ? cacheWidth : 300,
          null,
          CachedNetworkImageProvider(url),
        ),
        gaplessPlayback: true,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stack) =>
            loadBackground && url != coverUrl && coverUrl.isNotEmpty
            ? AnimeDetailBackground(
                coverUrl: coverUrl,
                backgroundUrl: '',
                loadBackground: false,
                cacheWidth: 300,
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
