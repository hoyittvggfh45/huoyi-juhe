/// 网盘刮削站点适配器表（自描述，调查 §4.1：站点/适用类
/// 型/能给的字段/取数方式/登录/镜像六项自描述，加一个站
/// 只加一条适配、不改主流程）。
///
/// 底账对账（2026-11-28 20:12 追加令，MDCx 爬虫成建制
/// 添加）：MDCx（sqzw-x/mdcx，GPL-3.0，仓库已归档）注册
/// 爬虫 38 个＝v1 函数式 36（airav、airav_cc、avsex、
/// avsox、cableav、cnmdb、dahlia、faleno、fantastica、
/// fc2、fc2club、fc2hub、fc2ppvdb、freejavbt、getchu、
/// getchu_dmm、giga、hdouban、hscangku、iqqtv、jav321、
/// javbus、javday、javlibrary、kin8、love6、lulubar、
/// madouqu、mdtv、mgstage、mmtv、mywife、official、
/// prestige、theporndb、xcity）＋新版类式 2（dmm、javdb）；
/// 另有 5 个未注册旧文件（guochan、iqqtv 旧版、javlibrary
/// 旧版、getchu_dl、theporndb_movies）不在其注册表内，本
/// 表不收（对账结论写报告）。凡人借其爬虫定义与配置语义，
/// 不搬其桌面端代码（GPL-3.0，见报告许可证节）。
///
/// 取数实现分层（报告逐站标注）：
/// - A 层（真取数）：local、javdb、dmm、r18dev、javbus、
///   javlibrary、avsox、fc2ppvdb、tmdb、douban、bangumi；
/// - B 层（已登记规格、取数未实现）：其余 MDCx 站与
///   thejavdb——链上走到只会快速落空走下一站，不假装能用；
/// - gfriends 是头像专用源（不在作品链里，合并后补头像）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../actress/actress_javdb_api.dart';
import '../actress/actress_json_fallback.dart';
import '../tmdb/tmdb_config.dart';
import '../tmdb/tmdb_metadata.dart';
import 'pan_scrape_identify.dart';
import 'pan_scrape_models.dart';
import 'pan_scrape_settings.dart';

/// 通用 HTTP 取文本（测试注入点）。
typedef PanHttpGet =
    Future<String> Function(String url, {Map<String, String>? headers});

/// 通用 HTTP 取字节（图片尺寸探测用，测试注入点）。
typedef PanHttpBytes = Future<List<int>> Function(String url);

/// 本地女优库按番号取行（测试注入点）。
typedef PanLocalEntriesLookup =
    Future<List<ActressJsonEntry>> Function(String code);

/// TMDB 取数（测试注入点；缺省走 TmdbService）。
typedef PanTmdbFetch =
    Future<TmdbMetadata?> Function({
      required String title,
      String? year,
      String? typeHint,
    });

/// 刮削依赖束（适配器取数所需的一切外部能力，测试可整体
/// 换成夹具）。
class PanScrapeDeps {
  PanScrapeDeps({
    this.localLookup,
    this.javdbClientFactory,
    this.tmdbFetch,
    this.httpGet,
    this.httpBytes,
    this.tmdbConfig = const TmdbConfig(),
  });

  final PanLocalEntriesLookup? localLookup;

  /// JavdbApiClient 工厂（缺省在实现层构造真客户端）。
  final JavdbApiClient? Function()? javdbClientFactory;

  final PanTmdbFetch? tmdbFetch;
  final PanHttpGet? httpGet;
  final PanHttpBytes? httpBytes;
  final TmdbConfig tmdbConfig;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

  Future<String> get(String url, {Map<String, String>? headers}) async {
    final injected = httpGet;
    if (injected != null) return injected(url, headers: headers);
    final response = await http
        .get(
          Uri.parse(url),
          headers: {
            'User-Agent': _ua,
            'Accept-Language': 'zh-CN,zh;q=0.9',
            ...?headers,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode} for $url');
    }
    return response.body;
  }

