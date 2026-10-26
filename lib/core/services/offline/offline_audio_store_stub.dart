/// 非 IO / 非 Web 平台的兜底实现（理论上不可达）：全部不可用。
///
/// 缓存任务会因 save 抛错而标记 failed（R8：不崩、不影响其余任务）。
library;

import 'audio_store_interface.dart';

/// audio_store.dart 的兜底分派目标（条件导入按名字匹配）。
AudioStore platformAudioStore() => _UnsupportedAudioStore();

class _UnsupportedAudioStore implements AudioStore {
  @override
  Future<String> save(String key, List<int> bytes) async =>
      throw UnsupportedError('当前平台不支持离线缓存');

  @override
  Future<bool> delete(String key) async => false;

  @override
  Future<String?> playableUrl(String key) async => null;

  @override
  Future<int> sizeOf(String key) async => 0;

  @override
  Future<void> clearAll() async {}

  @override
  String get locationLabel => '当前平台不支持';
}
