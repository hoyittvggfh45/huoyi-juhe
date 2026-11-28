/// 网盘多媒体主体（修仙版）：已登录网盘的媒体库浏览，对齐主聊
/// 魔蚁 MultimediaScreen 的形态与语义，按修仙版既有链路落地：
///
/// - 数据走 [CloudDriveContentClient]（站号 `cloud:<网盘id>`）：
///   网盘源切换（全部网盘聚合 + 逐家）、文件夹下钻（条目 id 的
///   `folder:` 前缀）、搜索（根目录走 [CloudDriveContentClient.search]、
///   下钻后走 [CloudDriveContentClient.searchIn]），与网盘当站的
///   片库流同一套引擎、同一份目录缓存；
/// - 卡片是海报墙（复用首页 [HomeMediaCard]）：文件夹与视频同格，
///   文件夹带「文件夹」角标；点文件夹下钻，点视频走
///   [openDramaSiteItem] 既有详情/播放链，不另开播放路径；
/// - 后台刮削补数（不阻塞列表、失败静默回落、不编数据）：文件名
///   解析后走 TMDB（[TmdbService]，自魔蚁 lib/tmdb 移植）补海报/
///   标题/简介与年份·类型副题；带番号的条目（含文件夹）另走
///   [PanCoverScrapeService] 按番号补真封面（本地女优库 → JavDB）。
///   魔蚁那条「成人刮削优先」前置链依赖魔蚁仓储的站源可见性
///   存储，修仙版没有对应物，未搬——番号作品由番号封面链兜底；
/// - 刮后真实归档（2026-11-28 补移动批）：刮出结果后经
///   [PanScrapeArchiver] 过三道闸，把刮成且分类明确的文件
///   移进网盘根下的分类文件夹（五家引擎建夹/移动已点亮，
///   逐条记账、失败不连坐、缓存归档标记防重复移）；
/// - 视图缓存与静默刷新、聚合去重、单盘失败落告警行，都照魔蚁
///   口径；未登录时是空态 + 「去网盘登录」跳 [CloudDriveScreen]
///   （登录/凭证/上传/离线管理页，与本主体分工不混）。
///
/// 首页「网盘」档的内容区用它（分类行右侧固定入口选中后显示）；
/// 登录管理仍走 [CloudDriveScreen]，从本主体的「管理」按钮或
/// 未登录空态进入，回来后自动重读登录态。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_site_content.dart';
import '../services/drama_site_play.dart';
import '../services/source_registry.dart';
import '../tmdb/tmdb_config.dart';
import '../tmdb/tmdb_metadata.dart';
import '../tmdb/tmdb_service.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import 'cloud_cover_scrape.dart';
import 'cloud_drive_client.dart';
import 'cloud_drive_factory.dart';
import 'pan_scrape_adapter.dart';
import 'pan_scrape_archiver.dart';
import 'pan_scrape_move_executor.dart';
import 'pan_scrape_adapters_impl.dart';
import 'pan_scrape_archive.dart';
import 'pan_scrape_cache.dart';
import 'pan_scrape_identify.dart';
import 'pan_scrape_models.dart';
import 'pan_scrape_service.dart';
import 'pan_scrape_settings.dart';
import 'pan_scrape_settings_page.dart';
import 'cloud_drive_screen.dart';
import 'cloud_drive_stations.dart';

/// 网盘客户端工厂（测试注入假网关的客户端；缺省按网盘 id 现建，
/// 与站表 clientFor 的 cloud 分支同一构造）。
typedef PanMediaClientFactory =
    CloudDriveContentClient Function(String providerId);

/// 番号封面取数（测试注入；缺省走 [PanCoverScrapeService] 真链）。
typedef PanMediaCoverFetcher = Future<String> Function(String code);

/// TMDB 元数据取数（测试注入；缺省走 [TmdbService] 真链）。
typedef PanMediaMetadataFetcher =
    Future<TmdbMetadata?> Function({
      required String title,
      String? year,
      String? typeHint,
    });

