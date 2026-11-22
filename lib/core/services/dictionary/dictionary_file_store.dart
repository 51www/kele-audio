/// 词库文件存储（Android/iOS 落盘；Web 不支持，走 stub）。
library;

export 'dictionary_file_store_stub.dart'
    if (dart.library.io) 'dictionary_file_store_io.dart';
