/// 网盘刮削默认设置档（出厂预置，用户 2026-11-28 20:10 令
/// 「刮削设置你帮我设置好」）：全部取值按站点刮削开源调查
/// （xiuxian_scraper_survey_20261128/REPORT.md）口径预置，开
/// 箱即用——自动刮削默认开、成人链默认开、主链站点默认全
/// 勾、冷门站默认不勾、TMDB 中文。用户在设置页的勾选/排序/
/// 开关改动落 SharedPreferences 覆盖默认值，「恢复默认」一
/// 键回到本档。每一项的依据写在字段注释里（调查报告条目）。
///
/// 本文件只放「值」：站点链与启停、字段优先级、各站限速/
/// 重试、缓存时长、成功门槛、分类文件夹与归档口径。执行逻
/// 辑在 pan_scrape_service.dart，站点规格在
/// pan_scrape_adapter.dart，分类判定在 pan_scrape_archive.dart。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 刮削设置（不可变值对象；改值走 [copyWith] 或设置页）。
class PanScrapeSettings {
  const PanScrapeSettings({
    required this.autoScrape,
    required this.adultChainEnabled,
    required this.chains,
    required this.enabledSites,
    required this.fieldPriority,
    required this.siteRate,
    required this.successNeedsCoverAndTitle,
    required this.preferHdCover,
    required this.preferVerticalPoster,
    required this.cacheTtl,
    required this.negativeCacheTtl,
    required this.maxCacheEntries,
    required this.concurrency,
    required this.perPageCap,
    required this.tmdbLanguage,
    required this.javdbCookie,
    required this.javdbImageCdnRewrite,
    required this.enabledCategories,
    required this.archiveViewEnabled,
    required this.realMoveEnabled,
  });

  /// 进文件夹后台增量自动刮（不挡浏览/播放）。调查 §4.6：
  /// 刮削与播放解耦、后台进行。
  final bool autoScrape;

  /// 成人（番号）链总开关。默认开：网盘主场就是番号作品。
  final bool adultChainEnabled;

  /// 各分型的站点链（站点 id 有序表，逐站回退、刮成即停）。
  /// 键：coded / uncensored / fc2 / cid / film / domestic。
  /// 番号主链口径＝调查 §4.3：本地女优库（零网络）→JavDB→
  /// DMM→JavBus→JavLibrary，其后接 MDCx 注册爬虫的同型站
  /// 点（2026-11-28 20:12 追加令：MDCx 爬虫成建制进表）。
  /// 设置页可上下移调序，改动落盘。
  final Map<String, List<String>> chains;

  /// 勾选启用的站点集合（设置页勾选式，2026-11-28 20:16
  /// 追加令）：链里未勾选的站自动跳过。出厂默认＝主链全
  /// 勾、冷门站不勾（见 PanScrapeDefaults）。
  final Set<String> enabledSites;

  /// 字段级合并优先级（字段名 → 站点 id 有序表）：调查
  /// §1.2 Javinizer 的 metadata.priority 与 §4.4 合并表。
  final Map<String, List<String>> fieldPriority;

  /// 各站限速与重试（站点 id → (最小间隔, 重试次数)）。
  /// JavDB 间隔 2 秒：AVDC README 实证只用 JavDB 刮约
  /// 30 部会被封 IP 一段时间（调查 §1.2），慢工防封。
  final Map<String, ({Duration minInterval, int maxRetries})> siteRate;

  /// 成功门槛＝封面＋标题齐才算刮成（调查 §1.2 JavSP 的
  /// required_keys=cover,title）。
  final bool successNeedsCoverAndTitle;

  /// 封面偏好：高清优先（DMM 高清升级链，调查 §3.3）。
  final bool preferHdCover;

  /// 竖版海报优先（海报墙卡片 5:7，调查 §4.4）。
  final bool preferVerticalPoster;

  /// 正缓存时长：刮成结果落库缓存、增量刮不重复（§4.6）。
  final Duration cacheTtl;

  /// 负缓存时长：刮不到的条目隔这段时间才重试（§4.6
  /// 「失败负缓存」；取 6 小时兼顾新片入库节奏）。
  final Duration negativeCacheTtl;

  /// 缓存条数上限（超出按最旧淘汰）。
  final int maxCacheEntries;

  /// 后台刮削并发数。
  final int concurrency;

  /// 单页最多自动刮条数。
  final int perPageCap;

  /// TMDB 语言：中文（调查 §4.3；凡人 TmdbConfig 缺省即
  /// zh-CN，此处钉死口径）。
  final String tmdbLanguage;

