import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/net_resilience.dart';

/// 网络容灾（GitHub 镜像回退 + DoH）的离线/夹具测试。
/// 真网证据在 net_resilience_live_test.dart（需 NET_RESILIENCE_LIVE=1）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 本文件要真建 socket：摘掉 flutter_test 的 mock HttpClient 覆盖层
  // （与 cached_dramas_page_test 同款处理）。
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

  group('GithubMirror 改写', () {
    test('内置插件索引地址改写成 jsDelivr 形态', () {
      final uri = Uri.parse(idjBuiltInSubscriptionUrl);
      final mirror = GithubMirror.jsDelivrUri(uri);
      expect(mirror, isNotNull);
      expect(
        mirror.toString(),
        'https://cdn.jsdelivr.net/gh/hoyittvggfh45/moytv@plugins/index.json',
      );
    });

    test('深层路径与查询串保留', () {
      final mirror = GithubMirror.jsDelivrUri(
        Uri.parse(
          'https://raw.githubusercontent.com/u/r/main/a/b/c.js?x=1',
        ),
      );
      expect(
        mirror.toString(),
        'https://cdn.jsdelivr.net/gh/u/r@main/a/b/c.js?x=1',
      );
    });

    test('提交哈希 ref 识别', () {
      expect(
        GithubMirror.isCommitSha('0123456789abcdef0123456789abcdef01234567'),
        isTrue,
      );
      expect(GithubMirror.isCommitSha('main'), isFalse);
      final mirror = GithubMirror.jsDelivrUri(
        Uri.parse(
          'https://raw.githubusercontent.com/u/r/'
          '0123456789abcdef0123456789abcdef01234567/f.json',
        ),
      );
      expect(
        mirror.toString(),
        'https://cdn.jsdelivr.net/gh/u/r@'
        '0123456789abcdef0123456789abcdef01234567/f.json',
      );
    });

    test('非 raw 地址不改写', () {
      expect(
        GithubMirror.jsDelivrUri(Uri.parse('https://github.com/u/r')),
        isNull,
      );
      expect(
        GithubMirror.jsDelivrUri(
          Uri.parse('https://api.github.com/repos/u/r/releases'),
        ),
        isNull,
      );
      expect(
        GithubMirror.jsDelivrUri(
          Uri.parse('https://example.com/u/r/main/f.json'),
        ),
        isNull,
      );
    });

    test('段数不足不改写', () {
      expect(
        GithubMirror.jsDelivrUri(
          Uri.parse('https://raw.githubusercontent.com/u/r'),
        ),
        isNull,
      );
    });
  });

  group('开关默认值与持久化', () {
    test('两开关默认开（装上即生效）', () async {
      await NetResiliencePreferences.instance.load();
      expect(
        NetResiliencePreferences.instance.githubMirrorEnabled.value,
        isTrue,
      );
      expect(NetResiliencePreferences.instance.dohEnabled.value, isTrue);
    });

    test('关掉后落盘、重读仍是关', () async {
      final prefs = NetResiliencePreferences.instance;
      await prefs.load();
      await prefs.setGithubMirrorEnabled(false);
      await prefs.setDohEnabled(false);
      expect(prefs.githubMirrorEnabled.value, isFalse);
      expect(prefs.dohEnabled.value, isFalse);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool(NetResiliencePreferences.githubMirrorKey), isFalse);
      expect(sp.getBool(NetResiliencePreferences.dohKey), isFalse);
      prefs.resetForTest();
      // resetForTest 把内存值拨回默认开；再 load 必须读回落盘的关。
      await prefs.load();
      expect(prefs.githubMirrorEnabled.value, isFalse);
      expect(prefs.dohEnabled.value, isFalse);
    });
  });

  group('DoH 解析器（注入查询）', () {
    test('走注入的查询并返回结果', () async {
      DohResolver.debugQuery = (host) async => [InternetAddress('1.2.3.4')];
      final result = await DohResolver.resolve('example.org');
      expect(result.map((a) => a.address), ['1.2.3.4']);
    });

    test('查询全失败抛 SocketException', () async {
      DohResolver.debugQuery = (host) async =>
          throw const SocketException('boom');
      await expectLater(
        DohResolver.resolve('example.org'),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('容灾连接工厂（本机服务器夹具）', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((request) {
        request.response
          ..statusCode = 200
          ..write('resilience-ok')
          ..close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('系统 DNS 失败 → DoH 给出地址 → 按 IP 连上并取到内容', () async {
      await NetResiliencePreferences.instance.load();
      ResilientConnectionFactory.debugSystemLookup = (host) async =>
          throw const SocketException('系统解析失败（模拟）');
      DohResolver.debugQuery = (host) async => [InternetAddress('127.0.0.1')];
      final client = createResilientHttpClient();
      client.findProxy = (_) => 'DIRECT';
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://blocked.example:$port/'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      expect(body, 'resilience-ok');
    });

    test('createResilientHttpClient 在 DoH 关时不挂工厂：解析失败即失败', () async {
      final prefs = NetResiliencePreferences.instance;
      await prefs.load();
      await prefs.setDohEnabled(false);
      // 系统解析被注入失败、DoH 桩本可成功——若工厂被偷偷挂上，
      // 请求会经工厂走 DoH 桩而成功；不挂工厂则原生客户端自己
      // 解析 blocked.example 必然失败。
      ResilientConnectionFactory.debugSystemLookup = (host) async =>
          throw const SocketException('系统解析失败（模拟）');
      DohResolver.debugQuery = (host) async => [InternetAddress('127.0.0.1')];
      final client = createResilientHttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 5);
      addTearDown(() => client.close(force: true));
      // 断言：关了就拿不到夹具内容（本机出口对任意连接都会假接，
      // 所以不断言「必然抛错」，只断言得不到 200+夹具正文）。
      String outcome;
      try {
        final request = await client
            .getUrl(Uri.parse('http://blocked.example:$port/'))
            .timeout(const Duration(seconds: 10));
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
        outcome = '${response.statusCode}:$body';
      } catch (error) {
        outcome = 'error:$error';
      }
      expect(outcome, isNot('200:resilience-ok'));
    });

    test('DoH 开关关掉后，系统 DNS 失败即失败（不偷偷走 DoH）', () async {
      final prefs = NetResiliencePreferences.instance;
      await prefs.load();
      await prefs.setDohEnabled(false);
      ResilientConnectionFactory.debugSystemLookup = (host) async =>
          throw const SocketException('系统解析失败（模拟）');
      var dohConsulted = false;
      DohResolver.debugQuery = (host) async {
        dohConsulted = true;
        return [InternetAddress('127.0.0.1')];
      };
      final client = HttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = ResilientConnectionFactory.connect;
      addTearDown(() => client.close(force: true));
      Object? caught;
      try {
        await client.getUrl(Uri.parse('http://blocked.example:$port/'));
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<SocketException>());
      expect(dohConsulted, isFalse);
    });

    test('系统 DNS 只返回回环地址（污染形态）→ 改走 DoH', () async {
      await NetResiliencePreferences.instance.load();
      // 污染：任意域名都给 127.0.0.1 的「别的端口」——本夹具直接给
      // 正确地址反而测不出切换；这里系统给回环但端口连不上不现实，
      // 改用：系统返回回环地址、DoH 返回同样回环但断言 DoH 被咨询。
      var dohConsulted = false;
      ResilientConnectionFactory.debugSystemLookup = (host) async =>
          [InternetAddress('127.0.0.1')];
      DohResolver.debugQuery = (host) async {
        dohConsulted = true;
        return [InternetAddress('127.0.0.1')];
      };
      final client = createResilientHttpClient();
      client.findProxy = (_) => 'DIRECT';
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://polluted.example:$port/'),
      );
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      // 系统结果全是可疑地址时不该直接采用，必须先咨询 DoH。
      expect(dohConsulted, isTrue);
    });
  });

  group('插件下载镜像回退（本机服务器夹具）', () {
    late HttpServer server;
    late int port;
    final seenPaths = <String>[];

    setUp(() async {
      seenPaths.clear();
      // 下载通道只走 https：夹具服务器用自签证书（test/fixtures），
      // 夹具客户端放行该证书；证书校验口径本身不在本组验证范围。
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/net_resilience_cert.pem')
        ..usePrivateKey('test/fixtures/net_resilience_key.pem');
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      port = server.port;
      server.listen((request) {
        seenPaths.add(request.uri.path);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"name":"夹具索引","plugins":[],"cms":[]}')
          ..close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    /// 夹具客户端：raw 域名一律连不上（模拟被掐），其余域名全部
    /// 落到本机夹具服务器。
    HttpClient fixtureClient() {
      final client = HttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (url, proxyHost, proxyPort) async {
        if (url.host == GithubMirror.rawHost) {
          throw const SocketException('连接被掐（模拟）');
        }
        final socket = await connectSocketWithTimeout(
          InternetAddress.loopbackIPv4,
          port,
          const Duration(seconds: 5),
        );
        // 工厂路要自己做 TLS 升级（自签证书在本夹具内放行）。
        final secure = await SecureSocket.secure(
          socket,
          host: url.host,
          onBadCertificate: (_) => true,
        );
        return ConnectionTask.fromSocket(Future.value(secure), () {});
      };
      return client;
    }

    IdjPluginStore fixtureStore() => IdjPluginStore(
      httpFactory: fixtureClient,
      uriValidator: (_) async {},
    );

    test('raw 拉不到 → 自动改走 jsDelivr 并拿到内容', () async {
      await NetResiliencePreferences.instance.load();
      final store = fixtureStore();
      final text = await store.downloadText(
        Uri.parse(idjBuiltInSubscriptionUrl),
        maxBytes: 1024 * 1024,
      );
      expect(text, contains('夹具索引'));
      expect(
        seenPaths,
        contains('/gh/hoyittvggfh45/moytv@plugins/index.json'),
      );
    });

    test('镜像开关关掉 → raw 拉不到就是失败，不改走', () async {
      final prefs = NetResiliencePreferences.instance;
      await prefs.load();
      await prefs.setGithubMirrorEnabled(false);
      final store = fixtureStore();
      await expectLater(
        store.downloadText(
          Uri.parse(idjBuiltInSubscriptionUrl),
          maxBytes: 1024 * 1024,
        ),
        throwsA(isA<IdjPluginFailure>()),
      );
      expect(seenPaths, isEmpty);
    });
  });
}
