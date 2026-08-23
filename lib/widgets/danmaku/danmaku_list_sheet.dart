import 'package:baka/api/bgm.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/material.dart';

/// 居中对话框形态展示的弹幕来源与检索面板
class DanmakuListSheet extends StatefulWidget {
  final DanmakuController controller;
  final String? defaultTitle;
  final int? defaultEpisode;
  final bool initialShowSearch;
  final ValueChanged<List<DanmakuItem>>? onDanmakuLoaded;

  const DanmakuListSheet({
    required this.controller,
    this.defaultTitle,
    this.defaultEpisode,
    this.initialShowSearch = false,
    this.onDanmakuLoaded,
    super.key,
  });

  static Future<void> show(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
    bool initialShowSearch = false,
    ValueChanged<List<DanmakuItem>>? onDanmakuLoaded,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: DanmakuListSheet(
            controller: controller,
            defaultTitle: defaultTitle,
            defaultEpisode: defaultEpisode,
            initialShowSearch: initialShowSearch,
            onDanmakuLoaded: onDanmakuLoaded,
          ),
        ),
      ),
    );
  }

  @override
  State<DanmakuListSheet> createState() => _DanmakuListSheetState();
}

class _DanmakuListSheetState extends State<DanmakuListSheet> {
  late bool _showSearch;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _isSearching = false;
  List<BgmSubjectInfo> _searchResults = [];
  String? _searchError;

  BgmSubjectInfo? _selectedSubject;
  final Map<int, List<int>> _episodesCache = {};
  final Set<int> _loadingEpisodesSet = {};
  int? _loadingEpIndex;

  late double _timeOffset;

