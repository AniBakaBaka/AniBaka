import 'package:baka/models/bgm.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:flutter/material.dart';

/// 弹幕来源与检索面板，可在播放器设置内进入并返回。
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
    return showPlayerSettingsPanel(
      context,
      DanmakuListSheet(
        controller: controller,
        defaultTitle: defaultTitle,
        defaultEpisode: defaultEpisode,
        initialShowSearch: initialShowSearch,
        onDanmakuLoaded: onDanmakuLoaded,
      ),
    );
  }

  @override
  State<DanmakuListSheet> createState() => _DanmakuListSheetState();
}

class _DanmakuListSheetState extends State<DanmakuListSheet> {
  final _searchController = TextEditingController();
  late bool _showSearch;
  bool _isSearching = false;
  String? _searchError;
  List<BgmInfo> _searchResults = const [];
  BgmInfo? _selectedSubject;
  Future<List<int>>? _episodes;
  (int?, int)? _loadingEpisode;
  BgmInfo? _matchedSubject;
  int? _matchedEpisode;
  int _searchRequest = 0;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _showSearch = widget.initialShowSearch;
    _searchController.text = widget.defaultTitle?.trim() ?? '';
    if (_showSearch) _doSearch(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String keyword) async {
    final clean = keyword.trim();
    if (clean.isEmpty) return;
    final request = ++_searchRequest;
    setState(() {
      _isSearching = true;
      _searchError = null;
      _searchResults = const [];
      _selectedSubject = null;
      _episodes = null;
    });
    try {
      final results = await searchBgmSubjects(clean);
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
        _searchError = results.isEmpty ? '未找到相关番剧' : null;
      });
      if (results.isNotEmpty) _selectSubject(results.first);
    } catch (e) {
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _isSearching = false;
        _searchError = '搜索失败: $e';
      });
    }
  }

  void _selectSubject(BgmInfo subject) {
    if (_selectedSubject?.subjectId == subject.subjectId) return;
    setState(() {
      _selectedSubject = subject;
      // The API already caches and deduplicates episode requests.
      _episodes = getBgmEpisodes(subject.subjectId!).then(
        (episodes) => [
          for (final episode in episodes)
            if ((episode['sort'] as num) > 0) (episode['sort'] as num).round(),
        ],
      );
    });
  }

  Future<void> _loadDanmaku(BgmInfo subject, int episode) async {
    final selection = (subject.subjectId, episode);
    if (_loadingEpisode == selection) return;
    final request = ++_loadRequest;
    setState(() => _loadingEpisode = selection);
    try {
      final items = await DanmakuController.fetchDanmaku(
        subjectId: subject.subjectId!,
        episodeIndex: episode,
        titles: subject.searchTitles,
      );
      if (!mounted || request != _loadRequest) return;
      widget.controller.setItems(items);
      widget.onDanmakuLoaded?.call(items);
      final title = subject.nameCn ?? subject.name ?? '动画';
      showSnackBar(
        '已关联《$title》第 $episode 话 (${items.isEmpty ? "无弹幕" : "${items.length} 条弹幕"})',
      );
      setState(() {
        _loadingEpisode = null;
        _matchedSubject = subject;
        _matchedEpisode = episode;
        _showSearch = false;
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _loadingEpisode = null);
      debugPrint('关联弹幕失败: $e');
    }
  }

  void _toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (_showSearch && _searchResults.isEmpty && !_isSearching) {
      _doSearch(_searchController.text);
    }
  }

  static const _muted = Color(0xFFB9C3CE);
  static const _sectionStyle = TextStyle(
    color: Colors.white,
    fontSize: 16,
    fontWeight: FontWeight.w700,
  );

  ButtonStyle _buttonStyle(BuildContext context, {bool selected = false}) {
    final colors = Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      backgroundColor: selected
          ? colors.primary
          : colors.secondaryContainer.withValues(alpha: 0.66),
      foregroundColor: selected
          ? colors.onPrimary
          : colors.onSecondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(
        color: selected
            ? Colors.transparent
            : colors.outlineVariant.withValues(alpha: 0.6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matchedTitle =
        _matchedSubject?.nameCn ??
        _matchedSubject?.name ??
        widget.defaultTitle ??
        '未指定番剧';
    final matchedEpisode = _matchedEpisode ?? widget.defaultEpisode;
    return PanelContainer(
      title: '弹幕管理',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前匹配', style: TextStyle(color: _muted, fontSize: 14)),
            const SizedBox(height: 8),
            Text(
              '$matchedTitle · ${matchedEpisode == null ? "未指定集数" : "第 ${matchedEpisode.toString().padLeft(2, '0')} 话"}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _sectionStyle.copyWith(height: 1.5),
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.controller.loadStatus,
                    style: const TextStyle(color: _muted, fontSize: 14),
                  ),
                  if (widget.controller.loading)
                    const LinearProgressIndicator(semanticsLabel: '正在加载弹幕'),
                ],
              ),
            ),
            const Divider(height: 40, color: Color(0xFF384452)),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('时间偏移', style: _sectionStyle)),
                      TextButton(
                        onPressed: () => widget.controller.setTimeOffset(0),
                        child: const Text('重置'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _buildOffsetButton(-0.5),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${widget.controller.timeOffset.toStringAsFixed(1)}s',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ),
                      _buildOffsetButton(0.5),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '负值提前，正值延后',
                    style: TextStyle(color: _muted, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Divider(height: 40, color: Color(0xFF384452)),
            Semantics(
              expanded: _showSearch,
              child: InkWell(
                onTap: _toggleSearch,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('手动检索', style: _sectionStyle),
                            SizedBox(height: 8),
                            Text(
                              '匹配不正确时，重新选择番剧与集数',
                              style: TextStyle(color: _muted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _showSearch
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_showSearch) ...[
              const SizedBox(height: 8),
              _buildSearchPanel(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOffsetButton(double delta) => Expanded(
    child: FilledButton(
      style: _buttonStyle(context),
      onPressed: () => widget.controller.setTimeOffset(
        (widget.controller.timeOffset * 10 + delta * 10).round() / 10,
      ),
      child: Text('${delta > 0 ? "+" : ""}${delta}s'),
    ),
  );

  Widget _buildSearchPanel() {
    final subject = _selectedSubject;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: _doSearch,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: '输入番剧名称搜索...',
            hintStyle: const TextStyle(color: _muted),
            filled: true,
            fillColor: colors.secondaryContainer.withValues(alpha: 0.66),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.primary),
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '清空',
                  onPressed: _searchController.clear,
                  icon: const Icon(Icons.clear),
                ),
                IconButton(
                  tooltip: '检索',
                  onPressed: _isSearching
                      ? null
                      : () => _doSearch(_searchController.text),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
        ),
        if (_isSearching)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(semanticsLabel: '正在检索番剧'),
          ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _searchError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Material(
              color: Colors.white.withValues(alpha: 0.025),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 224),
                child: ListView.separated(
                  primary: false,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _searchResults.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: Color(0xFF384452)),
                  itemBuilder: (context, index) {
                    final item = _searchResults[index];
                    final selected = subject?.subjectId == item.subjectId;
                    return Semantics(
                      selected: selected,
                      child: ListTile(
                        onTap: () => _selectSubject(item),
                        selected: selected,
                        selectedTileColor: colors.primary.withValues(
                          alpha: 0.16,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        minTileHeight: 48,
                        minLeadingWidth: 20,
                        horizontalTitleGap: 12,
                        leading: selected
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: colors.primary,
                                size: 22,
                              )
                            : const SizedBox(width: 22),
                        title: Text(
                          item.nameCn ?? item.name ?? '未知',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
        if (subject != null) ...[
          const SizedBox(height: 20),
          const Text(
            '选择集数',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<int>>(
            future: _episodes,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator(semanticsLabel: '正在加载集数');
              }
              if (snapshot.hasError) return const Text('剧集加载失败');
              final episodes = snapshot.data ?? const [];
              if (episodes.isEmpty) return const Text('暂无集数信息');
              return LayoutBuilder(
                builder: (context, constraints) {
                  final minWidth =
                      64 * MediaQuery.textScalerOf(context).scale(14) / 14;
                  final columns = ((constraints.maxWidth + 8) / (minWidth + 8))
                      .floor()
                      .clamp(1, 6);
                  final width =
                      (constraints.maxWidth - (columns - 1) * 8) / columns;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final episode in episodes)
                        _buildEpisodeButton(subject, episode, width),
                    ],
                  );
                },
              );
            },
          ),
          const SizedBox(height: 10),
          const Text(
            '点击集数即可重新关联弹幕',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
        ],
      ],
    );
  }

  Widget _buildEpisodeButton(
    BgmInfo subject,
    int episode,
    double width,
  ) {
    final loading = _loadingEpisode == (subject.subjectId, episode);
    final matchesSubject = _matchedSubject != null
        ? _matchedSubject!.subjectId == subject.subjectId
        : subject.searchTitles.contains(widget.defaultTitle?.trim());
    final selected =
        matchesSubject && (_matchedEpisode ?? widget.defaultEpisode) == episode;
    return SizedBox(
      width: width,
      child: Semantics(
        selected: selected,
        label: '第 $episode 话${loading ? "，正在关联" : ""}',
        child: FilledButton(
          style: _buttonStyle(context, selected: selected),
          onPressed: loading ? null : () => _loadDanmaku(subject, episode),
          child: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(episode.toString().padLeft(2, '0')),
        ),
      ),
    );
  }
}