/// 点视频卡的打开动作（测试注入；缺省走 [openDramaSiteItem]）。
typedef PanMediaOpenItem =
    void Function(BuildContext context, String siteId, DramaSiteItem item);

/// 已登录网盘条目读取（测试注入；缺省读 [CloudDriveStations.entries]）。
typedef PanMediaDriveEntries = List<SourceEntry> Function();

class CloudMultimediaBody extends StatefulWidget {
  const CloudMultimediaBody({
    super.key,
    this.clientFactory,
    this.coverFetcher,
    this.metadataFetcher,
    this.onOpenItem,
    this.driveEntries,
    this.onOpenCloudLogin,
    this.scrapeSettings,
  });

  final PanMediaClientFactory? clientFactory;
  final PanMediaCoverFetcher? coverFetcher;
  final PanMediaMetadataFetcher? metadataFetcher;
  final PanMediaOpenItem? onOpenItem;
  final PanMediaDriveEntries? driveEntries;

  /// 未登录空态/管理按钮的跳转；缺省推 [CloudDriveScreen]。
  final VoidCallback? onOpenCloudLogin;

  /// 刮削设置覆盖（测试/外层指定时用；缺省读设置存取，
  /// 读不到用出厂默认档）。
  final PanScrapeSettings? scrapeSettings;

  @override
  State<CloudMultimediaBody> createState() => _CloudMultimediaBodyState();
}

/// 一条带归属网盘的条目（聚合视图里点卡/下钻要知道回哪个网盘）。
class _PanEntry {
  const _PanEntry(this.providerId, this.item);
  final String providerId;
  final DramaSiteItem item;
  String get key => '$providerId|${item.id}';
  bool get isFolder => CloudDriveContentClient.isFolderItemId(item.id);

  /// 引擎聚合的虚拟「全部」夹：点了是聚合视图，不参与刮削。
  bool get isAggregateFolder =>
      item.id == '${CloudDriveContentClient.folderItemPrefix}__all__';
}

class _CloudMultimediaBodyState extends State<CloudMultimediaBody> {
  static const _pageCacheCap = 32;

  final _searchController = TextEditingController();
  final _clients = <String, CloudDriveContentClient>{};

  List<SourceEntry> _drives = const [];
  String _driveIdsStamp = '';
  String _selectedSource = '';
  final _drillStack =
      <({String providerId, String categoryId, String title})>[];
  var _entries = const <_PanEntry>[];
  var _loading = false;
  var _error = '';
  var _warning = '';

  /// 刮削后的展示副本（条目 key → 副本），原条目身份不变。
  final _display = <String, DramaSiteItem>{};

  /// 刮削管线（pan_scrape_*）：合并元数据与归档分类按条目
  /// key 存，卡面/副题/分类筛选都读它。
  final _scrapeMeta = <String, PanScrapedMeta>{};
  final _scrapeCategory = <String, String>{};
  PanScrapeService? _scrapeService;

  /// 刮后真实归档编排器（补移动批）：与刮削服务共用同一
  /// 份缓存（归档标记打在那里）；服务重建时一并作废。
  PanScrapeArchiver? _archiver;
  String _categoryFilter = '';
  final _pageCache = <String, ({List<_PanEntry> entries, String warning})>{};
  var _generation = 0;
  var _tmdbConfig = const TmdbConfig();

  late PanScrapeSettings _scrapeSettings =
      widget.scrapeSettings ?? PanScrapeDefaults.settings;

  bool get _fakePipeline =>
      widget.coverFetcher != null || widget.metadataFetcher != null;

