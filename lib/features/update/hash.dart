// 条件导出：Web（无 dart:io）使用桩，其余平台使用真实实现（提示词 2「代码组织」）。
export 'hash_stub.dart' if (dart.library.io) 'hash_io.dart';
