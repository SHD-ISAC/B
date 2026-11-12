import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/object_box/objectbox.g.dart';
import 'package:zephyr/plugin/plugin_registry_service.dart';
import 'package:zephyr/plugin/utils/plugin_cloud_download_utils.dart';
import 'package:zephyr/plugin/utils/plugin_update_channel_utils.dart';
import 'package:zephyr/plugin/utils/plugin_version_utils.dart';
import 'package:zephyr/util/json/json_value.dart';

class PluginCloudUpdateService {
  PluginCloudUpdateService._();
  static final PluginCloudUpdateService I = PluginCloudUpdateService._();

  /// 插件设置「同步」：固定走 npm / updateUrl 自身通道。
  ///
  /// 返回是否实际下载并应用了新版本。
  Future<bool> syncPluginFromSelfChannel(String uuid) async {
    final local = PluginRegistryService.I.getByUuid(uuid);
    if (local == null || local.isDeleted) {
      throw StateError('插件不存在或已删除');
    }

    final channel = await _resolveSelfUpdateChannel(local.uuid);
    final npmName = channel.npmName;
    final updateUrl = channel.updateUrl;
    if (npmName.isEmpty && updateUrl.isEmpty) {
      logger.d('插件无更新通道，跳过: ${local.uuid}');
      return false;
    }

    final remoteVersion = await fetchSelfChannelLatestVersion(
      npmName: npmName,
      updateUrl: updateUrl,
    );
    if (compareVersion(remoteVersion, local.version) <= 0) {
      return false;
    }

    final payload = await _downloadWithRetry(
      expectedUuid: local.uuid,
      download: () => _downloadAndVerify(
        expectedUuid: local.uuid,
        npmName: npmName,
        updateUrl: updateUrl,
        remoteVersion: remoteVersion,
        sourceLabel: '手动同步',
      ),
    );
    await _applyPluginUpdate(local: local, payload: payload);
    return true;
  }

  Future<_SelfUpdateChannel> _resolveSelfUpdateChannel(String uuid) async {
    final found = objectbox.pluginInfoBox
        .query(PluginInfo_.uuid.equals(uuid))
        .build()
        .findFirst();
    Map<String, dynamic>? info = parseGetInfoJson(found?.getInfoJson ?? '');

    if (info == null) {
      final local = PluginRegistryService.I.getByUuid(uuid);
      final script = local?.originScript.trim() ?? '';
      if (script.isNotEmpty) {
        try {
          info = await callGetInfoByGlobalQjs(script);
          await PluginRegistryService.I.persistGetInfoJson(
            uuid,
            encodeGetInfoJson(info),
          );
        } catch (e, st) {
          logger.w('刷新 getInfo 缓存失败: $uuid', error: e, stackTrace: st);
        }
      }
    }

    if (info == null) {
      return const _SelfUpdateChannel(npmName: '', updateUrl: '');
    }
    return _SelfUpdateChannel(
      npmName: readNpmNameFromInfo(info),
      updateUrl: readUpdateUrlFromInfo(info),
    );
  }

  Future<_PluginUpdatePayload> _downloadWithRetry({
    required String expectedUuid,
    required Future<_PluginUpdatePayload> Function() download,
  }) async {
    const maxAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await download();
      } catch (e, st) {
        lastError = e;
        final isNetworkError = isNetworkRetryableError(e);
        if (!isNetworkError) {
          rethrow;
        }
        if (attempt >= maxAttempts) {
          break;
        }
        logger.w(
          '插件更新网络错误，准备重试($attempt/$maxAttempts): $expectedUuid',
          error: e,
          stackTrace: st,
        );
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    throw StateError('插件更新网络错误，重试次数用尽: $expectedUuid, error: $lastError');
  }

  Future<_PluginUpdatePayload> _downloadAndVerify({
    required String expectedUuid,
    required String npmName,
    required String remoteVersion,
    required String updateUrl,
    required String sourceLabel,
  }) async {
    final script = await downloadPluginFromSelfChannel(
      npmName: npmName,
      updateUrl: updateUrl,
      remoteVersion: remoteVersion,
    );

    final info = await callGetInfoByGlobalQjs(script);
    final resolvedUuid = readUuidFromInfo(info);
    if (resolvedUuid != expectedUuid) {
      throw StateError('更新脚本 uuid 不匹配，期望=$expectedUuid, 实际=$resolvedUuid');
    }
    final resolvedVersion = readVersionFromInfo(info);

    return _PluginUpdatePayload(
      uuid: resolvedUuid,
      version: resolvedVersion.isNotEmpty ? resolvedVersion : remoteVersion,
      script: script,
      sourceLabel: sourceLabel,
      getInfoJson: encodeGetInfoJson(info),
    );
  }

  Future<void> _applyPluginUpdate({
    required PluginRuntimeState local,
    required _PluginUpdatePayload payload,
  }) async {
    final box = objectbox;

    final found = box.pluginInfoBox
        .query(PluginInfo_.uuid.equals(local.uuid))
        .build()
        .findFirst();
    final now = DateTime.now().toUtc();
    final toSave = PluginInfo(
      id: found?.id ?? 0,
      uuid: payload.uuid,
      version: payload.version,
      originScript: payload.script,
      insertedAt: found?.insertedAt ?? local.insertedAt,
      updatedAt: now,
      isEnabled: found?.isEnabled ?? local.isEnabled,
      isDeleted: false,
      deletedAt: null,
      lastLoadSuccess: false,
      lastLoadError: null,
      sortOrder: found?.sortOrder ?? local.sortOrder,
      debug: found?.debug ?? local.debug,
      debugUrl: found?.debugUrl ?? local.debugUrl,
      getInfoJson: payload.getInfoJson.isNotEmpty
          ? payload.getInfoJson
          : (found?.getInfoJson ?? ''),
    );
    await PluginRegistryService.I.upsert(toSave);

    final runtimeName = PluginRegistryService.I.resolveRuntimeName(
      payload.uuid,
    );
    final latest = PluginRegistryService.I.getByUuid(payload.uuid);
    if (latest != null && latest.isEnabled) {
      await PluginRegistryService.I.ensurePluginRuntimeReady(
        latest,
        runtimeName: runtimeName,
      );
      await PluginRegistryService.I.runPluginInitIfNeeded(
        latest,
        runtimeName: runtimeName,
      );
    }

    // 更新后再次刷新 getInfo 缓存（内存 + 持久化）。
    try {
      await PluginRegistryService.I.fetchPluginInfo(
        uuid: payload.uuid,
        runtimeName: runtimeName,
      );
    } catch (e, st) {
      logger.w('插件更新后回填信息失败: ${payload.uuid}', error: e, stackTrace: st);
    }
  }
}

class _SelfUpdateChannel {
  const _SelfUpdateChannel({required this.npmName, required this.updateUrl});

  final String npmName;
  final String updateUrl;
}

class _PluginUpdatePayload {
  const _PluginUpdatePayload({
    required this.uuid,
    required this.version,
    required this.script,
    required this.sourceLabel,
    required this.getInfoJson,
  });

  final String uuid;
  final String version;
  final String script;
  final String sourceLabel;
  final String getInfoJson;
}
