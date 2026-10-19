import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../agent/agent_api.dart';

class PlanRepository {
  PlanRepository(this.api);
  final AgentApi api;
  Map<String, dynamic> _document(Map<String, dynamic> record,
          {bool offline = false}) =>
      {
        ...Map<String, dynamic>.from(record['document'] as Map),
        '_cloud_id': record['id'],
        '_revision': record['revision'],
        '_offline': offline,
        '_training_days': record['training_days'] ?? [],
      };
  Future<void> _checkScope(String scope) async {
    if (scope != await api.storageScope()) {
      throw const AgentException('账号已切换，请重新加载');
    }
  }

  Future<Map<String, dynamic>?> load({String? id}) async {
    final scope = await api.storageScope();
    final preferences = await SharedPreferences.getInstance();
    try {
      Map<String, dynamic>? record;
      if (id != null) {
        record = await api.getPlan(id);
      } else {
        final response = await api.plans();
        final records = response['plans'] as List;
        if (records.isNotEmpty) {
          record = Map<String, dynamic>.from(records.first as Map);
        }
      }
      await _checkScope(scope);
      if (record == null) {
        await preferences.remove('agent_plan_$scope');
        return null;
      }
      await preferences.setString('agent_plan_$scope', jsonEncode(record));
      await _checkScope(scope);
      return _document(record);
    } on AgentException catch (error) {
      // Do not resurrect deleted plans or another account's cache after auth failures.
      if (error.status == 401 ||
          error.status == 403 ||
          error.status == 404 ||
          error.code == 'session_changed') {
        rethrow;
      }
      await _checkScope(scope);
      final raw = preferences.getString('agent_plan_$scope');
      if (raw == null) rethrow;
      final record = jsonDecode(raw) as Map<String, dynamic>;
      if (id != null && id != record['id']) rethrow;
      return _document(record, offline: true);
    }
  }

  Future<Map<String, dynamic>> save(Map<String, dynamic> document) async {
    final scope = await api.storageScope();
    final record = await api.savePlan(document,
        id: document['_cloud_id'] as String?,
        revision: document['_revision'] as int?);
    await _checkScope(scope);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('agent_plan_$scope', jsonEncode(record));
    await _checkScope(scope);
    return _document(record);
  }

  Future<void> delete(String id) async {
    final scope = await api.storageScope();
    await api.deletePlan(id);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString('agent_plan_$scope');
    if (raw != null && (jsonDecode(raw) as Map)['id'] == id) {
      await preferences.remove('agent_plan_$scope');
    }
    await _checkScope(scope);
  }
}

class TrainingPlanStorage {
  static Future<Map<String, dynamic>?> loadTrainingPlan({String? id}) async {
    final api = AgentApi();
    try {
      return await PlanRepository(api).load(id: id);
    } finally {
      api.close();
    }
  }

  static Future<Map<String, dynamic>> saveTrainingPlan(
      Map<String, dynamic> document) async {
    final api = AgentApi();
    try {
      return await PlanRepository(api).save(document);
    } finally {
      api.close();
    }
  }

  // Legacy unscoped files require an explicit import by their owner.
  static Future<Map<String, dynamic>?> readLegacyPlan() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/training_plan.json');
    if (!await file.exists()) return null;
    if (await file.length() > 96 * 1024) {
      throw const AgentException('旧版计划过大，请手动整理后导入');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }
}
