import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<bool> deliverAnnotationFile({
  required String fileName,
  required Uint8List bytes,
  required String mimeType,
}) async {
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (desktop) {
    final path = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
    return path != null;
  }
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: mimeType)],
    subject: fileName,
    text: '可乐听书划线导出',
  );
  return true;
}
