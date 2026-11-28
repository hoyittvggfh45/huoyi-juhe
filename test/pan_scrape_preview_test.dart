// 网盘带刮削（xiuxian_wangpan_scrape_20261128）预览：同一
// 页条目刮前（原文件名、无分类行）与刮后（刮后标题、封
// 面补齐、分类筛选行出现）对比出图，落本批 previews/。
// 数据是夹具，只验版式与落点，不冒充真数据。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/cloud_drive/cloud_drive_client.dart';
import 'package:fqapp/cloud_drive/cloud_drive_models.dart';
import 'package:fqapp/cloud_drive/cloud_multimedia_body.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/tmdb/tmdb_metadata.dart';

import 'preview_test_support.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_wangpan_scrape_20261128/previews';
const _boundaryKey = ValueKey<String>('pan-scrape-preview-boundary');

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_previewDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Widget _scene(Widget child) {
  return RepaintBoundary(
    key: _boundaryKey,
    child: MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansCJK', brightness: Brightness.dark),
      home: child,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

class _FakeGateway implements CloudCatalogGateway {
  _FakeGateway(this.pages);
  final Map<String, CatalogPage> pages;

  @override
  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
  }) async => pages['$source|$category|$query'] ?? CatalogPage(const []);

  @override
  Future<DramaDetail> detail(Drama drama) => throw UnimplementedError();

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) =>
      throw UnimplementedError();
}

_FakeGateway _gateway() => _FakeGateway({
  'cloud:pan115||': CatalogPage([
    Drama(
      id: 'cloud:pan115:f1',
      source: 'cloud:pan115',
      title: 'SSIS-001 某作品 1080p.mkv',
      description: '1.8 GB',
    ),
    Drama(
      id: 'cloud:pan115:f2',
      source: 'cloud:pan115',
      title: '某部电影.2024.1080p.mp4',
      description: '2.3 GB',
    ),
    Drama(
      id: 'cloud:pan115:f3',
      source: 'cloud:pan115',
      title: '庆余年 第二季 第05集.mp4',
      description: '900 MB',
    ),
    Drama(
      id: 'cloud:pan115:f4',
      source: 'cloud:pan115',
      title: '天美传媒 姐姐的秘密.mp4',
      description: '1.1 GB',
    ),
  ]),
});

Widget _body({required bool scraped}) {
  return Scaffold(
    appBar: AppBar(title: const Text('网盘')),
    body: CloudMultimediaBody(
      driveEntries: () => [
        SourceEntry(
          id: 'cloud:pan115',
          name: '115网盘',
          kind: SourceKind.cloudDrive,
          extra: const {'contentType': 'video'},
        ),
      ],
      clientFactory: (id) =>
          CloudDriveContentClient(providerId: id, gateway: _gateway()),
      scrapeSettings: scraped
          ? PanScrapeDefaults.settings
          : PanScrapeDefaults.settings.copyWith(autoScrape: false),
      coverFetcher: (code) async =>
          code == 'SSIS-001' ? 'https://img.example/ssis001.jpg' : '',
      metadataFetcher:
          ({required String title, String? year, String? typeHint}) async {
            if (title.contains('某部电影')) {
              return const TmdbMetadata(
                tmdbId: 1,
                mediaType: 'movie',
                title: '流浪地球2',
                year: '2023',
              );
            }
            if (title.contains('庆余年')) {
              return const TmdbMetadata(
                tmdbId: 2,
                mediaType: 'tv',
                title: '庆余年 第二季',
                year: '2024',
              );
            }
            return null;
          },
    ),
  );
}

/// 假 HTTP：任何 GET 回 1x1 PNG，让封面图一次加载成功
/// （预览只验版式；不打真网络、不留重试定时器）。
class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest();
}

class _FakeHttpRequest extends Fake implements HttpClientRequest {
  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeHttpResponse();
}

class _FakeHttpHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _FakeHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  static const _png = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ];

  @override
  int get statusCode => 200;

  @override
  int get contentLength => _png.length;

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  X509Certificate? get certificate => null;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  List<Cookie> get cookies => const [];

  @override
  Future<Socket> detachSocket() => throw UnsupportedError('fake');

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => throw UnsupportedError('fake');

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_png]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _FakeHttpOverrides();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 刮后预览有封面 URL 会触发图片缓存（path_provider），
    // 测试环境无插件实现，给通道打桩回临时目录。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );
  });

  testWidgets('01 刮前：原文件名海报墙、无分类行', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_scene(_body(scraped: false)));
    await _settle(tester);
    expect(find.text('SSIS-001 某作品 1080p.mkv'), findsOneWidget);
    await _capture(tester, '01_before_scrape');
  });

  testWidgets('02 刮后：刮后标题与分类筛选行', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_scene(_body(scraped: true)));
    await _settle(tester);
    expect(find.text('流浪地球2'), findsOneWidget);
    expect(find.text('庆余年 第二季'), findsOneWidget);
    await _capture(tester, '02_after_scrape');
    // 封面走网络图缓存，其内部一次性定时器用假时钟推完，
    // 避免测试收尾的 pending timer 断言（图已出）。
    await tester.pump(const Duration(minutes: 5));
  });
}
