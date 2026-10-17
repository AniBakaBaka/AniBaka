import 'package:flutter/material.dart';

import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/widgets/player/settings_panel.dart';

class DanmakuSettingsPage extends StatefulWidget {
  const DanmakuSettingsPage({
    required this.controller,
    this.defaultTitle,
    this.defaultEpisode,
    super.key,
  });

  final DanmakuController controller;
  final String? defaultTitle;
  final int? defaultEpisode;

  static Future<void> show(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
  }) => showPlayerSettingsPanel(
    context,
    DanmakuSettingsPage(
      controller: controller,
      defaultTitle: defaultTitle,
      defaultEpisode: defaultEpisode,
    ),
  );

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  final _word = TextEditingController();

  DanmakuController get _controller => widget.controller;

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  Future<void> _save() => DanmakuController.saveSettings(_controller);

  void _update(DanmakuOption option, {bool persist = false}) {
    setState(() => _controller.updateOption(option));
    if (persist) _save();
  }

  void _addWord() {
    final word = _word.text.trim();
    _word.clear();
    if (word.isEmpty) return;
    setState(() => _controller.addBlockWord(word));
    _save();
  }

  void _reset() {
    setState(
      () => _controller
        ..updateOption(DanmakuOption(fontSize: DanmakuOption.defaultFontSize))
        ..blockWords = const []
        ..blockRepeat = false
        ..blockColor = false,
    );
    _save();
    showSnackBar('已恢复默认设置');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final gap = SizedBox(height: isCompactPlayerPanel(context) ? 12 : 24);
    final o = _controller.option;
    Widget slider(
      String title,
      double value,
      String label,
      double min,
      double max,
      int divisions,
      DanmakuOption Function(double value) change,
    ) => PanelSliderTile(
      title: title,
      value: value,
      valueLabel: label,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: (v) => _update(change(v)),
      onChangeEnd: (_) => _save(),
    );

    return PanelContainer(
      title: '弹幕设置',
      child: ListView(
        padding: playerPanelContentPadding(context),
        children: [
          const PanelSectionTitle('弹幕匹配'),
          FilledButton.tonal(
            onPressed: () => DanmakuListSheet.show(
              context,
              _controller,
              defaultTitle: widget.defaultTitle,
              defaultEpisode: widget.defaultEpisode,
              initialShowSearch: true,
            ),
            child: const Row(
              children: [
                Icon(Icons.search_rounded),
                SizedBox(width: 12),
                Expanded(child: Text('搜索弹幕')),
                Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
          gap,
          const PanelSectionTitle('弹幕类型'),
          SegmentedButton<int>(
            multiSelectionEnabled: true,
            emptySelectionAllowed: true,
            expandedInsets: EdgeInsets.zero,
            segments: const [
              ButtonSegment(value: 0, label: Text('滚动')),
              ButtonSegment(value: 1, label: Text('顶部')),
              ButtonSegment(value: 2, label: Text('底部')),
            ],
            selected: {
              if (!o.hideScroll) 0,
              if (!o.hideTop) 1,
              if (!o.hideBottom) 2,
            },
            onSelectionChanged: (shown) => _update(
              o.copyWith(
                hideScroll: !shown.contains(0),
                hideTop: !shown.contains(1),
                hideBottom: !shown.contains(2),
              ),
              persist: true,
            ),
          ),
          gap,
          const PanelSectionTitle('弹幕外观'),
          PanelSettingsGroup(
            children: [
              slider(
                '显示区域',
                o.area,
                '${(o.area * 100).round()}%',
                .1,
                1,
                9,
                (v) => o.copyWith(area: v),
              ),
              const PanelDivider(),
              slider(
                '透明度',
                o.opacity,
                '${(o.opacity * 100).round()}%',
                .1,
                1,
                9,
                (v) => o.copyWith(opacity: v),
              ),
              const PanelDivider(),
              slider(
                '字体大小',
                o.fontSize,
                '${o.fontSize.round()}',
                12,
                36,
                12,
                (v) => o.copyWith(fontSize: v),
              ),
              const PanelDivider(),
              slider(
                '弹幕速度',
                20 - o.duration,
                '${o.duration.toStringAsFixed(1)}s',
                5,
                15,
                10,
                (v) => o.copyWith(duration: 20 - v),
              ),
              const PanelDivider(),
              slider(
                '描边宽度',
                o.strokeWidth,
                o.strokeWidth.toStringAsFixed(1),
                0,
                5,
                10,
                (v) => o.copyWith(strokeWidth: v),
              ),
              const PanelDivider(),
              PanelSelectTile(
                title: '字体',
                value: o.fontFamily,
                options: AppFonts.fontOptions,
                onChanged: (v) =>
                    _update(o.copyWith(fontFamily: v), persist: true),
              ),
            ],
          ),
          gap,
          const PanelSectionTitle('屏蔽管理'),
          PanelSwitchTile(
            title: '屏蔽重复弹幕',
            value: _controller.blockRepeat,
            onChanged: (v) {
              setState(() => _controller.blockRepeat = v);
              _save();
            },
          ),
          PanelSwitchTile(
            title: '屏蔽彩色弹幕',
            value: _controller.blockColor,
            onChanged: (v) {
              setState(() => _controller.blockColor = v);
              _save();
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _word,
            onSubmitted: (_) => _addWord(),
            decoration: InputDecoration(
              hintText: '输入关键词屏蔽',
              hintStyle: const TextStyle(color: Colors.white70),
              filled: true,
              fillColor: colors.secondaryContainer.withValues(alpha: .66),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(28)),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                tooltip: '添加屏蔽词',
                onPressed: _addWord,
                icon: const Icon(Icons.add_rounded),
              ),
            ),
          ),
          if (_controller.blockWords.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final word in _controller.blockWords)
                  InputChip(
                    label: Text(word),
                    deleteButtonTooltipMessage: '移除屏蔽词',
                    onDeleted: () {
                      setState(() => _controller.removeBlockWord(word));
                      _save();
                    },
                  ),
              ],
            ),
          ],
          gap,
          PanelResetButton(onPressed: _reset),
        ],
      ),
    );
  }
}
