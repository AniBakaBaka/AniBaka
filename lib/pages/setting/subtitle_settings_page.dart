import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';

export 'package:baka/models/subtitle_config.dart';

final _subtitleFontOptions = SubtitleConfig.availableFonts
    .map(
      (font) =>
          SelectionOption<String>(value: font['value']!, label: font['name']!),
    )
    .toList(growable: false);

final _subtitleFontLabels = {
  for (final font in SubtitleConfig.availableFonts)
    font['value']!: font['name']!,
};

const _subtitleColors = <Color>[
  Colors.white,
  Colors.black,
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFFFF0000),
  Color(0xFFFF69B4),
  Color(0xFFFFA500),
  Color(0xFF8B5CF6),
  Color(0xFF3B82F6),
];

class SubtitleSettingsPage extends StatefulWidget {
  final PlaybackController controller;

  const SubtitleSettingsPage({required this.controller, super.key});

  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) async {
    return showPlayerSettingsPanel(
      context,
      SubtitleSettingsPage(controller: controller),
    );
  }

  @override
  State<SubtitleSettingsPage> createState() => _SubtitleSettingsPageState();
}

class _SubtitleSettingsPageState extends State<SubtitleSettingsPage> {
  late SubtitleConfig _config;
  bool _isAdvancedExpanded = false;

  late List<SubtitleTrack> _subtitleTracks;
  SubtitleTrack? _currentTrack;

  @override
  void initState() {
    super.initState();
    _config = widget.controller.preferences.value.subtitleConfig;
    _subtitleTracks = widget.controller.subtitleTracks
        .where((track) => track.id != 'auto' && track.id != 'no')
        .toList(growable: false);
    _currentTrack = widget.controller.currentSubtitleTrack;
  }

  void _updateConfig(
    SubtitleConfig newConfig, {
    bool apply = true,
    bool persist = false,
  }) {
    setState(() => _config = newConfig);
    if (apply) {
      widget.controller.updateSubtitleConfig(newConfig, persist: persist);
    }
  }

  void _persistConfig() =>
      widget.controller.updateSubtitleConfig(_config, persist: true);

  void _resetSettings() {
    _updateConfig(const SubtitleConfig(), persist: true);
    showSnackBar('已恢复默认字幕设置');
  }

  void _selectTrack(SubtitleTrack track) async {
    await widget.controller.setSubtitleTrack(track);
    if (mounted) setState(() => _currentTrack = track);
  }

  Future<void> _selectFont() async {
    final font = await showAppSelectionDialog<String>(
      context,
      title: '选择字体',
      options: _subtitleFontOptions,
      currentValue: _config.fontFamily,
    );
    if (font != null && font != _config.fontFamily) {
      _updateConfig(_config.copyWith(fontFamily: font), persist: true);
    }
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
                const PanelSectionTitle('字幕轨道'),
                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    if (_subtitleTracks.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        child: Text(
                          '当前视频无内嵌字幕轨道',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      )
                    else ...[
                      _buildTrackTile(
                        label: '关闭字幕',
                        isSelected: _currentTrack?.id == 'no',
                        onTap: () => _selectTrack(SubtitleTrack.no()),
                        primaryColor: primaryColor,
                      ),
                      ..._subtitleTracks.map((track) {
                        final label = _buildTrackLabel(track);
                        return Column(
                          children: [
                            const PanelDivider(),
                            _buildTrackTile(
                              label: label,
                              isSelected: _currentTrack?.id == track.id,
                              onTap: () => _selectTrack(track),
                              primaryColor: primaryColor,
                            ),
                          ],
                        );
                      }),
                    ],
                  ],
                ),

                const SizedBox(height: 24),

