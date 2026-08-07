import 'package:flutter/material.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';


class DanmakuSettingsPage extends StatefulWidget {
  final DanmakuController controller;
  final String? defaultTitle;
  final int? defaultEpisode;

  const DanmakuSettingsPage({
    required this.controller,
    this.defaultTitle,
    this.defaultEpisode,
    super.key,
  });

  static Future<void> show(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
  }) async {
    await showPlayerSettingsPanel(
      context,
      DanmakuSettingsPage(
        controller: controller,
        defaultTitle: defaultTitle,
        defaultEpisode: defaultEpisode,
      ),
    );
  }


  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  late DanmakuOption _option;
  late List<String> _blockWords;
  late bool _blockRepeat;
  late bool _blockColor;
  bool _isAppearanceExpanded = false;

  final TextEditingController _wordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _option = widget.controller.option;
    _blockWords = List<String>.from(widget.controller.blockWords);
    _blockRepeat = widget.controller.blockRepeat;
    _blockColor = widget.controller.blockColor;
  }

  @override
  void dispose() {
    _wordController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings({bool applyOption = false}) {
    if (applyOption) widget.controller.updateOption(_option);
    widget.controller.blockWords = List<String>.unmodifiable(_blockWords);
    widget.controller.blockRepeat = _blockRepeat;
    widget.controller.blockColor = _blockColor;
    return DanmakuService.saveSettings(
      _option,
      blockWords: _blockWords,
      blockRepeat: _blockRepeat,
      blockColor: _blockColor,
    );
  }

  void _updateOption(
    DanmakuOption newOpt, {
    bool apply = true,
    bool persist = false,
  }) {
    setState(() => _option = newOpt);
    if (apply) widget.controller.updateOption(newOpt);
    if (persist) _saveSettings();
  }

  void _resetSettings() {
    final option = DanmakuOption(fontSize: DanmakuOption.defaultFontSize);
    setState(() {
      _option = option;
      _blockWords.clear();
      _blockRepeat = false;
      _blockColor = false;
    });
    widget.controller.updateOption(option);
    _saveSettings();
    showSnackBar('已恢复默认设置');
  }

  void _addBlockWord(String word) {
    final t = word.trim();
    if (t.isEmpty || _blockWords.contains(t)) return;
    setState(() => _blockWords.add(t));
    _saveSettings();
  }

  void _removeBlockWord(String word) {
    setState(() => _blockWords.remove(word));
    _saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final cardColor = Colors.white.withValues(alpha: 0.05);

    return PanelContainer(
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const PanelSectionTitle('弹幕匹配'),
                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          NavigationService.showDanmakuSearch(
                            context,
                            widget.controller,
                            defaultTitle: widget.defaultTitle,
                            defaultEpisode: widget.defaultEpisode,
                          );
                        },

                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: primaryColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.manage_search_rounded,
                                  color: primaryColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '手动弹幕检索',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      '弹幕匹配不准？手动检索并绑定弹幕库',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white38,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                const PanelSectionTitle('弹幕外观'),

                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    PanelSliderTile(
                      title: '显示区域',
                      value: _option.area,
                      valueLabel: '${(_option.area * 100).round()}%',
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: (v) => _updateOption(
                        _option.copyWith(area: v),
                        apply: false,
                      ),
                      onChangeEnd: (_) => _saveSettings(applyOption: true),
                    ),
                    const PanelDivider(),
                    PanelSliderTile(
                      title: '透明度',
                      value: _option.opacity,
                      valueLabel: '${(_option.opacity * 100).round()}%',
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: (v) => _updateOption(
                        _option.copyWith(opacity: v),
                        apply: false,
                      ),
                      onChangeEnd: (_) => _saveSettings(applyOption: true),
                    ),
                    if (_isAppearanceExpanded) ...[
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '字体大小',
                        value: _option.fontSize,
                        valueLabel: '${_option.fontSize.round()}',
                        min: 12,
                        max: 36,
                        divisions: 12,
                        onChanged: (v) => _updateOption(
                          _option.copyWith(fontSize: v),
                          apply: false,
                        ),
                        onChangeEnd: (_) => _saveSettings(applyOption: true),
                      ),
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '描边宽度',
                        value: _option.strokeWidth,
                        valueLabel: _option.strokeWidth.toStringAsFixed(1),
                        min: 0,
                        max: 5,
                        divisions: 10,
                        onChanged: (v) => _updateOption(
                          _option.copyWith(strokeWidth: v),
                          apply: false,
                        ),
                        onChangeEnd: (_) => _saveSettings(applyOption: true),
                      ),
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '弹幕速度',
                        value: 20.0 - _option.duration,
                        valueLabel: '${_option.duration.toStringAsFixed(1)}s',
                        min: 5.0,
                        max: 15.0,
                        divisions: 10,
                        onChanged: (v) => _updateOption(
                          _option.copyWith(duration: 20.0 - v),
                          apply: false,
                        ),
                        onChangeEnd: (_) => _saveSettings(applyOption: true),
                      ),
                    ],
                    const PanelDivider(),
                    PanelExpandToggle(
                      isExpanded: _isAppearanceExpanded,
                      onTap: () => setState(
                        () => _isAppearanceExpanded = !_isAppearanceExpanded,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                const PanelSectionTitle('弹幕类型'),
                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '显示设置',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 16),
                          GridView.count(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 0.82,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: [
                              _buildTypeToggleBtn(
                                icon: Icons.arrow_forward_rounded,
                                label: '滚动',
                                isActive: !_option.hideScroll,
                                activeColor: primaryColor,
                                onTap: () => _updateOption(
                                  _option.copyWith(
                                    hideScroll: !_option.hideScroll,
                                  ),
                                  persist: true,
                                ),
                              ),
                              _buildTypeToggleBtn(
                                icon: Icons.vertical_align_top_rounded,
                                label: '顶部',
                                isActive: !_option.hideTop,
                                activeColor: primaryColor,
                                onTap: () => _updateOption(
                                  _option.copyWith(hideTop: !_option.hideTop),
                                  persist: true,
                                ),
                              ),
                              _buildTypeToggleBtn(
                                icon: Icons.vertical_align_bottom_rounded,
                                label: '底部',
                                isActive: !_option.hideBottom,
                                activeColor: primaryColor,
                                onTap: () => _updateOption(
                                  _option.copyWith(
                                    hideBottom: !_option.hideBottom,
                                  ),
                                  persist: true,
                                ),
                              ),
                              _buildTypeToggleBtn(
                                icon: Icons.filter_list_rounded,
                                label: '去重',
                                isActive: _blockRepeat,
                                activeColor: primaryColor,
                                onTap: () {
                                  setState(() => _blockRepeat = !_blockRepeat);
                                  _saveSettings();
                                },
                              ),
                              _buildTypeToggleBtn(
                                icon: Icons.palette_outlined,
                                label: '屏蔽彩色',
                                isActive: _blockColor,
                                activeColor: primaryColor,
                                onTap: () {
                                  setState(() => _blockColor = !_blockColor);
                                  _saveSettings();
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                const PanelSectionTitle('屏蔽管理'),
                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color:
                                        theme.inputDecorationTheme.fillColor ??
                                        Colors.black.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: TextField(
                                    controller: _wordController,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '输入关键词屏蔽',
                                      hintStyle: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.7,
                                        ),
                                        fontSize: 13,
                                      ),
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 10,
                                          ),
                                      isDense: true,
                                    ),
                                    onSubmitted: (t) {
                                      _addBlockWord(t);
                                      _wordController.clear();
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () {
                                  _addBlockWord(_wordController.text);
                                  _wordController.clear();
                                },
                                style: FilledButton.styleFrom(
                                  backgroundColor: primaryColor,
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.onPrimary,
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text('添加'),
                              ),
                            ],
                          ),
                          if (_blockWords.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _blockWords
                                    .map(
                                      (w) => InkWell(
                                        onTap: () => _removeBlockWord(w),
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(
                                              alpha: 0.1,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                w,
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              const Icon(
                                                Icons.close,
                                                size: 12,
                                                color: Colors.white54,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                PanelResetButton(onPressed: _resetSettings),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeToggleBtn({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final foreground = isActive ? activeColor : Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: isActive
                ? activeColor.withValues(alpha: 0.14)
                : theme.colorScheme.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? activeColor.withValues(alpha: 0.45)
                  : theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: foreground, size: 20),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
