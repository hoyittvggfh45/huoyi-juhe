// 网盘刮削编排（xiuxian_wangpan_scrape_20261128）：出厂默
// 认档逐项断言、MDCx 爬虫底账对账、站点链回退与刮成即停、
// 字段级合并优先级、剧照整组回退、正/负缓存与增量、单站
// 限速、成人总开关、分类判定与真实移动防误移闸门。
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/cloud_drive/pan_scrape_adapter.dart';
import 'package:fqapp/cloud_drive/pan_scrape_archive.dart';
import 'package:fqapp/cloud_drive/pan_scrape_cache.dart';
import 'package:fqapp/cloud_drive/pan_scrape_identify.dart';
import 'package:fqapp/cloud_drive/pan_scrape_models.dart';
import 'package:fqapp/cloud_drive/pan_scrape_service.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings.dart';

class _FakeAdapter extends PanScrapeAdapter {
  _FakeAdapter(this._id, this._handler);
  final String _id;
  final Future<PanScrapedMeta?> Function(PanScrapeContext ctx) _handler;
  int calls = 0;

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs[_id]!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) {
    calls++;
    return _handler(ctx);
  }
}

PanScrapeService _service({
  required Map<String, PanScrapeAdapter> adapters,
  PanScrapeSettings? settings,
  PanScrapeCache? cache,
  List<Duration>? slept,
  int Function()? nowMs,
}) {
  return PanScrapeService(
    settings: settings ?? PanScrapeDefaults.settings,
    adapters: adapters,
    cache: cache ?? PanScrapeMemoryCache(nowMs: nowMs),
    sleeper: (d) async => slept?.add(d),
    nowMs: nowMs,
  );
}

PanScrapedMeta _meta({
  String title = '',
  String cover = '',
  String poster = '',
  List<String> stills = const [],
  String rating = '',
  String overview = '',
  String site = '',
}) => PanScrapedMeta(
  title: title,
  cover: cover,
  poster: poster.isEmpty ? cover : poster,
  stills: stills,
  rating: rating,
  overview: overview,
  sourceSite: site,
);

