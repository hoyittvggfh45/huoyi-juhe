import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/net_resilience.dart';

/// 网络容灾真网证据测试：默认跳过，只有 NET_RESILIENCE_LIVE=1 时才跑
/// （CI/常规回归不碰真网）。2026-11-28 本机实跑结果记录在
/// ~/workspace/xiuxian_net_resilience_20261128/REPORT.md。
final bool _live = Platform.environment['NET_RESILIENCE_LIVE'] == '1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? savedOverrides;

  setUp(() {
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    NetResiliencePreferences.instance.resetForTest();
    DohResolver.resetForTest();
    ResilientConnectionFactory.resetForTest();
  });

  tearDown(() {
    HttpOverrides.global = savedOverrides;
    DohResolver.resetForTest();
    ResilientConnectionFactory.resetForTest();
  });

  Future<List<int>> plainFetch(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      expect(response.statusCode, 200);
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  test(
    '验收1：raw 被掐 → 插件存储自动改走 jsDelivr 拉回真索引（与直连 md5 一致）',
    () async {
      await NetResiliencePreferences.instance.load();
      final directBytes = await plainFetch(Uri.parse(idjBuiltInSubscriptionUrl));
      final directMd5 = md5.convert(directBytes).toString();
      // ignore: avoid_print
      print('直连 raw：${directBytes.length} 字节，md5=$directMd5');

      // 夹具客户端：raw 域名在连接层一律拒绝（模拟被掐），其余域名
      // 交给容灾工厂（系统 DNS 正常时等价直连）。
      HttpClient blockedRawClient() {
        final client = HttpClient();
        client.connectionFactory = (url, proxyHost, proxyPort) async {
          if (url.host == GithubMirror.rawHost) {
            throw const SocketException('模拟 raw.githubusercontent.com 被掐');
          }
          return ResilientConnectionFactory.connect(url, proxyHost, proxyPort);
        };
        return client;
      }

      final store = IdjPluginStore(httpFactory: blockedRawClient);
      final text = await store.downloadText(
        Uri.parse(idjBuiltInSubscriptionUrl),
        maxBytes: 4 * 1024 * 1024,
      );
      final mirrorBytes = utf8.encode(text);
      final mirrorMd5 = md5.convert(mirrorBytes).toString();
      // ignore: avoid_print
      print('镜像回退：${mirrorBytes.length} 字节，md5=$mirrorMd5');
      expect(mirrorMd5, directMd5);

      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final plugins = decoded['plugins'] as List<dynamic>;
      // ignore: avoid_print
      print('索引名=${decoded['name']}，插件条数=${plugins.length}');
      expect(decoded['name'], isNotEmpty);
      expect(plugins.length, greaterThan(200));
    },
    skip: !_live,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '验收2a：DoH 真解析（本机沙箱借环境代理取证，真机走直连引导 IP）',
    () async {
      await NetResiliencePreferences.instance.load();
      // 本机沙箱把 Dart 进程的直连 TCP 关停（网关明文回绝
      // "Other TCP connections is turned off"），故取证时允许 DoH
      // 查询走环境代理；解析器逻辑、服务商顺序、JSON 解析、缓存
      // 都是生产同一套。真机默认 debugAllowProxy=false、直连引导 IP。
      DohResolver.debugAllowProxy = true;
      // 本机代理建隧道+TLS 实测可达 18 秒：取证时放宽单段超时，
      // 生产默认 10 秒不变。
      DohResolver.queryTimeout = const Duration(seconds: 45);
      // 本机出口抖动实测存在（curl 同路径也间歇超时）：最多试 3 次，
      // 每次尝试与结果都打印留痕。
      Future<List<InternetAddress>> resolveWithRetry(String host) async {
        Object? lastError;
        for (var attempt = 1; attempt <= 3; attempt++) {
          try {
            final result = await DohResolver.resolve(host);
            // ignore: avoid_print
            print('DoH 解析 $host 第 $attempt 次 → ${result.map((a) => a.address).toList()}');
            return result;
          } catch (error) {
            lastError = error;
            // ignore: avoid_print
            print('DoH 解析 $host 第 $attempt 次失败：$error');
          }
        }
        throw lastError!;
      }

      final resolved = await resolveWithRetry('cdn.jsdelivr.net');
      expect(resolved, isNotEmpty);
      final resolvedRaw = await resolveWithRetry('raw.githubusercontent.com');
      // ignore: avoid_print
      print(
        'DoH 解析 raw.githubusercontent.com → '
        '${resolvedRaw.map((a) => a.address).toList()}',
      );
      expect(
        resolvedRaw.map((a) => a.address),
        contains(startsWith('185.199.')),
      );
    },
    skip: !_live,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '验收2b：系统 DNS 全灭 → DoH 给 IP → 按 IP 直连取回真索引（需可直连环境）',
    () async {
      await NetResiliencePreferences.instance.load();

      final resolved = await DohResolver.resolve('cdn.jsdelivr.net');
      // ignore: avoid_print
      print('DoH 解析 cdn.jsdelivr.net → ${resolved.map((a) => a.address).toList()}');
      expect(resolved, isNotEmpty);

      // 模拟设备上系统 DNS 全灭：系统查询一律抛错，只剩 DoH 一条路。
      ResilientConnectionFactory.debugSystemLookup = (host) async =>
          throw const SocketException('模拟系统 DNS 全灭');

      final directBytes = await plainFetch(Uri.parse(idjBuiltInSubscriptionUrl));
      final directMd5 = md5.convert(directBytes).toString();

      final client = createResilientHttpClient();
      client.findProxy = (_) => 'DIRECT';
      try {
        final request = await client.getUrl(
          Uri.parse(
            'https://cdn.jsdelivr.net/gh/hoyittvggfh45/moytv@plugins/index.json',
          ),
        );
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
        }
        final viaDohMd5 = md5.convert(bytes).toString();
        // ignore: avoid_print
        print(
          'DoH 路取回：HTTP ${response.statusCode}，${bytes.length} 字节，md5=$viaDohMd5',
        );
        expect(response.statusCode, 200);
        expect(viaDohMd5, directMd5);
      } finally {
        client.close(force: true);
      }
    },
    // 本机沙箱网关关停 Dart 直连 TCP（见 2a 注释），本条只在
    // NET_RESILIENCE_LIVE_DIRECT=1 的可直连环境跑；本机记待真机验。
    skip: !_live || Platform.environment['NET_RESILIENCE_LIVE_DIRECT'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
