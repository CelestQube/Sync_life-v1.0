class ApiConfig {
  // API基础地址
  // USB 调试使用 adb reverse；局域网或正式服务器通过 dart-define 指定地址。
  static const String baseUrl = String.fromEnvironment('SYNC_LIFE_API_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000/api');
  // 登录接口
  static const String loginUrl = '$baseUrl/posture/login/';

  // 注册接口
  static const String registerUrl = '$baseUrl/posture/register/';

  // 发送验证码接口
  static const String sendCodeUrl = '$baseUrl/posture/send-code/';

  static const String agentUrl = '$baseUrl/agent';
  // 旧客户端兼容路径，后端已切换到自写工作流。
  static const String n8nUrl = '$baseUrl/posture/n8n/';

  // 蓝牙数据接口
  static const String bluetoothUrl = '$baseUrl/posture/bluetooth/';

  // 身体运动数据接口
  static const String bodyMovementUrl = '$baseUrl/posture/body-movement/';
  static const String motionEventsUrl = '$baseUrl/posture/motion/events/';
}
