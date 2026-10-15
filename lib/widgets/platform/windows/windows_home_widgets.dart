import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:baka/widgets/home/swiper_banner.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

const double windowsPosterRadius = 10;

const double _headerInlineWidth = 640;

double windowsTileTextHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return (10 + scaler.scale(13.5) * 1.3 + 2 + scaler.scale(11.5) * 1.3)
          .ceilToDouble() +
      2;
}

Duration _motion(BuildContext context, int milliseconds) =>
    context.reduceMotion ? Duration.zero : Duration(milliseconds: milliseconds);
ImageProvider _bannerImage(String url) =>
    ResizeImage.resizeIfNeeded(1920, null, CachedNetworkImageProvider(url));

class WindowsHeroBanner extends StatefulWidget {
  final List<Map> items;

  const WindowsHeroBanner({required this.items, super.key});

  @override
  State<WindowsHeroBanner> createState() => _WindowsHeroBannerState();
}

class _WindowsHeroBannerState extends State<WindowsHeroBanner>
    with SingleTickerProviderStateMixin {
  static const _interval = Duration(seconds: 7);

  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _interval,
  )..addStatusListener(_onProgressStatus);

  int _index = 0;
  final _hovered = ValueNotifier(false);
  bool _hidden = BannerVisibility.isHidden;
  bool _reduceMotion = false;
  bool _tickerEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = context.reduceMotion;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncAutoplay();
    _precache(_index + 1);
  }

  @override
  void didUpdateWidget(covariant WindowsHeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.items, widget.items)) return;
    final count = widget.items.length;
    _index = count == 0 ? 0 : _index.clamp(0, count - 1);
    _syncAutoplay(restart: true);
    _precache(_index + 1);
  }

  @override
  void dispose() {
    _progress.dispose();
    _hovered.dispose();
    super.dispose();
  }

  void _onProgressStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _goTo(_index + 1);
  }

  void _syncAutoplay({bool restart = false}) {
    if (restart) _progress.value = 0;
    final canPlay =
        _tickerEnabled && !_reduceMotion && !_hidden && widget.items.length > 1;
    if (!canPlay || _hovered.value) {
      _progress.stop();
      return;
    }
    _progress.forward();
  }

  void _goTo(int index) {
    final count = widget.items.length;
    if (count == 0) return;
    setState(() => _index = index % count);
    _precache(_index + 1);
    _syncAutoplay(restart: true);
  }

  /// 提前解码下一张横幅，避免交叉淡入时出现空白底色。
  void _precache(int index) {
    final count = widget.items.length;
    if (count < 2 || _hidden || !_tickerEnabled || _reduceMotion) return;
    final url = _imageUrl(widget.items[index % count]);
    if (url.isEmpty) return;
    precacheImage(_bannerImage(url), context, onError: (_, _) {});
  }

  void _setHovered(bool hovered) {
    if (_hovered.value == hovered) return;
    _hovered.value = hovered;
    _syncAutoplay();
  }

  Future<void> _toggleHidden() async {
    final confirmed = await BannerVisibility.confirmToggle(
      context,
      hidden: _hidden,
    );
    if (!confirmed || !mounted) return;
    setState(() => _hidden = !_hidden);
    BannerVisibility.setHidden(_hidden);
    _syncAutoplay(restart: true);
  }

  static String _imageUrl(Map item) => item['bannerImageUrl']?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    if (_hidden) return _buildHiddenBar(context);
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final item = widget.items[_index];
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth / 2.75).clamp(240.0, 440.0);
        return MouseRegion(
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          child: GestureDetector(
            onSecondaryTap: _toggleHidden,
            onLongPress: _toggleHidden,
            child: SizedBox(
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Color(0xFF15161A)),
                    AnimatedSwitcher(
                      duration: _motion(context, 600),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [...previous, ?current],
                      ),
                      child: _HeroSlide(
                        key: ValueKey<int>(_index),
                        item: item,
                        image: _imageUrl(item),
                        wide: constraints.maxWidth >= 720,
                      ),
                    ),
                    Positioned(
                      right: 28,
                      bottom: 28,
                      child: _buildControls(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final count = widget.items.length;
    if (count < 2) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          _ProgressDash(
            active: i == _index,
            progress: _progress,
            onTap: () => _goTo(i),
          ),
        const SizedBox(width: 10),
        ValueListenableBuilder<bool>(
          valueListenable: _hovered,
          builder: (context, hovered, child) => AnimatedOpacity(
            opacity: hovered ? 1 : 0,
            duration: _motion(context, 180),
            child: IgnorePointer(ignoring: !hovered, child: child),
          ),
          child: Row(
            children: [
              _GlassButton(
                icon: Icons.chevron_left_rounded,
                tooltip: '上一个',
                onTap: () => _goTo(_index - 1 + count),
              ),
              const SizedBox(width: 8),
              _GlassButton(
                icon: Icons.chevron_right_rounded,
                tooltip: '下一个',
                onTap: () => _goTo(_index + 1),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHiddenBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 18, right: 8),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '横幅已隐藏',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: _toggleHidden, child: const Text('管理')),
        ],
      ),
    );
  }
}

