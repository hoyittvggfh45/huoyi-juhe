// 网盘入口对齐（xiuxian_wangpan_entry_20261128）预览：真渲染出图落
// 本批 previews/。数据是夹具（假网关、假登录态），只验版式与落点，
// 不冒充真数据。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/cloud_drive/cloud_drive_client.dart';
import 'package:fqapp/cloud_drive/cloud_drive_models.dart';
import 'package:fqapp/cloud_drive/cloud_multimedia_body.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_wangpan_entry_20261128/previews';
const _boundaryKey = ValueKey<String>('pan-multimedia-preview-boundary');

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('01 网盘多媒体页：海报墙', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _FakeGateway({
      'cloud:pan115||': CatalogPage([
        Drama(
          id: 'cloud:pan115:folder:fld1',
          source: 'cloud:pan115',
          title: '电影收藏',
          kind: 'folder',
          folderId: 'fld1',
        ),
        Drama(
          id: 'cloud:pan115:f1',
          source: 'cloud:pan115',
          title: 'ABC-123 中文字幕版.mkv',
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
          title: '电视剧全集',
          kind: 'folder',
          folderId: 'fld2',
        ),
      ]),
    });
    await tester.pumpWidget(
      _scene(
        Scaffold(
          appBar: AppBar(title: const Text('网盘')),
          body: CloudMultimediaBody(
            driveEntries: () => [
              SourceEntry(
                id: 'cloud:pan115',
                name: '115网盘',
                kind: SourceKind.cloudDrive,
                extra: const {'contentType': 'video'},
              ),
              SourceEntry(
                id: 'cloud:quark',
                name: '夸克网盘',
                kind: SourceKind.cloudDrive,
                extra: const {'contentType': 'video'},
              ),
            ],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('电影收藏'), findsOneWidget);
    await _capture(tester, 'preview_pan_multimedia_body');
  });
  testWidgets('02 首页分类行：右侧固定网盘入口', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    // 字体预热：先泵一帧带中文字的占位，让字体在本用例里先落盘
    // 渲染一次，否则首个用例的分类条标签会出豆腐块（后续用例正常）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('推荐网盘'))),
    );
    await _settle(tester);
    tester.view.physicalSize = const Size(390, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _scene(
        Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: HomeTabBarDelegate(
                  selectedIndex: 0,
                  onSelect: (_) {},
                  dark: true,
                ),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('分类行右端是固定网盘入口，不必横滑到行尾'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('网盘'), findsOneWidget);
    final rect = tester.getRect(find.text('网盘'));
    expect(rect.right, lessThanOrEqualTo(390));
    await _capture(tester, 'preview_home_category_pan_entry');
  });

}
