/// 红果匿名签名身份的轮换层（只管匿名线，账号登录线不在这里）。
///
/// 盘点结论（2026-11-29）：
/// - 红果有两条匿名路：网页端抓取路（HongguoContentClient /
///   HgtvMirrorContentClient）只有浏览器 UA、没有任何设备身份，
///   无身份可轮换，本文件不碰；
/// - App 签名身份路（HgtvContentClient）此前是「每个客户端实例现
///   随机一对 device_id/iid、用完即弃」：既不落盘也不按任何节奏
///   换——同一天里开几次页面就是几套身份，服务端看等于不停换机。
///   本文件把这条路的身份供给收成一套有节奏的轮换：
///   同一天同一网络内稳定复现，跨天 / 换网络 / 被服务端拒才换。
///
/// 轮换口径（用户 2026-11-29 定版）：
/// 1. 触发三种：跨天、出口 IP 变了、被服务端拒（回空或明确拒绝码）。
///    同日同网保持稳定；播放途中不换——身份在客户端构造时定格，
///    本层只在构造（启动 / 打开站点页）与下一次构造前的安全边界
///    生效，进行中的请求链全程用同一套。
/// 2. 生成是确定性的：种子 = 机型档案 + 出口 IP + 日期 + 轮次，
///    SHA-256 派生。没有随机源参与——同机型同 IP 同一天必复现
///    同一套，换天 / 换 IP / 轮次 +1 自然换新。
/// 3. 机型档案以树里现行已对齐的那套为底（见 [HongguoDeviceProfile]）：
///    品牌 / 型号 / UA / 版本号全链自洽。App 侧没有读真实机型的
///    通道，这里不冒充读到了真机型；档案池目前只有这一档，今后
///    加档必须同厂同档、整套字段一起换，不许拼凑。
/// 4. 落盘只存匿名身份本体 + 日期戳 + IP 戳 + 轮次 + 被拒标记，
///    走 SharedPreferences 普通存储（不是凭据，不进安全存储；
///    账号会话的存储口径与此无关、互不读写）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 红果 App 档案：与 hgtv_content 的 _appQuery、hongguo_sign 签名栈
/// 字段（Argus 的 7.4.3.32 / v04.07.01-ml-android）、账号线设备表
/// （hongguo_account_sync._passportDeviceParams）同一套取值。
/// 改任何一处版本号，必须全链一起改。
class HongguoDeviceProfile {
  const HongguoDeviceProfile({
    required this.brand,
    required this.model,
    required this.osVersion,
    required this.osApi,
    required this.resolution,
    required this.dpi,
    required this.versionName,
    required this.versionCode,
    required this.channel,
    required this.userAgent,
  });

  final String brand;

  /// device_type 取值。
  final String model;
  final String osVersion;
  final String osApi;
  final String resolution;
  final String dpi;

  /// 7.4.3.32 / 74332：query、UA、签名栈三处同源。
  final String versionName;
  final String versionCode;
  final String channel;
  final String userAgent;

  /// 现行档案：Redmi 25053RT47C（红米 Turbo 4 同档），与 UA 串里
  /// 的机型、Build 号成套。档案池目前只有这一档。
  static const current = HongguoDeviceProfile(
    brand: 'Redmi',
    model: '25053RT47C',
    osVersion: '16',
    osApi: '36',
    resolution: '1280*2772',
    dpi: '520',
    versionName: '7.4.3.32',
    versionCode: '74332',
    channel: 'update_64',
    userAgent:
        'com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; '
        'Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 '
        'QuicVersion:c67e9834 2025-09-08)',
  );
}

/// 一套匿名身份：device_id / iid / cdid 三件同源（cdid 恒等于
/// device_id，与现行 _appQuery 及账号线 _accountParams 的口径
/// 一致——火蚁侧三修之一就是「重注册时 cdid 跟着换」，在这里
/// cdid 不是独立字段、天然随 device_id 一起换，不可能留旧值）。
class HongguoAnonIdentity {
  const HongguoAnonIdentity({
    required this.deviceId,
    required this.installId,
    required this.dateStamp,
    required this.ipStamp,
    required this.generation,
    this.profile = HongguoDeviceProfile.current,
  });

  final String deviceId;
  final String installId;

  /// 生成时的本地日期（yyyy-MM-dd）。
  final String dateStamp;

  /// 生成时探到的出口 IP；探不到时为 [HongguoIdentityService.unknownIp]。
  final String ipStamp;

  /// 同日同 IP 内被拒后的轮次：0 起，被拒一次 +1。
  final int generation;

  final HongguoDeviceProfile profile;