class _HeroSlide extends StatelessWidget {
  final Map item;
  final String image;
  final bool wide;

  const _HeroSlide({
    required this.item,
    required this.image,
    required this.wide,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final title = item['title']?.toString() ?? '';
    final subtitle = item['subtitle']?.toString().trim() ?? '';

    return GestureDetector(
      onTap: () => openBannerItem(context, item),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image.isNotEmpty)
              Image(
                image: _bannerImage(image),
                fit: BoxFit.cover,
                alignment: const Alignment(0, -0.2),
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white24,
                    size: 32,
                  ),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xC7000000),
                    Color(0x59000000),
                    Color(0x00000000),
                  ],
                  stops: [0, 0.42, 0.78],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                  stops: [0, 0.55],
                ),
              ),
            ),
            Positioned(
              left: 40,
              bottom: 32,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 520 : 360),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: wide ? 34 : 26,
                        height: 1.2,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        shadows: const [
                          Shadow(color: Color(0x66000000), blurRadius: 12),
                        ],
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressDash extends StatelessWidget {
  final bool active;
  final Animation<double> progress;
  final VoidCallback onTap;

  const _ProgressDash({
    required this.active,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
          child: AnimatedContainer(
            duration: _motion(context, 260),
            curve: Curves.easeOutCubic,
            width: active ? 36 : 14,
            height: 4,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? 0.3 : 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
            alignment: Alignment.centerLeft,
            child: active
                ? RepaintBoundary(
                    child: CustomPaint(
                      painter: _BannerProgress(progress),
                      child: const SizedBox.expand(),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _BannerProgress extends CustomPainter {
  _BannerProgress(this.progress) : super(repaint: progress);
  final Animation<double> progress;
  final _paint = Paint()..color = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final fraction = progress.isAnimating || progress.value > 0
        ? progress.value
        : 1.0;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * fraction, size.height),
      _paint,
    );
  }

  @override
  bool shouldRepaint(_BannerProgress oldDelegate) =>
      oldDelegate.progress != progress;
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _GlassButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PlatformTooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          hoverColor: Colors.white.withValues(alpha: 0.12),
          fixedSize: const Size(36, 36),
          minimumSize: const Size(36, 36),
          padding: EdgeInsets.zero,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
        ),
        icon: Icon(icon, size: 22),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 分区标题、分段选择与横向货架
// ---------------------------------------------------------------------------

class WindowsSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> trailing;

  const WindowsSectionHeader({
    required this.title,
    this.subtitle,
    this.trailing = const [],
    super.key,
  });

  static TextStyle titleStyle(ColorScheme colors) => TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.3,
    color: colors.onSurface,
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle(colors),
          ),
        ),
        if (subtitle case final subtitle? when subtitle.isNotEmpty) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
    if (trailing.isEmpty) return heading;

    // 窄窗口下星期选择器与翻页按钮会挤占标题，改为放到标题下方。
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _headerInlineWidth) {
          return Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: 12),
              ...trailing,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: trailing),
            ),
          ],
        );
      },
    );
  }
}

