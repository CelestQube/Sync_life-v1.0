import 'package:flutter/material.dart';
import 'dart:async';
import '../ui/app_theme.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  RegisterPageState createState() => RegisterPageState();
}

class RegisterPageState extends State<RegisterPage> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _verificationCodeController =
      TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _identityController = TextEditingController();
  final TextEditingController _illsController = TextEditingController();
  bool _isLoading = false;
  bool _isSendingCode = false;
  int _countdown = 0;
  String _errorMessage = '';

  Timer? _countdownTimer;
  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    for (final controller in [
      _phoneController,
      _emailController,
      _verificationCodeController,
      _passwordController,
      _ageController,
      _weightController,
      _heightController,
      _identityController,
      _illsController
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _sendVerificationCode() async {
    final String email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _errorMessage = '请输入邮箱地址';
      });
      return;
    }

    setState(() {
      _isSendingCode = true;
      _errorMessage = '';
    });

    try {
      final response = await http.post(
        Uri.parse(ApiConfig.sendCodeUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
        }),
      );

      if (!mounted) return;
      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == 'success') {
        _startCountdown();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('验证码已发送到您的邮箱')),
        );
      } else {
        setState(() {
          _errorMessage = data['error'] ?? '发送验证码失败';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '网络错误，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _isSendingCode = false);
    }
  }

  Future<void> _register() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    final String phone = _phoneController.text.trim();
    final String email = _emailController.text.trim();
    final String verificationCode = _verificationCodeController.text.trim();
    final String password = _passwordController.text.trim();
    final String ageStr = _ageController.text.trim();
    final String weightStr = _weightController.text.trim();
    final String heightStr = _heightController.text.trim();
    final String identity = _identityController.text.trim();
    final String ills = _illsController.text.trim();

    if (phone.isEmpty ||
        email.isEmpty ||
        verificationCode.isEmpty ||
        password.isEmpty ||
        ageStr.isEmpty ||
        weightStr.isEmpty ||
        heightStr.isEmpty) {
      setState(() {
        _errorMessage = '请填写所有必填字段';
        _isLoading = false;
      });
      return;
    }

    int age;
    double weight;
    double height;

    try {
      age = int.parse(ageStr);
      weight = double.parse(weightStr);
      height = double.parse(heightStr);
    } catch (e) {
      setState(() {
        _errorMessage = '请输入有效的年龄、体重和身高';
        _isLoading = false;
      });
      return;
    }

    try {
      final response = await http.post(
        Uri.parse(ApiConfig.registerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'phone': phone,
          'email': email,
          'password': password,
          'verification_code': verificationCode,
          'age': age,
          'weight': weight,
          'height': height,
          'identity': identity,
          'ills': ills,
        }),
      );

      if (!mounted) return;
      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['status'] == 'success') {
        // 注册成功，保存登录状态到本地存储
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('isLoggedIn', true);
        await prefs.setString('userIdentifier', phone);

        // 跳转到主页
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/main');
      } else {
        setState(() {
          _errorMessage = data['error'] ?? '注册失败';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '网络错误，请稍后重试';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _field(TextEditingController controller, String label, IconData icon,
          {TextInputType keyboard = TextInputType.text, bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
            controller: controller,
            obscureText: secret,
            keyboardType: keyboard,
            textInputAction: TextInputAction.next,
            decoration:
                InputDecoration(labelText: label, prefixIcon: Icon(icon))),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('创建账号')),
        body: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('开启你的日常记录',
                          style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              color: AppColors.deep)),
                      const SizedBox(height: 8),
                      const Text('留下基本信息，方便安排适合你的活动。',
                          style: TextStyle(color: AppColors.muted)),
                      const SizedBox(height: 22),
                      AppCard(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            const Text('账号信息',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 18),
                            _field(
                                _phoneController, '手机号', Icons.phone_outlined,
                                keyboard: TextInputType.phone),
                            _field(_emailController, '邮箱',
                                Icons.mail_outline_rounded,
                                keyboard: TextInputType.emailAddress),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                      child: _field(_verificationCodeController,
                                          '邮箱验证码', Icons.verified_outlined,
                                          keyboard: TextInputType.number)),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                      width: 104,
                                      child: FilledButton(
                                          onPressed:
                                              (_isSendingCode || _countdown > 0)
                                                  ? null
                                                  : _sendVerificationCode,
                                          child: _isSendingCode
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2))
                                              : Text(
                                                  _countdown > 0
                                                      ? '$_countdown 秒'
                                                      : '获取验证码',
                                                  style: const TextStyle(
                                                      fontSize: 12)))),
                                ]),
                            _field(_passwordController, '密码',
                                Icons.lock_outline_rounded,
                                secret: true),
                          ])),
                      AppCard(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            const Text('身体资料',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 18),
                            _field(_ageController, '年龄', Icons.cake_outlined,
                                keyboard: TextInputType.number),
                            _field(_heightController, '身高（厘米）',
                                Icons.height_rounded,
                                keyboard: const TextInputType.numberWithOptions(
                                    decimal: true)),
                            _field(_weightController, '体重（公斤）',
                                Icons.monitor_weight_outlined,
                                keyboard: const TextInputType.numberWithOptions(
                                    decimal: true)),
                            _field(_identityController, '日常身份（选填）',
                                Icons.badge_outlined),
                            _field(_illsController, '健康情况（选填）',
                                Icons.favorite_border_rounded),
                          ])),
                      if (_errorMessage.isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(_errorMessage,
                                style:
                                    const TextStyle(color: AppColors.danger))),
                      FilledButton(
                          onPressed: _isLoading ? null : _register,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Text('注册并开始',
                                  style: TextStyle(fontSize: 16))),
                      const SizedBox(height: 8),
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('已有账号？返回登录')),
                    ]),
              )),
            )),
      );
}
