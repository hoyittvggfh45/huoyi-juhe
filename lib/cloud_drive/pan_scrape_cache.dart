/// 网盘刮削持久缓存（调查 §4.6：结果落库缓存、增量刮、
/// 失败负缓存）：SharedPreferences 单键 JSON，按「网盘条
/// 目 ID」存一份、按「刮后番号/TMDB 标识」再索引一份——
/// 同一番号换个文件夹出现直接命中，不重复打站点。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'pan_scrape_models.dart';

/// 一条缓存记录：meta 为 null 表示负缓存（刮过但没刮到）。
class PanScrapeCacheRecord {
  const PanScrapeCacheRecord({
    required this.atMs,
    required this.identityKey,
    this.meta,
    this.archivedCategory = '',
  });

  final int atMs;
  final String identityKey;
  final PanScrapedMeta? meta;

  /// 归档标记（2026-11-28 补移动批）：本条目已被真实移动
  /// 归入的分类 id；空 = 未归档。归档幂等靠它：标记与目
  /// 标分类一致时重复执行直接跳过、不重复移。
  final String archivedCategory;

  bool get isNegative => meta == null;

  PanScrapeCacheRecord withArchivedCategory(String categoryId) =>
      PanScrapeCacheRecord(
        atMs: atMs,
        identityKey: identityKey,
        meta: meta,
        archivedCategory: categoryId,
      );

  Map<String, dynamic> toJson() => {
    'at': atMs,
    'idk': identityKey,
    'meta': meta?.toJson(),
    if (archivedCategory.isNotEmpty) 'arc': archivedCategory,
  };

  factory PanScrapeCacheRecord.fromJson(Map<String, dynamic> json) {
    final rawMeta = json['meta'];
    return PanScrapeCacheRecord(
      atMs: (json['at'] as num?)?.toInt() ?? 0,
      identityKey: json['idk']?.toString() ?? '',
      meta: rawMeta is Map<String, dynamic>
          ? PanScrapedMeta.fromJson(rawMeta)
          : null,
      archivedCategory: json['arc']?.toString() ?? '',
    );
  }
}

/// 缓存存取（可整体注入内存实现供测试）。
abstract class PanScrapeCache {
  Future<PanScrapeCacheRecord?> byItem(String itemKey);
  Future<PanScrapeCacheRecord?> byIdentity(String identityKey);
  Future<void> put(String itemKey, String identityKey, PanScrapedMeta? meta);

  /// 给条目打归档标记（记录不存在时不动）。同一条目重复
  /// 刮削（put 覆盖）时，只要识别钥匙没变，标记保留——
  /// 幂等不因重刮失效；钥匙变了（改名/换内容）标记作废。
  Future<void> markArchived(String itemKey, String categoryId);
  Future<void> remove(String itemKey);
}

/// SharedPreferences 实现：容量上限按最旧淘汰。
class PanScrapePrefsCache implements PanScrapeCache {
  PanScrapePrefsCache({
    Future<SharedPreferences> Function()? prefsProvider,
    this.maxEntries = 800,
    int Function()? nowMs,
  }) : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String storageKey = 'fanren_pan_scrape_cache_v1';

  final Future<SharedPreferences> Function() _prefsProvider;
  final int maxEntries;
  final int Function() _nowMs;

  Map<String, PanScrapeCacheRecord>? _items;
  Map<String, String>? _identityIndex;

