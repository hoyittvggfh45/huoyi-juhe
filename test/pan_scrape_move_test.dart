// 刮后归档全流程夹具演习（2026-11-28 补移动批）。
//
// 验收口径：假执行器 + 内存缓存，走完整条链——
// 刮成 → 规划 → 建夹/移动（假执行器记账）→ 缓存打归档
// 标记 → 重复执行幂等跳过；再验失败不连坐、未识别/未
// 刮成/分类未勾选三道闸各自拦得住、缓存标记在重刮后
// 保留（同一识别钥匙）。真账号实移不在此列（待真机验）。
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/cloud_drive/pan_scrape_archiver.dart';
import 'package:fqapp/cloud_drive/pan_scrape_archive.dart';
import 'package:fqapp/cloud_drive/pan_scrape_cache.dart';
import 'package:fqapp/cloud_drive/pan_scrape_identify.dart';
import 'package:fqapp/cloud_drive/pan_scrape_models.dart';
import 'package:fqapp/cloud_drive/pan_scrape_service.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings.dart';

/// 假执行器：记录每次调用，可按 provider 注入失败。
class _FakeExecutor implements PanDriveMoveExecutor {
  final calls = <({String providerId, String itemId, String folderName})>[];
  final Set<String> failProviders = {};

  @override
  Future<bool> moveToCategoryFolder({
    required String providerId,
    required String itemId,
    required String folderName,
  }) async {
    calls.add((
      providerId: providerId,
      itemId: itemId,
      folderName: folderName,
    ));
    return !failProviders.contains(providerId);
  }
}

PanScrapeOutcome _outcome(
  String fileName, {
  PanScrapedMeta? meta,
  bool complete = true,
}) {
  final identity = panIdentify(fileName);
  return PanScrapeOutcome(
    identity: identity,
    meta: meta,
    complete: complete,
    categoryId: panClassify(identity, meta),
    fromCache: false,
    visitedSites: const [],
  );
}

PanScrapedMeta _codedMeta() => const PanScrapedMeta(
  title: '某番号作品',
  cover: 'https://img/cover.jpg',
  poster: 'https://img/poster.jpg',
  stills: [],
  sourceSite: 'javdb',
);

PanScrapeArchiver _archiver(
  PanScrapeCache cache,
  _FakeExecutor executor, {
  PanScrapeSettings? settings,
}) => PanScrapeArchiver(
  settings: settings ?? PanScrapeDefaults.settings,
  cache: cache,
  executorFor: (_) => executor,
  nowMs: () => 1000,
);

PanArchiveJob _job(
  PanScrapeOutcome outcome, {
  String providerId = 'pan115',
  String itemKey = 'pan115|pan115:f1',
  String itemId = 'pan115:f1',
  String fileName = 'SSIS-001 x.mp4',
}) => PanArchiveJob(
  providerId: providerId,
  itemKey: itemKey,
  itemId: itemId,
  fileName: fileName,
  fromFolderId: '0',
  outcome: outcome,
);

