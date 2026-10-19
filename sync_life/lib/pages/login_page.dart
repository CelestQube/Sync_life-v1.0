import 'package:flutter/material.dart';
import '../ui/app_theme.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../mocap/user_session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final TextEditingController _identifierController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;
  String _errorMessage = '';

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final String identifier = _identifierController.text.trim();
    final String password = _passwordController.text.trim();

    if (identifier.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = '请输入手机号/邮箱和密码';
        _isLoading = false;
      });
      return;
    }

    try {
      print('开始登录请求，URL: ${ApiConfig.loginUrl}');
      print('请求数据: {"identifier": "$identifier", "password": "***"}');

      final response = await http
          .post(
            Uri.parse(ApiConfig.loginUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'identifier': identifier,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 10)); // 添加10秒超时

      print('登录请求响应状态码: ${response.statusCode}');

      final data = jsonDecode(response.body);
      if (!mounted) return;

      if (response.statusCode == 200 && data['status'] == 'success') {
        // 登录成功，保存用户信息到本地存储
        await UserSession.instance.signIn(data['user_id'] as int,
            (data['access_token'] as String?) ?? '', identifier);

        // 跳转到主页
        if (mounted) Navigator.pushReplacementNamed(context, '/main');
      } else {
        setState(() {
          _errorMessage = data['error'] ?? '登录失败';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '网络错误: $e';
      });
      print('登录网络错误详情: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight:
                        (constraints.maxHeight - 44).clamp(0, double.infinity)),
                child: Center(
                    child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                                padding: const EdgeInsets.all(15),
                                decoration: BoxDecoration(
                                    color: AppColors.soft,
                                    borderRadius: BorderRadius.circular(20)),
                                child: const Icon(Icons.spa_outlined,
                                    size: 36, color: AppColors.primary))),
                        const SizedBox(height: 22),
                        const Text('同律 Sync-Life',
                            style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                color: AppColors.deep)),
                        const SizedBox(height: 8),
                        const Text('记录活动，照顾日常。',
                            style: TextStyle(
                                fontSize: 16, color: AppColors.muted)),
                        const SizedBox(height: 28),
                        AppCard(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                              const Text('欢迎回来',
                                  style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 20),
                              TextField(
                                  controller: _identifierController,
                                  textInputAction: TextInputAction.next,
                                  autofillHints: const [AutofillHints.username],
                                  decoration: const InputDecoration(
                                      labelText: '手机号 / 邮箱',
                                      prefixIcon:
                                          Icon(Icons.person_outline_rounded))),
                              const SizedBox(height: 16),
                              TextField(
                                  controller: _passwordController,
                                  obscureText: true,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) {
                                    if (!_isLoading) _login();
                                  },
                                  autofillHints: const [AutofillHints.password],
                                  decoration: const InputDecoration(
                                      labelText: '密码',
                                      prefixIcon:
                                          Icon(Icons.lock_outline_rounded))),
                              if (_errorMessage.isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Text(_errorMessage,
                                        style: const TextStyle(
                                            color: AppColors.danger))),
                              const SizedBox(height: 22),
                              FilledButton(
                                  onPressed: _isLoading ? null : _login,
                                  child: _isLoading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2))
                                      : const Text('登录',
                                          style: TextStyle(fontSize: 16))),
                            ])),
                        TextButton(
                            onPressed: () =>
                                Navigator.pushNamed(context, '/register'),
                            child: const Text('还没有账号？立即注册')),
                      ]),
                )),
              )),
        )),
      );
}
