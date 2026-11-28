/// 网盘刮削编排服务：识别 → 查缓存 → 按分型站点链逐站
/// 回退 → 字段级合并 → 成功门槛判定 → 落缓存 → 分类。
///
/// 纪律（调查 §4.5/§4.6 与用户令）：
/// - 单站限速：同站两次请求间隔不低于设置档（JavDB 2 秒
///   防封 IP）；失败重试有上限（适配器抛错才重试，查不到
///   不重试、不空打站点）；
/// - 增量刮：正缓存 30 天内不重刮；负缓存 6 小时内不重
///   试；手动重刮（force）绕过缓存；
/// - 刮成即停：合并结果封面＋标题齐（成功门槛）立刻停链，
///   不再打扰后面的站；
/// - 成人链总开关关时，番号/无码/FC2/cid/国产型直接落
///   未刮（不发任何请求），影视型不受影响。
library;

import 'dart:async';

import 'pan_scrape_adapter.dart';
import 'pan_scrape_adapters_impl.dart';
import 'pan_scrape_archive.dart';
import 'pan_scrape_cache.dart';
import 'pan_scrape_identify.dart';
import 'pan_scrape_models.dart';
import 'pan_scrape_settings.dart';

/// 女优头像补数（合并后按名补缺，测试注入点）。
typedef PanAvatarFiller = Future<String> Function(String name);

/// 一次刮削的结局。
class PanScrapeOutcome {
  const PanScrapeOutcome({
    required this.identity,
    required this.meta,
    required this.complete,
    required this.categoryId,
    required this.fromCache,
    required this.visitedSites,
  });

  final PanScrapeIdentity identity;

  /// 合并后的元数据；全链落空为 null。
  final PanScrapedMeta? meta;

  /// 是否刮成（成功门槛：封面＋标题齐）。
  final bool complete;

  /// 归档分类 id（pan_scrape_archive 定稿名单）。
  final String categoryId;

  final bool fromCache;

  /// 本次实际打过的站（记账/排障用）。
  final List<String> visitedSites;
}

class PanScrapeService {
  PanScrapeService({
    required this.settings,
    PanScrapeDeps? deps,
    Map<String, PanScrapeAdapter>? adapters,
    PanScrapeCache? cache,
    PanAvatarFiller? avatarFiller,
    Future<void> Function(Duration)? sleeper,
    int Function()? nowMs,
  }) : deps = deps ?? PanScrapeDeps(),
       adapters = adapters ?? panBuildAdapters(),
       cache =
           cache ?? PanScrapePrefsCache(maxEntries: settings.maxCacheEntries),
       _avatarFiller = avatarFiller,
       _sleeper = sleeper ?? ((d) => Future<void>.delayed(d)),
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PanScrapeSettings settings;
  final PanScrapeDeps deps;
  final Map<String, PanScrapeAdapter> adapters;
  final PanScrapeCache cache;
  final PanAvatarFiller? _avatarFiller;
  final Future<void> Function(Duration) _sleeper;
  final int Function() _nowMs;

  final _lastHitMs = <String, int>{};
  final _siteLocks = <String, Future<void>>{};

  bool get _adultAllowed => settings.adultChainEnabled;

  bool _isAdultKind(PanScrapeKind kind) => kind != PanScrapeKind.film;

