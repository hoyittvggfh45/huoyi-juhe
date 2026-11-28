import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 网络容灾（2026-11-28 用户令，机制借 CloudStream 同名设置项、实现全自研）：
/// 两件套——
///
/// 1. **GitHub 镜像回退**：拉 `raw.githubusercontent.com` 上的文件
///    （插件索引 / 插件包 / 订阅文件）遇到网络层失败（连不上、解析不了、
///    超时）时，自动改写成 jsDelivr 镜像地址重拉。HTTP 状态错误是对方
///    给的真答复，不回退（镜像同样给不出）。
/// 2. **DNS over HTTPS（DoH）**：系统 DNS 解析失败、返回空、或只返回
///    内网/回环地址（污染的典型形态）时，改走 Cloudflare / Google 的
///    DoH 接口（JSON 形态）解析，再按解析出的 IP 建连。TLS 由连接
///    工厂以 `SecureSocket.secure(host: 原域名)` 完成（dart:io 对
///    工厂返回的 socket 不自动升级），SNI 与证书校验都对原域名，
///    不降级；代价是客户端级的 badCertificateCallback 对工厂路
///    不再生效（本应用没有给取数客户端挂这个回调，已清点）。
///
/// 覆盖面（如实）：DoH 挂在 Dart 侧 [HttpClient] 的 connectionFactory
/// 上，经 [ResilientHttpOverrides] 全局生效，覆盖全部 Dart 取数路
/// （插件下载、软件更新、package:http 各引擎、CachedNetworkImage
/// 封面图、演员库 ContentHttp 等）。挂不上的三条在设置页与报告里
/// 点名：Rust 核心（番茄主路，解析在 Rust 侧）、播放器原生取流
/// （media_kit/libmpv 原生网络栈）、WebView 内核（系统/内核自带解析）。
///
/// 两个开关默认都开（装上即生效，不用用户翻设置）；关掉即真关：
/// 镜像关 → 永不改写；DoH 关 → 新建 HttpClient 不再挂 connectionFactory。
class NetResiliencePreferences {
  NetResiliencePreferences._();

  static final NetResiliencePreferences instance =
      NetResiliencePreferences._();

  static const githubMirrorKey = 'net_github_mirror_enabled';
  static const dohKey = 'net_doh_enabled';

  /// GitHub 镜像回退开关，默认开。
  final ValueNotifier<bool> githubMirrorEnabled = ValueNotifier<bool>(true);

  /// DoH 开关，默认开。
  final ValueNotifier<bool> dohEnabled = ValueNotifier<bool>(true);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      githubMirrorEnabled.value = sp.getBool(githubMirrorKey) ?? true;
      dohEnabled.value = sp.getBool(dohKey) ?? true;
    } catch (_) {
      // 读盘失败按默认值（开）走：容灾是兜底，宁可开着。
    }
  }

  /// 仅测试用：清掉一次性的已加载标记，好让 mock 值被重新读到。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    githubMirrorEnabled.value = true;
    dohEnabled.value = true;
  }

  Future<void> setGithubMirrorEnabled(bool value) async {
    githubMirrorEnabled.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(githubMirrorKey, value);
    } catch (_) {
      // 本会话内的值仍然生效，只是没落盘。
    }
  }

  Future<void> setDohEnabled(bool value) async {
    dohEnabled.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(dohKey, value);
    } catch (_) {
      // 同上。
    }
  }
}

/// `raw.githubusercontent.com` → jsDelivr 的地址改写（纯函数）。
///
/// raw 形态：`https://raw.githubusercontent.com/{user}/{repo}/{ref}/{path...}`
/// jsDelivr 形态：`https://cdn.jsdelivr.net/gh/{user}/{repo}@{ref}/{path...}`
///
/// ref 是分支名或提交哈希：jsDelivr 对分支文件有缓存（更新延迟可达
/// 数小时），对提交哈希是不可变内容、无延迟问题。本树的内置索引地址
/// 用的是分支（plugins），改不了源头；能钉哈希的地址钉哈希后走同一
/// 改写、天然不受缓存延迟影响。
abstract final class GithubMirror {
  static const rawHost = 'raw.githubusercontent.com';
  static const mirrorHost = 'cdn.jsdelivr.net';

