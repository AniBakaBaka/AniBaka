import 'package:baka/app_state.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

TextStyle _fontStyle(
  String fontName, {
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? height,
  double? letterSpacing,
}) {
  if (AppFonts.isSystemFont(fontName)) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
  return GoogleFonts.getFont(
    fontName,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
}

class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({super.key});

  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  final _theme = Get.find<AppState>();
  late final ValueNotifier<double> _fontScale;

  @override
  void initState() {
    super.initState();
    _fontScale = ValueNotifier(_theme.fontScale);
  }

  @override
  void dispose() {
    _fontScale.dispose();
    super.dispose();
  }

  void _selectFont(String fontName) {
    if (_theme.fontFamily == fontName) return;
    HapticFeedback.selectionClick();
    _theme.setFontFamily(fontName);
  }

  void _setFontWeightIndex(int index) {
    if (_theme.fontWeightIndex == index) return;
    HapticFeedback.selectionClick();
    _theme.setFontWeightIndex(index);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: '字体设置'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 12),
                _buildPreviewCard(isDark),
                const SizedBox(height: 24),
                const SettingsSectionHeader('字体大小', bottomPadding: 4),
                const SizedBox(height: 8),
                _buildFontScaleSlider(isDark),
                const SizedBox(height: 20),
                const SettingsSectionHeader('字重', bottomPadding: 4),
                const SizedBox(height: 8),
                _buildFontWeightSelector(isDark),
                const SizedBox(height: 20),
                ..._buildFontCategories(isDark),
                const SizedBox(height: 24),
                _buildHintCard(isDark),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(bool isDark) {
    return Obx(() {
      final fontWeightIndex = _theme.fontWeightIndex;
      final selectedFont = _theme.fontFamily;
      final previewWeight = AppFonts.availableWeights[fontWeightIndex];
      return ValueListenableBuilder<double>(
        valueListenable: _fontScale,
        builder: (context, fontScale, _) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: ThemeColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.preview_rounded,
                      size: 18,
                      color: ThemeColors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '预览效果',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: ThemeColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      AppFonts.getLabelForFont(selectedFont),
                      style: const TextStyle(
                        fontSize: 12,
                        color: ThemeColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '命运石之门',
                style: _fontStyle(
                  selectedFont,
                  fontSize: 22.0 * fontScale,
                  fontWeight: previewWeight,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '这一切都是命运石之门的选择',
                style: _fontStyle(
                  selectedFont,
                  fontSize: 14.0 * fontScale,
                  fontWeight: previewWeight,
                  height: 1.8,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'EL PSY KONGROO Steins;Gate 1.048596%',
                style: _fontStyle(
                  selectedFont,
                  fontSize: 12.0 * fontScale,
                  fontWeight: previewWeight,
                  color: isDark ? Colors.white38 : Colors.black38,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildFontScaleSlider(bool isDark) {
    return ValueListenableBuilder<double>(
      valueListenable: _fontScale,
      builder: (context, fontScale, _) {
        final scalePercent = (fontScale * 100).round();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    'A',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black38,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: fontScale,
                      min: 0.8,
                      max: 1.30,
                      divisions: 11,
                      activeColor: ThemeColors.primary,
                      inactiveColor: isDark
                          ? Colors.white12
                          : Colors.black.withValues(alpha: 0.06),
                      onChanged: (value) => _fontScale.value = value,
                      onChangeEnd: (value) {
                        if (value != _theme.fontScale) {
                          _theme.setFontScale(value);
                        }
                      },
                    ),
                  ),
                  Text(
                    'A',
                    style: TextStyle(
                      fontSize: 20,
                      color: isDark ? Colors.white38 : Colors.black38,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$scalePercent%',
                style: const TextStyle(
                  fontSize: 13,
                  color: ThemeColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFontWeightSelector(bool isDark) {
    return Obx(
      () => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < AppFonts.availableWeights.length; i++)
              ChoiceChip(
                label: Text(
                  AppFonts.weightLabels[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: AppFonts.availableWeights[i],
                  ),
                ),
                selected: _theme.fontWeightIndex == i,
                onSelected: (_) => _setFontWeightIndex(i),
                showCheckmark: false,
                selectedColor: ThemeColors.primary,
                side: BorderSide(
                  color: isDark ? Colors.white10 : Colors.black12,
                  width: 0.5,
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFontCategories(bool isDark) {
    const categories = {
      'system': AppFonts.systemFonts,
      'sans': AppFonts.sansFonts,
      'serif': AppFonts.serifFonts,
      'handwriting': AppFonts.handwritingFonts,
      'display': AppFonts.displayFonts,
    };

    final widgets = <Widget>[];
    for (final entry in categories.entries) {
      final catLabel = AppFonts.categoryLabels[entry.key] ?? entry.key;
      final fonts = entry.value;
      widgets.add(SettingsSectionHeader(catLabel, bottomPadding: 4));
      widgets.add(const SizedBox(height: 8));
      widgets.add(
        Obx(
          () => SettingsGroup(
            children: ListTile.divideTiles(
              context: context,
              tiles: [
                for (final font in fonts)
                  ListTile(
                    selected: _theme.fontFamily == font['name'],
                    selectedColor: ThemeColors.primary,
                    leading: Icon(
                      _theme.fontFamily == font['name']
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                    ),
                    title: Text(font['label']!),
                    subtitle: Text(font['name']!),
                    trailing: Text(
                      font['preview']!,
                      style: _fontStyle(
                        font['name']!,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    onTap: () => _selectFont(font['name']!),
                  ),
              ],
            ).toList(growable: false),
          ),
        ),
      );
      widgets.add(const SizedBox(height: 20));
    }
    return widgets;
  }

  Widget _buildHintCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '字体通过 Google Fonts 在线加载，首次使用需要网络连接',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white30 : Colors.black38,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