  /// JavDB 网页版 Cookie（默认空）：MDCx 口径——JavDB 无
  /// 码内容网页版要登录 Cookie（调查 §1.1）。凡人主路走
  /// JavDB App 接口（免 Cookie），此值只供网页兜底适配器
  /// 用；空＝不带 Cookie，刮不到走链上下一站，不挡链。
  final String javdbCookie;

  /// JavDB 图走 tp.spfcas.com 无水印原图通道（MDCx 五条
  /// 免 CF 通道之一，调查 §1.3）：默认关——本机未实证该
  /// 域名映射，贸然改写可能让封面全灭；通道实现已备，实
  /// 证后再开。JavDB App 接口（逆向签名）是另一条免 CF
  /// 通道，已实证通、默认在用，不受此开关影响。
  final bool javdbImageCdnRewrite;

  /// 勾选启用的分类文件夹（分类 id，定稿名单见
  /// pan_scrape_archive.dart）：刮后归档只归入已勾选分类，
  /// 未勾选分类的条目留在原视图不归档。
  final Set<String> enabledCategories;

  /// 刮后分类视图（多媒体页内的虚拟分类，多媒体页分类行
  /// 筛选）：默认开——不动网盘文件的归档层，与真实移动
  /// 互不依赖（能力账见报告）。
  final bool archiveViewEnabled;

  /// 真实建夹＋移动（改动用户网盘原文件）：**默认开**
  /// （2026-11-28 补移动批，五家引擎建夹/移动接口已逐家
  /// 点亮，「能力具备即按分类勾选生效」）。防误移口径不
  /// 变：只有刮成（封面＋标题齐）且分类明确（非「未识
  /// 别」）且分类已勾选的条目才可移；移动逐条记账、失
  /// 败不连坐、成功打归档标记防重复移（规划器与能力账
  /// 在 pan_scrape_archive，编排在 pan_scrape_archiver）。
  final bool realMoveEnabled;

  List<String> chainFor(String kind) => [
    for (final site in chains[kind] ?? const <String>[])
      if (enabledSites.contains(site)) site,
  ];

  List<String> priorityFor(String field) => fieldPriority[field] ?? const [];

  ({Duration minInterval, int maxRetries}) rateFor(String siteId) =>
      siteRate[siteId] ??
      (minInterval: const Duration(milliseconds: 1200), maxRetries: 1);