  Future<List<int>> bytes(String url) async {
    final injected = httpBytes;
    if (injected != null) return injected(url);
    final response = await http
        .get(Uri.parse(url), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode} for $url');
    }
    return response.bodyBytes;
  }
}

/// 站点规格（自描述表的一行）。
class PanScrapeSiteSpec {
  const PanScrapeSiteSpec({
    required this.id,
    required this.name,
    required this.kinds,
    required this.fields,
    required this.method,
    this.requiresLogin = false,
    this.requiresCookie = false,
    this.mirrors = const [],
    this.fromMdcx = false,
    this.note = '',
  });

  final String id;

  /// 中文站名（设置页展示）。
  final String name;

  /// 适用分型。
  final Set<PanScrapeKind> kinds;

  /// 能给的字段（title/cover/poster/stills/overview/
  /// actress/rating/releaseDate/series/maker）。
  final Set<String> fields;

  /// 取数方式：local / api / web。
  final String method;

  final bool requiresLogin;
  final bool requiresCookie;
  final List<String> mirrors;

  /// 是否 MDCx 注册爬虫（底账对账用）。
  final bool fromMdcx;
  final String note;
}

/// 适配器上下文。
class PanScrapeContext {
  const PanScrapeContext({
    required this.identity,
    required this.settings,
    required this.deps,
  });

  final PanScrapeIdentity identity;
  final PanScrapeSettings settings;
  final PanScrapeDeps deps;
}

/// 站点适配器：给识别结果回元数据；查不到/失败回 null，
/// 不抛错（服务层负责重试与回退）。
abstract class PanScrapeAdapter {
  PanScrapeSiteSpec get spec;
  String get id => spec.id;
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx);
}

/// B 层适配器：规格已登记、取数未实现，恒回 null。
class PanSpecOnlyAdapter extends PanScrapeAdapter {
  PanSpecOnlyAdapter(this._spec);
  final PanScrapeSiteSpec _spec;
  @override
  PanScrapeSiteSpec get spec => _spec;
  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async => null;
}

const _javFields = {
  'title',
  'cover',
  'poster',
  'stills',
  'actress',
  'releaseDate',
  'series',
  'maker',
};

