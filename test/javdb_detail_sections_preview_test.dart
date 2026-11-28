// JavDB 三件预览（2026-11-28）：三张图存
// ~/workspace/xiuxian_detail_javdb3_20261128/previews/
// ①演员库详情页·评论页签；②演员库详情页·在线播放页签（found
// 线路 chip + 一家 ✗ + 懒查点击查询同框）；③片库详情页带番号
// 作品·JavDB 区在场。数据与 FPRE-249 真实形态同构（评论首条
// 磁力分享、清单名「无敌暴击」），配色走凡人深紫霓虹。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_crosssite_probe.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/film_detail_fill.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'preview_test_support.dart';
import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_detail_javdb3_20261128/previews';
const _magnet = 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary =
      tester.element(find.byType(RepaintBoundary).first).findRenderObject()
          as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 50,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

// ---- 演员库详情页假件（照 actress_work_detail_page_test 的假库） ----

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [
        for (final t in tables) {'name': t},
      ];
    }
    if (sql.contains('PRAGMA table_info(actresses)')) {
      return [
        {'name': 'name'},
        {'name': 'avatar'},
      ];
    }
    if (sql.contains('PRAGMA table_info(videos)')) {
      return [
        {'name': 'content'},
      ];
    }
    if (sql.contains('PRAGMA')) return [];
    if (sql.contains('a.avatar AS avatar')) {
      return [
        {'name': '演员甲', 'avatar': ''},
        {'name': '男演员乙', 'avatar': ''},
      ];
    }
    if (sql.contains('content AS content')) {
      return [
        {'content': '这是 SIGL-020 的简介内容。'},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'play_url': 'https://v.hersav.me/abc/abc.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
        {'name': '男演员乙'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '中文字幕'},
        {'name': '剧情'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (sql.contains('WHERE v.vod_id = ?')) {
        return [
          {
            'vodId': 'sigl-020',
            'title': 'SIGL-020 样本标题',
            'pic': '',
            'play': 'https://v.hersav.me/abc/abc.m3u8',
            'playAlt': '',
            'date': '2024-05-06',
            'typeName': '剧情',
            'actress': '演员甲',
          },
        ];
      }
      return [
        {
          'vodId': 'mida-002',
          'title': 'MIDA-002 相关作品',
          'pic': '',
          'play': '',
          'playAlt': '',
          'date': '2024-01-01',
          'typeName': '剧情',
          'actress': '演员甲',
        },
      ];
    }
    return [];
  }
}

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部')];

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
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/whos.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/whos.m3u8');
}

class _FakeProbeService extends CrossSiteProbeService {
  _FakeProbeService() : super(repository: _FakeRepository());

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    if (provider.id == 'avdb') {
      const drama = Drama(id: 'avdb-1', source: 'avdb', title: 'SIGL-020');
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.found,
        versions: [
          CrossSiteVersion(
            label: 'AVDB版',
            detail: DramaDetail(drama, [
              Episode({'id': 'e1', 'title': '正片', 'flag': '正片'}, 1),
              Episode({'id': 'e2', 'title': '正片', 'flag': '正片'}, 2),
            ]),
            lines: const [
              CrossSiteLine(label: '正片', episodeIndex: 0),
              CrossSiteLine(label: '正片', episodeIndex: 1),
            ],
          ),
        ],
      );
    }
    if (provider.id == 'javmenu') {
      return CrossSiteProbeResult(
        provider: provider,
        siteId: siteId,
        status: CrossSiteProbeStatus.empty,
      );
    }
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: CrossSiteProbeStatus.empty,
    );
  }
}