  PanScrapeSettings copyWith({
    bool? autoScrape,
    bool? adultChainEnabled,
    Map<String, List<String>>? chains,
    Set<String>? enabledSites,
    String? javdbCookie,
    bool? javdbImageCdnRewrite,
    Set<String>? enabledCategories,
    bool? archiveViewEnabled,
    bool? realMoveEnabled,
  }) {
    return PanScrapeSettings(
      autoScrape: autoScrape ?? this.autoScrape,
      adultChainEnabled: adultChainEnabled ?? this.adultChainEnabled,
      chains: chains ?? this.chains,
      enabledSites: enabledSites ?? this.enabledSites,
      fieldPriority: fieldPriority,
      siteRate: siteRate,
      successNeedsCoverAndTitle: successNeedsCoverAndTitle,
      preferHdCover: preferHdCover,
      preferVerticalPoster: preferVerticalPoster,
      cacheTtl: cacheTtl,
      negativeCacheTtl: negativeCacheTtl,
      maxCacheEntries: maxCacheEntries,
      concurrency: concurrency,
      perPageCap: perPageCap,
      tmdbLanguage: tmdbLanguage,
      javdbCookie: javdbCookie ?? this.javdbCookie,
      javdbImageCdnRewrite: javdbImageCdnRewrite ?? this.javdbImageCdnRewrite,
      enabledCategories: enabledCategories ?? this.enabledCategories,
      archiveViewEnabled: archiveViewEnabled ?? this.archiveViewEnabled,
      realMoveEnabled: realMoveEnabled ?? this.realMoveEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'autoScrape': autoScrape,
    'adultChainEnabled': adultChainEnabled,
    'chains': chains,
    'enabledSites': enabledSites.toList(),
    'javdbCookie': javdbCookie,
    'javdbImageCdnRewrite': javdbImageCdnRewrite,
    'enabledCategories': enabledCategories.toList(),
    'archiveViewEnabled': archiveViewEnabled,
    'realMoveEnabled': realMoveEnabled,
  };

  factory PanScrapeSettings.fromJson(
    Map<String, dynamic> json, {
    required PanScrapeSettings defaults,
  }) {
    Set<String> setOf(Object? v, Set<String> fallback) => v is List
        ? {
            for (final e in v)
              if (e != null) e.toString(),
          }
        : fallback;
    Map<String, List<String>> chainsOf(Object? v) {
      if (v is! Map) return defaults.chains;
      final out = <String, List<String>>{};
      for (final entry in defaults.chains.entries) {
        final raw = v[entry.key];
        out[entry.key] = raw is List
            ? [
                for (final e in raw)
                  if (e != null && entry.value.contains(e.toString()))
                    e.toString(),
              ]
            : entry.value;
        // 链里出厂后新增的站（版本升级）补到链尾，不丢站。
        for (final site in entry.value) {
          if (!out[entry.key]!.contains(site)) out[entry.key]!.add(site);
        }
      }
      return out;
    }

    return defaults.copyWith(
      autoScrape: json['autoScrape'] as bool? ?? defaults.autoScrape,
      adultChainEnabled:
          json['adultChainEnabled'] as bool? ?? defaults.adultChainEnabled,
      chains: chainsOf(json['chains']),
      enabledSites: setOf(json['enabledSites'], defaults.enabledSites),
      javdbCookie: json['javdbCookie'] as String? ?? defaults.javdbCookie,
      javdbImageCdnRewrite:
          json['javdbImageCdnRewrite'] as bool? ??
          defaults.javdbImageCdnRewrite,
      enabledCategories: setOf(
        json['enabledCategories'],
        defaults.enabledCategories,
      ),
      archiveViewEnabled:
          json['archiveViewEnabled'] as bool? ?? defaults.archiveViewEnabled,
      realMoveEnabled:
          json['realMoveEnabled'] as bool? ?? defaults.realMoveEnabled,
    );
  }
}

/// 出厂默认档（测试逐项断言钉死，防后续批次手滑改动）。
abstract final class PanScrapeDefaults {
  /// 默认勾选站点：主链全勾（本地/JavDB/DMM/JavBus/
  /// JavLibrary/r18dev/thejavdb/无码主站/FC2 主站/TMDB/
  /// 豆瓣/Bangumi/国产三站/mgstage），冷门站（厂商官网群、
  /// 小众聚合站）默认不勾——链里留位、勾上即生效。
  static const Set<String> defaultEnabledSites = {
    'local',
    'javdb',
    'dmm',
    'javbus',
    'javlibrary',
    'r18dev',
    'thejavdb',
    'jav321',
    'mgstage',
    'airav',
    'avsox',
    'avsex',
    'fc2ppvdb',
    'fc2club',
    'fc2hub',
    'fc2',
    'tmdb',
    'douban',
    'bangumi',
    'cnmdb',
    'madouqu',
    'mdtv',
  };

  /// 默认勾选分类：定稿 12 类全开（用户可在设置里关）。
  static const Set<String> defaultEnabledCategories = {
    'movie',
    'tv',
    'anime',
    'documentary',
    'variety',
    'coded',
    'uncensored',
    'fc2',
    'domestic_adult',
    'western',
    'amateur',
    'unidentified',
  };

