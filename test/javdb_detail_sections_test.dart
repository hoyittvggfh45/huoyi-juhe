// JavDB 三件共用组件（评论/相关清单/在线播放）测试 + 片库
// 详情页挂载验收。全部注入假件（JavdbFetch 假件 + 信封 JSON、
// 假探活服务、假仓储），不真连网。数据形态照 FPRE-249 实拉：
// 评论首条为磁力分享、清单名「无敌暴击」。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_crosssite_probe.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/javdb_detail_sections.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/film_detail_fill.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

const _magnet = 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';

String _envelope(Object? data) => jsonEncode({'success': 1, 'data': data});

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const [], page: page);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, const []);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/x.m3u8');
}

DramaDetail _foundDetail() {
  const drama = Drama(id: 'avdb-1', source: 'avdb', title: 'FPRE-249 样本');
  return DramaDetail(drama, [
    Episode({'id': 'e1', 'title': '正片', 'flag': '正片'}, 1),
    Episode({'id': 'e2', 'title': '正片', 'flag': '正片'}, 2),
  ]);
}

class _FakeProbeService extends CrossSiteProbeService {
  _FakeProbeService() : super(repository: _FakeRepository());

  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add('${provider.id}:$siteId');
    switch (provider.id) {
      case 'avdb':
        return CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.found,
          versions: [
            CrossSiteVersion(
              label: 'AVDB版',
              detail: _foundDetail(),
              lines: const [
                CrossSiteLine(label: '正片', episodeIndex: 0),
                CrossSiteLine(label: '正片', episodeIndex: 1),
              ],
            ),
          ],
        );
      case 'javmenu':
        return CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.empty,
        );
      case 'av01':
        return CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.failed,
        );
      default:
        return CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.empty,
        );
    }
  }
}

