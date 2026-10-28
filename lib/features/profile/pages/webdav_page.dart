import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/services/webdav_sync_service.dart';

/// WebDAV 云同步绑定页（设置 → 账号绑定）。
///
/// 设计定案：手动「备份到云端 / 从云端同步」，**整体覆盖、无合并**；
/// 同步集 = 设置 + 收藏 + 历史与进度 + 统计源；凭据仅存本机。
/// 兼容坚果云等标准 WebDAV 网盘（建议 HTTPS + 应用专用密码）。
class WebdavPage extends StatefulWidget {
  const WebdavPage({super.key});

  @override
  State<WebdavPage> createState() => _WebdavPageState();
}

class _WebdavPageState extends State<WebdavPage> {
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _dir;

  @override
  void initState() {
    super.initState();
    final service = context.read<WebdavSyncService>();
    _url = TextEditingController(text: service.serverUrl ?? '');
    _username = TextEditingController(text: service.username);
    _password = TextEditingController();
    _dir = TextEditingController(text: service.dir);
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _dir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<WebdavSyncService>();
    final tokens = AppTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spaceMd,
          tokens.spaceSm,
          tokens.spaceMd,
          tokens.spaceLg,
        ),
        children: [
          if (service.bound)
            _BoundCard(service: service)
          else
            _BindForm(
              service: service,
              url: _url,
              username: _username,
              password: _password,
              dir: _dir,
            ),
        ],
      ),
    );
  }
}

/// 未绑定：填写服务器/凭据 → 测试连接 → 绑定。
class _BindForm extends StatelessWidget {
  const _BindForm({
    required this.service,
    required this.url,
    required this.username,
    required this.password,
    required this.dir,
  });

  final WebdavSyncService service;
  final TextEditingController url;
  final TextEditingController username;
  final TextEditingController password;
  final TextEditingController dir;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final busy = service.busy;
    return KeleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('绑定 WebDAV', style: tokens.sectionStyle),
          const SizedBox(height: 6),
          Text(
            '支持坚果云等标准 WebDAV 网盘。建议使用 HTTPS 与应用专用密码；'
            '凭据仅保存在本机，不会上传。',
            style: tokens.captionStyle,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: url,
            enabled: !busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.jianguoyun.com/dav/',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: username,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '应用密码',
              hintText: '在网盘「安全设置」中生成',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: dir,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '同步目录（可选）',
              hintText: WebdavSyncService.defaultDir,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => _test(context),
                child: const Text('测试连接'),
              ),
              FilledButton(
                onPressed: busy ? null : () => _bind(context),
                child: Text(busy ? '请稍候…' : '绑定'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _test(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await service.testConnection(
      url: url.text,
      username: username.text,
      password: password.text,
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _bind(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // 绑定前先校验连通性，防手滑填错
    final test = await service.testConnection(
      url: url.text,
      username: username.text,
      password: password.text,
    );
    if (!test.ok) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('绑定失败：${test.message}')));
      return;
    }
    final result = await service.bind(
      url: url.text,
      username: username.text,
      password: password.text,
      dir: dir.text,
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }
}

/// 已绑定：服务器信息 + 备份 / 同步 / 解绑（覆盖语义二次确认）。
class _BoundCard extends StatelessWidget {
  const _BoundCard({required this.service});

  final WebdavSyncService service;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final busy = service.busy;
    return KeleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('已绑定', style: tokens.sectionStyle)),
              const InfoChip('WebDAV', tone: StageTone.done),
            ],
          ),
          const SizedBox(height: 12),
          _kv(tokens, '服务器', service.serverUrl ?? ''),
          _kv(tokens, '用户名', service.username),
          _kv(tokens, '同步目录', service.dir),
          const SizedBox(height: 12),
          Text(
            '备份 = 本机数据整体上传覆盖云端；同步 = 云端数据整体下载覆盖本机'
            '（设置、收藏、历史与进度、统计）。两台设备先后操作时以后操作者为准。',
            style: tokens.captionStyle,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => _backup(context),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('备份到云端'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : () => _sync(context),
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('从云端同步'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _unbind(context),
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('解除绑定'),
              ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 12),
            const Center(child: LinearProgressIndicator()),
          ],
        ],
      ),
    );
  }

  Widget _kv(AppTokens tokens, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 72, child: Text(k, style: tokens.captionStyle)),
            Expanded(child: Text(v, style: tokens.captionStyle)),
          ],
        ),
      );

  Future<void> _backup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(
      context,
      title: '备份到云端？',
      message: '将用本机的设置、收藏、历史与进度、统计数据整体覆盖云端文件。',
    );
    if (ok != true) return;
    final result = await service.backup();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _sync(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(
      context,
      title: '从云端同步？',
      message: '将用云端备份整体覆盖本机的设置、收藏、历史与进度、统计数据，'
          '本机现有数据将被替换且不可撤销。',
    );
    if (ok != true) return;
    final result = await service.syncFromCloud();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(result.message)));
  }

  Future<void> _unbind(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: '解除 WebDAV 绑定？',
      message: '仅清除本机保存的凭据，云端备份文件保留。',
    );
    if (ok != true) return;
    await service.unbind();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已解除绑定，云端备份文件保留')));
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String message,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
}