/// JavDB 假取数（SIGL-020）：搜索/详情补充/磁力/评论/清单全路。
Future<String> _fakeJavdbFetch(String url) async {
  String env(Object? data) => jsonEncode({'success': 1, 'data': data});
  if (url.contains('/reviews')) {
    return env({
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
          'content': '不錯的作品，畫質很好',
          'likes_count': 12,
          'created_at': '2024-05-02T09:00:00.000Z',
        },
      ],
    });
  }
  if (url.contains('lists/related')) {
    return env({
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
  if (url.contains('/magnets')) return env({'magnets': const []});
  if (url.contains('api/v4/movies')) {
    return env({
      'actors': [
        {'name': '演员甲', 'avatar_url': ''},
      ],
      'preview_images': const [],
      'maker_name': '制作商甲',
      'series_name': '系列甲',
      'score': '8.6',
      'score_count': 321,
    });
  }
  // 搜索
  return env({
    'movies': [
      {
        'id': 'm1',
        'number': 'SIGL-020',
        'title': 'SIGL-020 样本标题',
        'thumb_url': '',
        'cover_url': '',
        'duration': 7080,
        'release_date': '2024-05-06',
        'score': '8.6',
      },
    ],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('javdb3-preview-');
    Hive.init(hiveDir.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  Future<void> pumpWorkPage(WidgetTester tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = _FakeDb();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: RepaintBoundary(
          child: ActressWorkDetailPage.local(
            vodId: 'sigl-020',
            fallback: ActressLibraryDbFallback(
              pathResolver: () async => '/fake/女优库.db',
              opener: (path) async => db.query,
            ),
            repository: _FakeRepository(),
            javdbClient: JavdbApiClient(fetch: _fakeJavdbFetch),
            javdbProbeService: _FakeProbeService(),
            playUrlPrep: (url, headers) async => url,
          ),
        ),
      ),
    );
    await tester.pump();
    await _until(
      tester,
      () => find.text('这是 SIGL-020 的简介内容。').evaluate().isNotEmpty,
    );
    // 滚到 JavDB 区（滚动内容最末尾）：拖拽会被海报手势吃掉，
    // 直接拿主滚动位 jumpTo 到底。
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('work-detail-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('javdb-detail-sections'))
          .evaluate()
          .isNotEmpty,
      rounds: 10,
    );
    position.jumpTo(position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 300));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 300));
    await _until(tester, () => find.text('snoopy419').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 200));
  }


  testWidgets('预览1：演员库详情页·评论页签', (tester) async {
    await pumpWorkPage(tester);
    expect(find.text('snoopy419'), findsOneWidget);
    await _savePng(tester, '01_actress_detail_reviews.png');
  });

  testWidgets('预览2：演员库详情页·在线播放页签', (tester) async {
    await pumpWorkPage(tester);
    await tester.tap(find.text('在线播放'));
    await tester.pump();
    await _until(tester, () => find.text('线路1').evaluate().isNotEmpty);
    // 切页签后内容变高，再到底一次让懒查两行也进框。
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('work-detail-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('线路1'), findsOneWidget);
    expect(find.text('✗ 未找到'), findsWidgets);
    expect(find.text('点击查询'), findsWidgets);
    await _savePng(tester, '02_actress_detail_online.png');
  });

  testWidgets('预览3：片库详情页带番号作品·JavDB 区在场', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final episodes = [chapterAt(0), chapterAt(1)];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'NotoSansCJK',
          ),
        ),
        home: RepaintBoundary(
          child: SeriesDetailPage(
            seriesId: '998877',
            historyStore: MemoryReaderStore(),
            title: 'FPRE-249 样本标题',
            cover: '',
            episodes: episodes,
            seriesLoader: (_) async => SeriesDetail(
              seriesId: '998877',
              title: 'FPRE-249 样本标题',
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
            filmFillLoader: (code, meta) async => FilmDetailFill(code: code),
            javdbClient: JavdbApiClient(
              fetch: (url) async {
                if (url.contains('api/v2/search')) {
                  return jsonEncode({
                    'success': 1,
                    'data': {
                      'movies': [
                        {'id': 'wKm94b', 'number': 'FPRE-249', 'title': 't'},
                      ],
                    },
                  });
                }
                if (url.contains('/reviews')) {
                  return jsonEncode({
                    'success': 1,
                    'data': {
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
                      ],
                    },
                  });
                }
                if (url.contains('lists/related')) {
                  return jsonEncode({
                    'success': 1,
                    'data': {
                      'lists': [
                        {
                          'id': '5ED8p8',
                          'name': '无敌暴击',
                          'movies_count': 42,
                          'views_count': 12345,
                          'collections_count': 67,
                          'share_info': 'https://javdb.com/lists/5ED8p8',
                        },
                      ],
                    },
                  });
                }
                return jsonEncode({'success': 1, 'data': null});
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    final position = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('series-detail-content')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    for (var i = 0; i < 6; i++) {
      if (find
          .byKey(const ValueKey('javdb-detail-sections'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 300));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('javdb-detail-sections'))
            .evaluate()
            .isNotEmpty,
        rounds: 4,
      );
    }
    await _until(tester, () => find.text('snoopy419').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('javdb-detail-sections')), findsOneWidget);
    await _savePng(tester, '03_series_detail_javdb.png');
  });
}
