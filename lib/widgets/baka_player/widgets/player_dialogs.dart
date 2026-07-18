import 'package:baka/widgets/baka_player/anime4k.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

void showSpeedDialog(BuildContext context, PlaybackController controller) {
  const speeds = [0.5, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0];
  _showSelectionDialog<double>(
    context: context,
    title: '\u500d\u901f',
    items: speeds
        .map(
          (speed) => (
            value: speed,
            label: speed.toString(),
            selected: speed == controller.core.value.playbackRate,
          ),
        )
        .toList(),
    onSelect: controller.setRate,
    actions: [
      TextButton(
        onPressed: () {
          controller.setRate(1.0);
          Navigator.pop(context);
        },
        child: const Text('\u9ed8\u8ba4\u901f\u5ea6'),
      ),
    ],
  );
}

void showVideoFitDialog(BuildContext context, PlaybackController controller) {
  _showSelectionDialog<({BoxFit fit, String description})>(
    context: context,
    title: '\u753b\u9762\u6bd4\u4f8b',
    items: PlaybackController.videoFitTypes
        .map(
          (type) => (
            value: type,
            label: type.description,
            selected: type.fit == controller.preferences.value.videoFit,
          ),
        )
        .toList(),
    onSelect: (type) {
      controller.setVideoFit(type.fit, type.description);
    },
  );
}

Future<void> showAnime4KLevelDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  final result = await showAppSelectionDialog<String>(
    context,
    title: 'Anime4K \u8d85\u5206\u8fa8\u7387\u6863\u4f4d',
    options: [
      SelectionOption(
        value: 'low',
        label: Anime4K.levelNames['low']!,
        subtitle: '\u6027\u80fd\u4f18\u5148',
      ),
      SelectionOption(
        value: 'medium',
        label: Anime4K.levelNames['medium']!,
        subtitle:
            '\u753b\u8d28\u4e0e\u6027\u80fd\u5e73\u8861\uff08\u63a8\u8350\uff09',
      ),
      SelectionOption(
        value: 'high',
        label: Anime4K.levelNames['high']!,
        subtitle: '\u53cc\u91cd\u4fee\u590d\u653e\u5927',
      ),
      SelectionOption(
        value: 'ultra',
        label: Anime4K.levelNames['ultra']!,
        subtitle: '\u6700\u9ad8\u753b\u8d28',
      ),
    ],
    currentValue: controller.preferences.value.anime4KLevel,
  );
  if (result != null) {
    try {
      await controller.switchAnime4KLevel(result);
      showSnackBar('Anime4K level: ${Anime4K.levelNames[result]}');
    } catch (error) {
      showSnackBar('Anime4K level switch failed: $error');
    }
  }
}

void _showSelectionDialog<T>({
  required BuildContext context,
  required String title,
  required List<({T value, String label, bool selected})> items,
  required void Function(T) onSelect,
  List<Widget>? actions,
}) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Wrap(
        spacing: 8,
        children: items
            .map(
              (item) => InkWell(
                onTap: () {
                  onSelect(item.value);
                  Navigator.pop(ctx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(ctx).colorScheme.primary.withValues(
                      alpha: item.selected ? 0.3 : 0.1,
                    ),
                  ),
                  child: Text(item.label),
                ),
              ),
            )
            .toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(
            '\u53d6\u6d88',
            style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
          ),
        ),
        ...?actions,
      ],
    ),
  );
}
