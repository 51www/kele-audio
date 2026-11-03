import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 桌面端：另存为对话框（file_picker.saveFile 直接写 bytes）。
/// 移动端：落临时文件后调系统分享面板（发到网盘/微信/文件管理）。
Future<bool> deliverBackupFile(String fileName, Uint8List bytes) async {
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (desktop) {
    final path = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
    );
    return path != null; // 用户取消另存为
  }

  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'application/json')],
    subject: fileName,
    text: '可乐听书备份文件',
  );
  return true;
}