/// 全站规格表（凡人自有源＋MDCx 38 爬虫＋thejavdb＋
/// gfriends）。设置页两组勾选名单就出自此表：
/// 番号组＝kinds 含成人分型的站；影视组＝tmdb/douban/
/// bangumi（见 panScrapeFilmSiteIds）。
final Map<String, PanScrapeSiteSpec> panScrapeSiteSpecs = {
  // ---- 凡人自有源 ----
  'local': const PanScrapeSiteSpec(
    id: 'local',
    name: '本地女优库',
    kinds: {
      PanScrapeKind.coded,
      PanScrapeKind.uncensored,
      PanScrapeKind.fc2,
      PanScrapeKind.cid,
      PanScrapeKind.domestic,
    },
    fields: {..._javFields, 'overview'},
    method: 'local',
    note: '零网络第一顺位：已导入的女优库（51 万部）按番号直查',
  ),
  'javdb': const PanScrapeSiteSpec(
    id: 'javdb',
    name: 'JavDB 接口',
    kinds: {
      PanScrapeKind.coded,
      PanScrapeKind.uncensored,
      PanScrapeKind.fc2,
      PanScrapeKind.domestic,
    },
    fields: {..._javFields, 'rating'},
    method: 'api',
    fromMdcx: true,
    note:
        'App 接口逆向签名（MDCx javdb_app 免 CF 通道），本机已实拉通；'
        '网页版无码内容需 Cookie（设置里可填），接口路免 Cookie',
  ),
  'dmm': const PanScrapeSiteSpec(
    id: 'dmm',
    name: 'DMM / FANZA',
    kinds: {PanScrapeKind.coded, PanScrapeKind.cid},
    fields: {..._javFields, 'overview', 'rating'},
    method: 'web',
    fromMdcx: true,
    note:
        '一手源字段最全；凡人实现走 cid 直链图＋占位过滤，'
        '详情页解析需日本 IP 环境（未验）',
  ),
  'r18dev': const PanScrapeSiteSpec(
    id: 'r18dev',
    name: 'R18.dev 接口',
    kinds: {PanScrapeKind.coded, PanScrapeKind.cid},
    fields: {..._javFields, 'overview'},
    method: 'api',
    note: 'DMM 系 JSON API 化镜像（MDCx 免 CF 通道之一），无令牌',
  ),
  'thejavdb': const PanScrapeSiteSpec(
    id: 'thejavdb',
    name: 'TheJavDB 接口',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored, PanScrapeKind.cid},
    fields: _javFields,
    method: 'api',
    note: 'JavDB 数据 API 化、免 CF（MDCx 通道）；接口形态未实证，B 层登记',
  ),
  'tmdb': const PanScrapeSiteSpec(
    id: 'tmdb',
    name: 'TMDB',
    kinds: {PanScrapeKind.film, PanScrapeKind.domestic},
    fields: {'title', 'cover', 'poster', 'overview', 'rating', 'releaseDate'},
    method: 'api',
    note: '普通影视主查，语言 zh-CN',
  ),
  'douban': const PanScrapeSiteSpec(
    id: 'douban',
    name: '豆瓣',
    kinds: {PanScrapeKind.film},
    fields: {'title', 'cover', 'releaseDate'},
    method: 'api',
    note: '中文影视回退：subject_suggest 公开接口，本机已实拉 200',
  ),
  'bangumi': const PanScrapeSiteSpec(
    id: 'bangumi',
    name: 'Bangumi',
    kinds: {PanScrapeKind.film},
    fields: {'title', 'cover', 'overview', 'rating', 'releaseDate'},
    method: 'api',
    note: '动漫/中文影视回退：api.bgm.tv 公开搜索接口',
  ),
  'gfriends': const PanScrapeSiteSpec(
    id: 'gfriends',
    name: 'gFriends 头像仓',
    kinds: {},
    fields: {'actressAvatar'},
    method: 'api',
    note: '女优头像专用（GitHub 仓库按名取图），只补头像不进作品链',
  ),
  // ---- MDCx 注册爬虫（38 个，含上面的 javdb/dmm） ----
  'javbus': const PanScrapeSiteSpec(
    id: 'javbus',
    name: 'JavBus',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
    mirrors: ['busdmm.shop'],
    note: '有码/无码分开目录；免代理镜像域工具自动更新（调查 §1.1）',
  ),
  'javlibrary': const PanScrapeSiteSpec(
    id: 'javlibrary',
    name: 'JavLibrary',
    kinds: {PanScrapeKind.coded},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
    note: '老牌综合库常作回退；常遇 Cloudflare（调查 §1.1）',
  ),
  'jav321': const PanScrapeSiteSpec(
    id: 'jav321',
    name: 'Jav321',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
    note: 'DMM 目录镜像',
  ),
  'mgstage': const PanScrapeSiteSpec(
    id: 'mgstage',
    name: 'MGStage',
    kinds: {PanScrapeKind.coded, PanScrapeKind.cid},
    fields: {'title', 'cover', 'actress'},
    method: 'web',
    requiresCookie: true,
    fromMdcx: true,
    note: '素人一手（SIRO/259LUXU 等数字前缀）；需年龄验证 Cookie adc=1',
  ),
  'airav': const PanScrapeSiteSpec(
    id: 'airav',
    name: 'Airav',
    kinds: {PanScrapeKind.coded},
    fields: {'title'},
    method: 'web',
    fromMdcx: true,
    note: '中文标题源（标题优先级第二位）',
  ),
  'airav_cc': const PanScrapeSiteSpec(
    id: 'airav_cc',
    name: 'AiravCC',
    kinds: {PanScrapeKind.coded},
    fields: {'title'},
    method: 'web',
    fromMdcx: true,
  ),
  'xcity': const PanScrapeSiteSpec(
    id: 'xcity',
    name: 'XCity',
    kinds: {PanScrapeKind.coded},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'getchu': const PanScrapeSiteSpec(
    id: 'getchu',
    name: 'Getchu',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'getchu_dmm': const PanScrapeSiteSpec(
    id: 'getchu_dmm',
    name: 'GetchuDMM',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'official': const PanScrapeSiteSpec(
    id: 'official',
    name: '制作商官网',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
    note: '按番号前缀路由厂商官网，匹配不到不发请求（调查 §1.1）',
  ),
  'dahlia': const PanScrapeSiteSpec(
    id: 'dahlia',
    name: 'DAHLIA 官网',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'faleno': const PanScrapeSiteSpec(
    id: 'faleno',
    name: 'FALENO 官网',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'prestige': const PanScrapeSiteSpec(
    id: 'prestige',
    name: 'Prestige 官网',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'fantastica': const PanScrapeSiteSpec(
    id: 'fantastica',
    name: 'Fantastica',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'mywife': const PanScrapeSiteSpec(
    id: 'mywife',
    name: '舞ワイフ',
    kinds: {PanScrapeKind.coded, PanScrapeKind.cid},
    fields: {'title', 'cover', 'actress'},
    method: 'web',
    fromMdcx: true,
  ),
  'giga': const PanScrapeSiteSpec(
    id: 'giga',
    name: 'GIGA',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'hdouban': const PanScrapeSiteSpec(
    id: 'hdouban',
    name: 'HDouban',
    kinds: {PanScrapeKind.coded},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'javday': const PanScrapeSiteSpec(
    id: 'javday',
    name: 'JavDay',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'iqqtv': const PanScrapeSiteSpec(
    id: 'iqqtv',
    name: 'IQQTv',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'mmtv': const PanScrapeSiteSpec(
    id: 'mmtv',
    name: 'MMTV',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'lulubar': const PanScrapeSiteSpec(
    id: 'lulubar',
    name: 'Lulubar',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'love6': const PanScrapeSiteSpec(
    id: 'love6',
    name: 'Love6',
    kinds: {PanScrapeKind.coded},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'hscangku': const PanScrapeSiteSpec(
    id: 'hscangku',
    name: '黄色仓库',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'cableav': const PanScrapeSiteSpec(
    id: 'cableav',
    name: 'CableAV',
    kinds: {PanScrapeKind.coded, PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'cnmdb': const PanScrapeSiteSpec(
    id: 'cnmdb',
    name: '国产传媒库 CNMDB',
    kinds: {PanScrapeKind.domestic, PanScrapeKind.coded},
    fields: {'title', 'cover', 'actress'},
    method: 'web',
    fromMdcx: true,
    note: '国产成人数据库，国产链第一位',
  ),
  'madouqu': const PanScrapeSiteSpec(
    id: 'madouqu',
    name: '麻豆区',
    kinds: {PanScrapeKind.domestic},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'mdtv': const PanScrapeSiteSpec(
    id: 'mdtv',
    name: 'MDTV',
    kinds: {PanScrapeKind.domestic},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'avsox': const PanScrapeSiteSpec(
    id: 'avsox',
    name: 'AVSOX',
    kinds: {PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
    mirrors: ['avsox.click'],
    note: '无码专站；镜像 avsox.click 本机超时未通（2026-11-28 实测）',
  ),
  'avsex': const PanScrapeSiteSpec(
    id: 'avsex',
    name: 'AVSex',
    kinds: {PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'web',
    fromMdcx: true,
  ),
  'kin8': const PanScrapeSiteSpec(
    id: 'kin8',
    name: '金8天国',
    kinds: {PanScrapeKind.uncensored},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'freejavbt': const PanScrapeSiteSpec(
    id: 'freejavbt',
    name: 'FreeJavBT',
    kinds: {PanScrapeKind.uncensored},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'theporndb': const PanScrapeSiteSpec(
    id: 'theporndb',
    name: 'ThePornDB',
    kinds: {PanScrapeKind.uncensored},
    fields: _javFields,
    method: 'api',
    requiresLogin: true,
    fromMdcx: true,
    note: '欧美 scene 库，需账号 Token（调查 §1.1）；欧美分类的判定来源之一',
  ),
  'fc2': const PanScrapeSiteSpec(
    id: 'fc2',
    name: 'FC2 官网',
    kinds: {PanScrapeKind.fc2},
    fields: {'title', 'cover', 'releaseDate'},
    method: 'web',
    fromMdcx: true,
  ),
  'fc2club': const PanScrapeSiteSpec(
    id: 'fc2club',
    name: 'FC2Club',
    kinds: {PanScrapeKind.fc2},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'fc2hub': const PanScrapeSiteSpec(
    id: 'fc2hub',
    name: 'FC2Hub',
    kinds: {PanScrapeKind.fc2},
    fields: {'title', 'cover'},
    method: 'web',
    fromMdcx: true,
  ),
  'fc2ppvdb': const PanScrapeSiteSpec(
    id: 'fc2ppvdb',
    name: 'FC2PPVDB',
    kinds: {PanScrapeKind.fc2},
    fields: {'title', 'cover', 'releaseDate'},
    method: 'web',
    fromMdcx: true,
    note: 'FC2 PPV 数据库',
  ),
};

/// 影视库站点组（设置页第二组）：普通影视的库站。
const panScrapeFilmSiteIds = ['tmdb', 'douban', 'bangumi'];

/// MDCx 注册爬虫全名单（38，对账用）：凡人规格表里
/// fromMdcx 的站必须与此表逐项对上。
const panMdcxCrawlerIds = [
  'airav',
  'airav_cc',
  'avsex',
  'avsox',
  'cableav',
  'cnmdb',
  'dahlia',
  'dmm',
  'faleno',
  'fantastica',
  'fc2',
  'fc2club',
  'fc2hub',
  'fc2ppvdb',
  'freejavbt',
  'getchu',
  'getchu_dmm',
  'giga',
  'hdouban',
  'hscangku',
  'iqqtv',
  'jav321',
  'javbus',
  'javday',
  'javdb',
  'javlibrary',
  'kin8',
  'love6',
  'lulubar',
  'madouqu',
  'mdtv',
  'mgstage',
  'mmtv',
  'mywife',
  'official',
  'prestige',
  'theporndb',
  'xcity',
];

/// HTML 小工具（网页型适配器共用，正则轻解析：只取已知锚
/// 点，取不到回空、不猜）。
String panHtmlAttr(String html, String pattern) {
  final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
  return match == null ? '' : _decodeEntities(match.group(1) ?? '');
}

List<String> panHtmlAll(String html, String pattern) {
  return [
    for (final m in RegExp(pattern, caseSensitive: false).allMatches(html))
      if ((m.group(1) ?? '').trim().isNotEmpty) _decodeEntities(m.group(1)!),
  ];
}

String _decodeEntities(String text) {
  return text
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();
}

/// JavDB 图无水印通道改写（MDCx：图走 tp.spfcas.com，
/// 调查 §1.3）：pics.javdb.com 的路径原样换域名。非
/// JavDB 图不改。
String javdbNoWatermarkUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.contains('javdb.com')) return url;
  return uri.replace(host: 'tp.spfcas.com').toString();
}

/// JSON 安全取值小工具（接口型适配器共用）。
String panJsonStr(Object? value) => value?.toString() ?? '';

List<dynamic> panJsonList(Object? value) => value is List ? value : const [];

Map<String, dynamic>? panJsonMap(Object? value) => value is Map<String, dynamic>
    ? value
    : (value is Map ? value.cast<String, dynamic>() : null);

Object? panDecodeJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 站点自动分类（2026-11-28 20:29 追加令：设置里的站点不许
// 平铺长名单，按适配器自描述自动归组）
// ---------------------------------------------------------------------------

/// 站点组别定稿（设置页按此序展示，组级可整组勾选）。
class PanSiteGroup {
  const PanSiteGroup(this.id, this.label);
  final String id;
  final String label;
}

const panSiteGroups = [
  PanSiteGroup('local', '本地库'),
  PanSiteGroup('coded', '番号 · 有码'),
  PanSiteGroup('uncensored', '番号 · 无码'),
  PanSiteGroup('fc2', 'FC2'),
  PanSiteGroup('cid', '素人 · 连写 cid'),
  PanSiteGroup('domestic', '国产成人'),
  PanSiteGroup('film_tmdb', '影视库 · TMDB 系'),
  PanSiteGroup('film_cn', '影视库 · 中文库'),
  PanSiteGroup('avatar', '演员资料'),
];

String panSiteGroupLabel(String groupId) {
  for (final group in panSiteGroups) {
    if (group.id == groupId) return group.label;
  }
  return groupId;
}

/// 分型 → 组别（兼属标注用）。
String _groupOfKind(PanScrapeKind kind, PanScrapeSiteSpec spec) =>
    switch (kind) {
      PanScrapeKind.coded => 'coded',
      PanScrapeKind.uncensored => 'uncensored',
      PanScrapeKind.fc2 => 'fc2',
      PanScrapeKind.cid => 'cid',
      PanScrapeKind.domestic => 'domestic',
      PanScrapeKind.film => spec.id == 'tmdb' ? 'film_tmdb' : 'film_cn',
    };

/// 自动归组判定（只看适配器自描述，不靠人工名单）：
/// 1. 本地库（method=local）→ 本地库组；
/// 2. 只给头像字段（fields ⊆ {actressAvatar}）→ 演员资料组；
/// 3. 适用类型含 film → 影视库组（tmdb 独成 TMDB 系，
///    其余中文库归中文库组）；
/// 4. 其余按自描述里**首要类型**（kinds 声明序第一位）
///    归组——规格书写顺序即站点定位（综合站以有码为主、
///    国产库以国产为主），新适配器照此声明即自动进组。
String panSiteGroupOf(PanScrapeSiteSpec spec) {
  if (spec.method == 'local') return 'local';
  if (spec.fields.isNotEmpty &&
      spec.fields.every((f) => f == 'actressAvatar')) {
    return 'avatar';
  }
  if (spec.kinds.contains(PanScrapeKind.film)) {
    return spec.id == 'tmdb' ? 'film_tmdb' : 'film_cn';
  }
  if (spec.kinds.isEmpty) return 'coded';
  return _groupOfKind(spec.kinds.first, spec);
}

/// 兼属组别：站点除主组外还服务的组（设置页组内标注
/// 「兼属：无码、FC2」），按适用类型逐个映射、去掉主组。
List<String> panSiteCrossGroupsOf(PanScrapeSiteSpec spec) {
  final primary = panSiteGroupOf(spec);
  final cross = <String>{};
  for (final kind in spec.kinds) {
    final group = _groupOfKind(kind, spec);
    if (group != primary) cross.add(group);
  }
  return [
    for (final group in panSiteGroups)
      if (cross.contains(group.id)) group.label,
  ];
}

/// 全部规格按组归置（组序＝定稿序，组内保持规格表序）。
Map<String, List<PanScrapeSiteSpec>> panGroupedSiteSpecs() {
  final out = <String, List<PanScrapeSiteSpec>>{
    for (final group in panSiteGroups) group.id: [],
  };
  for (final spec in panScrapeSiteSpecs.values) {
    out[panSiteGroupOf(spec)]!.add(spec);
  }
  return out;
}
