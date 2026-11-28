// 网盘入口对齐主聊多媒体版（xiuxian_wangpan_entry_20261128）：
// 1) 首页分类行：网盘不再是横滑末位一档，钉在右端固定显示，
//    不横滑就能看到、点到；行内不出现第二个网盘。
// 2) 网盘多媒体主体：未登录空态、登录态海报墙、文件夹下钻、
//    点视频走打开链、网盘源切换、番号封面补刮。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/cloud_drive/cloud_drive_client.dart';
import 'package:fqapp/cloud_drive/cloud_drive_models.dart';
import 'package:fqapp/cloud_drive/cloud_multimedia_body.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

/// 假网关：按 (source, category, query) 记账并回夹具页。
class _FakeGateway implements CloudCatalogGateway {
  _FakeGateway(this.pages);

  /// key: `source|category|query` → 页；缺省回空页。
  final Map<String, CatalogPage> pages;
  final List<({String source, String category, String query})> calls = [];

  @override
  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
  }) async {
    calls.add((source: source, category: category, query: query));
    return pages['$source|$category|$query'] ?? CatalogPage(const []);
  }

  @override
  Future<DramaDetail> detail(Drama drama) => throw UnimplementedError();

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) =>
      throw UnimplementedError();
}

Drama _folder(String source, String folderId, String title) => Drama(
  id: '$source:folder:$folderId',
  source: source,
  title: title,
  kind: 'folder',
  folderId: folderId,
);

Drama _video(String source, String fileId, String title, {String cover = ''}) =>
    Drama(id: '$source:$fileId', source: source, title: title, cover: cover);

SourceEntry _drive(String providerId, String name) => SourceEntry(
  id: 'cloud:$providerId',
  name: name,
  kind: SourceKind.cloudDrive,
  extra: const {'contentType': 'video'},
);

