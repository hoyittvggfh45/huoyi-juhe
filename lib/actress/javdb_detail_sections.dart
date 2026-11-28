// JavDB 详情三件共用组件（2026-11-28）：评论 / 相关清单 /
// 在线播放三页签，演员库作品详情页与片库详情页共用同一份。
//
// 口径：
// - 番号 → movieId 照 actressJavdbSupplement 的既有口径：
//   searchMovies 后番号归一精确相等才认；解析失败/无命中/
//   解析中整块不渲染（SizedBox.shrink），与详情页补数静默一致。
// - 样式走凡人自己的深紫霓虹主题（Neon 色板 +
//   actressNeonCardDecoration），不用 AvPlay 的粉红/大红配色。
// - 三页签各自独立懒加载 + 缓存：评论在解析成功后默认加载，
//   清单与在线播放在首次选中时才拉；切页签不重复拉。
// - 在线播放六家顺序照 javdbOnlineProviders；其中 AVDB /
//   JavMenu / MemoJav / MissAV 四行的 siteIds 改直写修仙树真
//   注册的 seed_ 站 id（seed_avdb / seed_javmenu / seed_memojav
//   / seed_missav）——常量里的魔蚁裸 id（'avdb' 等）与 jar id
//   在修仙树未注册，此前靠 SourceRegistry backing 兜底间接命
//   中才通，2026-11-28 补接批改直写、消掉隐性依赖，其余两家
//   （AV01 / Jable 的 jar id）照常量。
// - 本地站一并搜（2026-11-28 补接）：宿主传 localPlans 时，
//   在线页签行 = 固定六家 + 本地计划行（与六家同 siteId 的
//   剔除），探活走同一 CrossSiteProbeService；探到线路经
//   onProbeFound 交宿主接入其播放线路体系（新令「搜出来自动
//   接入播放线路」）。
// - 线路自动播放（2026-11-28 补接）：点开在线页签后才探活；
//   任一行探到 found 即经 onAutoPlayLine 交宿主起播，全页签
//   只触发一次、先到先得；用户手动点过或宿主以
//   autoPlaySuppressed 压住（数据库有自带线路、先播数据库）
//   时不触发。
// - 探活/拉数结果回来时组件已卸载或已切番号一律丢弃（代次守卫）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_crosssite_probe.dart';
import 'actress_javdb_api.dart';
import 'actress_neon.dart';
import 'actress_online_sources.dart' show actressCodeKey;

/// 片库详情页挂载判据（可测纯函数）：有番号才挂 JavDB 三件，
/// 无番号作品整块不出现。
bool javdbSectionsVisibleFor(String filmCode) => filmCode.isNotEmpty;

/// 六家在修仙树的真注册站 id：常量里的魔蚁裸 id / 未注册 jar
/// id 换成 seed_ 站 id 直写（缘由见文件头）。AV01 / Jable 的
/// jar id 在修仙树真注册，照常量不动。
const javdbSeedSiteIds = <String, String>{
  'avdb': 'seed_avdb',
  'javmenu': 'seed_javmenu',
  'memojav': 'seed_memojav',
  'missav': 'seed_missav',
};

/// 有效在线平台表：照 [javdbOnlineProviders] 顺序，仅把
/// [javdbSeedSiteIds] 里四行的 siteIds 换成直写 seed_ 站 id。
List<CrossSiteProvider> javdbEffectiveProviders() {
  return [
    for (final provider in javdbOnlineProviders)
      if (javdbSeedSiteIds.containsKey(provider.id))
        CrossSiteProvider(
          id: provider.id,
          name: provider.name,
          siteIds: [javdbSeedSiteIds[provider.id]!],
          lazy: provider.lazy,
        )
      else
        provider,
  ];
}

/// 在线页签一行：一家平台 + 实际探活的站 id。固定六家的站
/// id 来自有效平台表（直写 seed_）；本地计划行的站 id 来自
/// 计划本身。siteId 为 null = 无源计划行（显示「未接入」，
/// 不探活）。
class JavdbOnlineRow {
  const JavdbOnlineRow({required this.provider, required this.siteId});

  final CrossSiteProvider provider;
  final String? siteId;
}