  String get cdid => deviceId;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'installId': installId,
    'dateStamp': dateStamp,
    'ipStamp': ipStamp,
    'generation': generation,
  };

  factory HongguoAnonIdentity.fromJson(Map<String, dynamic> json) =>
      HongguoAnonIdentity(
        deviceId: '${json['deviceId'] ?? ''}',
        installId: '${json['installId'] ?? ''}',
        dateStamp: '${json['dateStamp'] ?? ''}',
        ipStamp: '${json['ipStamp'] ?? ''}',
        generation: json['generation'] is num
            ? (json['generation'] as num).toInt()
            : 0,
      );

  bool get isWellFormed =>
      RegExp(r'^\d{19}$').hasMatch(deviceId) &&
      RegExp(r'^\d{19}$').hasMatch(installId) &&
      dateStamp.isNotEmpty;
}

/// 确定性派生：种子掺机型 + IP + 日期 + 轮次，SHA-256 输出按
/// 现行 _hgtvDeviceId 的形态取模成 19 位 id（[1e18, 9e18)）。
/// 同一种子必出同一套——这是「同日同网复现」的根。
class HongguoIdentityDeriver {
  const HongguoIdentityDeriver();

  static String seedFor({
    required HongguoDeviceProfile profile,
    required String ip,
    required String dateStamp,
    required int generation,
  }) {
    return 'hg-anon-v1|${profile.brand}|${profile.model}|$ip|$dateStamp|$generation';
  }

  HongguoAnonIdentity derive({
    required String ip,
    required String dateStamp,
    required int generation,
    HongguoDeviceProfile profile = HongguoDeviceProfile.current,
  }) {
    final seed = seedFor(
      profile: profile,
      ip: ip,
      dateStamp: dateStamp,
      generation: generation,
    );
    return HongguoAnonIdentity(
      deviceId: _idFromSeed('$seed|device'),
      installId: _idFromSeed('$seed|install'),
      dateStamp: dateStamp,
      ipStamp: ip,
      generation: generation,
      profile: profile,
    );
  }

  static String _idFromSeed(String seed) {
    final digest = sha256.convert(utf8.encode(seed)).bytes;
    var hi = 0;
    var lo = 0;
    for (var i = 0; i < 4; i++) {
      hi = (hi << 8) | digest[i];
      lo = (lo << 8) | digest[i + 4];
    }
    final combined = (hi << 32) | lo;
    final value = 1000000000000000000 + combined % 8000000000000000000;
    return value.toString();
  }
}

/// 身份落盘抽象：生产走 SharedPreferences，测试用内存实现。
abstract interface class HongguoIdentityStore {
  Future<HongguoAnonIdentity?> read();

  Future<bool> readRejected();

  Future<void> write(HongguoAnonIdentity identity, {required bool rejected});
}

class SharedPreferencesHongguoIdentityStore
    implements HongguoIdentityStore {
  static const _identityKey = 'hongguo_anon_identity_v1';
  static const _rejectedKey = 'hongguo_anon_identity_rejected_v1';

  @override
  Future<HongguoAnonIdentity?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_identityKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final identity = HongguoAnonIdentity.fromJson(decoded);
      return identity.isWellFormed ? identity : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> readRejected() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rejectedKey) ?? false;
  }

  @override
  Future<void> write(
    HongguoAnonIdentity identity, {
    required bool rejected,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_identityKey, jsonEncode(identity.toJson()));
    await prefs.setBool(_rejectedKey, rejected);
  }
}

class MemoryHongguoIdentityStore implements HongguoIdentityStore {
  HongguoAnonIdentity? stored;
  bool rejected = false;
  int writeCount = 0;

  @override
  Future<HongguoAnonIdentity?> read() async => stored;

  @override
  Future<bool> readRejected() async => rejected;

  @override
  Future<void> write(
    HongguoAnonIdentity identity, {
    required bool rejected,
  }) async {
    stored = identity;
    this.rejected = rejected;
    writeCount++;
  }
}

/// 出口 IP 探针：回纯文本 IP 的公共服务逐个试，短超时；全灭回
/// [HongguoIdentityService.unknownIp]。探不到不算换网——IP 戳
/// 两边都是 unknown 时视为同网，只有「已知且不同」才触发轮换。
Future<String> probeHongguoPublicIp(
  http.Client client, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  for (final url in const [
    'https://api.ipify.org',
    'https://ipv4.icanhazip.com',
  ]) {
    try {
      final response = await client.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode != 200) continue;
      final text = response.body.trim();
      if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(text)) return text;
    } catch (_) {
      // 换下一个候选。
    }
  }
  return HongguoIdentityService.unknownIp;
}

