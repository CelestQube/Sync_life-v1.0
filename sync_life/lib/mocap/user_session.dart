import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserSession extends ChangeNotifier {
  UserSession._();
  @visibleForTesting
  UserSession.forTesting();
  static final instance = UserSession._();
  Future<void>? _loading;
  bool _initialized = false;
  int? userId;
  String? token;
  bool get authenticated =>
      userId != null && token != null && token!.isNotEmpty;

  Future<void> initialize() =>
      _initialized ? Future<void>.value() : (_loading ??= _load());
  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('isLoggedIn') == true) {
      userId = preferences.getInt('userId');
      token = preferences.getString('accessToken');
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> signIn(int id, String accessToken, String identifier) async {
    await initialize();
    if (accessToken.isEmpty) throw StateError('后端未返回动作同步凭证，请更新后端');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('userId', id);
    await preferences.setString('accessToken', accessToken);
    await preferences.setString('userIdentifier', identifier);
    await preferences.setBool('isLoggedIn', true);
    userId = id;
    token = accessToken;
    notifyListeners();
  }

  Future<void> signOut() async {
    await initialize();
    userId = null;
    token = null;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('isLoggedIn', false);
    for (final key in ['userId', 'accessToken', 'userIdentifier']) {
      await preferences.remove(key);
    }
  }

  Map<String, String> get headers => {
        'Content-Type': 'application/json',
        if (authenticated) 'Authorization': 'Bearer $token',
      };
}