/// 页签行合并（可测纯函数）：固定六家在前（序照
/// [javdbEffectiveProviders]），本地计划行随后；与六家同
/// siteId 的本地行剔除（同一站不出现两行），provider id 已
/// 被占用的本地行也剔除（结果表按 provider id 索引）。
List<JavdbOnlineRow> javdbMergedOnlineRows(
  List<CrossSiteProvider> fixed,
  List<CrossSiteRowPlan> localPlans,
) {
  final rows = <JavdbOnlineRow>[];
  final usedSiteIds = <String>{};
  final usedIds = <String>{};
  for (final provider in fixed) {
    final siteId = provider.siteIds.isEmpty ? null : provider.siteIds.first;
    rows.add(JavdbOnlineRow(provider: provider, siteId: siteId));
    if (siteId != null) usedSiteIds.add(siteId);
    usedIds.add(provider.id);
  }
  for (final plan in localPlans) {
    final siteId = plan.siteId;
    if (siteId != null && usedSiteIds.contains(siteId)) continue;
    if (!usedIds.add(plan.provider.id)) continue;
    if (siteId != null) usedSiteIds.add(siteId);
    rows.add(JavdbOnlineRow(provider: plan.provider, siteId: siteId));
  }
  return rows;
}

class JavdbDetailSections extends StatefulWidget {
  const JavdbDetailSections({
    super.key,
    required this.code,
    required this.client,
    required this.repository,
    required this.onPlayLine,
    this.probeService,
    this.localPlans = const [],
    this.onAutoPlayLine,
    this.onProbeFound,
    this.autoPlaySuppressed = false,
  });

  final String code;
  final JavdbApiClient client;
  final AppRepository repository;
  final Future<void> Function(CrossSiteVersion version, CrossSiteLine line)
  onPlayLine;

  /// 探活服务（测试注入）；为空时以 [repository] 现建。
  final CrossSiteProbeService? probeService;

  /// 本地站探活计划（宿主以 planCrossSiteRows 现算）：非空时
  /// 在线页签在固定六家之后追加本地行，一并按番号搜线路。
  final List<CrossSiteRowPlan> localPlans;

  /// 自动播回调：任一行探到 found 后，把该行首版本首线路交
  /// 宿主起播，返回是否真起播。全页签只成功触发一次、先到
  /// 先得；为空时不自动播（只点播）。
  final Future<bool> Function(CrossSiteVersion version, CrossSiteLine line)?
  onAutoPlayLine;

  /// 探到线路时回调宿主（新令「搜出来自动接入播放线路」：
  /// 宿主把线路接入自己的播放线路体系当真线路用）。
  final void Function(CrossSiteProbeResult result)? onProbeFound;

  /// 自动播压住（宿主口径，新令「数据库有就播放数据库」）：
  /// true 时探活与接入照常，自动播不触发；由 true 变 false
  /// （宿主判定数据库无线路落定）时再补触发。
  final bool autoPlaySuppressed;

  @override
  State<JavdbDetailSections> createState() => _JavdbDetailSectionsState();
}

