// JavDB 在线播放补接批（2026-11-29）新测：
// ①六家 siteId 直写 seed_；②本地计划行合并/去重（纯函数）；
// ③探活未接入判据（clientFor 判空 → unavailable、不发搜索）；
// ④慢源 150 秒口径（timeoutFor 分流 + 功能验：慢源长超时
// 成、快源普通超时判失败）；⑤PH 搜索 404 判读（只收 PH 源
// 内、只判搜索）；⑥组件层：本地行进页签可播、未接入与未找
// 到文案分开；⑦自动播：只触发一次/压住不播/解除补触发/
// 手点后不抢/首行失败换下一行。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_crosssite_probe.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/javdb_detail_sections.dart';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

// ---- 假件 ----

class _FakeRepository extends AppRepository {
  int searchCalls = 0;

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
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchCalls++;
    return CatalogPage(const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'e1', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/x.m3u8');
}

/// 搜索慢回（120ms）的仓储：验慢源/快源超时分流。
class _SlowRepository extends _FakeRepository {
  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return CatalogPage([
      Drama(id: 'hit-1', source: sources.first, title: 'FPRE-249 样本'),
    ]);
  }
}

class _FakeJavdbClient extends JavdbApiClient {
  _FakeJavdbClient() : super(fetch: _fetch);

  static Future<String> _fetch(String url) async {
    String env(Object? data) => jsonEncode({'success': 1, 'data': data});
    if (url.contains('/reviews')) return env({'reviews': const []});
    if (url.contains('lists')) return env({'lists': const []});
    if (url.contains('/magnets')) return env({'magnets': const []});
    return env({
      'movies': [
        {
          'id': 'm1',
          'number': 'FPRE-249',
          'title': 'FPRE-249 样本标题',
          'thumb_url': '',
          'cover_url': '',
        },
      ],
    });
  }
}

CrossSiteVersion _version(String label, String source) {
  final drama = Drama(id: '$label-1', source: source, title: 'FPRE-249');
  return CrossSiteVersion(
    label: label,
    detail: DramaDetail(drama, [
      Episode({'id': 'e1', 'title': '正片', 'flag': '正片'}, 1),
    ]),
    lines: const [CrossSiteLine(label: '正片', episodeIndex: 0)],
  );
}

/// 按脚本回结果的探活服务：结果按 provider id 查（本地计划
/// 行的 provider id 即站 id，与 planCrossSiteRows 的合成口
/// 径一致）；未配置的一律 empty。
class _ScriptedProbeService extends CrossSiteProbeService {
  _ScriptedProbeService({this.statuses = const {}})
    : super(repository: _FakeRepository());

  final Map<String, CrossSiteProbeStatus> statuses;

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    final status = statuses[provider.id] ?? CrossSiteProbeStatus.empty;
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: status,
      versions: [
        if (status == CrossSiteProbeStatus.found)
          _version('${provider.name}版', siteId),
      ],
    );
  }
}

/// 本地计划行（照 planCrossSiteRows 的合成口径：一站一行、
/// provider id = 站 id）。
CrossSiteRowPlan _localPlan(String siteId, String name, {bool lazy = false}) {
  return CrossSiteRowPlan(
    provider: CrossSiteProvider(
      id: siteId,
      name: name,
      siteIds: [siteId],
      lazy: lazy,
    ),
    siteId: siteId,
  );
}

CrossSiteProvider _providerById(String id) =>
    javdbOnlineProviders.firstWhere((p) => p.id == id);

