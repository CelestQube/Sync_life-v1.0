import 'package:flutter/material.dart';
import 'mocap/user_session.dart';
import 'pages/personal_knowledge_page.dart';
import 'pages/body_movement_page.dart';
import 'pages/smart_agent_page.dart';
import 'pages/three_d_page.dart';
import 'pages/profile_page.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';
import 'pages/training_plan_page.dart';
import 'ui/app_theme.dart';
import 'ui/app_navigation.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // 检查登录状态的方法
  Future<bool> checkLoginStatus() async {
    await UserSession.instance.initialize();
    return UserSession.instance.authenticated;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '同律 Sync-Life',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: FutureBuilder<bool>(
        future: checkLoginStatus(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // 显示加载指示器
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          } else if (snapshot.hasData && snapshot.data!) {
            // 已登录，直接进入主页
            return const MainScreen();
          } else {
            // 未登录，显示登录页面
            return const LoginPage();
          }
        },
      ),
      routes: {
        '/login': (context) => const LoginPage(),
        '/register': (context) => const RegisterPage(),
        '/main': (context) => const MainScreen(),
        '/three_d': (context) => const ThreeDPage(),
        '/training_plan': (context) => const TrainingPlanPage(),
        '/personal_knowledge': (context) => const PersonalKnowledgePage(),
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.pagesForTesting});
  final List<Widget>? pagesForTesting;

  @override
  MainScreenState createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final _agentKey = GlobalKey<SmartAgentPageState>();
  final Set<int> _visited = {0};
  bool _routeArgsApplied = false;

  @override
  void initState() {
    super.initState();
    requestedMainTab.addListener(_requestedTab);
    requestedAgentDraft.addListener(_requestedDraft);
  }

  void _requestedTab() {
    final index = requestedMainTab.value;
    if (!mounted || index == null || index < 0 || index > 3) return;
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
  }

  void _requestedDraft() {
    final text = requestedAgentDraft.value;
    if (!mounted || text == null) return;
    setState(() {
      _currentIndex = 1;
      _visited.add(1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _agentKey.currentState?.prepareDraft(text);
      if (requestedAgentDraft.value == text) requestedAgentDraft.value = null;
    });
  }

  @override
  void dispose() {
    requestedMainTab.removeListener(_requestedTab);
    requestedAgentDraft.removeListener(_requestedDraft);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeArgsApplied) return;
    _routeArgsApplied = true;
    // 接收路由参数，切换到指定选项卡
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic>) {
      final tabIndex = args['tabIndex'];
      if (tabIndex is int) {
        setState(() {
          _currentIndex = tabIndex.clamp(0, 3);
          _visited.add(_currentIndex);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Keep visited pages mounted: BLE inference and the Unity view survive
      // tab changes, and returning to chat cannot resubmit an old prompt.
      body: IndexedStack(index: _currentIndex, children: [
        if (widget.pagesForTesting != null)
          ...List.generate(
              4,
              (i) => _visited.contains(i)
                  ? widget.pagesForTesting![i]
                  : const SizedBox.shrink())
        else ...[
          BodyMovementPage(
              active: _currentIndex == 0,
              onGenerateReport: (prompt) {
                setState(() {
                  _visited.add(1);
                  _currentIndex = 1;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _agentKey.currentState?.prepareDraft(prompt);
                });
              }),
          if (_visited.contains(1))
            SmartAgentPage(key: _agentKey)
          else
            const SizedBox.shrink(),
          if (_visited.contains(2))
            ThreeDPage(active: _currentIndex == 2)
          else
            const SizedBox.shrink(),
          if (_visited.contains(3)) ProfilePage() else const SizedBox.shrink(),
        ],
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
            _visited.add(index);
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded, color: AppColors.deep),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon:
                Icon(Icons.chat_bubble_rounded, color: AppColors.deep),
            label: '助手',
          ),
          NavigationDestination(
            icon: Icon(Icons.accessibility_new_outlined),
            selectedIcon:
                Icon(Icons.accessibility_new_rounded, color: AppColors.deep),
            label: '动作',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded, color: AppColors.deep),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
