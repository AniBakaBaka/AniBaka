import 'dart:async';
import 'package:baka/core/api_transport.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:flutter/material.dart';

String _time(int ms) => Duration(milliseconds: ms).toTimeString();

class _SkipDivider extends StatelessWidget {
  const _SkipDivider({this.height = 16});
  final double height;

  @override
  Widget build(BuildContext context) => Divider(
    height: height,
    thickness: 1,
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.75),
  );
}

class SkipSegmentsPanel extends StatefulWidget {
  const SkipSegmentsPanel({required this.controller, super.key})
    : type = null,
      sourceKey = null;

  const SkipSegmentsPanel._details({
    required this.controller,
    required this.type,
    required this.sourceKey,
  });

  final PlaybackController controller;
  final String? type;
  final String? sourceKey;
  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) => showPlayerSettingsPanel(
    context,
    SkipSegmentsPanel(controller: controller),
  );

  @override
  State<SkipSegmentsPanel> createState() => _SkipSegmentsPanelState();
}

class _SkipSegmentsPanelState extends State<SkipSegmentsPanel> {
  bool _busy = false;
  bool? _allEpisodes;
  PlaybackController get ctrl => widget.controller;

  void _editInVideo(String type) {
    if (ctrl.beginSkipSelection(type)) {
      closePlayerSettingsPanel(context);
    } else {
      showSnackBar('请等待视频就绪，且需要有播放控制权限');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showSnackBar('$error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bind() async {
    final original = ctrl.skipContext;
    if (original == null) return;
    final subject = TextEditingController(
      text: original.subjectId?.toString() ?? '',
    );
    final episode = TextEditingController(
      text: original.episodeId?.toString() ?? '',
    );
    List<DropdownMenuItem<int>> choices = const [];
    String? error;
    bool busy = false;
    try {
      final route = DialogRoute<(int, int)>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('绑定 Bangumi 剧集'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: subject,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '番剧条目 ID（/subject/ 后的数字）',
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              update(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                final id = int.tryParse(subject.text) ?? 0;
                                if (id <= 0) {
                                  throw const FormatException('请输入条目 ID');
                                }
                                choices = [
                                  for (final item in await getBgmEpisodes(id))
                                    DropdownMenuItem(
                                      value: item['id'] as int,
                                      child: Text(
                                        '${item['sort']} · ${(item['name_cn'] as String).isEmpty ? item['name'] : item['name_cn']}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ];
                              } catch (e) {
                                error = '$e';
                              }
                              if (context.mounted) update(() => busy = false);
                            },
                      child: const Text('加载正篇剧集'),
                    ),
                    if (choices.isNotEmpty)
                      DropdownButtonFormField<int>(
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '选择剧集'),
                        items: choices,
                        onChanged: (id) {
                          episode.text = '$id';
                        },
                      ),
                    TextField(
                      controller: episode,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '剧集 ID（/ep/ 后的数字，支持 SP）',
                      ),
                    ),
                    if (error != null) Text(error!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          final s = int.tryParse(subject.text) ?? 0,
                              e = int.tryParse(episode.text) ?? 0;
                          if (s <= 0 || e <= 0) {
                            throw const FormatException('请输入有效 ID');
                          }
                          final info = await getBgmEpisode(e);
                          if (info['subject_id'] != s) {
                            throw const FormatException('该剧集不属于所选番剧');
                          }
                          if (context.mounted) Navigator.pop(context, (s, e));
                        } catch (e) {
                          if (context.mounted) {
                            update(() {
                              error = '$e';
                              busy = false;
                            });
                          }
                        }
                      },
                child: const Text('绑定'),
              ),
            ],
          ),
        ),
      );
      final binding = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      if (mounted && binding != null && identical(original, ctrl.skipContext)) {
        final bound = original.bind(binding.$1, binding.$2);
        await ctrl.skipService.bind(bound);
        if (identical(original, ctrl.skipContext)) {
          ctrl.setSkipContext(bound);
        }
      }
    } finally {
      subject.dispose();
      episode.dispose();
    }
  }

  Widget _segment(SkipContext current, SkipData data, String type) {
    final segment = data.editableSegments
        .where((s) => s.type == type)
        .firstOrNull;
    final disabled = type == 'op' ? data.disabled.op : data.disabled.ed;
    final color = SkipSegmentColors.forType(type);
    final label = type == 'op' ? '片头' : '片尾';
    final canEdit =
        ctrl.canControlPlayback && ctrl.timeline.value.duration > Duration.zero;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 12),
                child: Icon(Icons.circle, size: 16, color: color),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      segment == null
                          ? '未设置'
                          : '${_time(segment.startMs)} – ${_time(segment.endMs)}',
                      style: TextStyle(
                        fontSize: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flex(
                    direction: MediaQuery.textScalerOf(context).scale(1) > 1.3
                        ? Axis.vertical
                        : Axis.horizontal,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('跳过', style: Theme.of(context).textTheme.labelSmall),
                      const SizedBox(width: 4),
                      Semantics(
                        label: '当前片源$label跳过',
                        child: Switch(
                          key: ValueKey('skip-enabled-$type'),
                          value: !disabled,
                          onChanged: _busy
                              ? null
                              : (enabled) => _run(() async {
                                  await ctrl.skipService.disable(
                                    current,
                                    type,
                                    !enabled,
                                  );
                                  if (identical(current, ctrl.skipContext)) {
                                    await ctrl.refreshSkipSegments(force: true);
                                  }
                                }),
                        ),
                      ),
                    ],
                  ),
                  if (!disabled &&
                      segment != null &&
                      (!segment.automatic ||
                          !segment.fits(
                            ctrl.timeline.value.duration.inMilliseconds,
                          )))
                    Text(
                      segment.fits(ctrl.timeline.value.duration.inMilliseconds)
                          ? '待确认，仅可手动跳过'
                          : '时长不符，仅可手动试用',
                      style: const TextStyle(
                        fontSize: 11,
                        color: SkipSegmentColors.ending,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const _SkipDivider(height: 24),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                key: ValueKey('edit-skip-$type'),
                onPressed: canEdit && !_busy ? () => _editInVideo(type) : null,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(segment == null ? '在视频中选择' : '在视频中调整'),
              ),
              if (segment != null && current.seriesLocalKey != null)
                TextButton.icon(
                  key: ValueKey('apply-skip-series-$type'),
                  onPressed: canEdit && !_busy
                      ? () => _save(
                          current,
                          segment,
                          share: false,
                          allEpisodes: true,
                        )
                      : null,
                  icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                  label: const Text('应用到全集'),
                ),
              if (segment != null)
                TextButton(
                  key: ValueKey('skip-details-$type'),
                  onPressed: () => showPlayerSettingsPanel(
                    context,
                    SkipSegmentsPanel._details(
                      controller: ctrl,
                      type: type,
                      sourceKey: current.localKey,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('区间详情'),
                          Text('来源与反馈', style: TextStyle(fontSize: 11)),
                        ],
                      ),
                      Icon(Icons.chevron_right_rounded, size: 20),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SkipData>(
    valueListenable: ctrl.skipData,
    builder: (context, data, _) {
      final type = widget.type;
      return type == null
          ? _buildOverview(context, data)
          : _buildDetails(context, data, type);
    },
  );

  Widget _buildOverview(BuildContext context, SkipData data) {
    final current = data.context;
    final colors = Theme.of(context).colorScheme;
    final number = current?.episodeNumber;
    final episode = number == null
        ? '当前片源'
        : '第 ${number == number.roundToDouble() ? number.toInt() : number} 集';
    return PanelContainer(
      title: '片头片尾',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新区间',
          onPressed: _busy
              ? null
              : () => _run(() => ctrl.refreshSkipSegments(force: true)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: ListView(
        padding: playerPanelContentPadding(context),
        children: [
          if (_busy) const LinearProgressIndicator(),
          ValueListenableBuilder<PlaybackPreferences>(
            valueListenable: ctrl.preferences,
            builder: (context, preferences, _) => PanelSettingsGroup(
              borderRadius: 16,
              children: [
                PanelSwitchTile(
                  title: '自动跳过',
                  subtitle: '使用本机或已确认区间\n第 1 集保留片头片尾',
                  value: preferences.enableSkipOpEd,
                  onChanged: (value) => _run(
                    () => ctrl.updatePreferences(
                      preferences.copyWith(enableSkipOpEd: value),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (current != null) ...[
            PanelSettingsGroup(
              borderRadius: 16,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('当前剧集'),
                  subtitle: Text(
                    '$episode · ${current.bound ? '已绑定 Bangumi' : '尚未绑定剧集'}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '绑定 / 更正',
                        style: TextStyle(color: colors.primary, fontSize: 12),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                  onTap: _busy ? null : () => _run(_bind),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '本集区间',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              child: Text(
                '已获取 ${data.editableSegments.length} 个区间',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
            PanelSettingsGroup(
              borderRadius: 16,
              children: [
                _segment(current, data, 'op'),
                const _SkipDivider(),
                _segment(current, data, 'ed'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '开关仅对当前片源生效',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
          if (data.editableSegments.isEmpty ||
              data.message.contains('失败') ||
              data.message.contains('暂不可用'))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                data.message,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ),
          const _SkipDivider(height: 24),
          Text(
            '未设置区间时，可在视频中直接选择。\n片尾结束位置请保留彩蛋与预告。',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(
    SkipContext current,
    SkipSegment segment, {
    required bool share,
    bool allEpisodes = false,
  }) => _run(() async {
    if (!identical(current, ctrl.skipContext) ||
        !segment.canPreview(ctrl.timeline.value.duration.inMilliseconds)) {
      throw const FormatException('视频已切换，请重新选择区间');
    }
    final local = SkipSegment(
      id: 'local:${segment.type}',
      type: segment.type,
      startMs: segment.startMs,
      endMs: segment.endMs,
      durationMs: ctrl.timeline.value.duration.inMilliseconds,
      origin: 'local',
      automatic: true,
      status: 'personal',
    );
    await ctrl.skipService.saveLocal(current, local, allEpisodes: allEpisodes);
    if (!identical(current, ctrl.skipContext)) return;
    try {
      if (share) {
        if (!apiTransport.session.isLoggedIn) {
          throw const FormatException('已保存到本机；登录后可共享');
        }
        try {
          await ctrl.skipService.submit(
            current,
            local,
            allEpisodes: allEpisodes,
          );
        } catch (error) {
          throw FormatException('已保存到本机；共享失败：$error');
        }
      }
      showSnackBar(
        share
            ? '${allEpisodes ? '全集区间' : '本集区间'}已保存并共享，其他用户确认后生效'
            : allEpisodes
            ? '已应用到同片源线路的全集'
            : '已保存到本机',
      );
    } finally {
      if (identical(current, ctrl.skipContext)) {
        unawaited(ctrl.refreshSkipSegments(force: true));
      }
    }
  });

  Future<void> _feedback(
    SkipContext current,
    SkipSegment segment,
    bool accurate,
  ) => _run(() async {
    if (!apiTransport.session.isLoggedIn) {
      throw const FormatException('请先登录再反馈');
    }
    if (!identical(current, ctrl.skipContext)) return;
    await ctrl.skipService.feedback(current, segment, accurate);
    if (identical(current, ctrl.skipContext)) {
      await ctrl.refreshSkipSegments(force: true);
    }
    showSnackBar('已提交反馈');
  });

  Future<void> _preview(SkipContext current, SkipSegment segment, bool end) =>
      _run(() async {
        final target = end
            ? (segment.endMs - 3000).clamp(segment.startMs, segment.endMs)
            : segment.startMs;
        await ctrl.seek(Duration(milliseconds: target));
        if (!mounted || !identical(current, ctrl.skipContext)) return;
        await ctrl.play();
        if (mounted) closePlayerSettingsPanel(context);
      });

  Widget _buildDetails(BuildContext context, SkipData data, String type) {
    final current = data.context;
    final label = type == 'op' ? '片头' : '片尾';
    final segment = data.editableSegments
        .where((s) => s.type == type)
        .firstOrNull;
    if (current == null ||
        current.localKey != widget.sourceKey ||
        segment == null) {
      return PanelContainer(
        title: '$label区间',
        child: const Center(child: Text('视频或区间已变更，请返回重新选择')),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final canPreview =
        !_busy &&
        ctrl.canControlPlayback &&
        segment.canPreview(ctrl.timeline.value.duration.inMilliseconds);
    final durationMatches = segment.fits(
      ctrl.timeline.value.duration.inMilliseconds,
    );
    final actionShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    final outlinedStyle = OutlinedButton.styleFrom(
      shape: actionShape,
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    final source = switch (segment.origin) {
      'local' => '本机标注',
      'aniskip' => 'AniSkip',
      _ => '社区标注',
    };
    final allEpisodes = _allEpisodes ?? segment.allEpisodes;
    return PanelContainer(
      title: '$label区间',
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              padding: playerPanelContentPadding(context).copyWith(bottom: 8),
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 12,
                      color: SkipSegmentColors.forType(type),
                    ),
                    const SizedBox(width: 8),
                    Text(label),
                    const Spacer(),
                    Text(
                      '时长 ${_time(segment.endMs - segment.startMs)}',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_time(segment.startMs)} – ${_time(segment.endMs)}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  segment.allEpisodes ? '适用范围：同片源线路全集' : '适用范围：本集',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (!durationMatches)
                  const Text('参考时长与当前视频不符，不会自动跳过。请先试看、校准，再保存到本机。'),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(shape: actionShape),
                  onPressed: canPreview ? () => _editInVideo(type) : null,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('在视频中调整'),
                ),
                const SizedBox(height: 4),
                Text(
                  '拖动进度条两端，完成后保存到本机。',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                const PanelSectionTitle('试看区间'),
                PanelSettingsGroup(
                  borderRadius: 16,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        Widget preview(bool end) => TextButton.icon(
                          key: ValueKey(
                            end ? 'preview-skip-end' : 'preview-skip-start',
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            alignment: Alignment.centerLeft,
                            minimumSize: const Size(0, 56),
                          ),
                          onPressed: canPreview
                              ? () => _preview(current, segment, end)
                              : null,
                          icon: const Icon(Icons.play_arrow_outlined, size: 24),
                          label: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(end ? '试看终点' : '试看起点'),
                              const SizedBox(height: 3),
                              Text(
                                end
                                    ? '从终点前 3 秒播放'
                                    : '从 ${_time(segment.startMs)} 开始播放',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        );
                        if (constraints.maxWidth < 280 ||
                            MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              preview(false),
                              const _SkipDivider(),
                              preview(true),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: preview(false)),
                            SizedBox(
                              height: 48,
                              child: VerticalDivider(
                                width: 16,
                                thickness: 1,
                                color: colors.outlineVariant.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                            ),
                            Expanded(child: preview(true)),
                          ],
                        );
                      },
                    ),
                    const _SkipDivider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      minTileHeight: 44,
                      leading: const Icon(Icons.skip_next_rounded),
                      title: const Text('手动跳过'),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                      ),
                      onTap: canPreview && !current.isFirstEpisode
                          ? () {
                              ctrl.previewSkipSegment(segment);
                              closePlayerSettingsPanel(context);
                            }
                          : null,
                    ),
                    if (current.isFirstEpisode)
                      Text(
                        '第 1 集保留片头片尾',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                const PanelSectionTitle('区间来源'),
                PanelSettingsGroup(
                  borderRadius: 16,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(child: Text(source)),
                          Text(
                            segment.origin == 'local'
                                ? '仅本机'
                                : segment.automatic
                                ? '已确认'
                                : '待确认',
                            style: TextStyle(
                              color: segment.automatic
                                  ? SkipSegmentColors.opening
                                  : SkipSegmentColors.ending,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (segment.origin != 'local' && durationMatches) ...[
                      Text(
                        '${segment.confirms} 人确认 · ${segment.reports} 人报错',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      const _SkipDivider(height: 12),
                      const Text('这个区间准确吗？', style: TextStyle(fontSize: 13)),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: outlinedStyle,
                              onPressed: _busy
                                  ? null
                                  : () => _feedback(current, segment, true),
                              icon: const Icon(
                                Icons.thumb_up_outlined,
                                size: 18,
                              ),
                              label: const Text('准确'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              style: outlinedStyle,
                              onPressed: _busy
                                  ? null
                                  : () => _feedback(current, segment, false),
                              icon: const Icon(Icons.flag_outlined, size: 18),
                              label: const Text('有误'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: playerPanelContentPadding(
              context,
            ).copyWith(top: 8, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current.seriesLocalKey != null)
                  SwitchListTile(
                    key: const ValueKey('share-skip-series'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('应用到全集'),
                    subtitle: const Text('保存和上传均使用此范围；已有单集校准优先'),
                    value: allEpisodes,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _allEpisodes = value),
                  ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final local = OutlinedButton.icon(
                      style: outlinedStyle,
                      onPressed: _busy
                          ? null
                          : () => _save(
                              current,
                              segment,
                              share: false,
                              allEpisodes: allEpisodes,
                            ),
                      icon: const Icon(Icons.save_alt_rounded, size: 18),
                      label: const Text('保存到本机'),
                    );
                    final share = FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: colors.onPrimary,
                        shape: actionShape,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: _busy
                          ? null
                          : () => _save(
                              current,
                              segment,
                              share: true,
                              allEpisodes: allEpisodes,
                            ),
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('保存并共享'),
                    );
                    if (constraints.maxWidth < 280 ||
                        MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [local, const SizedBox(height: 8), share],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: local),
                        const SizedBox(width: 12),
                        Expanded(child: share),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  '登录后可反馈或共享，另需 2 位用户确认。\n${allEpisodes ? '全集沿用相同起止时间，仅适用于同片源线路；第 1 集仍保留片头片尾。' : '仅适用于当前集、当前片源。'}',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
