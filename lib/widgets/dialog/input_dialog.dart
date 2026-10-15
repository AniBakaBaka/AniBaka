import 'package:flutter/material.dart';

const _actionShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
);
const _actionStyle = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 12)),
  shape: WidgetStatePropertyAll(_actionShape),
);
final _boldPattern = RegExp(r'\*\*(.*?)\*\*');

class AppDialog extends StatelessWidget {
  final String title;
  final Widget? content;
  final Widget? actions;
  final bool scrollable;

  const AppDialog({
    required this.title,
    super.key,
    this.content,
    this.actions,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: theme.colorScheme.surfaceTint,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (size.width * 0.9).clamp(280, 500),
          maxHeight: size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (content != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: scrollable
                      ? SingleChildScrollView(child: content)
                      : content,
                ),
              ),
            if (actions != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: actions,
              ),
          ],
        ),
      ),
    );
  }
}

/// 一个确认按钮，可选取消按钮；取消和关闭均不返回结果。
class AppDialogActions extends StatelessWidget {
  final String confirmText;
  final VoidCallback onConfirm;
  final String? cancelText;
  final bool isDestructive;

  const AppDialogActions({
    required this.confirmText,
    required this.onConfirm,
    this.cancelText,
    this.isDestructive = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (cancelText != null) ...[
          Expanded(
            child: FilledButton.tonal(
              onPressed: () => Navigator.pop(context),
              style: _actionStyle,
              child: Text(cancelText!),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: cancelText == null && !isDestructive
              ? FilledButton.tonal(
                  onPressed: onConfirm,
                  style: _actionStyle,
                  child: Text(confirmText),
                )
              : FilledButton(
                  onPressed: onConfirm,
                  style: isDestructive
                      ? _actionStyle.copyWith(
                          backgroundColor: WidgetStatePropertyAll(colors.error),
                          foregroundColor: WidgetStatePropertyAll(
                            colors.onError,
                          ),
                        )
                      : _actionStyle,
                  child: Text(confirmText),
                ),
        ),
      ],
    );
  }
}

class _InputDialog extends StatefulWidget {
  final String title;
  final String? hintText;
  final String confirmText;
  final bool obscureText;

  const _InputDialog({
    required this.title,
    required this.hintText,
    required this.confirmText,
    required this.obscureText,
  });

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialog(
      title: widget.title,
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: widget.obscureText,
        autocorrect: !widget.obscureText,
        enableSuggestions: !widget.obscureText,
        decoration: InputDecoration(
          hintText: widget.hintText,
          filled: true,
          fillColor:
              theme.inputDecorationTheme.fillColor ??
              theme.colorScheme.surfaceContainerHighest,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
        onSubmitted: (_) => _confirm(),
      ),
      actions: AppDialogActions(
        cancelText: '取消',
        confirmText: widget.confirmText,
        onConfirm: _confirm,
      ),
    );
  }
}

/// 确认返回输入内容，取消或关闭返回 null。
Future<String?> showAppInputDialog(
  BuildContext context, {
  required String title,
  String? hintText,
  String confirmText = '确定',
  bool obscureText = false,
}) => showDialog<String>(
  context: context,
  builder: (context) => _InputDialog(
    title: title,
    hintText: hintText,
    confirmText: confirmText,
    obscureText: obscureText,
  ),
);

/// 确认返回 true，取消或关闭返回 false。
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '确定',
  String cancelText = '取消',
  bool isDestructive = false,
  bool barrierDismissible = false,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => AppDialog(
        title: title,
        content: _formattedContent(context, content),
        actions: AppDialogActions(
          cancelText: cancelText,
          confirmText: confirmText,
          onConfirm: () => Navigator.pop(context, true),
          isDestructive: isDestructive,
        ),
      ),
    ) ==
    true;

Future<void> showAppInfoDialog(
  BuildContext context, {
  required String title,
  required String content,
  String buttonText = '我知道了',
  bool barrierDismissible = true,
}) => showDialog<void>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => AppDialog(
    title: title,
    content: _formattedContent(context, content),
    actions: AppDialogActions(
      confirmText: buttonText,
      onConfirm: () => Navigator.pop(context),
    ),
  ),
);

/// 直接使用调用方的数据，按需构建可见选项；取消或关闭返回 null。
Future<T?> showAppSelectionDialog<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required String Function(T) label,
  required bool Function(T) isSelected,
  String? Function(T)? subtitle,
}) => showDialog<T>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    return AppDialog(
      title: title,
      scrollable: false,
      content: ListView.builder(
        shrinkWrap: true,
        primary: false,
        padding: EdgeInsets.zero,
        itemCount: options.length,
        itemBuilder: (context, index) {
          final option = options[index];
          final selected = isSelected(option);
          final description = subtitle?.call(option);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              shape: _actionShape,
              selected: selected,
              selectedTileColor: theme.colorScheme.primaryContainer.withValues(
                alpha: 0.5,
              ),
              title: Text(
                label(option),
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              subtitle: description == null ? null : Text(description),
              trailing: selected
                  ? const Icon(Icons.check_rounded, size: 20)
                  : null,
              onTap: () => Navigator.pop(context, option),
            ),
          );
        },
      ),
      actions: AppDialogActions(
        confirmText: '取消',
        onConfirm: () => Navigator.pop(context),
      ),
    );
  },
);

Widget _formattedContent(BuildContext context, String content) {
  final theme = Theme.of(context);
  final style = theme.textTheme.bodyMedium!.copyWith(
    height: 1.6,
    color: theme.colorScheme.onSurfaceVariant,
  );
  final boldStyle = TextStyle(
    fontWeight: FontWeight.bold,
    color: theme.colorScheme.onSurface,
  );
  final spans = <InlineSpan>[];
  var lastEnd = 0;
  for (final match in _boldPattern.allMatches(content)) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: content.substring(lastEnd, match.start)));
    }
    spans.add(TextSpan(text: match.group(1), style: boldStyle));
    lastEnd = match.end;
  }
  if (spans.isEmpty) return Text(content, style: style);
  if (lastEnd < content.length) {
    spans.add(TextSpan(text: content.substring(lastEnd)));
  }
  return Text.rich(TextSpan(children: spans), style: style);
}