  Future<void> _ensureLoaded() async {
    if (_items != null) return;
    _items = {};
    _identityIndex = {};
    try {
      final prefs = await _prefsProvider();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final items = decoded['items'];
      if (items is Map) {
        for (final entry in items.entries) {
          final value = entry.value;
          if (value is Map<String, dynamic>) {
            final record = PanScrapeCacheRecord.fromJson(value);
            _items![entry.key.toString()] = record;
            if (record.identityKey.isNotEmpty) {
              _identityIndex![record.identityKey] = entry.key.toString();
            }
          }
        }
      }
    } catch (_) {
      _items = {};
      _identityIndex = {};
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefsProvider();
      await prefs.setString(
        storageKey,
        jsonEncode({
          'items': {
            for (final entry in _items!.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      );
    } catch (_) {
      // 缓存写失败不挡刮削主流程。
    }
  }

  @override
  Future<PanScrapeCacheRecord?> byItem(String itemKey) async {
    await _ensureLoaded();
    return _items![itemKey];
  }

  @override
  Future<PanScrapeCacheRecord?> byIdentity(String identityKey) async {
    await _ensureLoaded();
    final itemKey = _identityIndex![identityKey];
    if (itemKey == null) return null;
    return _items![itemKey];
  }

  @override
  Future<void> put(
    String itemKey,
    String identityKey,
    PanScrapedMeta? meta,
  ) async {
    await _ensureLoaded();
    final previous = _items![itemKey];
    _items![itemKey] = PanScrapeCacheRecord(
      atMs: _nowMs(),
      identityKey: identityKey,
      meta: meta,
      // 归档标记保留：同一条目、同一识别钥匙的重刮不冲掉
      // 已归档标记（幂等）；钥匙变了标记自然作废。
      archivedCategory:
          previous != null && previous.identityKey == identityKey
          ? previous.archivedCategory
          : '',
    );
    if (identityKey.isNotEmpty) _identityIndex![identityKey] = itemKey;
    while (_items!.length > maxEntries) {
      final oldest = _items!.entries.reduce(
        (a, b) => a.value.atMs <= b.value.atMs ? a : b,
      );
      _items!.remove(oldest.key);
      if (oldest.value.identityKey.isNotEmpty) {
        _identityIndex!.remove(oldest.value.identityKey);
      }
    }
    await _persist();
  }

  @override
  Future<void> markArchived(String itemKey, String categoryId) async {
    await _ensureLoaded();
    final previous = _items![itemKey];
    if (previous == null) return;
    _items![itemKey] = previous.withArchivedCategory(categoryId);
    await _persist();
  }

  @override
  Future<void> remove(String itemKey) async {
    await _ensureLoaded();
    final removed = _items!.remove(itemKey);
    if (removed != null && removed.identityKey.isNotEmpty) {
      _identityIndex!.remove(removed.identityKey);
    }
    await _persist();
  }
}

/// 内存实现（测试用，语义与持久实现一致）。
class PanScrapeMemoryCache implements PanScrapeCache {
  PanScrapeMemoryCache({int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowMs;
  final _items = <String, PanScrapeCacheRecord>{};
  final _identityIndex = <String, String>{};

  @override
  Future<PanScrapeCacheRecord?> byItem(String itemKey) async => _items[itemKey];

  @override
  Future<PanScrapeCacheRecord?> byIdentity(String identityKey) async {
    final itemKey = _identityIndex[identityKey];
    return itemKey == null ? null : _items[itemKey];
  }

  @override
  Future<void> put(
    String itemKey,
    String identityKey,
    PanScrapedMeta? meta,
  ) async {
    final previous = _items[itemKey];
    _items[itemKey] = PanScrapeCacheRecord(
      atMs: _nowMs(),
      identityKey: identityKey,
      meta: meta,
      archivedCategory:
          previous != null && previous.identityKey == identityKey
          ? previous.archivedCategory
          : '',
    );
    if (identityKey.isNotEmpty) _identityIndex[identityKey] = itemKey;
  }

  @override
  Future<void> markArchived(String itemKey, String categoryId) async {
    final previous = _items[itemKey];
    if (previous == null) return;
    _items[itemKey] = previous.withArchivedCategory(categoryId);
  }

  @override
  Future<void> remove(String itemKey) async {
    final removed = _items.remove(itemKey);
    if (removed != null) _identityIndex.remove(removed.identityKey);
  }
}
