import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/domain/playback.dart';
import '../../../core/services/bili_account_service.dart';
import '../../../core/services/player/player_service.dart';
import '../../discover/album_card.dart' show CoverImage;

/// B 站账号绑定页（设置 → 账号绑定）。
///
/// 扫码登录（PRD §7.6）：二维码登录链接由 `core/api` 生成并定时轮询，
/// 确认后 SESSDATA 等登录态仅存本地；绑定后解锁 192K 音质（大会员再解锁 Hi-Res）。
///
/// 联动（Q2/Q3）：绑定成功且当前档 132K → 自动升档 192K（显式 64K 不动，
/// 大会员不自动切 Hi-Res）；解绑 → 档位回落 132K 并提示。
class BiliAccountPage extends StatefulWidget {
  const BiliAccountPage({super.key});

  @override
  State<BiliAccountPage> createState() => _BiliAccountPageState();
}

class _BiliAccountPageState extends State<BiliAccountPage> {
  /// 服务引用在 initState 持有：dispose 时元素树已不稳定，
  /// 不能再做祖先查找（context.read 会断言崩溃）。
  late final BiliAccountService _service;
  late final PlayerService _player;
  bool _wasBound = false;

  @override
  void initState() {
    super.initState();
    _service = context.read<BiliAccountService>();
    _player = context.read<PlayerService>();
    _wasBound = _service.bound;
    _service.addListener(_onAccountChanged);
    if (_service.bound) {
      _service.refreshProfile();
    } else {
      _service.startQrLogin();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onAccountChanged);
    _service.stopQrLogin();
    super.dispose();
  }

  /// 监听未绑定 → 已绑定 翻转：触发自动升档（Q2a）。
  void _onAccountChanged() {
    final bound = _service.bound;
    if (bound && !_wasBound) {
      _wasBound = bound;
      _onBoundSuccess();
    } else {
      _wasBound = bound;
    }
  }

  /// 绑定成功：仅当前档 132K 时自动升档 192K（显式 64K 不动、不自动切 Hi-Res）。
  Future<void> _onBoundSuccess() async {
    final upgrade = _player.quality == AudioQuality.q132k;
    if (upgrade) {
      await _player.setQuality(AudioQuality.q192k);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            upgrade ? '绑定成功，已切换到 192K 音质' : '绑定成功，192K 音质已解锁',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<BiliAccountService>();
    return Scaffold(
      appBar: AppBar(title: const Text('B 站账号')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppTokens.of(context).spaceMd,
          AppTokens.of(context).spaceSm,
          AppTokens.of(context).spaceMd,
          AppTokens.of(context).spaceLg,
        ),
        children: [
          if (account.bound)
            _BoundCard(service: account)
          else
            _QrCard(service: account),
        ],
      ),
    );
  }
}

/// 未绑定：扫码登录卡（二维码 + 轮询状态 + 过期/失败重试）。
class _QrCard extends StatelessWidget {
  const _QrCard({required this.service});