Widget _barScene({
  required int selectedIndex,
  required ValueChanged<int> onSelect,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: HomeTabBarDelegate(
              selectedIndex: selectedIndex,
              onSelect: onSelect,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 200)),
        ],
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('首页分类行网盘固定入口', () {
    testWidgets('手机宽下网盘整字可见、不必横滑', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_barScene(selectedIndex: 0, onSelect: (_) {}));
      await tester.pumpAndSettle();
      expect(find.text('网盘'), findsOneWidget);
      final rect = tester.getRect(find.text('网盘'));
      // 整字落在屏内：左缘不小于 0、右缘不超过屏宽。
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
      // 其余分类仍在：首档「推荐」可见。
      expect(find.text('推荐'), findsOneWidget);
    });

    testWidgets('点固定网盘钮回全表下标、点其它分类下标不移位', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        _barScene(selectedIndex: 0, onSelect: selected.add),
      );
      await tester.pumpAndSettle();
      final panIndex = homeCategories.indexWhere(
        (c) => c.label == panHomeCategoryLabel,
      );
      await tester.tap(find.text('网盘'));
      expect(selected, [panIndex]);
      await tester.tap(find.text('短剧'));
      expect(selected, [panIndex, 2]);
    });

    testWidgets('网盘选中态落在固定钮上', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final panIndex = homeCategories.indexWhere(
        (c) => c.label == panHomeCategoryLabel,
      );
      await tester.pumpWidget(
        _barScene(selectedIndex: panIndex, onSelect: (_) {}),
      );
      await tester.pumpAndSettle();
      double fontSizeOf(String label) {
        final styles = tester.widgetList<AnimatedDefaultTextStyle>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedDefaultTextStyle),
          ),
        );
        return styles.first.style.fontSize ?? 0;
      }

      // 选中字号大于未选中（条带既有口径：17/15）。
      expect(fontSizeOf('网盘'), greaterThan(fontSizeOf('推荐')));
    });
  });

  group('网盘多媒体主体', () {
    Widget scene(CloudMultimediaBody body) {
      return MaterialApp(home: Scaffold(body: body));
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('未登录：空态 + 去网盘登录钮', (tester) async {
      await tester.pumpWidget(
        scene(CloudMultimediaBody(driveEntries: () => const [])),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('pan-multimedia-empty')), findsOneWidget);
      expect(find.text('还没有登录任何网盘'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pan-multimedia-login-button')),
        findsOneWidget,
      );
    });

    testWidgets('登录态：海报墙出文件夹与视频、文件夹带角标', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _folder('cloud:pan115', 'fld1', '电影收藏'),
          _video('cloud:pan115', 'f1', '某部电影.mkv'),
        ]),
      });
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [_drive('pan115', '115网盘')],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('电影收藏'), findsOneWidget);
      expect(find.text('某部电影.mkv'), findsOneWidget);
      expect(find.text('文件夹'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '全部网盘'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '115网盘'), findsOneWidget);
    });

    testWidgets('点文件夹下钻、面包屑出现、返回回根', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _folder('cloud:pan115', 'fld1', '电影收藏'),
        ]),
        'cloud:pan115|fld1|': CatalogPage([
          _video('cloud:pan115', 'f9', '夹中片.mp4'),
        ]),
      });
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [_drive('pan115', '115网盘')],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('电影收藏'));
      await settle(tester);
      expect(find.text('夹中片.mp4'), findsOneWidget);
      expect(
        gateway.calls.any(
          (c) => c.source == 'cloud:pan115' && c.category == 'fld1',
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('pan-multimedia-back')));
      await settle(tester);
      expect(find.text('电影收藏'), findsOneWidget);
      expect(find.text('夹中片.mp4'), findsNothing);
    });

    testWidgets('点视频走打开链（站号 + 条目）', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', '某部电影.mkv'),
        ]),
      });
      final opened = <({String siteId, DramaSiteItem item})>[];
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [_drive('pan115', '115网盘')],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
            onOpenItem: (context, siteId, item) =>
                opened.add((siteId: siteId, item: item)),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.text('某部电影.mkv'));
      await settle(tester);
      expect(opened, hasLength(1));
      expect(opened.single.siteId, 'cloud:pan115');
      expect(opened.single.item.id, 'cloud:pan115:f1');
    });

    testWidgets('切网盘源：只拉被选中的盘', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', '115的片.mkv'),
        ]),
        'cloud:quark||': CatalogPage([
          _video('cloud:quark', 'f2', '夸克的片.mkv'),
        ]),
      });
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [
              _drive('pan115', '115网盘'),
              _drive('quark', '夸克网盘'),
            ],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      );
      await settle(tester);
      // 全部网盘聚合：两家的片都在。
      expect(find.text('115的片.mkv'), findsOneWidget);
      expect(find.text('夸克的片.mkv'), findsOneWidget);
      gateway.calls.clear();
      await tester.tap(find.widgetWithText(ChoiceChip, '夸克网盘'));
      await settle(tester);
      expect(find.text('夸克的片.mkv'), findsOneWidget);
      expect(find.text('115的片.mkv'), findsNothing);
      expect(
        gateway.calls.every((c) => c.source == 'cloud:quark'),
        isTrue,
      );
    });

    testWidgets('番号封面补刮：无封面番号条目补上真封面', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', 'ABC-123 某作品.mkv'),
        ]),
      });
      String? coveredCode;
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [_drive('pan115', '115网盘')],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (code) async {
              coveredCode = code;
              return 'https://img.example/ABC-123.jpg';
            },
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      );
      await settle(tester);
      expect(coveredCode, 'ABC-123');
      final card = tester.widget<HomeMediaCard>(
        find.byType(HomeMediaCard).first,
      );
      expect(card.item.cover, 'https://img.example/ABC-123.jpg');
    });

    testWidgets('搜索：提交后按关键词拉当前盘', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', '根目录片.mkv'),
        ]),
        'cloud:pan115||关键词': CatalogPage([
          _video('cloud:pan115', 'f2', '命中的片.mkv'),
        ]),
      });
      await tester.pumpWidget(
        scene(
          CloudMultimediaBody(
            driveEntries: () => [_drive('pan115', '115网盘')],
            clientFactory: (id) =>
                CloudDriveContentClient(providerId: id, gateway: gateway),
            coverFetcher: (_) async => '',
            metadataFetcher:
                ({required String title, String? year, String? typeHint}) async =>
                    null,
          ),
        ),
      );
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('pan-multimedia-search')),
        '关键词',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('命中的片.mkv'), findsOneWidget);
      expect(
        gateway.calls.any((c) => c.query == '关键词'),
        isTrue,
      );
    });
  });
}
