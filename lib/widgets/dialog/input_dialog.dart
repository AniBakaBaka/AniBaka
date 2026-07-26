import 'package:flutter/material.dart';

/// 对话框返回结果枚举
enum DialogAction { confirm, cancel }

/// 输入对话框结果
class InputDialogResult {
  final DialogAction action;
  final String? value;

  const InputDialogResult(this.action, [this.value]);

  bool get isConfirmed => action == DialogAction.confirm;
}

/// 选择对话框选项
class SelectionOption<T> {
  final T value;
  final String label;
  final String? subtitle;

  const SelectionOption({
    required this.value,
    required this.label,
    this.subtitle,
  });
}

class _DialogConstants {
  static const double borderRadius = 24.0;
  static const double actionBorderRadius = 12.0;
  static const EdgeInsets contentPadding = EdgeInsets.all(24);
  static const EdgeInsets actionButtonPadding = EdgeInsets.symmetric(
    vertical: 12,
  );
  static const double actionSpacing = 12.0;
  static const double maxWidthRatio = 0.9;
  static const double maxWidthLimit = 500.0;
  static const double minDialogWidth = 280.0;

  static RoundedRectangleBorder get actionShape => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(actionBorderRadius),
  );
}

/// App对话框基础组件
/// 使用Theme系统，响应式布局，正确处理滚动
class AppDialog extends StatelessWidget {
  final String title;
  final String? content;
  final Widget? contentWidget;
  final List<Widget>? actions;

  const AppDialog({
    required this.title,
    super.key,
    this.content,
    this.contentWidget,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final screenWidth = MediaQuery.of(context).size.width;

    final maxWidth = (screenWidth * _DialogConstants.maxWidthRatio).clamp(
      _DialogConstants.minDialogWidth,
      _DialogConstants.maxWidthLimit,
    );

    final contentArea =
        contentWidget ??
        (content != null
            ? Text(
                content!,
                style: textTheme.bodyMedium?.copyWith(
                  height: 1.6,
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            : null);

    return Dialog(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: colorScheme.surfaceTint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_DialogConstants.borderRadius),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: _DialogConstants.contentPadding,
              child: Text(
                title,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            if (contentArea != null)
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    left: _DialogConstants.contentPadding.left,
                    right: _DialogConstants.contentPadding.right,
                    bottom: 16,
                  ),
                  child: contentArea,
                ),
              ),
            if (actions != null && actions!.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  left: _DialogConstants.contentPadding.left,
                  right: _DialogConstants.contentPadding.right,
                  bottom: _DialogConstants.contentPadding.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: actions!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// App输入对话框
class AppInputDialog extends StatefulWidget {
  final String title;
  final String? hintText;
  final String? initialValue;
  final int maxLines;
  final String confirmText;
  final String cancelText;
  final TextInputType? keyboardType;

  const AppInputDialog({
    required this.title,
    super.key,
    this.hintText = '请输入...',
    this.initialValue,
    this.maxLines = 1,
    this.confirmText = '确定',
    this.cancelText = '取消',
    this.keyboardType,
  });

  @override
  State<AppInputDialog> createState() => _AppInputDialogState();
}

class _AppInputDialogState extends State<AppInputDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleConfirm() {
    Navigator.pop(
      context,
      InputDialogResult(DialogAction.confirm, _controller.text),
    );
  }

  void _handleCancel() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final inputTheme = theme.inputDecorationTheme;

    return AppDialog(
      title: widget.title,
      contentWidget: TextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: widget.keyboardType,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          hintText: widget.hintText,
          filled: true,
          fillColor:
              inputTheme.fillColor ?? colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(
              _DialogConstants.actionBorderRadius,
            ),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(
              _DialogConstants.actionBorderRadius,
            ),
            borderSide: BorderSide(color: colorScheme.primary, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
        onSubmitted: (_) => _handleConfirm(),
      ),
      actions: [
        _buildDialogActionRow(
          context,
          cancelText: widget.cancelText,
          confirmText: widget.confirmText,
          onCancel: _handleCancel,
          onConfirm: _handleConfirm,
        ),
      ],
    );
  }
}

Widget _buildDialogActionRow(
  BuildContext context, {
  required String cancelText,
  required String confirmText,
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
  bool isDestructive = false,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  return Row(
    children: [
      Expanded(
        child: FilledButton.tonal(
          onPressed: onCancel,
          style: FilledButton.styleFrom(
            padding: _DialogConstants.actionButtonPadding,
            shape: _DialogConstants.actionShape,
          ),
          child: Text(cancelText),
        ),
      ),
      const SizedBox(width: _DialogConstants.actionSpacing),
      Expanded(
        child: FilledButton(
          onPressed: onConfirm,
          style: FilledButton.styleFrom(
            padding: _DialogConstants.actionButtonPadding,
            backgroundColor: isDestructive ? colorScheme.error : null,
            foregroundColor: isDestructive ? colorScheme.onError : null,
            shape: _DialogConstants.actionShape,
          ),
          child: Text(confirmText),
        ),
      ),
    ],
  );
}

/// App确认对话框
class AppConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmText;
  final String cancelText;
  final bool isDestructive;

  const AppConfirmDialog({
    required this.title,
    required this.content,
    super.key,
    this.confirmText = '确定',
    this.cancelText = '取消',
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: title,
      content: content,
      actions: [
        _buildDialogActionRow(
          context,
          cancelText: cancelText,
          confirmText: confirmText,
          onCancel: () => Navigator.pop(context, DialogAction.cancel),
          onConfirm: () => Navigator.pop(context, DialogAction.confirm),
          isDestructive: isDestructive,
        ),
      ],
    );
  }
}

/// App信息对话框（单按钮）
class AppInfoDialog extends StatelessWidget {
  final String title;
  final String content;
  final String buttonText;

  const AppInfoDialog({
    required this.title,
    required this.content,
    super.key,
    this.buttonText = '我知道了',
  });

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: title,
      content: content,
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            padding: _DialogConstants.actionButtonPadding,
            minimumSize: const Size(double.infinity, 0),
            shape: _DialogConstants.actionShape,
          ),
          child: Text(buttonText),
        ),
      ],
    );
  }
}