/// 轮换服务：进程内单例快照 + 异步校验。
///
/// - [snapshot] 同步取当前身份：有快照用快照；没有就按（今天、
///   unknown IP、轮次 0）确定性派生一个临时身份顶着用，并触发
///   一次异步 [ensureCurrent] 校准（校准结果给下一个客户端）。
/// - [ensureCurrent] 是唯一的换身份入口：读盘 → 探 IP → 按触发
///   口径裁决复用还是换新 → 落盘。客户端构造时调它定格身份，
///   构造完成后本实例不再回头读——播放途中不换由此保证。
/// - [markRejected] 只置标记：当前客户端这一轮请求按失败收尾
///   （不在请求链中途换人，保证同轮一致），下一次 [ensureCurrent]
///   时轮次 +1 换新。
class HongguoIdentityService {
  HongguoIdentityService({
    HongguoIdentityStore? store,
    Future<String> Function()? ipProbe,
    DateTime Function()? clock,
    this.profile = HongguoDeviceProfile.current,
  }) : _store = store ?? SharedPreferencesHongguoIdentityStore(),
       // 注入名 ipProbe 是对外测试口径，字段名带下划线保持私有。
       // ignore: prefer_initializing_formals
       _ipProbe = ipProbe,
       _clock = clock ?? DateTime.now;

  static const unknownIp = 'unknown';

  /// 生产单例：全 App 共用一份快照与落盘。
  static final HongguoIdentityService shared = HongguoIdentityService();

  final HongguoIdentityStore _store;
  final Future<String> Function()? _ipProbe;
  final DateTime Function() _clock;
  final HongguoDeviceProfile profile;

  HongguoAnonIdentity? _snapshot;
  Future<HongguoAnonIdentity>? _ensuring;

  static String dateStampOf(DateTime time) {
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${time.year}-$month-$day';
  }

  Future<String> _probeIp() async {
    final probe = _ipProbe;
    if (probe != null) return probe();
    final client = http.Client();
    try {
      return await probeHongguoPublicIp(client);
    } finally {
      client.close();
    }
  }

  /// 同步快照：见类注释。不会落盘、不会阻塞。
  HongguoAnonIdentity snapshot() {
    final current = _snapshot;
    if (current != null) return current;
    final provisional = const HongguoIdentityDeriver().derive(
      ip: unknownIp,
      dateStamp: dateStampOf(_clock()),
      generation: 0,
      profile: profile,
    );
    // 临时身份不进快照：等 ensureCurrent 校准后才定格。
    unawaited(ensureCurrent());
    return provisional;
  }

  /// 校验并在需要时轮换，返回定格后的身份。并发调用共用一次。
  Future<HongguoAnonIdentity> ensureCurrent() {
    final running = _ensuring;
    if (running != null) return running;
    final future = _ensureCurrent();
    _ensuring = future;
    return future.whenComplete(() {
      if (identical(_ensuring, future)) _ensuring = null;
    });
  }

  Future<HongguoAnonIdentity> _ensureCurrent() async {
    final today = dateStampOf(_clock());
    HongguoAnonIdentity? stored;
    var rejected = false;
    try {
      stored = await _store.read();
      rejected = await _store.readRejected();
    } catch (_) {
      stored = null;
    }
    final ip = await _probeIp();
    final deriver = const HongguoIdentityDeriver();

    if (stored != null && stored.isWellFormed) {
      final sameDay = stored.dateStamp == today;
      // IP 只有两边都已知且不同才算换网；任一为 unknown 不触发。
      final ipChanged =
          stored.ipStamp != unknownIp &&
          ip != unknownIp &&
          stored.ipStamp != ip;
      if (sameDay && !ipChanged && !rejected) {
        _snapshot = stored;
        return stored;
      }
      final next = deriver.derive(
        ip: ip,
        dateStamp: today,
        // 同日同网被拒：轮次 +1；跨天/换网：新一天新网络从 0 起。
        generation: (sameDay && !ipChanged) ? stored.generation + 1 : 0,
        profile: profile,
      );
      await _persist(next, rejected: false);
      return next;
    }

    final fresh = deriver.derive(
      ip: ip,
      dateStamp: today,
      generation: 0,
      profile: profile,
    );
    await _persist(fresh, rejected: false);
    return fresh;
  }

  Future<void> _persist(
    HongguoAnonIdentity identity, {
    required bool rejected,
  }) async {
    _snapshot = identity;
    try {
      await _store.write(identity, rejected: rejected);
    } catch (_) {
      // 落盘失败不挡取数：本进程内快照仍有效，下次启动重新派生
      // （同种子仍复现同一套，不会乱换）。
    }
  }

  /// 标记当前身份已被服务端拒：下一次 [ensureCurrent] 轮次 +1
  /// 换新。只置标记不动快照——正在用这套身份的客户端本轮照旧。
  Future<void> markRejected() async {
    final current = _snapshot;
    try {
      if (current != null) {
        await _store.write(current, rejected: true);
      } else {
        final stored = await _store.read();
        if (stored != null) await _store.write(stored, rejected: true);
      }
    } catch (_) {
      // 标记落盘失败时退而求其次：清快照让下次构造走完整校验；
      // 校验读不到标记仍会复用旧身份，不会误换。
    }
  }
}