                const PanelSectionTitle('字幕外观'),
                PanelSettingsGroup(
                  backgroundColor: cardColor,
                  children: [
                    _buildFontPicker(),
                    const PanelDivider(),
                    PanelSliderTile(
                      title: '字体大小',
                      value: _config.fontSize,
                      valueLabel: '${_config.fontSize.round()}',
                      min: 12,
                      max: 60,
                      divisions: 24,
                      onChanged: (v) => _updateConfig(
                        _config.copyWith(fontSize: v),
                        apply: false,
                      ),
                      onChangeEnd: (_) => _persistConfig(),
                    ),
                    const PanelDivider(),
                    PanelSliderTile(
                      title: '字幕位置',
                      value: _config.position,
                      valueLabel: '${_config.position.round()}%',
                      min: 0,
                      max: 100,
                      divisions: 20,
                      onChanged: (v) => _updateConfig(
                        _config.copyWith(position: v),
                        apply: false,
                      ),
                      onChangeEnd: (_) => _persistConfig(),
                    ),
                    const PanelDivider(),
                    PanelSliderTile(
                      title: '透明度',
                      value: _config.opacity,
                      valueLabel: '${(_config.opacity * 100).round()}%',
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: (v) => _updateConfig(
                        _config.copyWith(opacity: v),
                        apply: false,
                      ),
                      onChangeEnd: (_) => _persistConfig(),
                    ),
                    if (_isAdvancedExpanded) ...[
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '描边宽度',
                        value: _config.borderWidth,
                        valueLabel: _config.borderWidth.toStringAsFixed(1),
                        min: 0,
                        max: 6,
                        divisions: 12,
                        onChanged: (v) => _updateConfig(
                          _config.copyWith(borderWidth: v),
                          apply: false,
                        ),
                        onChangeEnd: (_) => _persistConfig(),
                      ),
                      const PanelDivider(),
                      PanelSwitchTile(
                        title: '粗体',
                        value: _config.bold,
                        onChanged: (value) => _updateConfig(
                          _config.copyWith(bold: value),
                          persist: true,
                        ),
                      ),
                      const PanelDivider(),
                      _buildColorPicker(
                        title: '字体颜色',
                        currentColor: _config.fontColor,
                        onSelect: (c) => _updateConfig(
                          _config.copyWith(fontColor: c),
                          persist: true,
                        ),
                        primaryColor: primaryColor,
                      ),
                      const PanelDivider(),
                      _buildColorPicker(
                        title: '描边颜色',
                        currentColor: _config.borderColor,
                        onSelect: (c) => _updateConfig(
                          _config.copyWith(borderColor: c),
                          persist: true,
                        ),
                        primaryColor: primaryColor,
                      ),
                      const PanelDivider(),
                      _buildColorPicker(
                        title: '背景颜色',
                        currentColor: _config.backgroundColor,
                        onSelect: (c) => _updateConfig(
                          _config.copyWith(backgroundColor: c),
                          persist: true,
                        ),
                        primaryColor: primaryColor,
                        includeTransparent: true,
                      ),
                    ],
                    const PanelDivider(),
                    PanelExpandToggle(
                      isExpanded: _isAdvancedExpanded,
                      onTap: () => setState(
                        () => _isAdvancedExpanded = !_isAdvancedExpanded,
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

  String _buildTrackLabel(SubtitleTrack track) {
    final parts = <String>[];
    if (track.title != null && track.title!.isNotEmpty) {
      parts.add(track.title!);
    }
    if (track.language != null && track.language!.isNotEmpty) {
      parts.add('[${track.language}]');
    }
    if (parts.isEmpty) {
      parts.add('轨道 ${track.id}');
    }
    return parts.join(' ');
  }

  Widget _buildTrackTile({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required Color primaryColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? primaryColor : Colors.white,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isSelected)
              Icon(Icons.check_rounded, color: primaryColor, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildFontPicker() {
    final currentLabel =
        _subtitleFontLabels[_config.fontFamily] ??
        _subtitleFontOptions.first.label;

    return InkWell(
      onTap: _selectFont,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '字体',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              currentLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorPicker({
    required String title,
    required Color currentColor,
    required ValueChanged<Color> onSelect,
    required Color primaryColor,
    bool includeTransparent = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in <Color>[
                if (includeTransparent) Colors.transparent,
                ..._subtitleColors,
              ])
                _buildColorChoice(color, currentColor, primaryColor, onSelect),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildColorChoice(
    Color color,
    Color currentColor,
    Color primaryColor,
    ValueChanged<Color> onSelect,
  ) {
    final isSelected = currentColor == color;
    final isTransparent = color == Colors.transparent;
    return GestureDetector(
      onTap: () => onSelect(color),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: isTransparent ? null : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected
                ? primaryColor
                : Colors.white.withValues(alpha: 0.3),
            width: isSelected ? 2.5 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.4),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: isTransparent
            ? const CustomPaint(painter: _DiagonalLinePainter())
            : null,
      ),
    );
  }
}

class _DiagonalLinePainter extends CustomPainter {
  const _DiagonalLinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x80FFFFFF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.8),
      Offset(size.width * 0.8, size.height * 0.2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