/// 紧凑的分段选择器，用于星期与榜单切换。
class WindowsSegmentedTabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  const WindowsSegmentedTabs({
    required this.labels,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: isDark ? 0.08 : 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < labels.length; i++)
            _Segment(
              label: labels[i],
              selected: i == selected,
              onTap: () => onChanged(i),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: _motion(context, 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? (isDark
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: selected && !isDark
                  ? const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? colors.onSurface : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 横向货架：标题栏右侧提供翻页按钮，弥补鼠标滚轮无法横向滚动的问题。
class WindowsShelf extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double spacing;
  final double gutter;

  /// 条目为空时显示在货架区域内的内容。
  final Widget? placeholder;

  /// 值变化时回到起点，例如切换星期或榜单。
  final Object? resetKey;

  const WindowsShelf({
    required this.title,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    required this.gutter,
    this.subtitle,
    this.actions = const [],
    this.spacing = 18,
    this.placeholder,
    this.resetKey,
    super.key,
  });

  @override
  State<WindowsShelf> createState() => _WindowsShelfState();
}

class _WindowsShelfState extends State<WindowsShelf> {
  final ScrollController _controller = ScrollController();
  final ValueNotifier<(bool, bool)> _edges = ValueNotifier((false, false));

  @override
  void didUpdateWidget(covariant WindowsShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey && _controller.hasClients) {
      _controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _edges.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return false;
    _edges.value = (
      metrics.pixels > metrics.minScrollExtent + 1,
      metrics.pixels < metrics.maxScrollExtent - 1,
    );
    return false;
  }

  void _page(int direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if (context.reduceMotion) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = widget.placeholder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.gutter),
          child: WindowsSectionHeader(
            title: widget.title,
            subtitle: widget.subtitle,
            trailing: [
              for (final action in widget.actions) ...[
                action,
                const SizedBox(width: 12),
              ],
              ValueListenableBuilder<(bool, bool)>(
                valueListenable: _edges,
                builder: (context, edges, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PageButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: '向前',
                      onTap: edges.$1 ? () => _page(-1) : null,
                    ),
                    const SizedBox(width: 6),
                    _PageButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: '向后',
                      onTap: edges.$2 ? () => _page(1) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: widget.height,
          child: widget.itemCount == 0 && placeholder != null
              ? Padding(
                  padding: EdgeInsets.symmetric(horizontal: widget.gutter),
                  child: placeholder,
                )
              : NotificationListener<ScrollMetricsNotification>(
                  onNotification: (n) => _onMetrics(n.metrics),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) => _onMetrics(n.metrics),
                    child: ListView.separated(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: widget.gutter),
                      itemCount: widget.itemCount,
                      addAutomaticKeepAlives: false,
                      separatorBuilder: (_, _) =>
                          SizedBox(width: widget.spacing),
                      itemBuilder: widget.itemBuilder,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _PageButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _PageButton({required this.icon, required this.tooltip, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PlatformTooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        style: IconButton.styleFrom(
          fixedSize: const Size(32, 32),
          minimumSize: const Size(32, 32),
          padding: EdgeInsets.zero,
          foregroundColor: colors.onSurface,
          disabledForegroundColor: colors.onSurface.withValues(alpha: 0.25),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
        ),
        icon: Icon(icon, size: 20),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 海报条目
// ---------------------------------------------------------------------------

/// 悬停时放大封面并提亮标题的海报卡片，标题与副标题位于封面下方。
class WindowsPosterTile extends StatefulWidget {
  final Map data;
  final Object heroTag;
  final int? posIndex;
  final int? rank;
  final double posterWidth;

  const WindowsPosterTile({
    required this.data,
    required this.heroTag,
    this.posIndex,
    this.rank,
    this.posterWidth = 132,
    super.key,
  });

  @override
  State<WindowsPosterTile> createState() => _WindowsPosterTileState();
}

class _WindowsPosterTileState extends State<WindowsPosterTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final rank = widget.rank;
    final meta = resolvePostCardMeta(data);
    final subtitle = data['subtitle']?.toString().trim() ?? '';
    Widget poster = _PosterFrame(
      data: data,
      heroTag: widget.heroTag,
      hovered: _hovered,
      tagText: rank == null ? meta.tagText : '',
      scoreText: meta.scoreText,
    );
    var captionInset = 0.0;
    double? width;
    if (rank == null) {
      poster = AspectRatio(aspectRatio: 2 / 3, child: poster);
    } else {
      final colors = Theme.of(context).colorScheme;
      final numeralWidth = rank >= 10 ? 116.0 : 72.0;
      captionInset = numeralWidth - 14;
      width = captionInset + widget.posterWidth;
      final style = DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: 120,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: rank >= 10 ? -6 : 0,
          color: rank <= 3 ? colors.primary : null,
          foreground: rank <= 3
              ? null
              : (Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2.5
                  ..color = colors.onSurface.withValues(alpha: 0.28)),
        ),
      );
      poster = SizedBox(
        height: widget.posterWidth * 1.5,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: numeralWidth,
              child: CustomPaint(painter: _RankNumeralPainter('$rank', style)),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: widget.posterWidth,
              child: poster,
            ),
          ],
        ),
      );
    }
    Widget caption = _TileCaption(
      title: data['title']?.toString() ?? '未知标题',
      subtitle: subtitle.isNotEmpty
          ? subtitle
          : rank == null
          ? meta.tagText
          : '第 $rank 名',
      hovered: _hovered,
    );
    if (rank != null) {
      caption = Padding(
        padding: EdgeInsets.only(left: captionInset),
        child: caption,
      );
    }
    final tile = _TileGesture(
      onHover: (value) => setState(() => _hovered = value),
      onTap: () => navigateToDetail(
        context,
        data,
        posIndex: widget.posIndex,
        heroTag: widget.heroTag,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [poster, caption],
      ),
    );
    return width == null ? tile : SizedBox(width: width, child: tile);
  }
}

/// 名次数字以字形基线对齐到封面底边，靠右绘制，放不下时等比缩小。
/// 直接按基线定位可以避免不同字体的上下留白让数字错位或被裁切。
class _RankNumeralPainter extends CustomPainter {
  final String text;
  final TextStyle style;

  _RankNumeralPainter(this.text, this.style);

  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final scale = painter.width > size.width ? size.width / painter.width : 1.0;
    canvas
      ..save()
      ..translate(size.width, size.height)
      ..scale(scale);
    painter.paint(canvas, Offset(-painter.width, -baseline));
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_RankNumeralPainter old) =>
      old.text != text || old.style != style;
}

/// 排行加载中的占位条目。
class WindowsRankSkeleton extends StatelessWidget {
  final double posterWidth;

  const WindowsRankSkeleton({required this.posterWidth, super.key});

  @override
  Widget build(BuildContext context) {
    return AppSkeletonizer(
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 8,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(left: 38),
          child: SizedBox(
            width: posterWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: posterWidth * 1.5,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(windowsPosterRadius),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 12,
                  width: posterWidth * 0.8,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 10,
                  width: posterWidth * 0.5,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TileGesture extends StatelessWidget {
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  final Widget child;

  const _TileGesture({
    required this.onHover,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(onTap: onTap, child: child),
      ),
    );
  }
}

class _PosterFrame extends StatelessWidget {
  final Map data;
  final Object heroTag;
  final bool hovered;
  final String tagText;
  final String? scoreText;

  const _PosterFrame({
    required this.data,
    required this.heroTag,
    required this.hovered,
    required this.tagText,
    required this.scoreText,
  });

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final score = scoreText;
    return AnimatedContainer(
      duration: _motion(context, 220),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(windowsPosterRadius),
        boxShadow: hovered
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ]
            : const [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(windowsPosterRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedScale(
              scale: hovered && !reduceMotion ? 1.06 : 1,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: Hero(
                tag: heroTag,
                child: buildCachedImage(data, double.infinity, double.infinity),
              ),
            ),
            if (tagText.isNotEmpty)
              Positioned(
                left: 8,
                top: 8,
                right: score == null ? 8 : 64,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _Badge(child: Text(tagText, maxLines: 1)),
                ),
              ),
            if (score != null)
              Positioned(
                right: 8,
                top: 8,
                child: _Badge(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 12,
                        color: Color(0xFFFFC53D),
                      ),
                      const SizedBox(width: 2),
                      Text(score),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final Widget child;

  const _Badge({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: DefaultTextStyle.merge(
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _TileCaption extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool hovered;

  const _TileCaption({
    required this.title,
    required this.subtitle,
    required this.hovered,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedDefaultTextStyle(
            duration: _motion(context, 160),
            // AnimatedDefaultTextStyle 会替换环境默认文字样式，全局字体要显式继承。
            style: context.withAppFont(
              TextStyle(
                fontSize: 13.5,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: hovered ? colors.primary : colors.onSurface,
              ),
            ),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.3,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
