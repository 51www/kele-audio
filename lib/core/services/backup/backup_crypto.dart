import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// 备份文件加解密（纯 Dart，Web / Android 通用）。
///
/// 口径：
/// - PBKDF2-SHA256 派生 64 字节：前 32 字节作 AES-256-CBC 密钥、
///   后 32 字节作 HMAC-SHA256 密钥；
/// - 随机 16 字节 salt 与 iv；AES-CBC + PKCS7 填充；
/// - **先校验 HMAC 再解密**（encrypt-then-MAC）；HMAC 覆盖 `salt || iv || ciphertext`；
/// - 密码错误 / 文件被篡改 / 密文损坏统一抛 [BackupCryptoException]
///   （文案不区分细节，防枚举）；
/// - 迭代次数 60000：安全与移动端体验间平衡（约几百毫秒级）。
class BackupCryptoException implements Exception {
  BackupCryptoException([this.message = '密码错误或文件已损坏']);

  final String message;

  @override
  String toString() => message;
}

const String kdfName = 'PBKDF2-SHA256';
const String cipherName = 'AES-256-CBC';
const int kdfIterations = 60000;

const int _saltLen = 16;
const int _ivLen = 16;
const int _keyLen = 64; // 32 AES + 32 HMAC
const int _macLen = 32;

/// 加密 payload：返回自描述加密结构（含 kdf/iterations/cipher/salt/iv/ciphertext/hmac）。
Map<String, dynamic> encryptBackupPayload(
  Map<String, dynamic> payload,
  String password,
) {
  final salt = _randomBytes(_saltLen);
  final iv = _randomBytes(_ivLen);
  final keys = _deriveKeys(password, salt);
  final aesKey = Uint8List.sublistView(keys, 0, 32);
  final macKey = Uint8List.sublistView(keys, 32);

  final cipherBytes = _aesCbc(aesKey, iv, Uint8List.fromList(
    utf8.encode(jsonEncode(payload)),
  ), forEncryption: true);
  final mac = _hmacSha256(macKey, [...salt, ...iv, ...cipherBytes]);

  return <String, dynamic>{
    'kdf': kdfName,
    'iterations': kdfIterations,
    'cipher': cipherName,
    'salt': base64Encode(salt),
    'iv': base64Encode(iv),
    'ciphertext': base64Encode(cipherBytes),
    'hmac': _toHex(mac),
  };
}

/// 解密 payload：HMAC 通过后才解密；任何异常统一抛 [BackupCryptoException]。
Map<String, dynamic> decryptBackupPayload(
  Map<String, dynamic> enc,
  String password,
) {
  try {
    if (enc['kdf'] != kdfName || enc['cipher'] != cipherName) {
      throw BackupCryptoException();
    }
    final iterations = (enc['iterations'] as num?)?.toInt();
    if (iterations == null || iterations < 1) throw BackupCryptoException();

    final salt = base64Decode(enc['salt'] as String);
    final iv = base64Decode(enc['iv'] as String);
    final cipherBytes = base64Decode(enc['ciphertext'] as String);
    final mac = _fromHex(enc['hmac'] as String);
    if (salt.isEmpty || iv.length != _ivLen || mac.length != _macLen) {
      throw BackupCryptoException();
    }

    // 先校验 HMAC（常量时间比较），再派生密钥解密
    final keys = _deriveKeys(password, salt, iterations: iterations);
    final expected = _hmacSha256(
      Uint8List.sublistView(keys, 32),
      [...salt, ...iv, ...cipherBytes],
    );
    if (!_constTimeEquals(expected, mac)) throw BackupCryptoException();

    final plain = _aesCbc(
      Uint8List.sublistView(keys, 0, 32),
      iv,
      cipherBytes,
      forEncryption: false,
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map<String, dynamic>) throw BackupCryptoException();
    return decoded;
  } on BackupCryptoException {
    rethrow;
  } catch (_) {
    // 解密失败 / 填充非法 / JSON 损坏 —— 不区分细节（防枚举）
    throw BackupCryptoException();
  }
}

// ---------------------------------------------------------------- 内部

final Random _secureRandom = Random.secure();

Uint8List _randomBytes(int len) =>
    Uint8List.fromList(List.generate(len, (_) => _secureRandom.nextInt(256)));

Uint8List _deriveKeys(String password, Uint8List salt, {int? iterations}) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations ?? kdfIterations, _keyLen));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _aesCbc(
  Uint8List key,
  Uint8List iv,
  Uint8List input, {
  required bool forEncryption,
}) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      forEncryption,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, KeyParameter>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(input);
}

Uint8List _hmacSha256(Uint8List key, List<int> input) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return mac.process(Uint8List.fromList(input));
}

bool _constTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String _toHex(List<int> bytes) => bytes.map((b) {
      final h = b.toRadixString(16);
      return h.length == 1 ? '0$h' : h;
    }).join();

Uint8List _fromHex(String hex) {
  if (hex.length.isOdd) throw const FormatException('bad hex');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
