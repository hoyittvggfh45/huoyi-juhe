/// 刮后分类归档（2026-11-28 20:16 追加令）：预置分类文
/// 件夹定稿名单＋判定规则，用户在设置里勾选启用哪些；
/// 条目刮完自动归入对应分类。
///
/// 落法两层（如实分工）：
/// 1. **虚拟分类视图**（已落地）：多媒体页按分类筛选展
///    示，不动网盘原文件——五家引擎都支持，默认开；
/// 2. **真实建夹＋移动**（2026-11-28 补移动批已接通）：
///    五家引擎（115/夸克/阿里/百度/移动云盘）已逐家补上
///    建夹/移动接口（各家已在用的鉴权/域名体系），执行器
///    是 pan_scrape_move_executor.dart 的
///    EnginePanDriveMoveExecutor（经引擎在根下建分类夹再
///    移入），归档编排在 pan_scrape_archiver.dart。防误移
///    口径不变：只移刮成（封面＋标题齐）且分类明确（非
///    未识别）的条目，未识别永不动。
library;

import 'pan_scrape_identify.dart';
import 'pan_scrape_models.dart';

/// 分类定稿（id → 中文名）。名单由用户令点名的 12 类定
/// 稿：电影/电视剧/动漫/纪录片/综艺/有码/无码/FC2/
/// 国产成人/欧美/素人/未识别。
class PanScrapeCategory {
  const PanScrapeCategory(this.id, this.label);
  final String id;
  final String label;
}

const panScrapeCategories = [
  PanScrapeCategory('movie', '电影'),
  PanScrapeCategory('tv', '电视剧'),
  PanScrapeCategory('anime', '动漫'),
  PanScrapeCategory('documentary', '纪录片'),
  PanScrapeCategory('variety', '综艺'),
  PanScrapeCategory('coded', '有码'),
  PanScrapeCategory('uncensored', '无码'),
  PanScrapeCategory('fc2', 'FC2'),
  PanScrapeCategory('domestic_adult', '国产成人'),
  PanScrapeCategory('western', '欧美'),
  PanScrapeCategory('amateur', '素人'),
  PanScrapeCategory('unidentified', '未识别'),
];

String panCategoryLabel(String id) {
  for (final category in panScrapeCategories) {
    if (category.id == id) return category.label;
  }
  return id;
}

/// 影视型细分关键词（文件名/标题特征判动漫/纪录片/综艺，
/// 与 MoviePilot 的类型词思路一致）。
final _animeWords = RegExp(r'动漫|动画|anime|番剧|剧场版', caseSensitive: false);
final _documentaryWords = RegExp(
  r'纪录片|纪录|documentary|bbc|国家地理|discovery',
  caseSensitive: false,
);
final _varietyWords = RegExp(r'综艺|真人秀|脱口秀|variety', caseSensitive: false);

/// 分类判定：识别分型优先，影视型再按 TMDB 媒体类型＋
/// 名称关键词细分。判定不出回 'unidentified'。
/// 规则（与分型一一对应，不串扰）：
/// - fc2 型 → FC2；uncensored 型 → 无码；domestic 型 →
///   国产成人；coded 型 → 有码（但主要来源是 theporndb
///   时归欧美）；cid 型 → 素人（连写 cid 多为 FANZA 素
///   人/同人作品）；
/// - film 型：动漫/纪录片/综艺关键词命中优先，其次
///   TMDB tv → 电视剧、movie → 电影；TMDB 没刮到时按季
///   集特征（有季集号 → 电视剧）兜底，再不行未识别；
/// - 刮削完全失败（meta 为 null）→ 未识别。
String panClassify(PanScrapeIdentity identity, PanScrapedMeta? meta) {
  if (meta == null) return 'unidentified';
  switch (identity.kind) {
    case PanScrapeKind.fc2:
      return 'fc2';
    case PanScrapeKind.uncensored:
      return 'uncensored';
    case PanScrapeKind.domestic:
      return 'domestic_adult';
    case PanScrapeKind.cid:
      return 'amateur';
    case PanScrapeKind.coded:
      if (meta.fieldSources.values.contains('theporndb') ||
          meta.sourceSite == 'theporndb') {
        return 'western';
      }
      return 'coded';
    case PanScrapeKind.film:
      final name = '${identity.rawName} ${meta.title}';
      if (_animeWords.hasMatch(name)) return 'anime';
      if (_documentaryWords.hasMatch(name)) return 'documentary';
      if (_varietyWords.hasMatch(name)) return 'variety';
      // TMDB 媒体类型藏在来源字段里没有直给，用 tmdbId 与
      // 标题解析的季集特征判：有季/集号按电视剧。
      final parsed = identity.parsed;
      if (parsed != null && (parsed.season != null || parsed.episode != null)) {
        return 'tv';
      }
      if (meta.tmdbId > 0) return 'movie';
      if (parsed != null && parsed.seriesTitle.isNotEmpty) return 'movie';
      return 'unidentified';
  }
}