/// 假 JavDB 取数：按 URL 分发搜索/评论/清单信封。
JavdbApiClient _fakeClient({bool match = true, bool emptyData = false}) {
  return JavdbApiClient(
    fetch: (url) async {
      if (url.contains('api/v2/search')) {
        return _envelope({
          'movies': [
            {
              'id': 'wKm94b',
              'number': match ? 'FPRE-249' : 'OTHER-001',
              'title': 'FPRE-249 样本标题',
            },
          ],
        });
      }
      if (url.contains('/reviews')) {
        if (emptyData) return _envelope({'reviews': const []});
        return _envelope({
          'reviews': [
            {
              'id': 101,
              'username': 'snoopy419',
              'status_title': '看過',
              'score': 5,
              'content': _magnet,
              'likes_count': 99,
              'created_at': '2024-05-01T08:30:00.000Z',
            },
            {
              'id': 102,
              'username': 'second_user',
              'status_title': '想看',
              'score': 0,
              'content': '不錯的作品',
              'likes_count': 12,
              'created_at': '2024-05-02T09:00:00.000Z',
            },
          ],
        });
      }
      if (url.contains('lists/related')) {
        if (emptyData) return _envelope({'lists': const []});
        return _envelope({
          'lists': [
            {
              'id': '5ED8p8',
              'name': '无敌暴击',
              'description': '精选清单说明',
              'movies_count': 42,
              'views_count': 12345,
              'collections_count': 67,
              'share_info': 'https://javdb.com/lists/5ED8p8',
              'created_at': '2023-01-15T10:00:00.000Z',
            },
          ],
        });
      }
      return _envelope(null);
    },
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 40,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') return null;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpSections(
    WidgetTester tester, {
    JavdbApiClient? client,
    _FakeProbeService? probe,
    void Function(CrossSiteVersion, CrossSiteLine)? onPlay,
  }) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: JavdbDetailSections(
              code: 'FPRE-249',
              client: client ?? _fakeClient(),
              repository: _FakeRepository(),
              probeService: probe ?? _FakeProbeService(),
              onPlayLine: (version, line) async => onPlay?.call(version, line),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('①解析命中：三页签出现，评论列出，点磁力出已复制提示', (tester) async {
    await pumpSections(tester);
    await _until(tester, () => find.text('评论').evaluate().isNotEmpty);
    expect(find.text('评论'), findsOneWidget);
    expect(find.text('相关清单'), findsOneWidget);
    expect(find.text('在线播放'), findsOneWidget);
    await _until(tester, () => find.text('snoopy419').evaluate().isNotEmpty);
    expect(find.textContaining('★ 5.0'), findsOneWidget);
    expect(find.textContaining('♥ 99'), findsOneWidget);
    expect(find.textContaining('2024-05-01'), findsOneWidget);
    // 磁力子串可点：点按复制并出 SnackBar。
    await tester.tap(
      find.byKey(const ValueKey('javdb-review-magnet-$_magnet')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('磁力链接已复制'), findsOneWidget);
  });

  testWidgets('②清单页签：列出行，点行出弹层（含分享链接与复制按钮）', (tester) async {
    await pumpSections(tester);
    await _until(tester, () => find.text('相关清单').evaluate().isNotEmpty);
    await tester.tap(find.text('相关清单'));
    await tester.pump();
    await _until(tester, () => find.text('无敌暴击').evaluate().isNotEmpty);
    expect(find.text('无敌暴击'), findsOneWidget);
    expect(find.text('共 42 部 · 浏览 12345 · 收藏 67'), findsOneWidget);
    await tester.tap(find.text('无敌暴击'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('精选清单说明'), findsOneWidget);
    expect(find.text('https://javdb.com/lists/5ED8p8'), findsOneWidget);
    expect(find.text('复制分享链接'), findsOneWidget);
  });

  testWidgets('③在线播放：found 出线路 chip 且回调正确，empty 出 ✗，懒查先显示点击查询', (tester) async {
    final probe = _FakeProbeService();
    CrossSiteVersion? playedVersion;
    CrossSiteLine? playedLine;
    await pumpSections(
      tester,
      probe: probe,
      onPlay: (version, line) {
        playedVersion = version;
        playedLine = line;
      },
    );
    await _until(tester, () => find.text('在线播放').evaluate().isNotEmpty);
    await tester.tap(find.text('在线播放'));
    await tester.pump();
    await _until(tester, () => find.text('线路1').evaluate().isNotEmpty);
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('线路2'), findsOneWidget);
    expect(find.text('✗ 未找到'), findsWidgets);
    expect(find.text('✗ 查询失败'), findsOneWidget);
    // 懒查两家未点前显示「点击查询」、且没有被自动探活。
    expect(find.text('点击查询'), findsNWidgets(2));
    expect(probe.probed.any((row) => row.startsWith('missav:')), isFalse);
    expect(probe.probed.any((row) => row.startsWith('jable:')), isFalse);
    // MissAV 探活必须走修仙树真注册的 seed_missav：点它后核对 siteId。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('javdb-provider-missav')),
        matching: find.text('点击查询'),
      ),
    );
    await tester.pump();
    await _until(
      tester,
      () => probe.probed.any((row) => row == 'missav:seed_missav'),
    );
    expect(probe.probed, contains('missav:seed_missav'));
    // 点 chip 回调带正确 version/line。
    await tester.tap(find.text('线路1'));
    await tester.pump();
    expect(playedVersion?.label, 'AVDB版');
    expect(playedLine?.episodeIndex, 0);
  });

  testWidgets('④无精确命中：组件在场但整块不渲染', (tester) async {
    await pumpSections(tester, client: _fakeClient(match: false));
    await _until(tester, () => true, rounds: 5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(JavdbDetailSections), findsOneWidget);
    expect(find.text('评论'), findsNothing);
    expect(find.text('相关清单'), findsNothing);
    expect(find.text('在线播放'), findsNothing);
  });

  testWidgets('⑤评论/清单为空：对应空态文案出现、不报错', (tester) async {
    await pumpSections(tester, client: _fakeClient(emptyData: true));
    await _until(tester, () => find.text('暂无评论').evaluate().isNotEmpty);
    expect(find.text('暂无评论'), findsOneWidget);
    await tester.tap(find.text('相关清单'));
    await tester.pump();
    await _until(tester, () => find.text('暂无相关清单').evaluate().isNotEmpty);
    expect(find.text('暂无相关清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('片库详情页挂载', () {
    late Directory directory;
    setUpAll(() async {
      directory = await Directory.systemTemp.createTemp('javdb3-series-');
      Hive.init(directory.path);
      await ShelfStore.instance.init();
    });
    tearDownAll(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    setUp(() async => ShelfStore.instance.clear());

    Future<void> pumpFilm(WidgetTester tester, {required bool withCode}) async {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final episodes = [chapterAt(0), chapterAt(1)];
      await tester.pumpWidget(
        hostPage(
          SeriesDetailPage(
            // id 不能长得像番号（film-1 会被既有口径认成 FILM-1，
            // 盖过标题里的真番号），用纯数字串 id。
            seriesId: '998877',
            historyStore: MemoryReaderStore(),
            title: withCode ? 'FPRE-249 样本标题' : '抽象三国第一季',
            cover: '',
            episodes: episodes,
            // 详情标题必须与页面标题同题：_titleText 以详情为准，
            // 通用夹具的「抽象三国第一季」会把番号冲掉。
            seriesLoader: (_) async => SeriesDetail(
              seriesId: '998877',
              title: withCode ? 'FPRE-249 样本标题' : '抽象三国第一季',
              episodeCount: episodes.length,
              episodeLabel: '共${episodes.length}集',
              status: 1,
            ),
            siteDetailLoader: (_) async => const FilmSiteDetail(
              synopsis: '这是一段影视简介。',
              extra: {'play_from': 'MissAV'},
              stills: [],
            ),
            commentLoader: (_) async => const PlayletCommentPage(),
            contentLoader: (_, _) async => const {},
            filmFillLoader: (code, meta) async =>
                FilmDetailFill(code: withCode ? code : ''),
            javdbClient: _fakeClient(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      // 番号补全链（_loadCodeMeta → _loadFilmFill）落定：照
      // series_detail_film_fill_test 的 pumpUntil 口径用假时钟
      // 步进轮询（番号索引走 rootBundle，在假时钟区里推进）。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
    }

    testWidgets('带番号作品：JavDB 区出现（页签可见）', (tester) async {
      await pumpFilm(tester, withCode: true);
      // JavDB 区在滚动内容底部，懒构建要先滚到附近才建。
      for (var i = 0; i < 8; i++) {
        if (find
            .byKey(const ValueKey('javdb-detail-sections'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
        await tester.pump(const Duration(milliseconds: 300));
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('javdb-detail-sections'))
              .evaluate()
              .isNotEmpty,
          rounds: 6,
        );
      }
      expect(
        find.byKey(const ValueKey('javdb-detail-sections')),
        findsOneWidget,
      );
      expect(find.text('在线播放'), findsOneWidget);
    });

    testWidgets('无番号作品：JavDB 区不出现', (tester) async {
      await pumpFilm(tester, withCode: false);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('javdb-detail-sections')), findsNothing);
      expect(find.byType(JavdbDetailSections), findsNothing);
    });

    test('挂载判据纯函数：番号非空才挂', () {
      expect(javdbSectionsVisibleFor('FPRE-249'), isTrue);
      expect(javdbSectionsVisibleFor(''), isFalse);
    });
  });
}