  final BiliAccountService service;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return KeleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('扫码绑定', style: tokens.sectionStyle),
          const SizedBox(height: 6),
          Text(
            '使用哔哩哔哩 App「我的」页扫一扫登录，绑定后解锁 192K 音质（大会员再解锁 Hi-Res）。',
            style: tokens.captionStyle,
          ),
          const SizedBox(height: 18),
          Center(child: _QrStage(service: service)),
          const SizedBox(height: 18),
          Text(
            '登录态仅保存在本机，不会上传；可随时在本页解除绑定。',
            style: tokens.captionStyle,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 二维码区：按扫码阶段渲染二维码 / 过期 / 失败占位与操作。
class _QrStage extends StatelessWidget {
  const _QrStage({required this.service});

  final BiliAccountService service;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final phase = service.qrPhase;

    if (phase == QrLoginPhase.success) {
      return _stageBox(
        context,
        icon: Icons.check_circle_outline_rounded,
        iconColor: scheme.primary,
        message: '登录成功，正在进入…',
      );
    }
    if (phase == QrLoginPhase.error) {
      return Column(
        children: [
          _stageBox(
            context,
            icon: Icons.wifi_off_rounded,
            message: service.qrError ?? '网络异常，请检查网络后重试',
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: service.startQrLogin,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      );
    }
    if (phase == QrLoginPhase.expired) {
      return Column(
        children: [
          _stageBox(
            context,
            icon: Icons.qr_code_2_rounded,
            message: '二维码已过期',
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: service.startQrLogin,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('刷新二维码'),
          ),
        ],
      );
    }

    final content = service.qrContent;
    if (content == null) {
      return _stageBox(
        context,
        icon: Icons.qr_code_2_rounded,
        message: '正在获取二维码…',
      );
    }

    final scanned = phase == QrLoginPhase.scanned;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            // 二维码识别要求深色码点 + 浅底，固定白底（不随主题变）
            color: Colors.white,
            borderRadius: BorderRadius.circular(tokens.radiusMd),
          ),
          child: QrImageView(
            data: content,
            size: 216,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (scanned)
              Icon(Icons.phone_iphone_rounded, size: 16, color: scheme.primary),
            if (scanned) const SizedBox(width: 6),
            Text(
              scanned ? '已扫码，请在手机上确认登录' : '等待扫码…',
              style: tokens.captionStyle.copyWith(
                color: scanned ? scheme.primary : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stageBox(
    BuildContext context, {
    required IconData icon,
    required String message,
    Color? iconColor,
  }) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 44, color: iconColor ?? scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: tokens.captionStyle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 已绑定：账号档案卡 + 刷新登录态 / 解除绑定。
class _BoundCard extends StatelessWidget {
  const _BoundCard({required this.service});

  final BiliAccountService service;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final account = service.account;
    final isVip = service.isVip;
    return KeleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Avatar(face: account?.face ?? ''),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account?.uname.isNotEmpty == true
                          ? account!.uname
                          : 'B 站账号',
                      style: tokens.titleStyle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'UID ${account?.mid ?? 0}',
                      style: tokens.captionStyle,
                    ),
                  ],
                ),
              ),
              if (isVip) ...[
                const InfoChip('大会员', tone: StageTone.accent),
                const SizedBox(width: 6),
              ],
              const InfoChip('已绑定', tone: StageTone.done),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            isVip
                ? '已解锁 192K 与 Hi-Res 音质。登录态仅保存在本机，可随时解除绑定。'
                : '已解锁 192K 音质，开通大会员可解锁 Hi-Res。登录态仅保存在本机，可随时解除绑定。',
            style: tokens.captionStyle,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: service.refreshProfile,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('刷新登录态'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _confirmUnbind(context),
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('解除绑定'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '绑定仅用于解锁高音质音源（PRD §7.6），不代替任何官方客户端功能。',
            style: tokens.captionStyle.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUnbind(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解除 B 站账号绑定？'),
        content: const Text('解绑后将退出本机登录态，音质自动回落到 132K（Hi-Res 一并收回）。收藏与收听记录不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await service.logout();
    if (!context.mounted) return;
    // Q3a：解绑 → 132K 回落由 setEntitlement 收口，这里只补一条提示
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('已解绑，音质已回落到 132K')),
      );
    // 解绑后回到扫码态
    await service.startQrLogin();
  }
}

/// 头像：失败/缺省回退默认图标（封面图同款 Web 反代解析）。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.face});

  final String face;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = CoverImage.resolveUrl(face);
    return CircleAvatar(
      radius: 28,
      backgroundColor: scheme.onSurface.withValues(alpha: 0.06),
      foregroundImage: resolved.isEmpty ? null : NetworkImage(resolved),
      // 无图时不允许回调（CircleAvatar 断言），失败静默回退底色
      onForegroundImageError: resolved.isEmpty ? null : (_, _) {},
      child: resolved.isEmpty
          ? Icon(Icons.person_rounded, size: 28, color: scheme.onSurfaceVariant)
          : null,
    );
  }
}
