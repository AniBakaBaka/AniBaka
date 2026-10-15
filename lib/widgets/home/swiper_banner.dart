import 'dart:async';
import 'package:baka/instance.dart';

import 'package:baka/app/navigation.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver;
import 'package:flutter/services.dart';

/// 首页横幅的隐藏偏好。隐藏 14 天后自动恢复，移动端与桌面端共用。
abstract final class BannerVisibility {
  static const _hiddenUntilKey = 'swiper_hidden_until';

  static DateTime? get _hiddenUntil =>
      DateTime.tryParse(Instances.sp.getString(_hiddenUntilKey) ?? '');

  static bool get isHidden {
    final hiddenUntil = _hiddenUntil;
    if (hiddenUntil == null) return false;
    if (hiddenUntil.isAfter(DateTime.now())) {
      return true;
    }
    Instances.sp.remove(_hiddenUntilKey);
    return false;
  }

  static void setHidden(bool hidden) {
    if (!hidden) {
      Instances.sp.remove(_hiddenUntilKey);
      return;
    }
    Instances.sp.setString(
      _hiddenUntilKey,
      DateTime.now().add(const Duration(days: 14)).toIso8601String(),
    );
  }

  /// 询问是否切换横幅的显示状态，用户确认时返回 true。
  static Future<bool> confirmToggle(
    BuildContext context, {
    required bool hidden,
  }) {
    HapticFeedback.mediumImpact();
    final remainingDays = _hiddenUntil?.difference(DateTime.now()).inDays ?? 0;
    return showAppConfirmDialog(
      context,
      title: 'Banner 设置',
      content: hidden ? '已隐藏，还剩 ${remainingDays + 1} 天。' : '隐藏此横幅 14 天以专注于内容？',
      confirmText: hidden ? '显示横幅' : '隐藏横幅',
      cancelText: '取消',
    );
  }
}

/// 首页控制器提供的 Bangumi 条目，移动端与桌面端共用。
void openBannerItem(BuildContext context, Map data) {
  HapticFeedback.lightImpact();
  NavigationService.toDetail(context, data);
}

class SwiperBanner extends StatefulWidget {
  final List<Map> swiperData;

  const SwiperBanner({required this.swiperData, super.key});

  @override
  State<SwiperBanner> createState() => _SwiperBannerState();
}

class _SwiperBannerState extends State<SwiperBanner> {
  CarouselController _carouselController = CarouselController();
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(0);
  Timer? _timer;
  bool _showSwiper = !BannerVisibility.isHidden;
  bool _isInteracting = false;
  bool _reduceVisualEffects = false;
  bool _tickerEnabled = true;

  @override
  void didUpdateWidget(covariant SwiperBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.swiperData, widget.swiperData)) return;

    final index = widget.swiperData.isEmpty
        ? 0
        : _currentIndexNotifier.value.clamp(0, widget.swiperData.length - 1);
    _resetCarousel(index);
    _restartAutoPlay();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceVisualEffects = context.reduceMotion;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _restartAutoPlay();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _carouselController.dispose();
    _currentIndexNotifier.dispose();
    super.dispose();
  }

  void _restartAutoPlay() {
    _timer?.cancel();
    if (_reduceVisualEffects ||
        !_tickerEnabled ||
        !_showSwiper ||
        widget.swiperData.length < 2) {
      return;
    }

    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_isInteracting ||
          !_carouselController.hasClients ||
          _carouselController.position.isScrollingNotifier.value) {
        return;
      }
      // 外层首页滚动或横幅离屏时，不再发起轮播布局和图片切换。
      // 只在定时器触发时读取现有状态，避免为每一帧增加滚动监听。
      final pageScroll = Scrollable.maybeOf(context, axis: Axis.vertical);
      if (pageScroll?.position.isScrollingNotifier.value ?? false) return;
      final sliver = context.findAncestorRenderObjectOfType<RenderSliver>();
      if (sliver?.geometry?.visible == false) return;
      unawaited(
        _carouselController.animateToItem(
          (_currentIndexNotifier.value + 1) % widget.swiperData.length,
          duration: const Duration(milliseconds: 600),
          curve: Curves.fastOutSlowIn,
        ),
      );
    });
  }

  void _resetCarousel(int index) {
    _carouselController.dispose();
    _carouselController = CarouselController(initialItem: index);
    _currentIndexNotifier.value = index;
    _isInteracting = false;
  }

  Future<void> _showSettingsDialog() async {
    final confirmed = await BannerVisibility.confirmToggle(
      context,
      hidden: !_showSwiper,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _showSwiper = !_showSwiper;
      _resetCarousel(_currentIndexNotifier.value);
    });
    BannerVisibility.setHidden(!_showSwiper);
    _restartAutoPlay();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSwiper) {
      return InkWell(
        onTap: _showSettingsDialog,
        onLongPress: _showSettingsDialog,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Chip(
              backgroundColor: Colors.transparent,
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              avatar: Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              label: Text(
                '横幅已隐藏',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (widget.swiperData.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final animationDuration = _reduceVisualEffects
        ? Duration.zero
        : const Duration(milliseconds: 400);

    return GestureDetector(
      onLongPress: _showSettingsDialog,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: (_) => _isInteracting = true,
            onPointerUp: (_) => _isInteracting = false,
            onPointerCancel: (_) => _isInteracting = false,
            child: CarouselView.builder(
              key: ObjectKey(_carouselController),
              controller: _carouselController,
              itemExtent: double.infinity,
              itemSnapping: true,
              infinite: widget.swiperData.length > 1,
              itemCount: widget.swiperData.length,
              onIndexChanged: (index) {
                _currentIndexNotifier.value = index;
              },
              itemBuilder: (_, index) => GestureDetector(
                onTap: () => openBannerItem(context, widget.swiperData[index]),
                child: buildNetworkImage(
                  widget.swiperData[index]['bannerImageUrl'] as String,
                  double.infinity,
                  double.infinity,
                  cacheWidth: 1080,
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 120,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: IgnorePointer(
              child: ValueListenableBuilder<int>(
                valueListenable: _currentIndexNotifier,
                builder: (context, currentIndex, child) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: animationDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.0, 0.3),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            widget.swiperData[currentIndex]['title'] as String,
                            key: ValueKey<int>(currentIndex),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                              fontStyle: FontStyle.italic,
                              letterSpacing: 0.5,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 8,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(widget.swiperData.length, (
                          idx,
                        ) {
                          final isActive = idx == currentIndex;
                          return AnimatedContainer(
                            duration: _reduceVisualEffects
                                ? Duration.zero
                                : const Duration(milliseconds: 300),
                            curve: Curves.easeOutQuart,
                            margin: const EdgeInsets.only(left: 4, bottom: 6),
                            height: 4,
                            width: isActive ? 18 : 6,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? primaryColor
                                  : Colors.white.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: isActive && !_reduceVisualEffects
                                  ? [
                                      BoxShadow(
                                        color: primaryColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                          );
                        }),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