  PanScrapeService get _service {
    final existing = _scrapeService;
    if (existing != null) return existing;
    final PanScrapeService built;
    if (_fakePipeline) {
      built = PanScrapeService(
        settings: _scrapeSettings,
        adapters: {
          'local': _FakeCoverAdapter(widget.coverFetcher ?? (_) async => ''),
          'tmdb': _FakeTmdbAdapter(
            widget.metadataFetcher ??
                ({
                  required String title,
                  String? year,
                  String? typeHint,
                }) async => null,
            _tmdbConfig,
          ),
          for (final spec in panScrapeSiteSpecs.values)
            if (spec.id != 'local' && spec.id != 'tmdb')
              spec.id: PanSpecOnlyAdapter(spec),
        },
        cache: PanScrapeMemoryCache(),
        sleeper: (_) async {},
      );
    } else {
      final gfriends = PanGfriendsAvatarSource();
      final deps = PanScrapeDeps(tmdbConfig: _tmdbConfig);
      built = PanScrapeService(
        settings: _scrapeSettings,
        deps: deps,
        avatarFiller: (name) => gfriends.avatarFor(name, deps),
      );
    }
    _scrapeService = built;
    return built;
  }

  CloudDriveContentClient _client(String providerId) => _clients.putIfAbsent(
    providerId,
    () =>
        widget.clientFactory?.call(providerId) ??
        CloudDriveContentClient(providerId: providerId),
  );

  static String _providerIdOf(SourceEntry entry) =>
      entry.id.startsWith('cloud:') ? entry.id.substring(6) : entry.id;

  @override
  void initState() {
    super.initState();
    _syncDrives();
    unawaited(_loadTmdbConfig());
    if (widget.scrapeSettings == null && !_fakePipeline) {
      unawaited(_loadScrapeSettings());
    }
    if (_drives.isNotEmpty) unawaited(_load());
  }

  Future<void> _loadScrapeSettings() async {
    try {
      final loaded = await PanScrapeSettingsStore().load();
      if (!mounted) return;
      setState(() {
        _scrapeSettings = loaded;
        _scrapeService = null;
        _archiver = null;
      });
    } catch (_) {
      // 读不到就用出厂默认档，刮削是补数、不挡列表。
    }
  }

  Future<void> _loadTmdbConfig() async {
    try {
      final config = await TmdbConfig.load();
      if (mounted) setState(() => _tmdbConfig = config);
    } catch (_) {
      // 配置读不到就用缺省配置：刮削是补数，失败静默不挡列表。
    }
  }

  /// 重读已登录网盘条目；集合变了（登录/退出回来）就重置视图，
  /// 与魔蚁 didUpdateWidget 的口径一致。返回是否发生重置。
  bool _syncDrives() {
    final entries = widget.driveEntries?.call() ?? CloudDriveStations.entries;
    final stamp = entries.map((e) => e.id).join(',');
    if (stamp == _driveIdsStamp && _drives.isNotEmpty) return false;
    final changed = stamp != _driveIdsStamp;
    _drives = entries;
    _driveIdsStamp = stamp;
    if (changed) {
      _selectedSource = '';
      _drillStack.clear();
      _display.clear();
      _scrapeMeta.clear();
      _scrapeCategory.clear();
      _categoryFilter = '';
      _pageCache.clear();
      _entries = const [];
    }
    return changed;
  }

  @override
  void dispose() {
    _generation++;
    _searchController.dispose();
    super.dispose();
  }

  String _pageKey(String query) {
    if (_drillStack.isNotEmpty) {
      final top = _drillStack.last;
      return 'drill|${top.providerId}|${top.categoryId}|$query';
    }
    return 'root|$_selectedSource|$query';
  }

  void _cachePage(String key, List<_PanEntry> entries, String warning) {
    _pageCache.remove(key);
    _pageCache[key] = (entries: entries, warning: warning);
    while (_pageCache.length > _pageCacheCap) {
      _pageCache.remove(_pageCache.keys.first);
    }
  }