  /// 刮一个条目。[itemKey] 是网盘条目唯一键（providerId|
  /// 条目 id），缓存按它与识别钥匙双索引。
  Future<PanScrapeOutcome> scrape(
    PanScrapeIdentity identity, {
    required String itemKey,
    bool force = false,
  }) async {
    // 成人链总开关：关了就不刮成人型（不发请求、不写负
    // 缓存——开关重开后应能立即刮）。
    if (_isAdultKind(identity.kind) && !_adultAllowed) {
      return PanScrapeOutcome(
        identity: identity,
        meta: null,
        complete: false,
        categoryId: 'unidentified',
        fromCache: false,
        visitedSites: const [],
      );
    }

    if (!force) {
      final cached =
          await cache.byItem(itemKey) ??
          await cache.byIdentity(identity.stableKey);
      if (cached != null) {
        final age = _nowMs() - cached.atMs;
        if (!cached.isNegative && age < settings.cacheTtl.inMilliseconds) {
          return _outcome(
            identity,
            cached.meta,
            fromCache: true,
            visited: const [],
          );
        }
        if (cached.isNegative &&
            age < settings.negativeCacheTtl.inMilliseconds) {
          return _outcome(identity, null, fromCache: true, visited: const []);
        }
      }
    }

    final chain = settings.chainFor(identity.chainKey);
    final bySite = <String, PanScrapedMeta>{};
    final visited = <String>[];
    PanScrapedMeta? merged;
    for (final siteId in chain) {
      final adapter = adapters[siteId];
      if (adapter == null) continue;
      visited.add(siteId);
      final meta = await _fetchWithRateLimit(adapter, identity);
      if (meta != null && !meta.isEmpty) {
        bySite[siteId] = meta;
        merged = PanScrapeMerger.merge(bySite, settings);
        if (_isComplete(merged)) break;
      }
    }
    merged ??= bySite.isEmpty ? null : PanScrapeMerger.merge(bySite, settings);
    if (merged != null && merged.isEmpty) merged = null;

    // 头像补缺：合并后仍缺头像的女优名，按 gFriends 等
    // 头像源补（注入了 filler 才做；补不到留空不编造）。
    if (merged != null &&
        _avatarFiller != null &&
        merged.actresses.isNotEmpty) {
      final avatars = Map<String, String>.from(merged.actressAvatars);
      var changed = false;
      for (final name in merged.actresses) {
        if (avatars.containsKey(name)) continue;
        try {
          final url = await _avatarFiller(name);
          if (url.isNotEmpty) {
            avatars[name] = url;
            changed = true;
          }
        } catch (_) {}
      }
      if (changed) {
        merged = PanScrapedMeta(
          title: merged.title,
          originalTitle: merged.originalTitle,
          cover: merged.cover,
          poster: merged.poster,
          coverNoWatermark: merged.coverNoWatermark,
          stills: merged.stills,
          overview: merged.overview,
          actresses: merged.actresses,
          actressAvatars: avatars,
          rating: merged.rating,
          releaseDate: merged.releaseDate,
          series: merged.series,
          maker: merged.maker,
          director: merged.director,
          durationMinutes: merged.durationMinutes,
          code: merged.code,
          tmdbId: merged.tmdbId,
          sourceSite: merged.sourceSite,
          fieldSources: merged.fieldSources,
        );
      }
    }

    await cache.put(itemKey, identity.stableKey, merged);
    return _outcome(identity, merged, fromCache: false, visited: visited);
  }

  bool _isComplete(PanScrapedMeta meta) =>
      settings.successNeedsCoverAndTitle ? meta.isComplete : !meta.isEmpty;

  PanScrapeOutcome _outcome(
    PanScrapeIdentity identity,
    PanScrapedMeta? meta, {
    required bool fromCache,
    required List<String> visited,
  }) {
    return PanScrapeOutcome(
      identity: identity,
      meta: meta,
      complete: meta != null && _isComplete(meta),
      categoryId: panClassify(identity, meta),
      fromCache: fromCache,
      visitedSites: visited,
    );
  }

  /// 单站取数：串行化同站请求＋最小间隔＋重试上限。
  Future<PanScrapedMeta?> _fetchWithRateLimit(
    PanScrapeAdapter adapter,
    PanScrapeIdentity identity,
  ) async {
    final siteId = adapter.id;
    final previous = _siteLocks[siteId] ?? Future<void>.value();
    final completer = Completer<void>();
    _siteLocks[siteId] = completer.future;
    await previous;
    try {
      final rate = settings.rateFor(siteId);
      final last = _lastHitMs[siteId];
      if (last != null && rate.minInterval > Duration.zero) {
        final wait = rate.minInterval.inMilliseconds - (_nowMs() - last);
        if (wait > 0) await _sleeper(Duration(milliseconds: wait));
      }
      final ctx = PanScrapeContext(
        identity: identity,
        settings: settings,
        deps: deps,
      );
      PanScrapedMeta? result;
      var attempts = 0;
      while (true) {
        attempts++;
        _lastHitMs[siteId] = _nowMs();
        try {
          result = await adapter.fetch(ctx);
          break;
        } catch (_) {
          if (attempts > rate.maxRetries) {
            result = null;
            break;
          }
        }
      }
      return result;
    } finally {
      completer.complete();
    }
  }
}