  static bool isRawGithubUri(Uri uri) => uri.host.toLowerCase() == rawHost;

  /// 40 位十六进制 = 完整提交哈希。
  static bool isCommitSha(String value) =>
      RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(value);

  /// 改写成 jsDelivr 地址；不是 raw 地址、或段数不足（缺 ref/路径）
  /// 时返回 null（不改写）。
  static Uri? jsDelivrUri(Uri uri) {
    if (!isRawGithubUri(uri)) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 4) return null;
    final user = segments[0];
    final repo = segments[1];
    final ref = segments[2];
    final path = segments.sublist(3).join('/');
    return Uri.parse(
      'https://$mirrorHost/gh/$user/$repo@$ref/$path',
    ).replace(query: uri.query.isEmpty ? null : uri.query);
  }
}

/// 一家 DoH 服务商：JSON 接口域名 + 引导 IP（域名本身解析不出来时，
/// 先按引导 IP 直连服务商域名取解析结果；TLS 仍按服务商域名校验）。
class DohProvider {
  const DohProvider({
    required this.name,
    required this.host,
    required this.bootstrapIps,
    required this.queryPath,
  });

  /// 界面/日志里的人话名。
  final String name;

  /// DoH 接口域名。
  final String host;

  /// 引导 IP（服务商公开的任播地址）。
  final List<String> bootstrapIps;

  /// 查询路径模板：`{name}`、`{type}` 占位。
  final String queryPath;

  Uri queryUri(String name, int type) => Uri.parse(
    'https://$host${queryPath.replaceAll('{name}', Uri.encodeQueryComponent(name)).replaceAll('{type}', '$type')}',
  );
}

/// DoH 解析器：Cloudflare 优先、Google 兜底；结果带 TTL 缓存。
///
/// 查询本身走一个特制的 HttpClient：connectionFactory 无视 URL 域名、
/// 直接连服务商的引导 IP——这样系统 DNS 全灭时 DoH 依然问得出去；
/// TLS 校验仍按服务商域名走 dart:io 默认逻辑，不降级。
class DohResolver {
  DohResolver._();

  static const List<DohProvider> providers = [
    DohProvider(
      name: 'Cloudflare',
      host: 'cloudflare-dns.com',
      bootstrapIps: ['1.1.1.1', '1.0.0.1'],
      queryPath: '/dns-query?name={name}&type={type}',
    ),
    DohProvider(
      name: 'Google',
      host: 'dns.google',
      bootstrapIps: ['8.8.8.8', '8.8.4.4'],
      queryPath: '/resolve?name={name}&type={type}',
    ),
  ];

  /// 单段查询超时。DoH 只在系统 DNS 已坏时才被咨询，预算给宽些：
  /// 10 秒一段、两家服务商顺序兜底，最坏约 40 秒后才认输——
  /// 对比「直接解析失败」，慢一点但能通更重要。
  /// 非 const 只为真网测试在本机慢代理下放宽取证，生产勿改。
  static Duration queryTimeout = const Duration(seconds: 10);

  static final Map<String, _DohCacheEntry> _cache = {};

  /// 测试缝：替换掉真实的 DoH 查询（返回解析到的地址列表）。
  @visibleForTesting
  static Future<List<InternetAddress>> Function(String host)? debugQuery;

  /// 测试缝：为 true 时 DoH 查询不强制直连、允许走系统/环境代理。
  /// 只供本机沙箱取证（该环境 Dart 进程的直连 TCP 被网关关停）；
  /// 生产恒为 false——真机上 DoH 的意义就是绕开本地解析与代理。
  @visibleForTesting
  static bool debugAllowProxy = false;

