import 'site_library.dart';

/// 内置站自动分类（2026-11-28 用户令「639 站点列表分类」）。
///
/// 分类不靠人工逐个排：每个站按登记元数据（分区 zone + 成人标记
/// adult）自动归类，今后站点增减只改登记数据、分类自动跟着变。
/// 主分类按内容形态分（影视 / 成人类按形态拆开 / 短剧 / 小说 /
/// 漫画 / 听书 / 直播），归不进已知分区的落 [SiteCategory.other]
/// 并由对账测试点名；大类（超过 [siteCategoryKindSplitThreshold]）
/// 再按来源形态（kind）二级分组：Python 站 / Jar 站 / 书源站 /
/// 原生站 / 直播源。
///
/// 本模块只做分类与分组，不决定可见性：成人站的境界分档门禁仍由
/// 调用方原有逻辑（visibleSiteIds 等）在组表前过滤，分类只对已
/// 可见的站排版，绝不把未解锁的站带进列表。
enum SiteCategory {
  film,
  adultFilm,
  drama,
  novel,
  adultNovel,
  comic,
  adultComic,
  audio,
  adultAudio,
  live,
  other,
}

extension SiteCategoryLabel on SiteCategory {
  String get label => switch (this) {
    SiteCategory.film => '影视',
    SiteCategory.adultFilm => '成人影视',
    SiteCategory.drama => '短剧',
    SiteCategory.novel => '小说',
    SiteCategory.adultNovel => '成人小说',
    SiteCategory.comic => '漫画',
    SiteCategory.adultComic => '成人漫画',
    SiteCategory.audio => '听书',
    SiteCategory.adultAudio => '成人听书',
    SiteCategory.live => '直播',
    SiteCategory.other => '其他',
  };
}

/// 一个站的分类元数据（从登记行抽出的最小集）。
typedef SiteCategoryMeta = ({String zone, bool adult, String kind});

/// 分类判定（纯函数）：只看分区与成人标记。
///
/// - video：非成人 → 影视，成人 → 成人影视；
/// - drama：短剧（短剧区自有分档，不按成人拆）；
/// - novel / comic / audio：按成人标记拆普通 / 成人两类；
/// - live：直播（直播站的成人标记在登记里恒为真，单成一类，
///   可见性仍归直播页与境界门禁原有逻辑管）；
/// - 未知分区 → 其他（对账时点名，不许静默吞掉）。
SiteCategory siteCategoryOf({required String zone, required bool adult}) {
  switch (zone) {
    case 'video':
      return adult ? SiteCategory.adultFilm : SiteCategory.film;
    case 'drama':
      return SiteCategory.drama;
    case 'novel':
      return adult ? SiteCategory.adultNovel : SiteCategory.novel;
    case 'comic':
      return adult ? SiteCategory.adultComic : SiteCategory.comic;
    case 'audio':
      return adult ? SiteCategory.adultAudio : SiteCategory.audio;
    case 'live':
      return SiteCategory.live;
    default:
      return SiteCategory.other;
  }
}

/// 来源形态（kind）的显示名与排序：二级分组用。
const siteKindOrder = <String>[
  'pyImport',
  'jarImport',
  'legadoImport',
  'nativeGate',
  'livePlatform',
  'liveM3u',
];

String siteKindLabel(String kind) => switch (kind) {
  'pyImport' => 'Python 站',
  'jarImport' => 'Jar 站',
  'legadoImport' => '书源站',
  'nativeGate' => '原生站',
  'livePlatform' => '直播平台',
  'liveM3u' => '直播源',
  _ => '其他来源',
};

int _kindRank(String kind) {
  final index = siteKindOrder.indexOf(kind);
  return index >= 0 ? index : siteKindOrder.length;
}

/// 大类二级拆分门槛：类内站数超过这个数才按来源形态再分组，
/// 小类保持一整组（避免几个站也拆出三四个空壳小标题）。现行
/// 639 站里只有成人影视（433）超过此线；小说（86）整组保留。
const siteCategoryKindSplitThreshold = 100;

/// 分类分组结果一段：类 + 类内站（保持输入原序）。
class SiteCategorySection<T> {
  const SiteCategorySection(this.category, this.items);

  final SiteCategory category;
  final List<T> items;

  int get count => items.length;
}

/// 按分类分组：段按 [SiteCategory] 声明顺序出，类内保持输入原序；
/// 空类不出段。分组是输入的一个划分——每项恰好进一段，不丢不重。
List<SiteCategorySection<T>> groupStationsByCategory<T>(
  Iterable<T> items,
  SiteCategoryMeta Function(T item) metaOf,
) {
  final byCategory = <SiteCategory, List<T>>{};
  for (final item in items) {
    final meta = metaOf(item);
    byCategory
        .putIfAbsent(
          siteCategoryOf(zone: meta.zone, adult: meta.adult),
          () => <T>[],
        )
        .add(item);
  }
  return [
    for (final category in SiteCategory.values)
      if ((byCategory[category] ?? const []).isNotEmpty)
        SiteCategorySection(category, byCategory[category]!),
  ];
}

/// 来源形态分组结果一段：kind + 显示名 + 段内站（保持输入原序）。
class SiteKindSection<T> {
  const SiteKindSection(this.kind, this.items);

  final String kind;
  final List<T> items;

  String get label => siteKindLabel(kind);
  int get count => items.length;
}

/// 按来源形态分组：段按 [siteKindOrder] 出，未知 kind 落最后一段
/// 「其他来源」；类内保持输入原序。
List<SiteKindSection<T>> groupStationsByKind<T>(
  Iterable<T> items,
  String Function(T item) kindOf,
) {
  final byKind = <String, List<T>>{};
  for (final item in items) {
    byKind.putIfAbsent(kindOf(item), () => <T>[]).add(item);
  }
  final kinds = byKind.keys.toList()
    ..sort((a, b) => _kindRank(a).compareTo(_kindRank(b)));
  return [
    for (final kind in kinds) SiteKindSection(kind, byKind[kind]!),
  ];
}

/// 站点库行 → 分类元数据。
SiteCategoryMeta siteCategoryMetaOfStation(SiteLibraryStation station) => (
  zone: station.zone,
  adult: station.isAdult,
  kind: station.kind,
);

/// 随包名单行 → 分类元数据。
SiteCategoryMeta siteCategoryMetaOfRoster(SiteLibraryRosterEntry entry) => (
  zone: entry.zone,
  adult: entry.adult,
  kind: entry.kind,
);