  static const PanScrapeSettings settings = PanScrapeSettings(
    autoScrape: true,
    adultChainEnabled: true,
    chains: {
      // 有码主链：本地→JavDB→DMM→JavBus→JavLibrary（调查
      // §4.3），其后 MDCx 有码/综合站按可靠性排。
      'coded': [
        'local',
        'javdb',
        'dmm',
        'javbus',
        'javlibrary',
        'r18dev',
        'thejavdb',
        'jav321',
        'mgstage',
        'airav',
        'airav_cc',
        'xcity',
        'getchu_dmm',
        'getchu',
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
        'cnmdb',
      ],
      // 无码专链：本地→JavDB（App 接口免 Cookie）→AVSOX→
      // avsex→JavBus 无码区→freejavbt→kin8→theporndb→
      // cableav→lulubar（调查 §4.3＋MDCx 无码专站）。
      'uncensored': [
        'local',
        'javdb',
        'avsox',
        'avsex',
        'javbus',
        'freejavbt',
        'kin8',
        'theporndb',
        'cableav',
        'lulubar',
      ],
      // FC2 专链：本地→JavDB→fc2ppvdb→fc2club→fc2hub→
      // fc2 官网（调查 §4.3＋MDCx FC2 四爬虫）。
      'fc2': ['local', 'javdb', 'fc2ppvdb', 'fc2club', 'fc2hub', 'fc2'],
      // 连写 cid：多为 FANZA 素人/同人，DMM 直查优先。
      'cid': ['local', 'dmm', 'r18dev', 'javdb', 'thejavdb', 'mgstage'],
      // 普通影视：TMDB 主查→豆瓣→Bangumi 中文回退（§4.3）。
      'film': ['tmdb', 'douban', 'bangumi'],
      // 国产成人：标题检索为主——JavDB 标题搜→cnmdb→
      // madouqu→mdtv→TMDB 兜底（2026-11-28 20:16 追加令）。
      'domestic': ['javdb', 'cnmdb', 'madouqu', 'mdtv', 'tmdb'],
    },
    enabledSites: defaultEnabledSites,
    fieldPriority: {
      // 封面：DMM 高清升级优先（调查 §4.4/§3.3）。
      'cover': [
        'dmm',
        'javdb',
        'r18dev',
        'local',
        'javbus',
        'javlibrary',
        'thejavdb',
        'avsox',
        'fc2ppvdb',
        'tmdb',
        'douban',
      ],
      // 竖版海报：r18dev 优先（Javinizer 默认口径，§1.2）。
      'poster': ['r18dev', 'dmm', 'javdb', 'local', 'tmdb'],
      // 标题：中文标题 JavDB 优先、airav 次之（§4.4）。
      'title': [
        'javdb',
        'airav',
        'dmm',
        'local',
        'r18dev',
        'javbus',
        'javlibrary',
        'tmdb',
        'douban',
      ],
      // 简介：DMM 剧情最全；JavDB 不提供剧情（§1.1）。
      'overview': ['dmm', 'r18dev', 'local', 'tmdb', 'douban'],
      'actress': ['dmm', 'javdb', 'local', 'r18dev', 'javbus'],
      // 女优头像：gFriends 现成头像仓优先、JavDB 次之。
      'actressAvatar': ['gfriends', 'javdb', 'dmm'],
      // 评分：JavDB 评分人数最多（§1.1）。
      'rating': ['javdb', 'dmm', 'tmdb', 'douban'],
      // 剧照：整组回退（MDCx 口径：一组图只取一个站）。
      'stills': ['dmm', 'javdb', 'local'],
      'releaseDate': ['dmm', 'javdb', 'local', 'javbus', 'javlibrary'],
      'series': ['dmm', 'javdb', 'local'],
      'maker': ['dmm', 'javdb', 'local'],
    },
    siteRate: {
      'local': (minInterval: Duration.zero, maxRetries: 0),
      'javdb': (minInterval: Duration(milliseconds: 2000), maxRetries: 1),
      'dmm': (minInterval: Duration(milliseconds: 1000), maxRetries: 1),
      'javbus': (minInterval: Duration(milliseconds: 1500), maxRetries: 1),
      'javlibrary': (minInterval: Duration(milliseconds: 2000), maxRetries: 1),
      'r18dev': (minInterval: Duration(milliseconds: 1000), maxRetries: 2),
      'thejavdb': (minInterval: Duration(milliseconds: 1000), maxRetries: 1),
      'tmdb': (minInterval: Duration(milliseconds: 500), maxRetries: 1),
      'douban': (minInterval: Duration(milliseconds: 1000), maxRetries: 1),
      'bangumi': (minInterval: Duration(milliseconds: 1000), maxRetries: 1),
      'avsox': (minInterval: Duration(milliseconds: 1500), maxRetries: 1),
      'fc2ppvdb': (minInterval: Duration(milliseconds: 1500), maxRetries: 1),
    },
    successNeedsCoverAndTitle: true,
    preferHdCover: true,
    preferVerticalPoster: true,
    cacheTtl: Duration(days: 30),
    negativeCacheTtl: Duration(hours: 6),
    maxCacheEntries: 800,
    concurrency: 3,
    perPageCap: 60,
    tmdbLanguage: 'zh-CN',
    javdbCookie: '',
    javdbImageCdnRewrite: false,
    enabledCategories: defaultEnabledCategories,
    archiveViewEnabled: true,
    realMoveEnabled: true,
  );
}

/// 设置存取：SharedPreferences 单键 JSON，存全量覆盖档。
class PanScrapeSettingsStore {
  PanScrapeSettingsStore({Future<SharedPreferences> Function()? prefsProvider})
    : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  static const String storageKey = 'fanren_pan_scrape_settings_v1';

  final Future<SharedPreferences> Function() _prefsProvider;

  Future<PanScrapeSettings> load() async {
    try {
      final prefs = await _prefsProvider();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return PanScrapeDefaults.settings;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return PanScrapeDefaults.settings;
      return PanScrapeSettings.fromJson(
        json,
        defaults: PanScrapeDefaults.settings,
      );
    } catch (_) {
      return PanScrapeDefaults.settings;
    }
  }

  Future<void> save(PanScrapeSettings settings) async {
    final prefs = await _prefsProvider();
    await prefs.setString(storageKey, jsonEncode(settings.toJson()));
  }

  Future<void> reset() async {
    final prefs = await _prefsProvider();
    await prefs.remove(storageKey);
  }
}
