import 'dart:async';
import 'package:baka/instance.dart';

import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/settings_service.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

class SwiperBanner extends StatefulWidget {
  final List<Map> swiperData;

  const SwiperBanner({required this.swiperData, super.key});

  @override
  State<SwiperBanner> createState() => _SwiperBannerState();
}

class _SwiperBannerState extends State<SwiperBanner> {
  late final PageController _pageController = PageController();
  final ValueNotifier<int> _currentIndexNotifier = ValueNotifier<int>(0);
  Timer? _timer;
  bool _showSwiper = !SwiperSettingsService.isHidden;
  bool _isInteracting = false;
  bool _reduceVisualEffects = false;
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _restartAutoPlay();
  }

  @override
  void didUpdateWidget(covariant SwiperBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.swiperData, widget.swiperData)) return;

    final index = widget.swiperData.isEmpty
        ? 0
        : _currentIndexNotifier.value.clamp(0, widget.swiperData.length - 1);
    _currentIndexNotifier.value = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _pageController.hasClients &&
          widget.swiperData.isNotEmpty) {
        _pageController.jumpToPage(index);
      }
    });
    _restartAutoPlay();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceVisualEffects = context.reduceMotion;
    final tickerEnabled = TickerMode.of(context);
    if (_reduceVisualEffects == reduceVisualEffects &&
        _tickerEnabled == tickerEnabled) {
      return;
    }
    _reduceVisualEffects = reduceVisualEffects;
    _tickerEnabled = tickerEnabled;
    _restartAutoPlay();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
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
      if (_isInteracting || !_pageController.hasClients) return;
      _pageController.animateToPage(
        (_currentIndexNotifier.value + 1) % widget.swiperData.length,
        duration: const Duration(milliseconds: 600),
        curve: Curves.fastOutSlowIn,
      );
    });
  }

  void _toggleSwiper() {
    setState(() => _showSwiper = !_showSwiper);
    if (_showSwiper) {
      SwiperSettingsService.show();
    } else {
      SwiperSettingsService.hide();
    }
    _restartAutoPlay();
  }

  Future<void> _showSettingsDialog() async {
    HapticFeedback.mediumImpact();
    final remainingDays = SwiperSettingsService.remainingDays;
    final confirmed = await showAppConfirmDialog(
      context,
      title: 'Banner 设置',
      content: _showSwiper
          ? '隐藏此横幅 14 天以专注于内容？'
          : '已隐藏，还剩 ${remainingDays + 1} 天。',
      confirmText: _showSwiper ? '隐藏横幅' : '显示横幅',
      cancelText: '取消',
    );
    if (confirmed && mounted) _toggleSwiper();
  }

  void _openItem(int index) {
    HapticFeedback.lightImpact();
    final data = widget.swiperData[index];
    final link = data['videos']?.toString() ?? '';
    if (link.isNotEmpty && !link.contains(r'$')) {
      unawaited(launchUrlString(link, mode: LaunchMode.externalApplication));
      return;
    }
    NavigationService.toDetail(context, data);
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
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.swiperData.length,
              onPageChanged: (index) {
                _currentIndexNotifier.value = index;
              },
              itemBuilder: (_, index) => GestureDetector(
                onTap: () => _openItem(index),
                child: CachedNetworkImage(
                  imageUrl:
                      widget.swiperData[index]['bannerImageUrl'] as String,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  memCacheWidth: 1080,
                  useOldImageOnUrlChange: true,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  placeholder: (_, _) =>
                      const ColoredBox(color: Color(0xFF121212)),
                  errorWidget: (_, _, _) => const ColoredBox(
                    color: Color(0xFF121212),
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white24,
                    ),
                  ),
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
                            _titleAt(currentIndex),
                            key: ValueKey<int>(currentIndex),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22, // 增大字号，更具视觉冲击力
                              height: 1.2,
                              fontWeight: FontWeight.w900,
                              fontStyle:
                                  FontStyle.italic, // 倾斜字体带来强烈的动感（符合动漫应用调性）
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

  String _titleAt(int index) {
    if (index < 0 || index >= widget.swiperData.length) return '';
    return widget.swiperData[index]['title'] as String;
  }
}