  /// 仅测试用：清缓存与测试缝。
  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    debugQuery = null;
    debugAllowProxy = false;
  }

  /// 解析 [host]：先查缓存，再依次问各服务商（A 记录优先，无 A 再 AAAA）。
  /// 全部失败抛 [SocketException]。
  static Future<List<InternetAddress>> resolve(String host) async {
    final override = debugQuery;
    if (override != null) return override(host);
    final key = host.toLowerCase();
    final cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.addresses;
    }
    for (final provider in providers) {
      try {
        final result = await _queryProvider(provider, host);
        if (result.addresses.isNotEmpty) {
          _cache[key] = result;
          return result.addresses;
        }
      } catch (error) {
        AppLog.w('net', 'DoH 解析失败（${provider.name}，$host）', error: error);
      }
    }
    throw SocketException('加密 DNS 解析失败：$host');
  }

  static Future<_DohCacheEntry> _queryProvider(
    DohProvider provider,
    String host,
  ) async {
    // A（1）先问；A 空再问 AAAA（28）。
    var minTtl = 600;
    final addresses = <InternetAddress>[];
    for (final type in const [1, 28]) {
      final uri = provider.queryUri(host, type);
      final json = await _fetchJsonViaBootstrap(provider, uri);
      final answers = json['Answer'];
      if (answers is List) {
        for (final item in answers) {
          if (item is! Map) continue;
          final answerType = item['type'];
          final data = item['data'];
          final ttl = item['TTL'];
          if (ttl is int && ttl > 0 && ttl < minTtl) minTtl = ttl;
          if (answerType != type || data is! String) continue;
          try {
            addresses.add(InternetAddress(data));
          } catch (_) {
            // 不是 IP 字面量的 data（如 CNAME 目标）跳过。
          }
        }
      }
      if (addresses.isNotEmpty) break;
    }
    final ttlSeconds = minTtl.clamp(60, 600);
    return _DohCacheEntry(
      addresses,
      DateTime.now().add(Duration(seconds: ttlSeconds)),
    );
  }

  /// 按引导 IP 连服务商域名取 JSON：connectionFactory 只连引导 IP，
  /// HTTPS 的 SNI/证书仍由 dart:io 按 URL 域名（服务商域名）校验。
  static Future<Map<String, dynamic>> _fetchJsonViaBootstrap(
    DohProvider provider,
    Uri uri,
  ) async {
    final client = HttpClient();
    // DoH 查询的意义就是绕开本地解析与代理：强制直连引导 IP，
    // 不读系统/环境代理（代理在时它自己会解析，DoH 也无从兜底）。
    if (!debugAllowProxy) {
      client.findProxy = (_) => 'DIRECT';
    }
    client.connectionTimeout = queryTimeout;
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      // 有代理时按代理走（代理自己解析），不强行直连引导 IP。
      if (proxyHost != null) {
        final socket = await connectSocketWithTimeout(
          proxyHost,
          proxyPort ?? 443,
          queryTimeout,
        );
        return ConnectionTask.fromSocket(Future.value(socket), () {});
      }
      for (final ip in provider.bootstrapIps) {
        try {
          final socket = await connectSocketWithTimeout(
            InternetAddress(ip),
            443,
            queryTimeout,
          );
          // 同连接工厂的口径：工厂路要自己按服务商域名做 TLS 升级。
          final secure = await SecureSocket.secure(
            socket,
            host: provider.host,
          );
          return ConnectionTask.fromSocket(Future.value(secure), () {});
        } catch (_) {
          // 换下一个引导 IP。
        }
      }
      throw SocketException('DoH 服务商连不上：${provider.host}');
    };
    try {
      final request = await client.getUrl(uri).timeout(queryTimeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(queryTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(queryTimeout);
      if (response.statusCode != 200) {
        throw SocketException('DoH 查询返回 HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const SocketException('DoH 查询返回内容异常');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}

class _DohCacheEntry {
  _DohCacheEntry(this.addresses, this.expiresAt);

  final List<InternetAddress> addresses;
  final DateTime expiresAt;
}

/// 容灾连接工厂：给 dart:io [HttpClient] 用的 connectionFactory。
///
/// 顺序（每个连接现做，不缓存连接层面的裁决）：
/// 1. 目标是 IP 字面量 / localhost / .local → 直连，永不走 DoH。
/// 2. 系统 DNS 解析：成功且结果不全是内网/回环地址 → 按系统结果连
///    （逐个试，连上为止）。
/// 3. 系统解析失败 / 为空 / 只剩内网回环地址（污染形态），且 DoH
///    开关开着 → DoH 解析 → 按 DoH 结果连。
/// 4. DoH 也失败 → 若第 2 步手里还有系统结果（哪怕形态可疑），拿它
///    做最后尝试；实在没有才抛错。
/// 有 HTTP 代理时（proxyHost 非空）：连接目标是代理本身，代理负责
/// 解析远端域名；本工厂只对代理地址做同样的「系统 → DoH」兜底。
abstract final class ResilientConnectionFactory {
  static const Duration lookupTimeout = Duration(seconds: 5);
  static const Duration connectTimeout = Duration(seconds: 10);

  /// 测试缝：替换系统 DNS 查询。
  @visibleForTesting
  static Future<List<InternetAddress>> Function(String host)? debugSystemLookup;

  /// 仅测试用：清测试缝。
  @visibleForTesting
  static void resetForTest() {
    debugSystemLookup = null;
  }

  static Future<List<InternetAddress>> _systemLookup(String host) {
    final override = debugSystemLookup;
    if (override != null) return override(host);
    return InternetAddress.lookup(host).timeout(lookupTimeout);
  }

  /// 地址是否属于「不该是公网域名解析结果」的形态：
  /// 回环 / 链路本地 / 私网 / 未指定。公网域名只返回这类地址 →
  /// 按污染处理。100.64.0.0/10（运营商 CGNAT）不在此列，不误判。
  static bool isSuspiciousAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && raw.length == 4) {
      if (raw[0] == 10) return true;
      if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
      if (raw[0] == 192 && raw[1] == 168) return true;
      if (raw[0] == 0) return true;
      return false;
    }
    if (raw.isNotEmpty && (raw[0] & 0xfe) == 0xfc) return true; // fc00::/7
    return false;
  }

  static bool _isLocalTarget(String host) {
    final lower = host.toLowerCase();
    return lower == 'localhost' ||
        lower.endsWith('.local') ||
        InternetAddress.tryParse(host) != null;
  }

  static Future<ConnectionTask<Socket>> connect(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final host = proxyHost ?? url.host;
    final port = proxyPort ?? url.port;
    // 关键口径：dart:io 对自定义 connectionFactory 返回的 socket
    // 不再自动做 TLS 升级（默认路是 SecureSocket.startConnect 自带
    // 升级，工厂路没有）。https 直连必须由工厂自己按原域名升级：
    // SecureSocket.secure 的 host 用 URL 原域名，SNI 与证书校验都
    // 对原域名，不降级。走代理时相反——客户端先用明文 socket 建
    // CONNECT 隧道、再自己升级，所以代理分支交回裸 socket。
    final upgradeTls = proxyHost == null && url.isScheme('https');
    var cancelled = false;
    Socket? established;

    /// 对一批地址逐个尝试「TCP 建连（＋https 时按原域名 TLS 升级）」，
    /// 握手失败也算该地址失败、换下一个——这样系统 DNS 给的地址
    /// 连得上却握手失败（假 IP 拦截的典型形态）时能继续换 DoH 地址。
    Future<Socket?> tryAddresses(List<InternetAddress> addresses) async {
      for (final address in addresses) {
        Socket? raw;
        try {
          raw = await connectSocketWithTimeout(
            address,
            port,
            connectTimeout,
          );
          if (!upgradeTls) return raw;
          final secure = await SecureSocket.secure(raw, host: url.host);
          return secure;
        } catch (_) {
          raw?.destroy();
          // 换下一个地址。
        }
      }
      return null;
    }

    Future<Socket> dial() async {
      // 1. 本地/IP 字面量：直连（代理主机是 IP 时同理）。
      final literal = InternetAddress.tryParse(host);
      if (literal != null) {
        final socket = await tryAddresses([literal]);
        if (socket != null) return socket;
        throw SocketException('连不上：$host:$port');
      }
      if (proxyHost == null && _isLocalTarget(host)) {
        final raw = await connectSocketWithTimeout(
          host,
          port,
          connectTimeout,
        );
        if (!upgradeTls) return raw;
        return SecureSocket.secure(raw, host: url.host);
      }

      // 2. 系统 DNS。
      List<InternetAddress> systemAddresses = const [];
      Object? systemError;
      try {
        systemAddresses = await _systemLookup(host);
      } catch (error) {
        systemError = error;
      }
      final systemUsable = systemAddresses.any(
        (a) => !isSuspiciousAddress(a),
      );
      if (systemUsable) {
        final socket = await tryAddresses(systemAddresses);
        if (socket != null) return socket;
        // 系统给了公网地址却全连不上/握手失败：走 DoH 再试一批。
      }

      // 3. DoH 兜底。
      if (NetResiliencePreferences.instance.dohEnabled.value) {
        try {
          final dohAddresses = await DohResolver.resolve(host);
          final socket = await tryAddresses(dohAddresses);
          if (socket != null) return socket;
        } catch (error) {
          AppLog.w('net', 'DoH 兜底未连上（$host）', error: error);
        }
      }

      // 4. 最后尝试系统结果（哪怕形态可疑），都没有才抛错。
      if (systemAddresses.isNotEmpty && !systemUsable) {
        final socket = await tryAddresses(systemAddresses);
        if (socket != null) return socket;
      }
      throw SocketException(
        '域名无法解析或连不上：$host',
        osError: systemError is OSError ? systemError : null,
      );
    }

    final future = dial().then((socket) {
      if (cancelled) {
        socket.destroy();
        throw const SocketException('连接已取消');
      }
      established = socket;
      return socket;
    });
    // 竞态兜底：dial 若在 HttpClient 订阅 task.socket 之前就失败，
    // 这个 future 会在零监听状态下带错完成、被运行时当未捕获异常
    // 再投递一遍（调用方 catch 到也照样报）。先挂一个吞错分支占住
    // 监听，真正的错误仍由 HttpClient 的订阅原样收到。
    unawaited(future.then((_) {}, onError: (Object _) {}));
    return ConnectionTask.fromSocket(future, () {
      cancelled = true;
      established?.destroy();
    });
  }
}

/// 带超时的 TCP 建连：[Socket.startConnect] 给的是 ConnectionTask，
/// 这里等到真 socket 落地，超时就取消任务。
Future<Socket> connectSocketWithTimeout(
  Object host,
  int port,
  Duration timeout,
) async {
  final task = await Socket.startConnect(host, port).timeout(timeout);
  return task.socket.timeout(
    timeout,
    onTimeout: () {
      task.cancel();
      throw TimeoutException('连接超时', timeout);
    },
  );
}

/// 建带容灾连接工厂的 [HttpClient]。DoH 开关关着时返回原生客户端
/// （不挂工厂＝真关）。
HttpClient createResilientHttpClient({SecurityContext? context}) {
  final client = HttpClient(context: context);
  if (NetResiliencePreferences.instance.dohEnabled.value) {
    client.connectionFactory = ResilientConnectionFactory.connect;
  }
  return client;
}

/// 全局 HttpOverrides：让全应用所有 `HttpClient()`（含 package:http
/// 的 IOClient、CachedNetworkImage 的缓存管理器）在 DoH 开着时都走
/// 容灾连接工厂。开关每次新建客户端时现读，切换即时生效（对新连接）。
/// 只在 main() 里安装一次；测试不安装、需要时显式用
/// [createResilientHttpClient] 或直接设 connectionFactory。
class ResilientHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return createResilientHttpClient(context: context);
  }
}