void main() {
  group('出厂默认档（用户令：设置由我们预置，逐项钉死）', () {
    final s = PanScrapeDefaults.settings;

    test('总开关：自动刮开、成人链开、分类视图开、真实移动开', () {
      expect(s.autoScrape, isTrue);
      expect(s.adultChainEnabled, isTrue);
      expect(s.archiveViewEnabled, isTrue);
      // 2026-11-28 补移动批：五家引擎建夹/移动点亮后，
      // 真实移动按「能力具备即按分类勾选生效」默认开。
      expect(s.realMoveEnabled, isTrue);
    });

    test('番号主链顺序：本地→JavDB→DMM→JavBus→JavLibrary', () {
      expect(s.chains['coded']!.take(5), [
        'local',
        'javdb',
        'dmm',
        'javbus',
        'javlibrary',
      ]);
    });

    test('无码/FC2 专链与影视链、国产链', () {
      expect(s.chains['uncensored']!.take(3), ['local', 'javdb', 'avsox']);
      expect(s.chains['fc2'], [
        'local',
        'javdb',
        'fc2ppvdb',
        'fc2club',
        'fc2hub',
        'fc2',
      ]);
      expect(s.chains['film'], ['tmdb', 'douban', 'bangumi']);
      expect(s.chains['domestic']!.first, 'javdb');
    });

    test('默认勾选：主链全勾、冷门站不勾', () {
      for (final id in [
        'local',
        'javdb',
        'dmm',
        'javbus',
        'javlibrary',
        'r18dev',
        'thejavdb',
        'avsox',
        'fc2ppvdb',
        'tmdb',
        'douban',
        'bangumi',
        'cnmdb',
        'madouqu',
        'mdtv',
      ]) {
        expect(s.enabledSites, contains(id), reason: id);
      }
      for (final id in ['xcity', 'official', 'dahlia', 'love6', 'hscangku']) {
        expect(s.enabledSites, isNot(contains(id)), reason: id);
      }
      // chainFor 必须过滤未勾选站。
      expect(s.chainFor('coded'), isNot(contains('xcity')));
      expect(s.chainFor('coded').take(5), [
        'local',
        'javdb',
        'dmm',
        'javbus',
        'javlibrary',
      ]);
    });

    test('字段优先级：封面 DMM、标题 JavDB、简介 DMM、评分 JavDB', () {
      expect(s.fieldPriority['cover']!.first, 'dmm');
      expect(s.fieldPriority['poster']!.first, 'r18dev');
      expect(s.fieldPriority['title']!.first, 'javdb');
      expect(s.fieldPriority['overview']!.first, 'dmm');
      expect(s.fieldPriority['rating']!.first, 'javdb');
      expect(s.fieldPriority['actressAvatar']!.first, 'gfriends');
      expect(s.fieldPriority['stills'], ['dmm', 'javdb', 'local']);
    });

    test('限速与重试：JavDB 2 秒防封、r18dev 重试 2', () {
      expect(s.rateFor('javdb').minInterval, const Duration(seconds: 2));
      expect(s.rateFor('javdb').maxRetries, 1);
      expect(s.rateFor('r18dev').maxRetries, 2);
      expect(s.rateFor('local').minInterval, Duration.zero);
    });

    test('门槛/缓存/语言：封面+标题、30 天/6 小时、中文', () {
      expect(s.successNeedsCoverAndTitle, isTrue);
      expect(s.preferHdCover, isTrue);
      expect(s.preferVerticalPoster, isTrue);
      expect(s.cacheTtl, const Duration(days: 30));
      expect(s.negativeCacheTtl, const Duration(hours: 6));
      expect(s.tmdbLanguage, 'zh-CN');
      expect(s.javdbCookie, '');
      expect(s.javdbImageCdnRewrite, isFalse);
    });

    test('分类定稿 12 类默认全勾', () {
      expect(panScrapeCategories.length, 12);
      expect(s.enabledCategories.length, 12);
      expect(
        s.enabledCategories,
        containsAll(PanScrapeDefaults.defaultEnabledCategories),
      );
    });
  });

  group('MDCx 爬虫底账对账', () {
    test('注册爬虫 38 个逐项都在凡人规格表且标 fromMdcx', () {
      expect(panMdcxCrawlerIds.length, 38);
      for (final id in panMdcxCrawlerIds) {
        final spec = panScrapeSiteSpecs[id];
        expect(spec, isNotNull, reason: '缺站 $id');
        expect(spec!.fromMdcx, isTrue, reason: id);
      }
    });

    test('MDCx 系站在默认链里有位次（链内对账）', () {
      final s = PanScrapeDefaults.settings;
      final allChained = s.chains.values.expand((c) => c).toSet();
      for (final id in panMdcxCrawlerIds) {
        expect(allChained, contains(id), reason: '链里缺 $id');
      }
    });
  });

  group('站点链回退与字段合并', () {
    test('逐站回退：本地空→JavDB 抛错重试→DMM 给图，合并按字段优先级', () async {
      var javdbAttempts = 0;
      final adapters = <String, PanScrapeAdapter>{
        'local': _FakeAdapter('local', (_) async => null),
        'javdb': _FakeAdapter('javdb', (_) async {
          javdbAttempts++;
          if (javdbAttempts == 1) throw StateError('网络抖动');
          // 只给标题+评分、不给封面：未达门槛，链继续到 DMM。
          return _meta(title: 'JavDB标题', rating: '4.5', site: 'javdb');
        }),
        'dmm': _FakeAdapter(
          'dmm',
          (_) async => _meta(cover: 'https://dmm/hd.jpg', site: 'dmm'),
        ),
        'javbus': _FakeAdapter(
          'javbus',
          (_) async => _meta(title: '不应到达', cover: 'x', site: 'javbus'),
        ),
      };
      final service = _service(adapters: adapters);
      final outcome = await service.scrape(
        panIdentify('SSIS-001 某片.mkv'),
        itemKey: 'pan115|f1',
      );
      expect(javdbAttempts, 2); // 抛错重试一次后成功
      expect(outcome.complete, isTrue);
      expect(outcome.meta!.title, 'JavDB标题'); // 标题 JavDB 优先
      expect(outcome.meta!.cover, 'https://dmm/hd.jpg'); // 封面 DMM 优先
      expect(outcome.meta!.rating, '4.5');
      expect(outcome.meta!.fieldSources['cover'], 'dmm');
      expect(outcome.meta!.fieldSources['title'], 'javdb');
      // 刮成即停：javbus 没被打。
      expect((adapters['javbus']! as _FakeAdapter).calls, 0);
      expect(outcome.categoryId, 'coded');
    });

    test('剧照整组回退：一组只取一个站、不混搭', () async {
      final adapters = <String, PanScrapeAdapter>{
        'local': _FakeAdapter('local', (_) async => null),
        // JavDB 只给剧照（未刮成，链继续）；DMM 给全套+剧照。
        'javdb': _FakeAdapter(
          'javdb',
          (_) async => _meta(stills: ['j1', 'j2'], site: 'javdb'),
        ),
        'dmm': _FakeAdapter(
          'dmm',
          (_) async =>
              _meta(title: '标题', cover: 'c', stills: ['d1'], site: 'dmm'),
        ),
      };
      final service = _service(adapters: adapters);
      final outcome = await service.scrape(
        panIdentify('ABP-123 片.mkv'),
        itemKey: 'pan115|f2',
      );
      expect(outcome.meta!.stills, ['d1']);
      expect(outcome.meta!.fieldSources['stills'], 'dmm');
    });

    test('全链落空：meta 为 null、分类未识别、不编造', () async {
      final adapters = <String, PanScrapeAdapter>{
        'local': _FakeAdapter('local', (_) async => null),
        'javdb': _FakeAdapter('javdb', (_) async => null),
        'dmm': _FakeAdapter('dmm', (_) async => null),
        'javbus': _FakeAdapter('javbus', (_) async => null),
        'javlibrary': _FakeAdapter('javlibrary', (_) async => null),
      };
      final service = _service(adapters: adapters);
      final outcome = await service.scrape(
        panIdentify('ZZZ-999 某片.mkv'),
        itemKey: 'pan115|f3',
      );
      expect(outcome.meta, isNull);
      expect(outcome.complete, isFalse);
      expect(outcome.categoryId, 'unidentified');
    });

    test('未勾选的站被跳过（勾选式启停生效）', () async {
      final settings = PanScrapeDefaults.settings.copyWith(
        enabledSites: {...PanScrapeDefaults.defaultEnabledSites}
          ..remove('javdb'),
      );
      final javdb = _FakeAdapter(
        'javdb',
        (_) async => _meta(title: 't', cover: 'c'),
      );
      final adapters = <String, PanScrapeAdapter>{
        'local': _FakeAdapter('local', (_) async => null),
        'javdb': javdb,
        'dmm': _FakeAdapter(
          'dmm',
          (_) async => _meta(title: 't', cover: 'c', site: 'dmm'),
        ),
      };
      final service = _service(adapters: adapters, settings: settings);
      await service.scrape(panIdentify('SSIS-001 x.mkv'), itemKey: 'k');
      expect(javdb.calls, 0);
    });
  });

  group('缓存与增量', () {
    test('正缓存命中：第二次同条目不打站', () async {
      final local = _FakeAdapter(
        'local',
        (_) async => _meta(title: '本地标题', cover: 'c', site: 'local'),
      );
      final service = _service(adapters: {'local': local});
      final id = panIdentify('SSIS-001 x.mkv');
      final first = await service.scrape(id, itemKey: 'pan115|f1');
      final second = await service.scrape(id, itemKey: 'pan115|f1');
      expect(first.fromCache, isFalse);
      expect(second.fromCache, isTrue);
      expect(local.calls, 1);
    });

    test('按番号索引命中：换文件夹同番号不重刮', () async {
      final local = _FakeAdapter(
        'local',
        (_) async => _meta(title: '本地标题', cover: 'c', site: 'local'),
      );
      final service = _service(adapters: {'local': local});
      final id = panIdentify('SSIS-001 x.mkv');
      await service.scrape(id, itemKey: 'pan115|folderA');
      final second = await service.scrape(id, itemKey: 'quark|folderB');
      expect(second.fromCache, isTrue);
      expect(local.calls, 1);
    });

    test('负缓存：6 小时内不重试、过期后重试', () async {
      var now = 1000000000;
      final local = _FakeAdapter('local', (_) async => null);
      final cache = PanScrapeMemoryCache(nowMs: () => now);
      final service = _service(
        adapters: {'local': local},
        cache: cache,
        nowMs: () => now,
      );
      final id = panIdentify('ZZZ-999 x.mkv');
      await service.scrape(id, itemKey: 'k1');
      await service.scrape(id, itemKey: 'k1');
      expect(local.calls, 1);
      now += const Duration(hours: 6).inMilliseconds + 1;
      await service.scrape(id, itemKey: 'k1');
      expect(local.calls, 2);
    });

    test('手动重刮 force 绕缓存', () async {
      final local = _FakeAdapter(
        'local',
        (_) async => _meta(title: 't', cover: 'c', site: 'local'),
      );
      final service = _service(adapters: {'local': local});
      final id = panIdentify('SSIS-001 x.mkv');
      await service.scrape(id, itemKey: 'k1');
      await service.scrape(id, itemKey: 'k1', force: true);
      expect(local.calls, 2);
    });
  });

  group('限速与总开关', () {
    test('同站最小间隔：第二次请求前先等', () async {
      final slept = <Duration>[];
      var now = 5000000;
      final javdb = _FakeAdapter(
        'javdb',
        (_) async => _meta(title: 't', cover: 'c', site: 'javdb'),
      );
      final service = _service(
        adapters: {'javdb': javdb},
        slept: slept,
        nowMs: () => now,
      );
      final id = panIdentify('SSIS-001 x.mkv');
      await service.scrape(id, itemKey: 'k1', force: true);
      await service.scrape(id, itemKey: 'k2', force: true);
      expect(slept, contains(const Duration(seconds: 2)));
    });

    test('成人链关：番号型不发任何请求', () async {
      final settings = PanScrapeDefaults.settings.copyWith(
        adultChainEnabled: false,
      );
      final local = _FakeAdapter(
        'local',
        (_) async => _meta(title: 't', cover: 'c'),
      );
      final service = _service(adapters: {'local': local}, settings: settings);
      final outcome = await service.scrape(
        panIdentify('SSIS-001 x.mkv'),
        itemKey: 'k1',
      );
      expect(local.calls, 0);
      expect(outcome.meta, isNull);
    });
  });

  group('分类判定与归档闸门', () {
    test('分型→分类一一对应', () {
      final meta = _meta(title: 't', cover: 'c');
      expect(panClassify(panIdentify('FC2-PPV-123456.mp4'), meta), 'fc2');
      expect(panClassify(panIdentify('HEYZO-1234.mp4'), meta), 'uncensored');
      expect(
        panClassify(panIdentify('星空传媒 XK-9527 故事.mp4'), meta),
        'domestic_adult',
      );
      expect(panClassify(panIdentify('259luxu0123.mp4'), meta), 'amateur');
      expect(panClassify(panIdentify('SSIS-001 x.mp4'), meta), 'coded');
    });

    test('影视分类：季集→电视剧、TMDB 电影→电影、关键词→动漫', () {
      final meta = _meta(title: 't', cover: 'c');
      expect(panClassify(panIdentify('庆余年 第二季 第05集.mp4'), meta), 'tv');
      final movieMeta = PanScrapedMeta(title: 't', cover: 'c', tmdbId: 123);
      expect(panClassify(panIdentify('某部电影.2024.mp4'), movieMeta), 'movie');
      expect(panClassify(panIdentify('进击的巨人 动漫 第01集.mp4'), meta), 'anime');
      expect(
        panClassify(panIdentify('地球脉动 纪录片 第01集.mp4'), meta),
        'documentary',
      );
    });

    test('归档规划：刮成+明确分类才可移；未识别永不动', () {
      final meta = _meta(title: 't', cover: 'c');
      final plan = panArchivePlanFor(
        identity: panIdentify('SSIS-001 x.mp4'),
        meta: meta,
        complete: true,
        enabledCategories: PanScrapeDefaults.defaultEnabledCategories,
      );
      expect(plan.movable, isTrue);
      final unknown = panArchivePlanFor(
        identity: panIdentify('某部电影.2024.mp4'),
        meta: null,
        complete: false,
        enabledCategories: PanScrapeDefaults.defaultEnabledCategories,
      );
      expect(unknown.movable, isFalse);
    });

    test('真实移动闸门：开关关拒、执行器缺失拒、五家能力全点亮', () async {
      final plan = panArchivePlanFor(
        identity: panIdentify('SSIS-001 x.mp4'),
        meta: _meta(title: 't', cover: 'c'),
        complete: true,
        enabledCategories: PanScrapeDefaults.defaultEnabledCategories,
      );
      final off = await panTryRealMove(
        realMoveEnabled: false,
        providerId: 'pan115',
        itemId: 'f1',
        plan: plan,
        executor: null,
      );
      expect(off.moved, isFalse);
      final noExecutor = await panTryRealMove(
        realMoveEnabled: true,
        providerId: 'pan115',
        itemId: 'f1',
        plan: plan,
        executor: null,
      );
      expect(noExecutor.moved, isFalse);
      expect(noExecutor.reason, contains('暂不支持'));
      // 2026-11-28 补移动批：五家能力账全部点亮，键是
      // provider 真实 id（移动云盘是 yun139，不是旧误写
      // 的 cloud139）。
      expect(panDriveMoveCapability.values.every((v) => v), isTrue);
      expect(
        panDriveMoveCapability.keys,
        containsAll(['pan115', 'quark', 'aliyun', 'baidu', 'yun139']),
      );
      expect(panDriveMoveCapability.containsKey('cloud139'), isFalse);
    });
  });

  group('站点自动分类（2026-11-28 20:29 追加令）', () {
    test('MDCx 38 爬虫逐个归组正确', () {
      const expected = {
        'coded': [
          'javdb',
          'dmm',
          'javbus',
          'javlibrary',
          'jav321',
          'mgstage',
          'airav',
          'airav_cc',
          'xcity',
          'getchu',
          'getchu_dmm',
          'official',
          'dahlia',
          'faleno',
          'prestige',
          'fantastica',
          'mywife',
          'giga',
          'hdouban',
          'javday',
          'iqqtv',
          'mmtv',
          'lulubar',
          'love6',
          'hscangku',
          'cableav',
        ],
        'uncensored': ['avsox', 'avsex', 'kin8', 'freejavbt', 'theporndb'],
        'fc2': ['fc2', 'fc2club', 'fc2hub', 'fc2ppvdb'],
        'domestic': ['cnmdb', 'madouqu', 'mdtv'],
      };
      var counted = 0;
      for (final entry in expected.entries) {
        for (final id in entry.value) {
          counted++;
          expect(
            panSiteGroupOf(panScrapeSiteSpecs[id]!),
            entry.key,
            reason: '$id 应归 ${entry.key} 组',
          );
        }
      }
      expect(counted, 38);
    });

    test('凡人自有源归组：本地/TMDB/豆瓣/Bangumi/头像仓', () {
      expect(panSiteGroupOf(panScrapeSiteSpecs['local']!), 'local');
      expect(panSiteGroupOf(panScrapeSiteSpecs['tmdb']!), 'film_tmdb');
      expect(panSiteGroupOf(panScrapeSiteSpecs['douban']!), 'film_cn');
      expect(panSiteGroupOf(panScrapeSiteSpecs['bangumi']!), 'film_cn');
      expect(panSiteGroupOf(panScrapeSiteSpecs['gfriends']!), 'avatar');
      expect(panSiteGroupOf(panScrapeSiteSpecs['r18dev']!), 'coded');
      expect(panSiteGroupOf(panScrapeSiteSpecs['thejavdb']!), 'coded');
    });

    test('跨型站按主类型归组、兼属标注齐', () {
      // JavDB 主组有码，兼属无码/FC2/国产。
      final javdb = panScrapeSiteSpecs['javdb']!;
      expect(panSiteGroupOf(javdb), 'coded');
      expect(
        panSiteCrossGroupsOf(javdb),
        containsAll(['番号 · 无码', 'FC2', '国产成人']),
      );
      // 单型站无兼属。
      expect(panSiteCrossGroupsOf(panScrapeSiteSpecs['avsox']!), isEmpty);
      expect(panSiteCrossGroupsOf(panScrapeSiteSpecs['fc2ppvdb']!), isEmpty);
    });

    test('新适配器自动进组：只凭自描述、不靠人工名单', () {
      const futureUncensored = PanScrapeSiteSpec(
        id: 'future_site',
        name: '未来无码站',
        kinds: {PanScrapeKind.uncensored},
        fields: {'title', 'cover'},
        method: 'web',
      );
      expect(panSiteGroupOf(futureUncensored), 'uncensored');
      const futureFc2 = PanScrapeSiteSpec(
        id: 'future_fc2',
        name: '未来 FC2 站',
        kinds: {PanScrapeKind.fc2},
        fields: {'title'},
        method: 'api',
      );
      expect(panSiteGroupOf(futureFc2), 'fc2');
      const futureFilm = PanScrapeSiteSpec(
        id: 'future_film',
        name: '未来影视库',
        kinds: {PanScrapeKind.film},
        fields: {'title'},
        method: 'api',
      );
      expect(panSiteGroupOf(futureFilm), 'film_cn');
    });

    test('分组覆盖全表：每组非空或有定稿，总站数对账', () {
      final grouped = panGroupedSiteSpecs();
      var total = 0;
      for (final group in panSiteGroups) {
        total += grouped[group.id]!.length;
      }
      expect(total, panScrapeSiteSpecs.length);
      expect(grouped['coded']!.length, 28); // MDCx 26 + r18dev + thejavdb
      expect(grouped['uncensored']!.length, 5);
      expect(grouped['fc2']!.length, 4);
      expect(grouped['domestic']!.length, 3);
    });
  });
}