  Future<void> _load({bool clearFirst = false, bool dropCache = false}) async {
    if (_syncDrives() && _drives.isEmpty) {
      setState(() {
        _loading = false;
        _error = '';
        _warning = '';
      });
      return;
    }
    final query = _searchController.text.trim();
    final key = _pageKey(query);
    if (dropCache) _pageCache.remove(key);
    if (!dropCache) {
      final cached = _pageCache[key];
      if (cached != null) {
        final generation = ++_generation;
        setState(() {
          _entries = cached.entries;
          _warning = cached.warning;
          _loading = false;
          _error = '';
        });
        unawaited(_enrichAll(cached.entries, generation));
        unawaited(_refreshInBackground(key, query, generation));
        return;
      }
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
      if (clearFirst) _entries = const [];
    });
    try {
      final result = await _fetchView(query);
      if (!mounted || generation != _generation) return;
      _cachePage(key, result.entries, result.warning);
      setState(() {
        _entries = result.entries;
        _warning = result.warning;
        _loading = false;
      });
      unawaited(_enrichAll(result.entries, generation));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _errorText(error);
      });
    }
  }

  /// 缓存命中后的静默刷新：现拉与缓存比对，有变化才换上并回写；
  /// 没变化/失败都不动界面（照魔蚁口径）。
  Future<void> _refreshInBackground(
    String key,
    String query,
    int generation,
  ) async {
    try {
      final result = await _fetchView(query);
      if (!mounted || generation != _generation) return;
      final cached = _pageCache[key];
      if (cached == null || _sameEntries(cached.entries, result.entries)) {
        return;
      }
      _cachePage(key, result.entries, result.warning);
      setState(() {
        _entries = result.entries;
        _warning = result.warning;
      });
      unawaited(_enrichAll(result.entries, generation));
    } catch (_) {
      // 静默刷新失败：继续显示缓存页。
    }
  }

  bool _sameEntries(List<_PanEntry> a, List<_PanEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key ||
          a[i].item.title != b[i].item.title ||
          a[i].item.cover != b[i].item.cover) {
        return false;
      }
    }
    return true;
  }

  /// 取当前视图：下钻中只取所在夹；否则按选中网盘取，或聚合
  /// 全部网盘（去重、单盘失败落告警）。单目标失败抛给上层落错误态。
  Future<({List<_PanEntry> entries, String warning})> _fetchView(
    String query,
  ) async {
    if (_drillStack.isNotEmpty) {
      final top = _drillStack.last;
      final client = _client(top.providerId);
      final items = query.isEmpty
          ? (await client.catalog(top.categoryId, 1)).items
          : await client.searchIn(top.categoryId, query);
      return (
        entries: [for (final item in items) _PanEntry(top.providerId, item)],
        warning: '',
      );
    }
    final targets = _selectedSource.isEmpty
        ? _drives.map(_providerIdOf).toList()
        : [_selectedSource];
    if (targets.length == 1) {
      final client = _client(targets.first);
      final items = query.isEmpty
          ? (await client.catalog(
              CloudDriveContentClient.rootCategoryId,
              1,
            )).items
          : await client.search(query);
      return (
        entries: [for (final item in items) _PanEntry(targets.first, item)],
        warning: '',
      );
    }
    final entries = <_PanEntry>[];
    final seen = <String>{};
    final warnings = <String>[];
    for (final providerId in targets) {
      try {
        final client = _client(providerId);
        final items = query.isEmpty
            ? (await client.catalog(
                CloudDriveContentClient.rootCategoryId,
                1,
              )).items
            : await client.search(query);
        for (final item in items) {
          final entry = _PanEntry(providerId, item);
          if (seen.add(entry.key)) entries.add(entry);
        }
      } catch (error) {
        final name = _driveName(providerId);
        warnings.add('$name 加载失败：${_errorText(error)}');
      }
    }
    return (entries: entries, warning: warnings.join(' '));
  }

  String _driveName(String providerId) {
    for (final entry in _drives) {
      if (_providerIdOf(entry) == providerId) return entry.name;
    }
    return providerId;
  }

  String _errorText(Object error) {
    final text = error.toString();
    return text.isEmpty ? '加载失败，请检查网络后重试' : text;
  }

  // --------------------------------------------------------------------------
  // 刮削补数（后台、静默回落）
  // --------------------------------------------------------------------------

  DramaSiteItem _displayOf(_PanEntry entry) =>
      _display[entry.key] ?? entry.item;

  /// 刮削管线（pan_scrape_service）：识别分型 → 缓存 →
  /// 站点链回退 → 字段合并 → 分类，后台跑、不挡浏览与
  /// 播放；结果只改展示副本（标题/封面/副题），原条目身
  /// 份与打开链不动。未刮/刮不到时保持原文件名原样。
  Future<void> _enrichAll(List<_PanEntry> entries, int generation) async {
    final candidates = entries
        .where((e) => !e.isAggregateFolder)
        .take(_scrapeSettings.perPageCap)
        .toList();
    if (candidates.isEmpty) return;
    final service = _service;
    var next = 0;
    Future<void> worker() async {
      while (mounted && generation == _generation) {
        if (next >= candidates.length) return;
        final entry = candidates[next++];
        await _scrapeOne(service, entry, force: false);
        if (!mounted || generation != _generation) return;
      }
    }

    await Future.wait([
      for (var i = 0; i < _scrapeSettings.concurrency; i++) worker(),
    ]);
  }

  Future<void> _scrapeOne(
    PanScrapeService service,
    _PanEntry entry, {
    required bool force,
  }) async {
    final identity = panIdentify(entry.item.title);
    final PanScrapeOutcome outcome;
    if (!_scrapeSettings.autoScrape && !force) {
      // 自动刮关：只认缓存里已有的结果，不发新请求。
      final cached =
          await service.cache.byItem(entry.key) ??
          await service.cache.byIdentity(identity.stableKey);
      if (cached == null) return; // 没刮过：不下分类结论
      if (cached.isNegative) {
        if (mounted) {
          setState(() => _scrapeCategory[entry.key] = 'unidentified');
        }
        return;
      }
      outcome = PanScrapeOutcome(
        identity: identity,
        meta: cached.meta,
        complete: cached.meta!.isComplete,
        categoryId: panClassify(identity, cached.meta),
        fromCache: true,
        visitedSites: const [],
      );
    } else {
      outcome = await service.scrape(
        identity,
        itemKey: entry.key,
        force: force,
      );
    }
    if (!mounted) return;
    setState(() {
      _scrapeCategory[entry.key] = outcome.categoryId;
      final meta = outcome.meta;
      if (meta == null) return;
      _scrapeMeta[entry.key] = meta;
      final base = _display[entry.key] ?? entry.item;
      final scrapedCover = meta.displayCover(
        preferVertical: _scrapeSettings.preferVerticalPoster,
      );
      _display[entry.key] = DramaSiteItem(
        id: base.id,
        title: meta.title.isNotEmpty ? meta.title : base.title,
        cover: scrapedCover.isNotEmpty ? scrapedCover : base.cover,
        remark: base.remark,
      );
    });
    _maybeArchive(entry, outcome);
  }

  PanScrapeArchiver get _archiverInstance {
    final existing = _archiver;
    if (existing != null) return existing;
    final built = PanScrapeArchiver(
      settings: _scrapeSettings,
      cache: _service.cache,
      executorFor: (_) => EnginePanDriveMoveExecutor(
        engineProvider: CloudDriveFactory.engine,
      ),
    );
    _archiver = built;
    return built;
  }

  /// 刮后真实归档（补移动批）：开关开、非文件夹、非注入
  /// 假管线时，后台把刮成且分类明确的条目移进网盘分类
  /// 文件夹。三道闸与幂等都在归档器里把；这里失败全静
  /// 默（归档是补数动作、不挡浏览，逐条原因在归档器记账
  /// 里）。注意：条目移走后当前页的展示副本仍在，刷新/
  /// 重进文件夹后以网盘实况为准。
  void _maybeArchive(_PanEntry entry, PanScrapeOutcome outcome) {
    if (!_scrapeSettings.realMoveEnabled) return;
    if (_fakePipeline) return;
    if (entry.item.id.startsWith('folder:')) return;
    unawaited(_archive(entry, outcome));
  }

  /// 条目当前所在文件夹（记账用）：取下钻栈里该网盘最深
  /// 一层的文件夹 id；没下钻过就是根目录（记空串）。
  String _currentFolderIdOf(String providerId) {
    for (final level in _drillStack.reversed) {
      if (level.providerId != providerId) continue;
      const prefix = 'folder:';
      return level.categoryId.startsWith(prefix)
          ? level.categoryId.substring(prefix.length)
          : level.categoryId;
    }
    return '';
  }

  Future<void> _archive(_PanEntry entry, PanScrapeOutcome outcome) async {
    try {
      await _archiverInstance.archiveOne(
        PanArchiveJob(
          providerId: entry.providerId,
          itemKey: entry.key,
          itemId: entry.item.id,
          fileName: entry.item.title,
          fromFolderId: _currentFolderIdOf(entry.providerId),
          outcome: outcome,
        ),
      );
    } catch (_) {
      // 归档失败静默：原因在归档器记账里，文件仍在原地。
    }
  }

  /// 手动重刮（长按卡片）：绕缓存强制重走链，结果用
  /// SnackBar 明示——刮成报标题、没刮到报保持原名。
  Future<void> _rescrapeEntry(_PanEntry entry) async {
    final outcome = await _service.scrape(
      panIdentify(entry.item.title),
      itemKey: entry.key,
      force: true,
    );
    if (!mounted) return;
    await _scrapeOne(_service, entry, force: false);
    final messenger = ScaffoldMessenger.of(context);
    if (outcome.meta != null && outcome.complete) {
      messenger.showSnackBar(
        SnackBar(content: Text('已刮到：${outcome.meta!.title}')),
      );
    } else if (outcome.meta != null) {
      messenger.showSnackBar(const SnackBar(content: Text('刮到部分信息，封面或标题仍缺')));
    } else {
      messenger.showSnackBar(const SnackBar(content: Text('没刮到，保持原文件名')));
    }
  }

  Future<void> _openScrapeSettings() async {
    final next = await Navigator.of(context).push<PanScrapeSettings>(
      MaterialPageRoute(
        builder: (_) => PanScrapeSettingsPage(initial: _scrapeSettings),
      ),
    );
    if (!mounted || next == null) return;
    setState(() {
      _scrapeSettings = next;
      _scrapeService = null;
      _archiver = null;
      if (!_scrapeSettings.archiveViewEnabled) _categoryFilter = '';
    });
    unawaited(_enrichAll(_entries, _generation));
  }

  // --------------------------------------------------------------------------
  // 交互
  // --------------------------------------------------------------------------

  void _onTapEntry(_PanEntry entry) {
    if (entry.isFolder) {
      setState(() {
        _drillStack.add((
          providerId: entry.providerId,
          categoryId: entry.item.id,
          title: entry.item.title,
        ));
        _searchController.clear();
      });
      unawaited(_load(clearFirst: true));
      return;
    }
    final display = _displayOf(entry);
    final siteId = 'cloud:${entry.providerId}';
    final opener = widget.onOpenItem;
    if (opener != null) {
      opener(context, siteId, display);
    } else {
      unawaited(openDramaSiteItem(context, siteId, display));
    }
  }

  void _onBack() {
    if (_drillStack.isEmpty) return;
    setState(() {
      _drillStack.removeLast();
      _searchController.clear();
    });
    unawaited(_load(clearFirst: true));
  }

  void _onSelectDrive(String providerId) {
    if (_selectedSource == providerId) return;
    setState(() {
      _selectedSource = providerId;
      _drillStack.clear();
      _searchController.clear();
    });
    unawaited(_load(clearFirst: true));
  }

  Future<void> _openCloudLogin() async {
    final opener = widget.onOpenCloudLogin;
    if (opener != null) {
      opener();
      return;
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CloudDriveScreen()));
    if (!mounted) return;
    // 登录/退出可能已发生：重读条目并重拉当前视图。
    _syncDrives();
    unawaited(_load(clearFirst: true, dropCache: true));
  }

  String? _subtitleFor(_PanEntry entry) {
    final scraped = _scrapeMeta[entry.key];
    if (scraped != null) {
      final parts = <String>[
        if (scraped.releaseDate.isNotEmpty)
          scraped.releaseDate.length >= 4
              ? scraped.releaseDate.substring(0, 4)
              : scraped.releaseDate,
        if (scraped.actresses.isNotEmpty) scraped.actresses.first,
        if (scraped.rating.isNotEmpty) '评分 ${scraped.rating}',
      ];
      if (parts.isNotEmpty) return parts.join(' · ');
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // 界面
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_drives.isEmpty) return _loggedOutView();
    return Column(
      key: const ValueKey('pan-multimedia-body'),
      children: [
        _driveRow(),
        _searchRow(),
        if (_scrapeSettings.archiveViewEnabled) _categoryRow(),
        if (_drillStack.isNotEmpty) _breadcrumbRow(),
        if (_error.isNotEmpty && _entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              _error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (_warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              _warning,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _loggedOutView() {
    return Center(
      key: const ValueKey('pan-multimedia-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            const Text('还没有登录任何网盘', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              '登录 115 / 夸克 / 阿里 / 百度 / 移动云盘后，'
              '这里会把网盘里的视频按海报墙显示出来',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('pan-multimedia-login-button'),
              onPressed: () => unawaited(_openCloudLogin()),
              child: const Text('去网盘登录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _driveRow() {
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 2, 2),
            child: Row(
              children: [
                ChoiceChip(
                  key: const ValueKey('pan-multimedia-drive-chip-all'),
                  label: const Text('全部网盘'),
                  selected: _selectedSource.isEmpty,
                  onSelected: (_) => _onSelectDrive(''),
                ),
                const SizedBox(width: 8),
                for (final entry in _drives) ...[
                  ChoiceChip(
                    key: ValueKey('pan-multimedia-drive-chip-${entry.id}'),
                    label: Text(entry.name),
                    selected: _selectedSource == _providerIdOf(entry),
                    onSelected: (_) => _onSelectDrive(_providerIdOf(entry)),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('pan-multimedia-scrape-settings'),
          icon: const Icon(Icons.tune),
          tooltip: '刮削设置',
          onPressed: () => unawaited(_openScrapeSettings()),
        ),
        IconButton(
          key: const ValueKey('pan-multimedia-manage'),
          icon: const Icon(Icons.manage_accounts_outlined),
          tooltip: '网盘登录与管理',
          onPressed: () => unawaited(_openCloudLogin()),
        ),
      ],
    );
  }

  /// 刮后分类筛选行（虚拟归档视图）：只列当前页真出现
  /// 过、且设置里勾选启用的分类；选中后海报墙只显该类。
  Widget _categoryRow() {
    final present = <String>{
      for (final entry in _entries)
        if (_scrapeCategory[entry.key] != null) _scrapeCategory[entry.key]!,
    };
    final chips = [
      for (final category in panScrapeCategories)
        if (present.contains(category.id) &&
            _scrapeSettings.enabledCategories.contains(category.id))
          category,
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          ChoiceChip(
            key: const ValueKey('pan-multimedia-category-all'),
            label: const Text('全部分类'),
            selected: _categoryFilter.isEmpty,
            onSelected: (_) => setState(() => _categoryFilter = ''),
          ),
          const SizedBox(width: 8),
          for (final category in chips) ...[
            ChoiceChip(
              key: ValueKey('pan-multimedia-category-${category.id}'),
              label: Text(category.label),
              selected: _categoryFilter == category.id,
              onSelected: (_) => setState(() => _categoryFilter = category.id),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('pan-multimedia-search'),
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: '搜索网盘视频',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('pan-multimedia-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => unawaited(_load(dropCache: true)),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumbRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('pan-multimedia-back'),
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回上一级',
            onPressed: _onBack,
          ),
          Expanded(
            child: Text(
              _drillStack.map((e) => e.title).join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty && _entries.isEmpty) {
      return Center(
        key: const ValueKey('pan-multimedia-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => unawaited(_load(dropCache: true)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('这里空空如也'));
    }
    final visible = _categoryFilter.isEmpty
        ? _entries
        : [
            for (final entry in _entries)
              if ((_scrapeCategory[entry.key] ?? 'unidentified') ==
                  _categoryFilter)
                entry,
          ];
    if (visible.isEmpty) {
      return const Center(child: Text('该分类下暂无条目'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        final cardWidth =
            (constraints.maxWidth -
                homeGutter * 2 -
                (columns - 1) * homeGridGap) /
            columns;
        final scaler = MediaQuery.textScalerOf(context);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: homeGridGap,
            mainAxisSpacing: 20,
            mainAxisExtent: homeCardExtent(context, cardWidth, scaler),
          ),
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final entry = visible[index];
            final display = _displayOf(entry);
            return GestureDetector(
              key: ValueKey('pan-media-wrap-${entry.key}'),
              behavior: HitTestBehavior.deferToChild,
              onLongPress: () => unawaited(_rescrapeEntry(entry)),
              child: HomeMediaCard(
                key: ValueKey('pan-media-${entry.key}'),
                item: MediaItem(
                  id: display.id,
                  title: display.title,
                  cover: display.cover,
                  author: '',
                  badge: entry.isFolder ? '文件夹' : '',
                  ep: _subtitleFor(entry) ?? display.remark,
                  kind: 'film',
                ),
                coverWidth: cardWidth,
                onTap: () => _onTapEntry(entry),
              ),
            );
          },
        );
      },
    );
  }
}

/// 测试注入的假本地适配器：把 widget 的 coverFetcher 包成
/// 「本地库」一站（回封面即视为本地命中）。
class _FakeCoverAdapter extends PanScrapeAdapter {
  _FakeCoverAdapter(this._fetch);
  final PanMediaCoverFetcher _fetch;

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['local']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    if (code == null || code.isEmpty) return null;
    final cover = await _fetch(code);
    if (cover.isEmpty) return null;
    return PanScrapedMeta(
      cover: cover,
      poster: cover,
      code: code,
      sourceSite: 'local',
    );
  }
}

/// 测试注入的假 TMDB 适配器：把 widget 的 metadataFetcher
/// 包成 TMDB 一站，映射口径与 PanTmdbAdapter 一致。
class _FakeTmdbAdapter extends PanScrapeAdapter {
  _FakeTmdbAdapter(this._fetch, this._config);
  final PanMediaMetadataFetcher _fetch;
  final TmdbConfig _config;

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['tmdb']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final parsed = ctx.identity.parsed;
    if (parsed == null) return null;
    final meta = await _fetch(title: parsed.searchTitle, year: parsed.year);
    if (meta == null) return null;
    return PanScrapedMeta(
      title: meta.title,
      originalTitle: meta.originalTitle,
      cover: meta.backdropUrl(_config),
      poster: meta.posterUrl(_config),
      overview: meta.overview,
      rating: meta.voteAverage?.toString() ?? '',
      releaseDate: meta.year,
      tmdbId: meta.tmdbId,
      sourceSite: 'tmdb',
    );
  }
}