/// 取数放根区跑：真客户端/仓储内部有联网超时定时器，挂在
/// 页面区（测试假时钟区）里会被扣住不放——片库详情页补全链
/// _callRealFilmFill 同一解法。结果经 Completer 回页面区。
Future<T> _rootRun<T>(Future<T> Function() body) {
  final completer = Completer<T>();
  Zone.root.run(() async {
    try {
      completer.complete(await body());
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  });
  return completer.future;
}

class _JavdbDetailSectionsState extends State<JavdbDetailSections> {
  late final CrossSiteProbeService _probeService =
      widget.probeService ??
      CrossSiteProbeService(repository: widget.repository);
  late final List<CrossSiteProvider> _providers = javdbEffectiveProviders();

  var _generation = 0;
  String? _movieId;
  var _tab = 0;

  // 评论页签状态。
  final _reviews = <JavdbReview>[];
  var _reviewsPage = 0;
  var _reviewsHasMore = false;
  var _reviewsLoading = false;
  var _reviewsLoaded = false;
  var _reviewsFailed = false;

  // 相关清单页签状态。
  List<JavdbRelatedList> _lists = const [];
  var _listsLoading = false;
  var _listsLoaded = false;
  var _listsFailed = false;

  // 在线播放页签状态。
  final _probeResults = <String, CrossSiteProbeResult>{};
  final _probing = <String>{};
  var _onlineStarted = false;

  // 自动播状态（本代 = 同番号）：只成功触发一次；用户手动
  // 点过任一线路后不再抢；已试过且宿主没起播的行不重复试。
  var _autoPlayDone = false;
  var _autoPlayBusy = false;
  var _manualPlayed = false;
  final _autoPlayTried = <String>{};

  /// 页签行：固定六家 + 本地计划行（合并规则见
  /// [javdbMergedOnlineRows]）。
  List<JavdbOnlineRow> get _rows =>
      javdbMergedOnlineRows(_providers, widget.localPlans);

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(JavdbDetailSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      unawaited(_resolve());
      return;
    }
    // 宿主压住解除（数据库无线路落定）时补触发自动播：
    // 已探到的 found 行直接拿来起播，不必等新探活。已试表
    // 一并清掉：压住期间宿主可能以更新鲜的状态拒过起播
    // （组件 prop 还没跟上），那几行不算真试过，解除后要
    // 能重试；真起播成功有 _autoPlayDone 挡、用户手点有
    // _manualPlayed 挡，多试一次无害。
    if (oldWidget.autoPlaySuppressed && !widget.autoPlaySuppressed) {
      _autoPlayTried.clear();
      _maybeAutoPlay();
    }
  }

  Future<void> _resolve() async {
    final generation = ++_generation;
    final code = widget.code;
    setState(() {
      _movieId = null;
      _tab = 0;
      _reviews.clear();
      _reviewsPage = 0;
      _reviewsHasMore = false;
      _reviewsLoading = false;
      _reviewsLoaded = false;
      _reviewsFailed = false;
      _lists = const [];
      _listsLoading = false;
      _listsLoaded = false;
      _listsFailed = false;
      _probeResults.clear();
      _probing.clear();
      _onlineStarted = false;
      _autoPlayDone = false;
      _autoPlayBusy = false;
      _manualPlayed = false;
      _autoPlayTried.clear();
    });
    final target = actressCodeKey(code);
    if (target.isEmpty) return;
    String? movieId;
    try {
      final hits = await _rootRun(() => widget.client.searchMovies(code));
      for (final movie in hits) {
        if (actressCodeKey(movie.number) == target) {
          movieId = movie.id;
          break;
        }
      }
    } catch (_) {
      movieId = null;
    }
    if (!mounted || generation != _generation) return;
    if (movieId == null || movieId.isEmpty) return;
    setState(() => _movieId = movieId);
    unawaited(_loadReviews());
  }

  // ---- 评论 ----

  Future<void> _loadReviews({bool more = false}) async {
    final movieId = _movieId;
    if (movieId == null || _reviewsLoading) return;
    if (more && !_reviewsHasMore) return;
    final generation = _generation;
    final page = more ? _reviewsPage + 1 : 1;
    setState(() {
      _reviewsLoading = true;
      _reviewsFailed = false;
    });
    List<JavdbReview> rows;
    var failed = false;
    try {
      rows = await _rootRun(
        () => widget.client.movieReviews(movieId, page: page),
      );
    } catch (_) {
      rows = const [];
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _reviewsLoading = false;
      _reviewsLoaded = true;
      _reviewsFailed = failed && page == 1 && _reviews.isEmpty;
      if (!failed) {
        if (page == 1) _reviews.clear();
        _reviews.addAll(rows);
        _reviewsPage = page;
        _reviewsHasMore = rows.length >= 10;
      }
    });
  }

  // ---- 相关清单 ----

  Future<void> _loadLists() async {
    final movieId = _movieId;
    if (movieId == null || _listsLoading || _listsLoaded) return;
    final generation = _generation;
    setState(() {
      _listsLoading = true;
      _listsFailed = false;
    });
    List<JavdbRelatedList> rows;
    var failed = false;
    try {
      rows = await _rootRun(() => widget.client.movieRelatedLists(movieId));
    } catch (_) {
      rows = const [];
      failed = true;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _listsLoading = false;
      _listsLoaded = true;
      _listsFailed = failed;
      if (!failed) _lists = rows;
    });
  }

  // ---- 在线播放 ----

  void _startOnlineIfNeeded() {
    if (_onlineStarted) return;
    _onlineStarted = true;
    for (final row in _rows) {
      if (!row.provider.lazy) unawaited(_probe(row));
    }
  }

  Future<void> _probe(JavdbOnlineRow row) async {
    final provider = row.provider;
    if (_probing.contains(provider.id)) return;
    if (_probeResults[provider.id]?.status == CrossSiteProbeStatus.found) {
      return;
    }
    final siteId = row.siteId;
    if (siteId == null || siteId.isEmpty) return;
    final generation = _generation;
    final code = widget.code;
    setState(() => _probing.add(provider.id));
    final result = await _rootRun(
      () => _probeService.probeProvider(provider, siteId, code),
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _probing.remove(provider.id);
      _probeResults[provider.id] = result;
    });
    // 探到线路：先交宿主接入其播放线路体系（新令「搜出来
    // 自动接入播放线路」），再看自动播（先到先得）。
    if (result.status == CrossSiteProbeStatus.found) {
      widget.onProbeFound?.call(result);
      _maybeAutoPlay();
    }
  }

  /// 线路 chip 手动点播：记下「用户已手动播」，迟到的自动
  /// 播不再抢占。
  void _playLineManually(CrossSiteVersion version, CrossSiteLine line) {
    _manualPlayed = true;
    unawaited(widget.onPlayLine(version, line));
  }

  /// 自动播：按行序找第一个还没试过的 found 行，把其首版本
  /// 首线路交宿主预检起播；宿主真起播了才算触发（置
  /// [_autoPlayDone]），没起播（解不出地址等）换下一行试。
  /// 压住中 / 已触发 / 正在试 / 用户手动播过，一律不触发。
  void _maybeAutoPlay() {
    if (widget.onAutoPlayLine == null) return;
    if (widget.autoPlaySuppressed) return;
    if (_autoPlayDone || _autoPlayBusy || _manualPlayed) return;
    for (final row in _rows) {
      final result = _probeResults[row.provider.id];
      if (result == null || result.status != CrossSiteProbeStatus.found) {
        continue;
      }
      if (_autoPlayTried.contains(row.provider.id)) continue;
      if (result.versions.isEmpty) continue;
      final version = result.versions.first;
      if (version.lines.isEmpty) continue;
      _autoPlayTried.add(row.provider.id);
      _autoPlayBusy = true;
      final generation = _generation;
      final callback = widget.onAutoPlayLine!;
      unawaited(() async {
        var started = false;
        try {
          started = await callback(version, version.lines.first);
        } catch (_) {
          started = false;
        }
        _autoPlayBusy = false;
        if (!mounted || generation != _generation) return;
        if (started) {
          _autoPlayDone = true;
          return;
        }
        // 这行没起成：若期间用户没手动播，换下一行 found 试。
        _maybeAutoPlay();
      }());
      return;
    }
  }

  void _selectTab(int index) {
    if (_tab == index) return;
    setState(() => _tab = index);
    if (index == 0 && !_reviewsLoaded && !_reviewsLoading) {
      unawaited(_loadReviews());
    }
    if (index == 1) unawaited(_loadLists());
    if (index == 2) _startOnlineIfNeeded();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_movieId == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('javdb-detail-sections'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: actressNeonCardDecoration(radius: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _tabPill('评论', 0),
              const SizedBox(width: 8),
              _tabPill('相关清单', 1),
              const SizedBox(width: 8),
              _tabPill('在线播放', 2),
            ],
          ),
          const SizedBox(height: 12),
          if (_tab == 0) _reviewsTab(),
          if (_tab == 1) _listsTab(),
          if (_tab == 2) _onlineTab(),
        ],
      ),
    );
  }

  Widget _tabPill(String label, int index) {
    final selected = _tab == index;
    return GestureDetector(
      key: ValueKey('javdb-tab-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectTab(index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          gradient: selected ? Neon.edgeGradient : null,
          color: selected ? null : Neon.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Neon.violet.withValues(alpha: .8),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Neon.text : Neon.textDim,
          ),
        ),
      ),
    );
  }

  // ---- 评论页签 ----

  Widget _reviewsTab() {
    if (_reviewsFailed) {
      return _retryRow('评论加载失败，点按重试', () => _loadReviews());
    }
    if (_reviewsLoading && _reviews.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator(color: Neon.cyan)),
      );
    }
    if (_reviewsLoaded && _reviews.isEmpty) {
      return const Text(
        '暂无评论',
        style: TextStyle(color: Neon.textDim, fontSize: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final review in _reviews) _reviewRow(review),
        if (_reviewsHasMore)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('javdb-reviews-more'),
              onPressed: _reviewsLoading
                  ? null
                  : () => unawaited(_loadReviews(more: true)),
              child: Text(
                _reviewsLoading ? '加载中…' : '加载更多',
                style: const TextStyle(color: Neon.cyan, fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }

  Widget _reviewRow(JavdbReview review) {
    final meta = <String>[
      if (review.statusTitle.isNotEmpty) review.statusTitle,
      if (review.score > 0) '★ ${review.score.toStringAsFixed(1)}',
      '♥ ${review.likesCount}',
      if (review.createdAt.length >= 10) review.createdAt.substring(0, 10),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  review.username,
                  style: const TextStyle(
                    color: Neon.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                meta.join('  '),
                style: const TextStyle(color: Neon.textFaint, fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _reviewContent(review.content),
        ],
      ),
    );
  }

  /// 正文渲染：磁力子串渲染成可点文本，点按复制该磁力。
  Widget _reviewContent(String content) {
    final links = javdbMagnetLinksIn(content);
    if (links.isEmpty) {
      return Text(
        content,
        style: const TextStyle(color: Neon.textDim, fontSize: 13, height: 1.5),
      );
    }
    final spans = <InlineSpan>[];
    var rest = content;
    for (final link in links) {
      final index = rest.indexOf(link);
      if (index < 0) continue;
      if (index > 0) spans.add(TextSpan(text: rest.substring(0, index)));
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            key: ValueKey('javdb-review-magnet-$link'),
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: link));
              _snack('磁力链接已复制');
            },
            child: Text(
              link,
              style: const TextStyle(
                color: Neon.cyan,
                fontSize: 13,
                height: 1.5,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      );
      rest = rest.substring(index + link.length);
    }
    if (rest.isNotEmpty) spans.add(TextSpan(text: rest));
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: Neon.textDim, fontSize: 13, height: 1.5),
        children: spans,
      ),
    );
  }

  // ---- 相关清单页签 ----

  Widget _listsTab() {
    if (_listsFailed) {
      return _retryRow('相关清单加载失败，点按重试', () {
        _listsLoaded = false;
        return _loadLists();
      });
    }
    if (_listsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator(color: Neon.cyan)),
      );
    }
    if (_listsLoaded && _lists.isEmpty) {
      return const Text(
        '暂无相关清单',
        style: TextStyle(color: Neon.textDim, fontSize: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final list in _lists) _listRow(list)],
    );
  }

  Widget _listRow(JavdbRelatedList list) {
    return InkWell(
      key: ValueKey('javdb-list-${list.id}'),
      onTap: () => _showListSheet(list),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              list.name,
              style: const TextStyle(
                color: Neon.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '共 ${list.moviesCount} 部 · 浏览 ${list.viewsCount} · 收藏 ${list.collectionsCount}',
              style: const TextStyle(color: Neon.textFaint, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  void _showListSheet(JavdbRelatedList list) {
    final linkMatch = RegExp(r'https?://[^\s]+').firstMatch(list.shareInfo);
    final shareLink = linkMatch?.group(0) ?? '';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neon.surface,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              list.name,
              style: const TextStyle(
                color: Neon.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (list.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                list.description,
                style: const TextStyle(
                  color: Neon.textDim,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              '共 ${list.moviesCount} 部 · 浏览 ${list.viewsCount} · 收藏 ${list.collectionsCount}',
              style: const TextStyle(color: Neon.textDim, fontSize: 12.5),
            ),
            if (shareLink.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                shareLink,
                style: const TextStyle(color: Neon.cyan, fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              TextButton(
                key: const ValueKey('javdb-list-copy-share'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: shareLink));
                  if (!mounted) return;
                  _snack('链接已复制');
                },
                child: const Text(
                  '复制分享链接',
                  style: TextStyle(color: Neon.cyan, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- 在线播放页签 ----

  Widget _onlineTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final row in _rows) _providerRow(row)],
    );
  }

  Widget _providerRow(JavdbOnlineRow row) {
    final provider = row.provider;
    final result = _probeResults[provider.id];
    final probing = _probing.contains(provider.id);
    // 状态四分（2026-11-28 补接）：found 找到 / empty 真没有
    // / failed 查询失败 / unavailable 未接入（含无源计划行），
    // 文案各表一种，不许拿失败或未接入冒充未找到。慢源
    // （JavMenu/MemoJav）探活放长到 150 秒，没回来之前一直
    // 是 probing「查询中」，不会被误标未找到。
    final status = row.siteId == null
        ? CrossSiteProbeStatus.unavailable
        : probing
        ? CrossSiteProbeStatus.probing
        : (result?.status ??
              (provider.lazy
                  ? CrossSiteProbeStatus.lazy
                  : CrossSiteProbeStatus.probing));
    Widget trailing;
    VoidCallback? onRowTap;
    switch (status) {
      case CrossSiteProbeStatus.lazy:
        trailing = TextButton(
          key: ValueKey('javdb-probe-${provider.id}'),
          onPressed: () => unawaited(_probe(row)),
          child: const Text(
            '点击查询',
            style: TextStyle(color: Neon.cyan, fontSize: 12.5),
          ),
        );
      case CrossSiteProbeStatus.probing:
        trailing = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Neon.cyan,
              ),
            ),
            SizedBox(width: 6),
            Text('查询中…', style: TextStyle(color: Neon.textDim, fontSize: 12.5)),
          ],
        );
      case CrossSiteProbeStatus.found:
        trailing = const SizedBox.shrink();
      case CrossSiteProbeStatus.empty:
        trailing = const Text(
          '✗ 未找到',
          style: TextStyle(color: Neon.textFaint, fontSize: 12.5),
        );
      case CrossSiteProbeStatus.failed:
        trailing = const Text(
          '✗ 查询失败',
          style: TextStyle(color: Neon.textFaint, fontSize: 12.5),
        );
        onRowTap = () => unawaited(_probe(row));
      case CrossSiteProbeStatus.unavailable:
        trailing = const Text(
          '未接入',
          style: TextStyle(color: Neon.textFaint, fontSize: 12.5),
        );
    }
    return InkWell(
      key: ValueKey('javdb-provider-${provider.id}'),
      onTap: onRowTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    provider.name,
                    style: const TextStyle(
                      color: Neon.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                trailing,
              ],
            ),
            if (status == CrossSiteProbeStatus.found && result != null)
              _versionLines(result),
          ],
        ),
      ),
    );
  }

  Widget _versionLines(CrossSiteProbeResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final version in result.versions) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              version.label,
              style: const TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: _lineChips(version)),
        ],
      ],
    );
  }

  List<Widget> _lineChips(CrossSiteVersion version) {
    final chips = <Widget>[];
    var mainCount = 0;
    for (final line in version.lines) {
      final isMain = line.label.trim().isEmpty || line.label.trim() == '正片';
      final label = isMain ? '线路${++mainCount}' : line.label;
      chips.add(
        GestureDetector(
          key: ValueKey('javdb-line-chip-$label-${line.episodeIndex}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _playLineManually(version, line),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Neon.surfaceHigh,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Neon.cyan.withValues(alpha: .6)),
            ),
            child: Text(
              label,
              style: const TextStyle(color: Neon.cyan, fontSize: 12.5),
            ),
          ),
        ),
      );
    }
    return chips;
  }

  Widget _retryRow(String text, Future<void> Function() onRetry) {
    return InkWell(
      onTap: () => unawaited(onRetry()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(
          text,
          style: const TextStyle(color: Neon.textDim, fontSize: 13),
        ),
      ),
    );
  }
}
