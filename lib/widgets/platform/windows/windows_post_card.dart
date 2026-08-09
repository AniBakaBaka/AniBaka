import 'package:flutter/material.dart';

const kCardBorderRadius = 12.0;
const kSmallBorderRadius = 5.0;
const kCardPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 10);
const kTextStyleTitle = TextStyle(
  color: Colors.white,
  fontWeight: FontWeight.w600,
  fontSize: 14,
  height: 1.2,
);

Widget buildTag(String text, {Color? backgroundColor}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: backgroundColor ?? Colors.black54,
      borderRadius: BorderRadius.circular(kSmallBorderRadius),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
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
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kCardBorderRadius),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Hero(
          tag: heroTag,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kCardBorderRadius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                _buildBottomInfo(data),
                if (scoreText != null)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: buildTag(
                      scoreText!,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.9),
                    ),
                  ),
                if (tagText.isNotEmpty)
                  Positioned(left: 6, top: 6, child: buildTag(tagText)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _buildGradientBottom({required List<Widget> children}) {
  return Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: Container(
      padding: kCardPadding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.8)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    ),
  );
}

Widget _buildBottomInfo(Map data) {
  return _buildGradientBottom(
    children: [
      Text(
        data['title'] ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: kTextStyleTitle,
      ),
      if (data['subtitle']?.isNotEmpty == true)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            data['subtitle'],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ),
    ],
  );
}
