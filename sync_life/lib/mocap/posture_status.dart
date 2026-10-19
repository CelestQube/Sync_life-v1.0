import 'package:flutter/material.dart';
import 'mocap_service.dart';
import 'posture_classifier.dart';
import 'posture_sync.dart';
import 'user_session.dart';
import '../ui/app_theme.dart';

class PostureStatus extends StatelessWidget {
  const PostureStatus({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge([
        MocapService.instance,
        PostureSyncService.instance,
        UserSession.instance
      ]),
      builder: (context, _) {
        final estimate = MocapService.instance.posture;
        final sync = PostureSyncService.instance;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('当前动作：${estimate?.state.label ?? '等待衣物数据'}'),
          Text(
              sync.pendingSegments > 0
                  ? '活动已保存在手机，等待上传'
                  : sync.uploadedSegments > 0
                      ? '活动记录已保存'
                      : '连接衣物后开始记录',
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          if (sync.error != null)
            Text(sync.error!, style: const TextStyle(color: Colors.red)),
          if (!UserSession.instance.authenticated)
            TextButton(
                onPressed: () => Navigator.pushNamed(context, '/login'),
                child: const Text('登录并记录动作')),
          if (sync.error != null && UserSession.instance.authenticated)
            TextButton(onPressed: sync.retry, child: const Text('重试同步')),
          if (sync.hasExpiredRecords)
            TextButton(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                              title: const Text('整理过期的离线记录'),
                              content: const Text(
                                  '超过 30 天且尚未上传的明细已无法补传。清理这些手机记录后，可继续同步近期活动；清理后无法恢复。'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('保留')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('清理过期记录'))
                              ]));
                  if (confirmed == true) await sync.discardExpiredRecords();
                },
                child: const Text('整理过期记录')),
        ]);
      });
}
