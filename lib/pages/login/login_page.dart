import 'package:baka/api/post.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/network_service.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:get/get.dart';
import 'package:baka/widgets/common/tab_indicator.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

class Login extends StatefulWidget {
  const Login({super.key});

  @override
  LoginState createState() => LoginState();
}

class LoginState extends State<Login> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _nameController = TextEditingController();
  final _pwdController = TextEditingController();
  final _qqController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameController.dispose();
    _pwdController.dispose();
    _qqController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final name = _nameController.text.trim();
    final pwd = _pwdController.text.trim();
    if (name.isEmpty || pwd.isEmpty) {
      showSnackBar('什么都没有输入');
      return;
    }
    showSnackBar('登录中···');
    try {
      final res = jsonDecode(
        (await login({'name': name, 'pwd': pwd, 'platform': 'app'})).data,
      );
      if (res['code'] != 200) {
        showSnackBar(res['msg']);
        return;
      }
      await NetUtils.saveTokenResponse(Map<String, dynamic>.from(res));
      await Instances.sp.setString('userinfo', jsonEncode(res['user']));
      Get.find<AppState>().triggerLoginRefresh();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (_) {
      showSnackBar('登录失败，请检查网络');
    }
  }

  Future<void> _register() async {
    final name = _nameController.text.trim();
    final pwd = _pwdController.text.trim();
    final qq = _qqController.text.trim();
    if (name.isEmpty || pwd.isEmpty || qq.isEmpty) {
      showSnackBar('请填写完整信息');
      return;
    }
    try {
      final res = jsonDecode(
        (await register({'name': name, 'pwd': pwd, 'qq': qq})).data,
      );
      showSnackBar(res['msg']);
      if (res['code'] == 200) {
        _tabController.index = 0;
      }
    } catch (_) {
      showSnackBar('注册失败，请检查网络');
    }
  }

  Widget _buildInput({
    required String hint,
    required TextEditingController controller,
    bool obscure = false,
  }) {
    return Container(
      margin: const EdgeInsets.all(10.0),
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: Colors.black12,
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration.collapsed(hintText: hint),
      ),
    );
  }

  ButtonStyle get _buttonStyle => ButtonStyle(
    backgroundColor: WidgetStateProperty.all(
      Theme.of(context).colorScheme.primary,
    ),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
    ),
  );

  Widget buildLogin() {
    return Column(
      children: [
        _buildInput(hint: '用户名或qq', controller: _nameController),
        _buildInput(hint: '密码', controller: _pwdController, obscure: true),
        Padding(
          padding: const EdgeInsets.all(10),
          child: ElevatedButton(
            style: _buttonStyle,
            onPressed: _login,
            child: const Text(
              '登录',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildRegister() {
    return Column(
      children: [
        _buildInput(hint: 'QQ', controller: _qqController),
        _buildInput(hint: '用户名', controller: _nameController),
        _buildInput(hint: '密码', controller: _pwdController, obscure: true),
        Padding(
          padding: const EdgeInsets.all(10),
          child: ElevatedButton(
            style: _buttonStyle,
            onPressed: _register,
            child: const Text(
              '注册',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.primary),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(50),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/ic_launcher.png', height: 80),
              ),
              const SizedBox(height: 30),
              TabBar(
                tabAlignment: TabAlignment.center,
                controller: _tabController,
                isScrollable: true,
                labelStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.normal,
                ),
                indicator: ArcTabIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
                dividerColor: Colors.transparent,
                tabs: const [
                  Center(child: Text('登录')),
                  Center(child: Text('注册')),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TabBarView(
                    controller: _tabController,
                    children: [buildLogin(), buildRegister()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