void main() {
  group('归档全流程（刮成→移动→记账→幂等）', () {
    test('一条走通：执行器被调、缓存落标记、记账齐全', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      await cache.put('pan115|pan115:f1', 'coded:SSIS-001', _codedMeta());
      final executor = _FakeExecutor();
      final archiver = _archiver(cache, executor);

      final result = await archiver.archiveOne(
        _job(_outcome('SSIS-001 x.mp4', meta: _codedMeta())),
      );

      expect(result.moved, isTrue);
      expect(result.plan.categoryId, 'coded');
      expect(result.plan.folderName, '有码');
      expect(executor.calls, hasLength(1));
      expect(executor.calls.single.folderName, '有码');
      expect(executor.calls.single.itemId, 'pan115:f1');
      // 归档标记落在缓存里（幂等的根）。
      final record = await cache.byItem('pan115|pan115:f1');
      expect(record?.archivedCategory, 'coded');
      // 记账：源→目标→结果齐全。
      final entry = archiver.log.single;
      expect(entry.providerId, 'pan115');
      expect(entry.fromFolderId, '0');
      expect(entry.targetFolderName, '有码');
      expect(entry.moved, isTrue);
      expect(entry.skipped, isFalse);
    });

    test('重复执行：标记命中直接跳过，执行器不再被调', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      await cache.put('pan115|pan115:f1', 'coded:SSIS-001', _codedMeta());
      final executor = _FakeExecutor();
      final archiver = _archiver(cache, executor);
      final job = _job(_outcome('SSIS-001 x.mp4', meta: _codedMeta()));

      final first = await archiver.archiveOne(job);
      final second = await archiver.archiveOne(job);

      expect(first.moved, isTrue);
      expect(second.moved, isFalse);
      expect(second.skipped, isTrue);
      expect(second.reason, contains('跳过重复移动'));
      expect(executor.calls, hasLength(1));
      expect(archiver.log, hasLength(2));
      expect(archiver.log.last.skipped, isTrue);
    });

    test('批量：一条失败不连坐，其余照常归档', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      await cache.put('quark|quark:q1', 'coded:IPX-811', _codedMeta());
      await cache.put('pan115|pan115:f1', 'coded:SSIS-001', _codedMeta());
      final executor = _FakeExecutor()..failProviders.add('quark');
      final archiver = _archiver(cache, executor);

      final results = await archiver.archiveAll([
        _job(
          _outcome('IPX-811 y.mp4', meta: _codedMeta()),
          providerId: 'quark',
          itemKey: 'quark|quark:q1',
          itemId: 'quark:q1',
          fileName: 'IPX-811 y.mp4',
        ),
        _job(_outcome('SSIS-001 x.mp4', meta: _codedMeta())),
      ]);

      expect(results[0].moved, isFalse);
      expect(results[1].moved, isTrue);
      // 失败条目不打标记（下次还能重试），成功条目打了。
      expect(
        (await cache.byItem('quark|quark:q1'))?.archivedCategory,
        isEmpty,
      );
      expect(
        (await cache.byItem('pan115|pan115:f1'))?.archivedCategory,
        'coded',
      );
      expect(archiver.log, hasLength(2));
    });
  });

  group('三道闸在归档器层同样拦得住', () {
    test('真实移动开关关：不调执行器', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      final executor = _FakeExecutor();
      final archiver = _archiver(
        cache,
        executor,
        settings: PanScrapeDefaults.settings.copyWith(realMoveEnabled: false),
      );
      final result = await archiver.archiveOne(
        _job(_outcome('SSIS-001 x.mp4', meta: _codedMeta())),
      );
      expect(result.moved, isFalse);
      expect(result.reason, contains('未开启'));
      expect(executor.calls, isEmpty);
    });

    test('未刮成（缺封面/标题）：不调执行器', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      final executor = _FakeExecutor();
      final archiver = _archiver(cache, executor);
      final result = await archiver.archiveOne(
        _job(_outcome('SSIS-001 x.mp4', meta: null, complete: false)),
      );
      expect(result.moved, isFalse);
      expect(executor.calls, isEmpty);
    });

    test('未识别：不调执行器', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      final executor = _FakeExecutor();
      final archiver = _archiver(cache, executor);
      final result = await archiver.archiveOne(
        _job(
          _outcome('随手拍的一段视频.mp4', meta: null, complete: false),
          fileName: '随手拍的一段视频.mp4',
        ),
      );
      expect(result.moved, isFalse);
      expect(result.plan.categoryId, 'unidentified');
      expect(executor.calls, isEmpty);
    });

    test('分类未勾选：不调执行器', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      final executor = _FakeExecutor();
      final archiver = _archiver(
        cache,
        executor,
        settings: PanScrapeDefaults.settings.copyWith(
          enabledCategories: {'movie'},
        ),
      );
      final result = await archiver.archiveOne(
        _job(_outcome('SSIS-001 x.mp4', meta: _codedMeta())),
      );
      expect(result.moved, isFalse);
      expect(executor.calls, isEmpty);
    });
  });

  group('缓存归档标记', () {
    test('重刮 put 覆盖：同一识别钥匙标记保留、换钥匙作废', () async {
      final cache = PanScrapeMemoryCache(nowMs: () => 1000);
      await cache.put('k1', 'coded:SSIS-001', _codedMeta());
      await cache.markArchived('k1', 'coded');
      await cache.put('k1', 'coded:SSIS-001', _codedMeta());
      expect((await cache.byItem('k1'))?.archivedCategory, 'coded');
      await cache.put('k1', 'coded:IPX-811', _codedMeta());
      expect((await cache.byItem('k1'))?.archivedCategory, isEmpty);
    });

    test('记录 JSON 往返带标记；旧格式（无 arc 键）读出为空', () {
      final record = PanScrapeCacheRecord(
        atMs: 5,
        identityKey: 'coded:SSIS-001',
        meta: _codedMeta(),
        archivedCategory: 'coded',
      );
      final back = PanScrapeCacheRecord.fromJson(record.toJson());
      expect(back.archivedCategory, 'coded');
      final legacy = PanScrapeCacheRecord.fromJson(const {
        'at': 5,
        'idk': 'coded:SSIS-001',
        'meta': null,
      });
      expect(legacy.archivedCategory, isEmpty);
    });
  });
}