void main() {
  test('①六家在线源 siteId 直写 seed_、序不变（AVDB 第一）', () {
    final providers = javdbEffectiveProviders();
    expect(providers.map((p) => p.id).toList(), [
      'avdb',
      'javmenu',
      'av01',
      'memojav',
      'missav',
      'jable',
    ]);
    final rows = javdbMergedOnlineRows(providers, const []);
    expect(rows.map((r) => r.siteId).toList(), [
      'seed_avdb',
      'seed_javmenu',
      'jar:zakatv:zakav01',
      'seed_memojav',
      'seed_missav',
      'jar:zakatv:ZakaJable',
    ]);
    expect(javdbSeedSiteIds['avdb'], 'seed_avdb');
    expect(javdbSeedSiteIds['javmenu'], 'seed_javmenu');
    expect(javdbSeedSiteIds['memojav'], 'seed_memojav');
    expect(javdbSeedSiteIds['missav'], 'seed_missav');
  });

  test('②本地行合并：六家在前、同站去重（含与六家同站）、无站号保留', () {
    final rows = javdbMergedOnlineRows(javdbEffectiveProviders(), [
      _localPlan('seed_local_a', '甲站'),
      _localPlan('seed_avdb', '撞AVDB'),
      const CrossSiteRowPlan(
        provider: CrossSiteProvider(
          id: 'unconnected-x',
          name: '无站号',
          siteIds: [],
          lazy: false,
        ),
      ),
      _localPlan('seed_local_a', '甲站二'),
    ]);
    expect(rows.length, 8);
    expect(rows.first.provider.name, 'AVDB');
    expect(rows[6].provider.name, '甲站');
    expect(rows[7].provider.name, '无站号');
    expect(rows[7].siteId, isNull);
    expect(rows.where((r) => r.provider.name == '撞AVDB'), isEmpty);
    expect(rows.where((r) => r.provider.name == '甲站二'), isEmpty);
  });

  test('③未接入判据：clientAvailable 为假直接 unavailable、不发搜索', () async {
    final repo = _FakeRepository();
    final service = CrossSiteProbeService(
      repository: repo,
      clientAvailable: (_) async => false,
    );
    final result = await service.probeProvider(
      _providerById('avdb'),
      'seed_avdb',
      'FPRE-249',
    );
    expect(result.status, CrossSiteProbeStatus.unavailable);
    expect(repo.searchCalls, 0);
  });

  test('④慢源超时分流：慢源用 slowTimeout 探成、快源普通超时判失败', () async {
    final service = CrossSiteProbeService(
      repository: _SlowRepository(),
      perSiteTimeout: const Duration(milliseconds: 40),
      slowTimeout: const Duration(milliseconds: 400),
      clientAvailable: (_) async => true,
    );
    expect(
      service.timeoutFor('seed_javmenu'),
      const Duration(milliseconds: 400),
    );
    expect(service.timeoutFor('memojav'), const Duration(milliseconds: 400));
    expect(service.timeoutFor('seed_avdb'), const Duration(milliseconds: 40));
    final slow = await service.probeProvider(
      _providerById('javmenu'),
      'seed_javmenu',
      'FPRE-249',
    );
    expect(slow.status, CrossSiteProbeStatus.found);
    final fast = await service.probeProvider(
      _providerById('avdb'),
      'seed_avdb',
      'FPRE-249',
    );
    expect(fast.status, CrossSiteProbeStatus.failed);
  });

  test('⑤PH 搜索 404 判读：查无此物判未找到、正常页照出、浏览不判', () async {
    const notFoundHtml = '<html><head><title>没发现页面</title></head>'
        '<body><li class="pcVideoListItem" data-video-vkey="rec001">'
        '<a href="/view_video.php?viewkey=rec001" title="推荐位视频">'
        '<img data-src="https://example.test/r.jpg"/></a>'
        '<span class="duration">09:59</span></li></body></html>';
    const okHtml = '<html><head><title>搜索结果</title></head>'
        '<body><li class="pcVideoListItem" data-video-vkey="hit001">'
        '<a href="/view_video.php?viewkey=hit001" title="FPRE-249 样本">'
        '<img data-src="https://example.test/h.jpg"/></a>'
        '<span class="duration">10:20</span></li></body></html>';
    expect(phIsNotFoundPage(notFoundHtml), isTrue);
    expect(phIsNotFoundPage(okHtml), isFalse);
    const source = PhActressSource();
    Future<String> fetch404(String url, Map<String, String> headers) async =>
        notFoundHtml;
    Future<String> fetchOk(String url, Map<String, String> headers) async =>
        okHtml;
    final searched404 = await source.fetchCards(
      primaryId: 'hot',
      secondaryId: 'all',
      query: 'FPRE-249',
      page: 1,
      fetch: fetch404,
    );
    expect(searched404, isEmpty);
    final searchedOk = await source.fetchCards(
      primaryId: 'hot',
      secondaryId: 'all',
      query: 'FPRE-249',
      page: 1,
      fetch: fetchOk,
    );
    expect(searchedOk.length, 1);
    expect(searchedOk.single.pageUrl, contains('hit001'));
    // 浏览（query 空）不判 404：模板里的卡照旧解析，判读只收搜索。
    final browsed = await source.fetchCards(
      primaryId: 'hot',
      secondaryId: 'all',
      query: '',
      page: 1,
      fetch: fetch404,
    );
    expect(browsed.length, 1);
  });

  // ---- 组件层 ----

  Widget sectionsTree({
    CrossSiteProbeService? probeService,
    List<CrossSiteRowPlan> localPlans = const [],
    Future<bool> Function(CrossSiteVersion, CrossSiteLine)? onAutoPlayLine,
    Future<void> Function(CrossSiteVersion, CrossSiteLine)? onPlayLine,
    void Function(CrossSiteProbeResult)? onProbeFound,
    bool autoPlaySuppressed = false,
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: JavdbDetailSections(
          code: 'FPRE-249',
          client: _FakeJavdbClient(),
          repository: _FakeRepository(),
          probeService: probeService,
          localPlans: localPlans,
          onAutoPlayLine: onAutoPlayLine,
          onProbeFound: onProbeFound,
          autoPlaySuppressed: autoPlaySuppressed,
          onPlayLine: onPlayLine ?? (_, _) async {},
        ),
      ),
    ),
  );

  Future<void> openOnlineTab(WidgetTester tester) async {
    await _until(tester, () => find.text('在线播放').evaluate().isNotEmpty);
    await tester.tap(find.text('在线播放'));
    await tester.pump();
  }

  const chipKey = ValueKey('javdb-line-chip-线路1-0');

  testWidgets('⑥本地行进页签：found 出 chip 可播、接入回调到、懒查行不探', (
    tester,
  ) async {
    final played = <String>[];
    final adopted = <String>[];
    await tester.pumpWidget(
      sectionsTree(
        probeService: _ScriptedProbeService(
          statuses: const {'seed_local_a': CrossSiteProbeStatus.found},
        ),
        localPlans: [
          _localPlan('seed_local_a', '甲站'),
          _localPlan('seed_avdb', '撞AVDB'),
          _localPlan('seed_local_lazy', '懒站', lazy: true),
        ],
        onPlayLine: (version, line) async => played.add(version.label),
        onProbeFound: (result) => adopted.add(result.siteId),
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => find.text('甲站版').evaluate().isNotEmpty);
    expect(find.text('甲站'), findsOneWidget);
    expect(find.text('撞AVDB'), findsNothing);
    expect(
      find.byKey(const ValueKey('javdb-probe-seed_local_lazy')),
      findsOneWidget,
    );
    expect(adopted, contains('seed_local_a'));
    await tester.tap(find.byKey(chipKey));
    await tester.pump();
    expect(played, ['甲站版']);
  });

  testWidgets('⑥未接入与未找到文案分开', (tester) async {
    await tester.pumpWidget(
      sectionsTree(
        probeService: _ScriptedProbeService(
          statuses: const {
            'memojav': CrossSiteProbeStatus.unavailable,
            'javmenu': CrossSiteProbeStatus.empty,
          },
        ),
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => find.text('未接入').evaluate().isNotEmpty);
    expect(find.text('未接入'), findsOneWidget);
    expect(find.text('✗ 未找到'), findsWidgets);
  });

  testWidgets('⑦自动播只触发一次：首个 found 行起播、后来者不抢', (
    tester,
  ) async {
    final autoCalls = <String>[];
    await tester.pumpWidget(
      sectionsTree(
        probeService: _ScriptedProbeService(
          statuses: const {
            'avdb': CrossSiteProbeStatus.found,
            'javmenu': CrossSiteProbeStatus.found,
          },
        ),
        onAutoPlayLine: (version, line) async {
          autoCalls.add(version.label);
          return true;
        },
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => autoCalls.isNotEmpty);
    // 再等其余探活都落定，确认没有第二次触发。
    await _until(tester, () => find.text('JavMenu版').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(autoCalls, ['AVDB版']);
  });

  testWidgets('⑦自动播压住不播、压住解除后补触发一次', (tester) async {
    final autoCalls = <String>[];
    Future<bool> onAuto(CrossSiteVersion version, CrossSiteLine line) async {
      autoCalls.add(version.label);
      return true;
    }

    final service = _ScriptedProbeService(
      statuses: const {'avdb': CrossSiteProbeStatus.found},
    );
    await tester.pumpWidget(
      sectionsTree(
        probeService: service,
        onAutoPlayLine: onAuto,
        autoPlaySuppressed: true,
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => find.text('AVDB版').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(autoCalls, isEmpty);
    await tester.pumpWidget(
      sectionsTree(
        probeService: service,
        onAutoPlayLine: onAuto,
        autoPlaySuppressed: false,
      ),
    );
    await _until(tester, () => autoCalls.isNotEmpty);
    expect(autoCalls, ['AVDB版']);
  });

  testWidgets('⑦用户先手点后自动播不再抢', (tester) async {
    final autoCalls = <String>[];
    final played = <String>[];
    Future<bool> onAuto(CrossSiteVersion version, CrossSiteLine line) async {
      autoCalls.add(version.label);
      return true;
    }

    Future<void> onPlay(CrossSiteVersion version, CrossSiteLine line) async =>
        played.add(version.label);
    final service = _ScriptedProbeService(
      statuses: const {'avdb': CrossSiteProbeStatus.found},
    );
    await tester.pumpWidget(
      sectionsTree(
        probeService: service,
        onAutoPlayLine: onAuto,
        onPlayLine: onPlay,
        autoPlaySuppressed: true,
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => find.byKey(chipKey).evaluate().isNotEmpty);
    await tester.tap(find.byKey(chipKey));
    await tester.pump();
    expect(played, ['AVDB版']);
    await tester.pumpWidget(
      sectionsTree(
        probeService: service,
        onAutoPlayLine: onAuto,
        onPlayLine: onPlay,
        autoPlaySuppressed: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(autoCalls, isEmpty);
  });

  testWidgets('⑦自动播首行失败换下一行、成功后停', (tester) async {
    final autoCalls = <String>[];
    await tester.pumpWidget(
      sectionsTree(
        probeService: _ScriptedProbeService(
          statuses: const {
            'avdb': CrossSiteProbeStatus.found,
            'javmenu': CrossSiteProbeStatus.found,
            'memojav': CrossSiteProbeStatus.found,
          },
        ),
        onAutoPlayLine: (version, line) async {
          autoCalls.add(version.label);
          return version.label != 'AVDB版';
        },
      ),
    );
    await openOnlineTab(tester);
    await _until(tester, () => autoCalls.length >= 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(autoCalls, ['AVDB版', 'JavMenu版']);
  });
}