/// 一条归档计划（真实移动层用）：目标分类文件夹名＋是否
/// 允许真移（防误移口径的判定结果）。
class PanArchivePlan {
  const PanArchivePlan({
    required this.categoryId,
    required this.folderName,
    required this.movable,
    required this.reason,
  });

  final String categoryId;
  final String folderName;

  /// 是否允许真实移动：刮成＋分类明确＋分类已勾选启用。
  final bool movable;
  final String reason;
}

/// 归档规划器：给条目算分类与可移性。虚拟视图只用
/// categoryId；真实移动层必须 movable 才许动文件。
PanArchivePlan panArchivePlanFor({
  required PanScrapeIdentity identity,
  required PanScrapedMeta? meta,
  required bool complete,
  required Set<String> enabledCategories,
}) {
  final categoryId = panClassify(identity, meta);
  final label = panCategoryLabel(categoryId);
  if (!complete) {
    return PanArchivePlan(
      categoryId: categoryId,
      folderName: label,
      movable: false,
      reason: '未刮成（封面＋标题未齐），不移动',
    );
  }
  if (categoryId == 'unidentified') {
    return PanArchivePlan(
      categoryId: categoryId,
      folderName: label,
      movable: false,
      reason: '未识别分类，永不移动（防误移口径）',
    );
  }
  if (!enabledCategories.contains(categoryId)) {
    return PanArchivePlan(
      categoryId: categoryId,
      folderName: label,
      movable: false,
      reason: '该分类未在设置里勾选启用',
    );
  }
  return PanArchivePlan(
    categoryId: categoryId,
    folderName: label,
    movable: true,
    reason: '刮成且分类明确，可移动',
  );
}

/// 五家引擎的建夹/移动能力账：2026-11-28 补移动批逐家
/// 给 provider 补上 createFolder/moveFile 后**五家全部
/// 点亮**（键是 provider 真实 id；上一批误写成 cloud139
/// 的键已订正为 yun139）。真账号实移未验（本机无五家账
/// 号），逐家列在补移动批报告的待真机验清单里。
const panDriveMoveCapability = <String, bool>{
  'pan115': true,
  'quark': true,
  'aliyun': true,
  'baidu': true,
  'yun139': true,
};

/// 真实移动执行器接口。树内实现是
/// EnginePanDriveMoveExecutor（pan_scrape_move_executor
/// .dart），经 CloudDriveEngine 落到各家 provider。
abstract class PanDriveMoveExecutor {
  /// 在 [providerId] 网盘根下确保分类文件夹存在并把条目
  /// 移入。返回是否真的移动成功。
  Future<bool> moveToCategoryFolder({
    required String providerId,
    required String itemId,
    required String folderName,
  });
}

/// 真实移动闸门：开关＋能力＋可移性三道都过才放行执行，
/// 任一不过回原因（页面/日志可查），绝不静默乱动文件。
Future<({bool moved, String reason})> panTryRealMove({
  required bool realMoveEnabled,
  required String providerId,
  required String itemId,
  required PanArchivePlan plan,
  required PanDriveMoveExecutor? executor,
}) async {
  if (!realMoveEnabled) return (moved: false, reason: '真实移动未开启');
  if (!plan.movable) return (moved: false, reason: plan.reason);
  if (panDriveMoveCapability[providerId] != true || executor == null) {
    return (moved: false, reason: '该网盘暂不支持真实移动（引擎能力未点亮或执行器未接入）');
  }
  final ok = await executor.moveToCategoryFolder(
    providerId: providerId,
    itemId: itemId,
    folderName: plan.folderName,
  );
  return (moved: ok, reason: ok ? '已移动' : '引擎移动失败');
}
