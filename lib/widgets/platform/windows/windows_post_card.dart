import 'package:flutter/material.dart';

const double kCardRadius = 10.0;
const double kTagRadius = 4.0;

Widget buildTag(String text, {Color? backgroundColor}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
    decoration: BoxDecoration(
      color: backgroundColor ?? Colors.black54,
      borderRadius: BorderRadius.circular(kTagRadius),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class WindowsCard extends StatelessWidget {
  final Map data;
  final String tagText;
  final String? scoreText;
  final Object heroTag;
  final Widget image;

  const WindowsCard({
    required this.data,
    required this.tagText,
    required this.scoreText,
    required this.heroTag,
    required this.image,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final title = data['title']?.toString() ?? '';
    final subtitle = data['subtitle']?.toString() ?? '';

    return AspectRatio(
      aspectRatio: 2 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kCardRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: heroTag,
              child: image,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (scoreText != null)
              Positioned(
                right: 6,
                top: 6,
                child: buildTag(
                  scoreText!,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
                ),
              ),
            if (tagText.isNotEmpty)
              Positioned(
                left: 6,
                top: 6,
                child: buildTag(tagText),
              ),
          ],
        ),
      ),
    );
  }
}
