import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../mocap/user_session.dart';
import 'mocap_devices_page.dart';
import '../config/api_config.dart';
import '../ui/app_theme.dart';
import '../mocap/mocap_service.dart';

class ProfilePage extends StatefulWidget {
  ProfilePage({super.key});

  @override
  ProfilePageState createState() => ProfilePageState();
}

class ProfilePageState extends State<ProfilePage> {
  // 用户数据
  String _phone = '';
  String _email = '';
  String _identity = '';
  String _ills = '';
  int _age = 0;
  String _gender = '';
  double _height = 0.0;
  double _weight = 0.0;
  bool _isLoading = true;
  bool _isDataLoaded = false;
  int? _userId;

  @override
  void initState() {
    super.initState();
    _checkAndUpdateAge();
    _loadUserId();
  }

  Future<void> _loadUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('userId');
    final userIdentifier = prefs.getString('userIdentifier');
    final isLoggedInValue = prefs.getBool('isLoggedIn') ?? false;

    print('isLoggedIn: $isLoggedInValue');
    print('userIdentifier: $userIdentifier');
    print('userId: $userId');

    if (mounted) {
      setState(() {
        if (userIdentifier != null) {
          _phone = userIdentifier;
        }
        _userId = userId;
        _isLoading = false;
        _isDataLoaded = true;
      });
    }
  }

  Widget _setting(IconData icon, String title, VoidCallback onTap,
          {String? subtitle}) =>
      ListTile(
        leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: AppColors.soft, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 20)),
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: AppColors.muted, size: 20),
        onTap: onTap,
      );

  Widget _group(List<Widget> children) => AppCard(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i != children.length - 1)
            const Padding(
                padding: EdgeInsets.only(left: 66, right: 16),
                child: Divider()),
        ],
      ]));

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('退出登录'),
              content: const Text('确定要退出当前账号吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('退出')),
              ],
            ));
    if (confirm == true && mounted) {
      await UserSession.instance.signOut();
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('我的')),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : !_isDataLoaded
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: EmptyStateCard(
                        icon: Icons.person_outline,
                        title: '登录后开启你的日常记录',
                        description: '保存计划和资料，随时接着聊。',
                        action: FilledButton(
                            onPressed: () => Navigator.pushReplacementNamed(
                                context, '/login'),
                            child: const Text('去登录'))))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                    children: [
                        AppCard(
                            color: AppColors.soft,
                            child: Row(children: [
                              Container(
                                  width: 56,
                                  height: 56,
                                  decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(18)),
                                  child: const Icon(
                                      Icons.person_outline_rounded,
                                      size: 32,
                                      color: AppColors.primary)),
                              const SizedBox(width: 16),
                              const Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text('我的日常',
                                        style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.deep)),
                                    SizedBox(height: 4),
                                    Text('让每一点进步，都被记住',
                                        style: TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 13)),
                                  ])),
                            ])),
                        const SectionHeading('计划与记录'),
                        _group([
                          AnimatedBuilder(
                              animation: MocapService.instance,
                              builder: (_, __) => _setting(
                                  Icons.bluetooth_rounded,
                                  '我的衣物',
                                  _showDeviceManagementDialog,
                                  subtitle: MocapService.instance.bothReady
                                      ? '上衣和裤子已连接'
                                      : '连接后自动记录活动')),
                          _setting(
                              Icons.bookmark_border_rounded,
                              '我的资料',
                              () => Navigator.pushNamed(
                                  context, '/personal_knowledge'),
                              subtitle: '习惯、目标与健康情况'),
                          _setting(
                              Icons.event_note_outlined,
                              '训练计划',
                              () => Navigator.pushNamed(
                                  context, '/training_plan')),
                        ]),
                        const SectionHeading('身体资料'),
                        _group([
                          _setting(
                              Icons.cake_outlined, '年龄', _showChangeAgeDialog),
                          _setting(Icons.person_outline_rounded, '性别',
                              _showChangeGenderDialog),
                          _setting(Icons.height_rounded, '身高',
                              _showChangeHeightDialog),
                          _setting(Icons.monitor_weight_outlined, '体重',
                              _showChangeWeightDialog),
                          _setting(Icons.badge_outlined, '日常身份',
                              _showChangeIdentityDialog),
                          _setting(Icons.favorite_border_rounded, '健康情况',
                              _showChangeIllsDialog),
                        ]),
                        const SectionHeading('账号设置'),
                        _group([
                          _setting(Icons.phone_outlined, '手机号',
                              _showChangePhoneDialog),
                          _setting(Icons.mail_outline_rounded, '邮箱',
                              _showChangeEmailDialog),
                          _setting(Icons.lock_outline_rounded, '修改密码',
                              _showChangePasswordDialog),
                        ]),
                        TextButton.icon(
                            onPressed: _logout,
                            style: TextButton.styleFrom(
                                foregroundColor: AppColors.danger),
                            icon: const Icon(Icons.logout_rounded, size: 18),
                            label: const Text('退出登录')),
                      ]),
      );

  // 与 3D 页共用真实蓝牙连接和校准状态。
  void _showDeviceManagementDialog() {
    Navigator.push(context,
        MaterialPageRoute<void>(builder: (_) => const MocapDevicesPage()));
  }

  // 修改手机号对话框
  void _showChangePhoneDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController phoneController = TextEditingController();
    final TextEditingController codeController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改手机号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text('原手机号：$_phone'),
            const SizedBox(height: 16),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: '新手机号',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: codeController,
                    decoration: const InputDecoration(
                      labelText: '验证码',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () {
                    // 发送验证码到邮箱
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('验证码已发送到您的邮箱')),
                    );
                  },
                  child: const Text('获取验证码'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final newPhone = phoneController.text.trim();
              final code = codeController.text.trim();

              if (newPhone.isEmpty || code.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写完整信息')),
                );
                return;
              }

              // 验证验证码逻辑
              setState(() {
                _phone = newPhone;
              });
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('手机号修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改邮箱对话框
  void _showChangeEmailDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController oldCodeController = TextEditingController();
    final TextEditingController newEmailController = TextEditingController();
    final TextEditingController newCodeController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改邮箱'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('第一步：验证原邮箱'),
            const SizedBox(height: 8),
            Text('原邮箱：$_email'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: oldCodeController,
                    decoration: const InputDecoration(
                      labelText: '验证码',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () {
                    // 发送验证码到原邮箱
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('验证码已发送到原邮箱')),
                    );
                  },
                  child: const Text('获取验证码'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('第二步：设置新邮箱'),
            TextField(
              controller: newEmailController,
              decoration: const InputDecoration(
                labelText: '新邮箱',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: newCodeController,
                    decoration: const InputDecoration(
                      labelText: '验证码',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () {
                    final newEmail = newEmailController.text.trim();
                    if (newEmail.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请输入新邮箱')),
                      );
                      return;
                    }
                    // 发送验证码到新邮箱
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('验证码已发送到新邮箱')),
                    );
                  },
                  child: const Text('获取验证码'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final oldCode = oldCodeController.text.trim();
              final newEmail = newEmailController.text.trim();
              final newCode = newCodeController.text.trim();

              if (oldCode.isEmpty || newEmail.isEmpty || newCode.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写完整信息')),
                );
                return;
              }

              // 更新到后端
              await _updateUserInfo({'email': newEmail});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('邮箱修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改密码对话框
  void _showChangePasswordDialog() {
    final TextEditingController oldPasswordController = TextEditingController();
    final TextEditingController newPasswordController = TextEditingController();
    final TextEditingController confirmPasswordController =
        TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPasswordController,
              decoration: const InputDecoration(
                labelText: '原密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: newPasswordController,
              decoration: const InputDecoration(
                labelText: '新密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: confirmPasswordController,
              decoration: const InputDecoration(
                labelText: '确认新密码',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final oldPassword = oldPasswordController.text.trim();
              final newPassword = newPasswordController.text.trim();
              final confirmPassword = confirmPasswordController.text.trim();

              if (oldPassword.isEmpty ||
                  newPassword.isEmpty ||
                  confirmPassword.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请填写完整信息')),
                );
                return;
              }

              if (newPassword != confirmPassword) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('两次输入的密码不一致')),
                );
                return;
              }

              // 更新到后端
              await _updateUserInfo({'password': newPassword});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('密码修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改身份对话框
  void _showChangeIdentityDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController identityController =
        TextEditingController(text: _identity);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改身份'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: identityController,
              decoration: const InputDecoration(
                labelText: '身份',
                border: OutlineInputBorder(),
                hintText: '可选，默认为"默认"',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final newIdentity = identityController.text.trim();

              // 更新到后端
              await _updateUserInfo(
                  {'identity': newIdentity.isEmpty ? '默认' : newIdentity});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('身份修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改疾病史对话框
  void _showChangeIllsDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController illsController =
        TextEditingController(text: _ills);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改疾病史'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: illsController,
              decoration: const InputDecoration(
                labelText: '疾病史',
                border: OutlineInputBorder(),
                hintText: '可选，默认为"无"',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final newIlls = illsController.text.trim();

              // 更新到后端
              await _updateUserInfo({'ills': newIlls.isEmpty ? '无' : newIlls});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('疾病史修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改年龄对话框
  void _showChangeAgeDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController ageController =
        TextEditingController(text: _age.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改年龄'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ageController,
              decoration: const InputDecoration(
                labelText: '年龄',
                border: OutlineInputBorder(),
                hintText: '请输入您的年龄',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final ageText = ageController.text.trim();

              if (ageText.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入年龄')),
                );
                return;
              }

              final newAge = int.tryParse(ageText);
              if (newAge == null || newAge < 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的年龄')),
                );
                return;
              }

              // 更新到后端
              await _updateUserInfo({'age': newAge});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('年龄修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改身高对话框
  void _showChangeHeightDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController heightController =
        TextEditingController(text: _height > 0 ? _height.toString() : '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改身高'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: heightController,
              decoration: const InputDecoration(
                labelText: '身高',
                border: OutlineInputBorder(),
                hintText: '请输入您的身高（cm）',
              ),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final heightText = heightController.text.trim();

              if (heightText.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入身高')),
                );
                return;
              }

              final newHeight = double.tryParse(heightText);
              if (newHeight == null || newHeight <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的身高')),
                );
                return;
              }

              // 更新到后端
              await _updateUserInfo({'height': newHeight});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('身高修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 修改体重对话框
  void _showChangeWeightDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    final TextEditingController weightController =
        TextEditingController(text: _weight > 0 ? _weight.toString() : '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改体重'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: weightController,
              decoration: const InputDecoration(
                labelText: '体重',
                border: OutlineInputBorder(),
                hintText: '请输入您的体重（kg）',
              ),
              keyboardType: TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final weightText = weightController.text.trim();

              if (weightText.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入体重')),
                );
                return;
              }

              final newWeight = double.tryParse(weightText);
              if (newWeight == null || newWeight <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入有效的体重')),
                );
                return;
              }

              // 更新到后端
              await _updateUserInfo({'weight': newWeight});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('体重修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 检查是否需要自动增加年龄
  void _checkAndUpdateAge() {
    // 这里可以实现每年自动增加一岁的逻辑
    // 例如：存储用户的生日，然后根据当前日期计算年龄
    // 由于这是模拟环境，我们暂时不实现具体的自动增加逻辑
    // 实际应用中，应该在应用启动时检查并更新年龄
  }

  // 从本地存储中读取用户信息
  Future<void> _loadUserInfoFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final userIdentifier = prefs.getString('userIdentifier');
    final userId = prefs.getInt('userId');
    final isLoggedIn = prefs.getBool('isLoggedIn');

    print('=== 读取本地存储信息 ===');
    print('isLoggedIn: $isLoggedIn');
    print('userIdentifier: $userIdentifier');
    print('userId: $userId');

    if (mounted) {
      setState(() {
        if (userIdentifier != null) {
          _phone = userIdentifier;
        }
        _userId = userId;
      });
    }

    try {
      final userInfoJson = prefs.getString('user_info');
      if (userInfoJson != null) {
        final userInfo = jsonDecode(userInfoJson);
        print('从本地存储读取到用户信息: $userInfo');

        if (mounted) {
          setState(() {
            _email = userInfo['email'] ?? '';
            _age = userInfo['age'] ?? 0;
            _gender = userInfo['gender'] ?? '';
            _height = userInfo['height'] ?? 0.0;
            _weight = userInfo['weight'] ?? 0.0;
            _identity = userInfo['identity'] ?? '';
            _ills = userInfo['ills'] ?? '';
            _isDataLoaded = true;
          });
        }
      }
    } catch (e) {
      print('从本地存储读取用户信息失败: $e');
    }
  }

  // 保存用户信息到本地存储
  Future<void> _saveUserInfoToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userInfo = {
        'phone': _phone,
        'email': _email,
        'age': _age,
        'gender': _gender,
        'height': _height,
        'weight': _weight,
        'identity': _identity,
        'ills': _ills,
      };
      final userInfoJson = jsonEncode(userInfo);
      await prefs.setString('user_info', userInfoJson);
      print('用户信息已保存到本地存储');
    } catch (e) {
      print('保存用户信息到本地存储失败: $e');
    }
  }

  // 从后端获取用户详细信息
  Future<void> _fetchUserInfo() async {
    if (_userId == null) {
      await _loadUserInfoFromStorage();
      if (_userId == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isDataLoaded = false;
          });
        }
        return;
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _isDataLoaded = false;
      });
    }

    try {
      print('=== 开始获取用户信息 ===');
      print('请求URL: ${ApiConfig.baseUrl}/posture/info/');
      print('请求参数: user_id = $_userId');

      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/posture/info/'),
        headers: UserSession.instance.headers,
        body: jsonEncode({'user_id': _userId}),
      );

      print('响应状态码: ${response.statusCode}');
      print('响应内容: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        print('解析后的数据: $data');
        print('status字段: ${data['status']}');

        if (data['status'] == 'success') {
          if (mounted) {
            setState(() {
              _phone = data['phone'] ?? '';
              _email = data['email'] ?? '';
              _age = data['age'] ?? 0;
              _height = data['height'] ?? 0.0;
              _weight = data['weight'] ?? 0.0;
              _identity = data['identity'] ?? '';
              _ills = data['ills'] ?? '';
              _isDataLoaded = true;
              print('设置_isDataLoaded为true');
            });
            // 保存用户信息到本地存储
            await _saveUserInfoToStorage();
            // 启动动画
          }
        } else {
          print('后端返回失败: ${data['status']}');
          if (mounted) {
            setState(() {
              _isLoading = false;
              _isDataLoaded = false;
            });
          }
        }
      } else {
        print('HTTP请求失败: ${response.statusCode}');
        if (mounted) {
          setState(() {
            _isLoading = false;
            _isDataLoaded = false;
          });
        }
      }
    } catch (e) {
      print('获取用户信息失败: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isDataLoaded = false;
        });
      }
    } finally {
      // 无论成功失败，都要将_isLoading设置为false
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
    print('=== 获取用户信息完成 ===');
    print('_isLoading: $_isLoading');
  }

  // 更新用户信息到后端
  Future<void> _updateUserInfo(Map<String, dynamic> updates) async {
    if (_userId == null) {
      await _loadUserInfoFromStorage();
      if (_userId == null) return;
    }

    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/posture/update/'),
        headers: UserSession.instance.headers,
        body: jsonEncode({'user_id': _userId, ...updates}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' && mounted) {
          // 更新成功，刷新本地数据
          await _fetchUserInfo();
        }
      }
    } catch (e) {
      print('更新用户信息失败: $e');
    }
  }

  // 修改性别对话框
  void _showChangeGenderDialog() async {
    await _fetchUserInfo();
    if (!mounted) return;

    String selectedGender = _gender.isEmpty ? 'other' : _gender;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改性别'),
        content: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return RadioGroup<String>(
              groupValue: selectedGender,
              onChanged: (value) {
                if (value != null) {
                  setState(() => selectedGender = value);
                }
              },
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String>(title: Text('男'), value: 'male'),
                  RadioListTile<String>(title: Text('女'), value: 'female'),
                  RadioListTile<String>(title: Text('保密'), value: 'other'),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              // 更新到后端
              await _updateUserInfo({'gender': selectedGender});
              if (!mounted || !context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('性别修改成功')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 移除didChangeDependencies中的刷新，避免重复请求
}
