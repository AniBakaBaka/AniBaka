import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class AnimeDetailBackground extends StatelessWidget {
  const AnimeDetailBackground({
    required this.url,
    required this.cacheWidth,
    super.key,
  });

  final String url;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const SizedBox.shrink();

    return RepaintBoundary(
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          cacheWidth,
          null,
          CachedNetworkImageProvider(url),
        ),
        gaplessPlayback: true,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}
