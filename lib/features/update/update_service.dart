import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'update_checker.dart';
import 'update_config.dart';
import 'update_downloader.dart';
import 'update_models.dart';
import 'update_platform.dart';
import 'update_repository.dart';

/// 检查 / 下载 / 安装 状态机（提示词 2「交互：永不强制」）。
enum UpdatePhase { idle, checking, upToDate, available, error }

class UpdateService extends ChangeNotifier {
  UpdateService({
    Dio? dio,
    UpdateRepository? repository,
    UpdateDownloader? downloader,
    UpdateInstaller? installer,
  })  : _repository = repository ?? UpdateRepository(dio: dio ?? Dio(_dioOptions)),
        _downloader = downloader ?? UpdateDownloader(dio: dio ?? Dio(_dioOptions)),
        _installer = installer ?? UpdateInstaller();

  static final BaseOptions _dioOptions = BaseOptions(
    connectTimeout: UpdateConfig.connectTimeout,
    receiveTimeout: UpdateConfig.receiveTimeout,
  );

  final UpdateRepository _repository;
  final UpdateDownloader _downloader;
  final UpdateInstaller _installer;

  UpdatePhase phase = UpdatePhase.idle;
  String? currentVersion;
  String? errorMessage;
  GhRelease? release;
  GhAsset? selectedAsset;
  String? expectedSha256;

  // ── 下载态 ───────────────────────────────────────────────
  bool downloading = false;
  int received = 0;
  int total = 0;
  String? currentSource;
  String? downloadedPath;
  String? installError;
  CancelToken? _cancelToken;

  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 字节数转人类可读（如 12.5 MB）。
  static String formatSize(int bytes) {
    if (bytes <= 0) return '';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }

  /// 读取真实 package 版本作为比对基准（避免硬编码漂移导致误报，提示词 4）。
  Future<void> init() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      currentVersion = info.version;
    } catch (_) {
      currentVersion = null;
    }
  }

  void reset() {
    phase = UpdatePhase.idle;
    errorMessage = null;
    release = null;
    selectedAsset = null;
    expectedSha256 = null;
    downloading = false;
    received = 0;
    total = 0;
    currentSource = null;
    downloadedPath = null;
    installError = null;
    notifyListeners();
  }

  /// 手动检查（提示词 1：仅手动触发）。
  Future<void> check() async {
    if (phase == UpdatePhase.checking) return;
    phase = UpdatePhase.checking;
    errorMessage = null;
    notifyListeners();

    try {
      final String cur = currentVersion ?? await _readVersion();
      final GhRelease rel = await _repository.fetchLatestRelease();
      if (!isUpdateAvailable(rel.tagName, cur)) {
        phase = UpdatePhase.upToDate;
        notifyListeners();
        return;
      }
      final GhAsset? asset = selectAsset(rel.assets);
      if (asset == null) {
        // 有更新但无适用产物（如无 Android apk），不提示。
        phase = UpdatePhase.upToDate;
        notifyListeners();
        return;
      }
      release = rel;
      selectedAsset = asset;
      expectedSha256 = asset.sha256;
      phase = UpdatePhase.available;
    } on UpdateException catch (e) {
      phase = UpdatePhase.error;
      errorMessage = e.message;
    } on DioException catch (e) {
      phase = UpdatePhase.error;
      errorMessage =
          translateApiError(e.response?.statusCode, message: e.message);
    } catch (e) {
      phase = UpdatePhase.error;
      errorMessage = '检查更新失败：$e';
    } finally {
      notifyListeners();
    }
  }

  Future<String> _readVersion() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    currentVersion = info.version;
    return info.version;
  }

  /// 开始下载（多源 + 校验，见 [UpdateDownloader]）。
  Future<void> startDownload() async {
    if (selectedAsset == null || downloading) return;
    downloading = true;
    received = 0;
    total = selectedAsset!.size;
    downloadedPath = null;
    installError = null;
    notifyListeners();

    final Directory dir = await getApplicationDocumentsDirectory();
    final String safeName = selectedAsset!.name.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final String target = '${dir.path}/kele_update_$safeName';
    _cancelToken = CancelToken();

    try {
      final String path = await _downloader.download(
        asset: selectedAsset!,
        targetPath: target,
        cancelToken: _cancelToken,
        onProgress: (DownloadProgress p) {
          received = p.received;
          total = p.total;
          currentSource = p.currentSource;
          notifyListeners();
        },
      );
      downloadedPath = path;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // 用户取消：立即终止，不再试下一源，回到说明页。
        downloading = false;
        notifyListeners();
        return;
      }
      errorMessage =
          '下载失败：${translateApiError(e.response?.statusCode, message: e.message)}';
      downloading = false;
      phase = UpdatePhase.available; // 停留说明页可重试
      notifyListeners();
      return;
    } catch (e) {
      errorMessage = '下载失败：$e';
      downloading = false;
      notifyListeners();
      return;
    }
    downloading = false;
    notifyListeners();
  }

  /// 用户取消下载（提示词 3-5：立即终止，不试下一源）。
  void cancelDownload() {
    _cancelToken?.cancel('user_cancel');
  }

  /// 安装。返回结果供 UI 决定：拉起安装器 / 提示去授权。
  Future<InstallResult> install() async {
    if (downloadedPath == null) return InstallResult.needsPermission;
    installError = null;
    try {
      final bool can = await _installer.canRequestInstall();
      if (!can) {
        await _installer.openInstallPermission();
        return InstallResult.needsPermission;
      }
      await _installer.installApk(downloadedPath!);
      return InstallResult.installing;
    } on PlatformException catch (e) {
      installError = '安装失败：${e.message ?? e.code}';
      notifyListeners();
      return InstallResult.needsPermission;
    } catch (e) {
      installError = '安装失败：$e';
      notifyListeners();
      return InstallResult.needsPermission;
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }
}