/// 显示App输入对话框
///
/// 返回 [InputDialogResult]，可通过 `isConfirmed` 判断是否确认
Future<InputDialogResult?> showAppInputDialog(
  BuildContext context, {
  required String title,
  String? hintText,
  String? initialValue,
  int maxLines = 1,
  String confirmText = '确定',
  String cancelText = '取消',
  TextInputType? keyboardType,
  bool barrierDismissible = true,
}) {
  return showDialog<InputDialogResult>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AppInputDialog(
      title: title,
      hintText: hintText,
      initialValue: initialValue,
      maxLines: maxLines,
      confirmText: confirmText,
      cancelText: cancelText,
      keyboardType: keyboardType,
    ),
  );
}

/// 显示App确认对话框
///
/// 返回 [DialogAction]，确认返回 `DialogAction.confirm`，取消返回 `DialogAction.cancel`
Future<DialogAction?> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '确定',
  String cancelText = '取消',
  bool isDestructive = false,
  bool barrierDismissible = false,
}) {
  return showDialog<DialogAction>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AppConfirmDialog(
      title: title,
      content: content,
      confirmText: confirmText,
      cancelText: cancelText,
      isDestructive: isDestructive,
    ),
  );
}

/// 显示App信息对话框
Future<void> showAppInfoDialog(
  BuildContext context, {
  required String title,
  required String content,
  String buttonText = '我知道了',
  bool barrierDismissible = true,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) =>
        AppInfoDialog(title: title, content: content, buttonText: buttonText),
  );
}

/// App选择对话框
class AppSelectionDialog<T> extends StatelessWidget {
  final String title;
  final List<SelectionOption<T>> options;
  final T? currentValue;
  final String cancelText;

  const AppSelectionDialog({
    required this.title,
    required this.options,
    this.currentValue,
    this.cancelText = '取消',
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AppDialog(
      title: title,
      contentWidget: Column(
        mainAxisSize: MainAxisSize.min,
        children: options.map((option) {
          final isSelected = option.value == currentValue;
          return InkWell(
            onTap: () => Navigator.pop(context, option.value),
            borderRadius: BorderRadius.circular(
              _DialogConstants.actionBorderRadius,
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  _DialogConstants.actionBorderRadius,
                ),
                color: isSelected
                    ? colorScheme.primaryContainer.withValues(alpha: 0.5)
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          option.label,
                          style: textTheme.bodyLarge?.copyWith(
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: isSelected
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                          ),
                        ),
                        if (option.subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              option.subtitle!,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_rounded,
                      color: colorScheme.primary,
                      size: 20,
                    ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            padding: _DialogConstants.actionButtonPadding,
            minimumSize: const Size(double.infinity, 0),
            shape: _DialogConstants.actionShape,
          ),
          child: Text(cancelText),
        ),
      ],
    );
  }
}

/// 显示App选择对话框
///
/// 返回选中的值，取消或点击外部返回 null
Future<T?> showAppSelectionDialog<T>(
  BuildContext context, {
  required String title,
  required List<SelectionOption<T>> options,
  T? currentValue,
  String cancelText = '取消',
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AppSelectionDialog<T>(
      title: title,
      options: options,
      currentValue: currentValue,
      cancelText: cancelText,
    ),
  );
}