  @override
  void initState() {
    super.initState();
    _showSearch = widget.initialShowSearch;
    _timeOffset = widget.controller.timeOffset;
    final initial = widget.defaultTitle?.trim() ?? '';
    if (initial.isNotEmpty) {
      _searchController.text = initial;
      if (_showSearch) {
        _doSearch(initial);
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String keyword) async {
    final clean = keyword.trim();
    if (clean.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchError = null;
      _searchResults = [];
      _selectedSubject = null;
    });

    try {
      final results = await BgmService.searchSubjects(clean);
      if (!mounted) return;

      setState(() {
        _searchResults = results;
        _isSearching = false;
        if (results.isEmpty) {
          _searchError = '未找到相关番剧';
        } else {
          _selectSubject(results.first);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _searchError = '搜索失败: $e';
        });
      }
    }
  }

  Future<void> _selectSubject(BgmSubjectInfo subject) async {
    setState(() => _selectedSubject = subject);

    final subjectId = subject.subjectId;
    if (_episodesCache.containsKey(subjectId)) return;

    setState(() => _loadingEpisodesSet.add(subjectId));

    try {
      final rawEpisodes = await getBgmEpisodes(subjectId);
      final epNumbers = <int>[
        for (final raw in rawEpisodes)
          if ((raw['sort'] as num).toDouble() > 0) (raw['sort'] as num).round(),
      ];

      if (mounted) {
        setState(() {
          _episodesCache[subjectId] = epNumbers;
          _loadingEpisodesSet.remove(subjectId);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _episodesCache[subjectId] = const [];
          _loadingEpisodesSet.remove(subjectId);
          _searchError = '剧集加载失败';
        });
      }
    }
  }

  Future<void> _loadDanmaku(BgmSubjectInfo subject, int epIndex) async {
    setState(() => _loadingEpIndex = epIndex);

    try {
      final items = await DanmakuService.fetch(
        subjectId: subject.subjectId,
        episodeIndex: epIndex,
        titles: subject.searchTitles,
      );

      if (!mounted) return;

      widget.controller.reset();
      if (items.isNotEmpty) {
        widget.controller.setItems(items);
      }
      widget.onDanmakuLoaded?.call(items);

      final title = subject.nameCn ?? subject.name ?? '动画';

      showSnackBar(
        items.isNotEmpty
            ? '已关联《$title》第 $epIndex 话 (${items.length} 条弹幕)'
            : '已关联《$title》第 $epIndex 话 (无弹幕)',
      );

      setState(() {
        _loadingEpIndex = null;
        _showSearch = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingEpIndex = null);
        showSnackBar('关联失败: $e');
      }
    }
  }

  void _adjustOffset(double delta) {
    final next = double.parse((_timeOffset + delta).toStringAsFixed(1));
    setState(() => _timeOffset = next);
    widget.controller.setTimeOffset(next);
  }

  void _resetOffset() {
    setState(() => _timeOffset = 0.0);
    widget.controller.setTimeOffset(0.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primaryColor = colorScheme.primary;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final count = widget.controller.items.length;
        const providerName = 'dandanplay';
        final animeTitle = widget.defaultTitle?.trim();

        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 20,
                spreadRadius: -2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.subtitles_rounded,
                        color: primaryColor,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '弹幕管理',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const Spacer(),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.of(context).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 32,
                        decoration: BoxDecoration(
                          color: primaryColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '来源: $providerName',
                                  style: TextStyle(
                                    color: colorScheme.onSurface,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryColor.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '自建服务器获取',
                                    style: TextStyle(
                                      color: primaryColor,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: primaryColor.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '$count 条弹幕',
                                    style: TextStyle(
                                      color: primaryColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${animeTitle != null && animeTitle.isNotEmpty ? "《$animeTitle》 " : ""}${widget.defaultEpisode != null ? "第 ${widget.defaultEpisode} 话" : "未指定集数"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                Row(
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          _showSearch = !_showSearch;
                          if (_showSearch &&
                              _searchResults.isEmpty &&
                              _searchController.text.isNotEmpty) {
                            _doSearch(_searchController.text);
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _showSearch
                              ? primaryColor.withValues(alpha: 0.12)
                              : colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _showSearch
                                ? primaryColor
                                : primaryColor.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _showSearch
                                  ? Icons.close_rounded
                                  : Icons.search_rounded,
                              size: 14,
                              color: primaryColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _showSearch ? '收起检索' : '手动检索',
                              style: TextStyle(
                                color: primaryColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Text(
                          '延迟: ',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha: 0.7),
                            fontSize: 10,
                          ),
                        ),
                        if (_timeOffset != 0.0)
                          Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Text(
                              '${_timeOffset > 0 ? "+$_timeOffset" : "$_timeOffset"}s',
                              style: TextStyle(
                                color: primaryColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        _buildOffsetPill(
                          '-0.5s',
                          () => _adjustOffset(-0.5),
                          colorScheme,
                          primaryColor,
                        ),
                        _buildOffsetPill(
                          '重置',
                          _resetOffset,
                          colorScheme,
                          primaryColor,
                          isReset: true,
                        ),
                        _buildOffsetPill(
                          '+0.5s',
                          () => _adjustOffset(0.5),
                          colorScheme,
                          primaryColor,
                        ),
                      ],
                    ),
                  ],
                ),

                if (_showSearch) ...[
                  const SizedBox(height: 10),
                  _buildSearchPanel(colorScheme, primaryColor),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchPanel(ColorScheme colors, Color primaryColor) {
    final epNumbers = _selectedSubject != null
        ? (_episodesCache[_selectedSubject!.subjectId] ?? const [])
        : const <int>[];
    final isLoadingEps =
        _selectedSubject != null &&
        _loadingEpisodesSet.contains(_selectedSubject!.subjectId);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: primaryColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _searchFocusNode.hasFocus
                          ? primaryColor
                          : colors.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        color: primaryColor.withValues(alpha: 0.7),
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: 11,
                          ),
                          decoration: InputDecoration(
                            hintText: '输入番剧名称搜索...',
                            hintStyle: TextStyle(
                              color: colors.onSurface.withValues(alpha: 0.4),
                              fontSize: 11,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: _doSearch,
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() {});
                          },
                          child: Icon(
                            Icons.cancel,
                            size: 13,
                            color: colors.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                height: 32,
                child: FilledButton(
                  onPressed: _isSearching
                      ? null
                      : () => _doSearch(_searchController.text),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: _isSearching
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '检索',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),

          if (_searchError != null) ...[
            const SizedBox(height: 6),
            Text(
              _searchError!,
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
            ),
          ],

          if (_searchResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 24,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: _searchResults.length,
                itemBuilder: (context, index) {
                  final item = _searchResults[index];
                  final isSelected =
                      _selectedSubject?.subjectId == item.subjectId;
                  final title = item.nameCn ?? item.name ?? '未知';

                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      onTap: () => _selectSubject(item),
                      borderRadius: BorderRadius.circular(4),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? primaryColor.withValues(alpha: 0.15)
                              : colors.surface,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: isSelected
                                ? primaryColor
                                : colors.outlineVariant.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected ? primaryColor : colors.onSurface,
                            fontSize: 10,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],

          if (_selectedSubject != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '选择集数',
                  style: TextStyle(
                    color: colors.onSurface.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (isLoadingEps)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: primaryColor,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 26,
              child: epNumbers.isEmpty && !isLoadingEps
                  ? Text(
                      '暂无集数信息',
                      style: TextStyle(
                        color: colors.onSurface.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      itemCount: epNumbers.length,
                      itemBuilder: (ctx, index) {
                        final epNum = epNumbers[index];
                        final isCurrent = widget.defaultEpisode == epNum;
                        final isLoadingThis = _loadingEpIndex == epNum;

                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: () => _loadDanmaku(_selectedSubject!, epNum),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? primaryColor
                                    : colors.surface,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isCurrent
                                      ? primaryColor
                                      : colors.outlineVariant.withValues(
                                          alpha: 0.3,
                                        ),
                                ),
                              ),
                              child: isLoadingThis
                                  ? SizedBox(
                                      width: 10,
                                      height: 10,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: isCurrent
                                            ? colors.onPrimary
                                            : primaryColor,
                                      ),
                                    )
                                  : Text(
                                      'E$epNum',
                                      style: TextStyle(
                                        color: isCurrent
                                            ? colors.onPrimary
                                            : colors.onSurface,
                                        fontSize: 10,
                                        fontWeight: isCurrent
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                      ),
                                    ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOffsetPill(
    String label,
    VoidCallback onTap,
    ColorScheme colors,
    Color primaryColor, {
    bool isReset = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
          decoration: BoxDecoration(
            color: isReset
                ? colors.surface
                : primaryColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isReset
                  ? colors.outlineVariant.withValues(alpha: 0.3)
                  : primaryColor.withValues(alpha: 0.2),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isReset
                  ? colors.onSurface.withValues(alpha: 0.7)
                  : primaryColor,
              fontSize: 9.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
