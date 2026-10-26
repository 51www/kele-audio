/// 离线音频存储的平台分派（M8 / PRD §5.8）。
///
/// - IO（Android / 桌面）：`<应用支持目录>/offline_audio/<key>.m4s`；
/// - Web：IndexedDB（Blob）+ `blob:` URL，断网可播；
/// - 其他平台：stub，全部不可用（任务会标记失败，R8 不崩）。
library;

import 'audio_store_interface.dart';

import 'offline_audio_store_stub.dart'
    if (dart.library.io) 'offline_audio_store_io.dart'
    if (dart.library.html) 'offline_audio_store_web.dart';

export 'audio_store_interface.dart';

/// 平台实现入口。
AudioStore createAudioStore() => platformAudioStore();
