// 网盘刮削页面衔接（xiuxian_wangpan_scrape_20261128）：
// 多媒体页刮后展示（标题/封面替换、原名回落）、长按手动
// 重刮、分类筛选行、刮削设置页打开即预置值（主链勾选、
// 冷门未勾、分类全勾）与恢复默认。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/cloud_drive/cloud_drive_client.dart';
import 'package:fqapp/cloud_drive/cloud_drive_models.dart';
import 'package:fqapp/cloud_drive/cloud_multimedia_body.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/tmdb/tmdb_metadata.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';

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

Drama _video(String source, String fileId, String title) =>
    Drama(id: '$source:$fileId', source: source, title: title);

SourceEntry _drive(String providerId, String name) => SourceEntry(
  id: 'cloud:$providerId',
  name: name,
  kind: SourceKind.cloudDrive,
  extra: const {'contentType': 'video'},
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('多媒体页刮削衔接', () {
    testWidgets('刮后展示：番号条目补封面、影视条目换刮后标题', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', 'ABC-123 某作品.mkv'),
          _video('cloud:pan115', 'f2', '某部电影.2024.1080p.mp4'),
        ]),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudMultimediaBody(
              driveEntries: () => [_drive('pan115', '115网盘')],
              clientFactory: (id) =>
                  CloudDriveContentClient(providerId: id, gateway: gateway),
              coverFetcher: (code) async =>
                  code == 'ABC-123' ? 'https://img.example/ABC-123.jpg' : '',
              metadataFetcher:
                  ({
                    required String title,
                    String? year,
                    String? typeHint,
                  }) async => title.contains('某部电影')
                  ? const TmdbMetadata(
                      tmdbId: 42,
                      mediaType: 'movie',
                      title: '刮后片名',
                      year: '2024',
                    )
                  : null,
            ),
          ),
        ),
      );
      await _settle(tester);
      // 番号条目：封面补上（标题无源，保持原名不编造）。
      final cards = tester
          .widgetList<HomeMediaCard>(find.byType(HomeMediaCard))
          .toList();
      final coded = cards.firstWhere((c) => c.item.id.endsWith('f1'));
      expect(coded.item.cover, 'https://img.example/ABC-123.jpg');
      expect(coded.item.title, 'ABC-123 某作品.mkv');
      // 影视条目：标题换成 TMDB 刮后名。
      expect(find.text('刮后片名'), findsOneWidget);
    });

    testWidgets('长按手动重刮：自动没刮到、重刮补上并出分类', (tester) async {
      var coverReady = false;
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', 'ABC-123 某作品.mkv'),
        ]),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudMultimediaBody(
              driveEntries: () => [_drive('pan115', '115网盘')],
              clientFactory: (id) =>
                  CloudDriveContentClient(providerId: id, gateway: gateway),
              coverFetcher: (code) async =>
                  coverReady ? 'https://img.example/late.jpg' : '',
              metadataFetcher:
                  ({
                    required String title,
                    String? year,
                    String? typeHint,
                  }) async => null,
            ),
          ),
        ),
      );
      await _settle(tester);
      var card = tester.widget<HomeMediaCard>(find.byType(HomeMediaCard).first);
      expect(card.item.cover, isEmpty);
      coverReady = true;
      await tester.longPress(
        find.byKey(const ValueKey('pan-media-wrap-pan115|cloud:pan115:f1')),
      );
      await _settle(tester);
      card = tester.widget<HomeMediaCard>(find.byType(HomeMediaCard).first);
      expect(card.item.cover, 'https://img.example/late.jpg');
      // 分类行出现「有码」筛选（刮后分类归档的虚拟视图）。
      expect(
        find.byKey(const ValueKey('pan-multimedia-category-coded')),
        findsOneWidget,
      );
    });

    testWidgets('未刮到保持原文件名、不回退不编造', (tester) async {
      final gateway = _FakeGateway({
        'cloud:pan115||': CatalogPage([
          _video('cloud:pan115', 'f1', 'ZZZ-999 查无此片.mkv'),
        ]),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudMultimediaBody(
              driveEntries: () => [_drive('pan115', '115网盘')],
              clientFactory: (id) =>
                  CloudDriveContentClient(providerId: id, gateway: gateway),
              coverFetcher: (_) async => '',
              metadataFetcher:
                  ({
                    required String title,
                    String? year,
                    String? typeHint,
                  }) async => null,
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('ZZZ-999 查无此片.mkv'), findsOneWidget);
    });
  });

  group('刮削设置页', () {
    testWidgets('打开即预置值：主链勾选、冷门未勾、分类全勾', (tester) async {
      // 超高视口让整页一次建完，免滚动断言（列表懒构建）。
      tester.view.physicalSize = const Size(390, 9000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: PanScrapeSettingsPage(initial: PanScrapeDefaults.settings),
        ),
      );
      await _settle(tester);
      CheckboxListTile tileOf(String key) =>
          tester.widget<CheckboxListTile>(find.byKey(ValueKey(key)));
      expect(tileOf('pan-setting-auto').value, isTrue);
      expect(tileOf('pan-setting-adult').value, isTrue);
      // 2026-11-28 补移动批：五家引擎建夹/移动点亮后默认开。
      expect(tileOf('pan-setting-real-move').value, isTrue);
      for (final (key, expected) in [
        ('pan-setting-category-movie', true),
        ('pan-setting-category-fc2', true),
        ('pan-setting-category-domestic_adult', true),
        ('pan-setting-site-local', true),
        ('pan-setting-site-javdb', true),
        ('pan-setting-site-xcity', false),
        ('pan-setting-site-tmdb', true),
      ]) {
        expect(tileOf(key).value, expected, reason: key);
      }
    });

    testWidgets('组级勾选：整组关/开一并落盘', (tester) async {
      tester.view.physicalSize = const Size(390, 9000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final store = PanScrapeSettingsStore();
      await tester.pumpWidget(
        MaterialApp(
          home: PanScrapeSettingsPage(
            initial: PanScrapeDefaults.settings,
            store: store,
          ),
        ),
      );
      await _settle(tester);
      // FC2 组默认全勾（组头为勾选态）；点组头整组关。
      final groupTile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('pan-setting-group-fc2')),
      );
      expect(groupTile.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('pan-setting-group-fc2')));
      await _settle(tester);
      var loaded = await store.load();
      expect(
        loaded.enabledSites,
        isNot(containsAll(['fc2ppvdb', 'fc2club', 'fc2hub', 'fc2'])),
      );
      // 组内单站重新勾上后，组头不再是全勾态。
      await tester.tap(find.byKey(const ValueKey('pan-setting-site-fc2')));
      await _settle(tester);
      loaded = await store.load();
      expect(loaded.enabledSites, contains('fc2'));
      expect(loaded.enabledSites, isNot(contains('fc2ppvdb')));
    });

    testWidgets('勾选改动落盘、恢复默认回到预置档', (tester) async {
      tester.view.physicalSize = const Size(390, 9000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final store = PanScrapeSettingsStore();
      await tester.pumpWidget(
        MaterialApp(
          home: PanScrapeSettingsPage(
            initial: PanScrapeDefaults.settings,
            store: store,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('pan-setting-site-xcity')));
      await _settle(tester);
      var loaded = await store.load();
      expect(loaded.enabledSites, contains('xcity'));
      await tester.tap(find.byKey(const ValueKey('pan-setting-reset')));
      await _settle(tester);
      loaded = await store.load();
      expect(loaded.enabledSites, isNot(contains('xcity')));
      expect(loaded.autoScrape, isTrue);
    });
  });
}
