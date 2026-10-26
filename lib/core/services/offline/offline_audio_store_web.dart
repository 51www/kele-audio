/// Web 平台实现：IndexedDB（Blob）+ `blob:` URL 播放。
///
/// 浏览器没有文件系统，M8 离线缓存在 Web 预览端把音频字节存 IndexedDB
///（与 `flutter_cache_manager` 的图片缓存同一介质）。`blob:` URL 直接交给
/// media_kit 的 HTMLAudioElement 后端播放，因此**断网后已缓存内容可播**
///（PRD §5.8 验收在浏览器可直接演练）。
///
/// 用 `package:web` + `dart:js_interop`（dart:html 已弃用）；任何一步失败
/// 都抛异常，由调用方把任务标记为失败（R8：不阻塞其余任务）。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_store_interface.dart';

/// audio_store.dart 的 Web 分派目标（条件导入按名字匹配）。
AudioStore platformAudioStore() => IdbAudioStore();

class IdbAudioStore implements AudioStore {
  static const String _dbName = 'kele_audio';
  static const String _storeName = 'offline_audio';

  Future<web.IDBDatabase>? _opening;

  Future<web.IDBDatabase> _open() {
    final opening = _opening;
    if (opening != null) return opening;
    final completer = Completer<web.IDBDatabase>();

    void completeFrom(web.IDBRequest req) {
      req.onsuccess = ((web.Event _) {
        final db = req.result as web.IDBDatabase;
        if (db.objectStoreNames.contains(_storeName)) {
          completer.complete(db);
          return;
        }
        // 库已存在但缺 store：升一版重建（幂等，只发生一次）
        db.close();
        final up = web.window.indexedDB.open(_dbName, 2);
        up.onupgradeneeded = ((web.Event _) {
          (up.result as web.IDBDatabase)
              .createObjectStore(_storeName);
        }).toJS;
        up.onsuccess = ((web.Event _) {
          completer.complete(up.result as web.IDBDatabase);
        }).toJS;
        up.onerror = ((web.Event _) =>
                completer.completeError(Exception('IndexedDB 升级失败')))
            .toJS;
      }).toJS;
      req.onerror = ((web.Event _) =>
              completer.completeError(Exception('IndexedDB 打开失败')))
          .toJS;
    }

    completeFrom(web.window.indexedDB.open(_dbName, 1));
    _opening = completer.future;
    return completer.future;
  }

  Future<(web.IDBObjectStore, web.IDBTransaction)> _store(
      {bool readonly = false}) async {
    final db = await _open();
    final tx = db.transaction(
      _storeName.toJS,
      readonly ? 'readonly' : 'readwrite',
    );
    return (tx.objectStore(_storeName), tx);
  }

  Future<void> _waitTx(web.IDBTransaction tx) {
    final c = Completer<void>();
    tx.oncomplete = ((web.Event _) => c.complete()).toJS;
    tx.onerror = ((web.Event _) =>
            c.completeError(Exception('IndexedDB 事务失败')))
        .toJS;
    return c.future;
  }

  Future<web.Blob?> _read(String key) async {
    final db = await _open();
    final tx = db.transaction(_storeName.toJS, 'readonly');
    final req = tx.objectStore(_storeName).get(key.toJS);
    final done = Completer<web.Blob?>();
    req.onsuccess = ((web.Event _) {
      final r = req.result;
      done.complete(r == null ? null : r as web.Blob);
    }).toJS;
    req.onerror = ((web.Event _) =>
            done.completeError(Exception('IndexedDB 读取失败')))
        .toJS;
    unawaited(_waitTx(tx).catchError((Object _) {}));
    return done.future;
  }

  @override
  Future<String> save(String key, List<int> bytes) async {
    final blob = web.Blob(
      [Uint8List.fromList(bytes).toJS].toJS,
    );
    final (store, tx) = await _store();
    store.put(blob, key.toJS);
    await _waitTx(tx);
    return web.URL.createObjectURL(blob);
  }

  @override
  Future<bool> delete(String key) async {
    final (store, tx) = await _store();
    store.delete(key.toJS);
    await _waitTx(tx);
    return true;
  }

  @override
  Future<String?> playableUrl(String key) async {
    final blob = await _read(key);
    return blob == null ? null : web.URL.createObjectURL(blob);
  }

  @override
  Future<int> sizeOf(String key) async {
    final blob = await _read(key);
    return blob?.size.toInt() ?? 0;
  }

  @override
  Future<void> clearAll() async {
    final (store, tx) = await _store();
    store.clear();
    await _waitTx(tx);
  }

  @override
  String get locationLabel => '浏览器 IndexedDB / offline_audio';
}
