import 'dart:convert';
import 'dart:io';

import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as webview_windows;

class WebViewPage extends StatefulWidget {
  const WebViewPage({required this.url, required this.title, super.key});
  final String url;
  final String title;

  @override
  WebViewPageState createState() => WebViewPageState();
}

class WebViewPageState extends State<WebViewPage> {
  static final bool _isDesktop = Platform.isWindows || Platform.isMacOS;
  static const _bgColor = Color.fromRGBO(17, 17, 17, 1);
  static const _accentColor = Color.fromRGBO(46, 194, 223, 1);

  late WebViewController _mobileController;
  late webview_windows.WebviewController _desktopController;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _initDesktopWebView();
    } else {
      _initMobileWebView();
    }
  }

  /// 统一处理 JS 消息，返回回调 JSON（无匹配时返回 null）
  String? _handleJsMessage(Map<String, dynamic> data) {
    final options = data['options'] as Map<String, dynamic>?;
    if (options == null) return null;

    final successId = options['success'];

    switch (data['name']) {
      case 'showToast':
        showSnackBar(options['title']);
        return '{"id":"$successId"}';
      case 'navigateTo':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WebViewPage(
              url: widget.url + options['url'],
              title: widget.title,
            ),
          ),
        );
        return '{"id":"$successId"}';
      default:
        return null;
    }
  }

  void _initMobileWebView() {
    _mobileController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'nativeChannel',
        onMessageReceived: (msg) {
          final json = _handleJsMessage(jsonDecode(msg.message));
          if (json != null) {
            _mobileController.runJavaScript(
              'window["javascriptChannel"]($json)',
            );
          }
        },
      )
      ..setBackgroundColor(_bgColor)
      ..loadRequest(Uri.parse(widget.url));
    _isReady = true;
  }

  Future<void> _initDesktopWebView() async {
    _desktopController = webview_windows.WebviewController();
    await _desktopController.initialize();
    await _desktopController.loadUrl(widget.url);

    _desktopController.webMessage.listen((message) async {
      final json = _handleJsMessage(jsonDecode(message));
      if (json != null) {
        await _desktopController.executeScript(
          'window["javascriptChannel"]($json)',
        );
      }
    });

    if (mounted) setState(() => _isReady = true);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.light,
      ),
      child: Scaffold(
        floatingActionButton: FloatingActionButton(
          mini: true,
          heroTag: 'btn1',
          onPressed: () => showSnackBar('投稿先加群丫：937149521'),
          backgroundColor: _accentColor,
          child: const Icon(Icons.add, color: Colors.white),
        ),
        backgroundColor: _bgColor,
        body: SafeArea(
          child: Stack(
            children: [
              _buildWebView(),
              Positioned(
                top: 1,
                right: 1,
                child: Container(
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(50),
                  ),
                  height: 30,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: SvgPicture.asset(
                          'assets/more.svg',
                          height: 30,
                          colorFilter: const ColorFilter.mode(
                            _accentColor,
                            BlendMode.srcIn,
                          ),
                        ),
                        onPressed: () => showSnackBar('敬请期待'),
                      ),
                      const VerticalDivider(
                        width: 1,
                        color: Color.fromRGBO(46, 194, 223, 0.6),
                      ),
                      IconButton(
                        icon: SvgPicture.asset(
                          'assets/dot-circle.svg',
                          height: 30,
                          colorFilter: const ColorFilter.mode(
                            _accentColor,
                            BlendMode.srcIn,
                          ),
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebView() {
    if (!_isReady) {
      return const AppSkeletonizer(
        enabled: true,
        baseColor: Color(0xFF161616),
        highlightColor: Color(0xFF282828),
        child: SizedBox.expand(),
      );
    }
    return _isDesktop
        ? webview_windows.Webview(_desktopController)
        : WebViewWidget(controller: _mobileController);
  }

  @override
  void dispose() {
    if (_isDesktop) _desktopController.dispose();
    super.dispose();
  }
}
