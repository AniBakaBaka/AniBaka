import 'package:flutter/material.dart';
import 'package:baka/widgets/baka_player/controller.dart';

class DanmakuInputOverlay extends StatefulWidget {
  final PlaybackController controller;
  final void Function(String text, Color color, int type) onSend;

  const DanmakuInputOverlay({
    required this.controller,
    required this.onSend,
    super.key,
  });

  @override
  State<DanmakuInputOverlay> createState() => _DanmakuInputOverlayState();
}

class _DanmakuInputOverlayState extends State<DanmakuInputOverlay>
    with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  Color _selectedColor = const Color(0xFFFFFFFF);
  int _selectedType = 1; // 1: 滚动, 4: 底部, 5: 顶部 (B站标准)

  static const _colors = [
    Color(0xFFFFFFFF),
    Color(0xFFFE0302),
    Color(0xFFFFFF00),
    Color(0xFF00CD00),
    Color(0xFF00FFFF),
    Color(0xFFCC0273),
    Color(0xFF0000FF),
    Color(0xFF000000),
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutBack),
        );

    _animController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _textController.text.trim();
    if (text.isNotEmpty) {
      widget.onSend(text, _selectedColor, _selectedType);
      _close();
    }
  }

  void _close() {
    _animController.reverse().then((_) {
      if (widget.controller.overlay.value.showDanmakuInput) {
        widget.controller.setDanmakuInputVisible(false);
        widget.controller.setControlsVisible(true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _close();
        }
      },
      child: GestureDetector(
        onTap: _close,
        child: Stack(
          children: [
            Positioned.fill(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: Container(
                  color: Colors.black.withValues(
                    alpha: 0.01,
                  ),
                ),
              ),
            ),

            Align(
              alignment: Alignment.bottomCenter,
              child: SlideTransition(
                position: _slideAnim,
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                      margin: const EdgeInsets.only(
                        bottom: 20,
                        left: 16,
                        right: 16,
                      ),
                      constraints: const BoxConstraints(maxWidth: 640),
                      decoration: BoxDecoration(
                        color: const Color(
                          0xFF1E1E1E,
                        ).withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: Row(
                              children: [
                                _buildTypeSelector(),
                                const SizedBox(width: 12),
                                Container(
                                  width: 1,
                                  height: 20,
                                  color: Colors.white24,
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: _buildColorSelector()),
                              ],
                            ),
                          ),

                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                      borderRadius: BorderRadius.circular(22),
                                    ),
                                    child: TextField(
                                      controller: _textController,
                                      focusNode: _focusNode,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: '发个友善的弹幕见证当下...',
                                        hintStyle: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.4,
                                          ),
                                          fontSize: 14,
                                        ),
                                        border: InputBorder.none,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 10,
                                            ),
                                        isDense: true,
                                      ),
                                      textInputAction: TextInputAction.send,
                                      onSubmitted: (_) => _handleSend(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                GestureDetector(
                                  onTap: _handleSend,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Theme.of(context).colorScheme.primary,
                                          Theme.of(context).colorScheme.primary
                                              .withValues(alpha: 0.8),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.4),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.arrow_upward_rounded,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTypeIcon(1, Icons.sort_rounded, '滚动'),
        const SizedBox(width: 4),
        _buildTypeIcon(5, Icons.vertical_align_top_rounded, '顶部'),
        const SizedBox(width: 4),
        _buildTypeIcon(4, Icons.vertical_align_bottom_rounded, '底部'),
      ],
    );
  }

  Widget _buildTypeIcon(int type, IconData icon, String tooltip) {
    final isSelected = _selectedType == type;
    return GestureDetector(
      onTap: () => setState(() => _selectedType = type),
      child: Tooltip(
        message: tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isSelected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildColorSelector() {
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _colors.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final color = _colors[index];
          final isSelected = _selectedColor == color;

          return GestureDetector(
            onTap: () => setState(() => _selectedColor = color),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.transparent,
                  width: 2,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: isSelected
                  ? const Center(
                      child: Icon(Icons.check, size: 14, color: Colors.black54),
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }
}
