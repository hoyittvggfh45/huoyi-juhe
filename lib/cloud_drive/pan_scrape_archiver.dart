/// 刮后归档编排器（2026-11-28 补移动批）：把上一批的
/// 归档**规划器**接到**真执行**——刮削服务产出结果后，
/// 本编排器逐条过三道闸（真实移动开关、只移刮成且分类
/// 明确且分类已勾选、未识别永不动），过闸后经执行器在
/// 目标网盘根下建分类文件夹（已有不重建）并移入。
///
/// 口径（任务书钉死）：
/// - 逐条记账：每条尝试都落一条 [PanArchiveLogEntry]
///   （源文件夹→目标分类文件夹→成败与原因），批次日志
///   存在 [log] 里，页面/测试可读；
/// - 失败不连坐：单条失败只记该条，批内其余条目照常；
/// - 回滚提示：失败条目的 reason 如实带接口原因，用户
///   可在原文件夹里找到该文件（移动是原子的、没移成就
///   还在原地，不需要真回滚动作）；
/// - 幂等：移动成功立刻在刮削缓存打归档标记（分类
///   id），重复执行时标记一致直接跳过，不重复移；
/// - 只做移动归档这一件事：不删、不改名、不分享。
library;

import 'pan_scrape_archive.dart';
import 'pan_scrape_cache.dart';
import 'pan_scrape_move_executor.dart';
import 'pan_scrape_service.dart';
import 'pan_scrape_settings.dart';

/// 一条归档记账。
class PanArchiveLogEntry {
  const PanArchiveLogEntry({
    required this.atMs,
    required this.providerId,
    required this.itemKey,
    required this.fileName,
    required this.fromFolderId,
    required this.categoryId,
    required this.targetFolderName,
    required this.moved,
    required this.skipped,
    required this.reason,
  });

  final int atMs;

  /// 网盘 provider id（pan115/quark/aliyun/baidu/yun139）。
  final String providerId;

  /// 条目键（多媒体页 `_PanEntry.key`）。
  final String itemKey;
  final String fileName;

  /// 源文件夹 id（条目被刮时所在文件夹；根为各家根 id）。
  final String fromFolderId;

  /// 规划出的分类 id（未规划出时为空串）。
  final String categoryId;

  /// 目标分类文件夹名（与预置 12 类一致）。
  final String targetFolderName;

  /// 是否真的移动成功。
  final bool moved;

  /// 是否因已归档标记跳过（幂等命中，不算失败）。
  final bool skipped;
  final String reason;

  @override
  String toString() =>
      '[$providerId] $fileName（源 $fromFolderId）→ 「$targetFolderName」：'
      '${moved ? '已移动' : skipped ? '跳过' : '未移动'}（$reason）';
}

/// 一次归档尝试的结果。
class PanArchiveResult {
  const PanArchiveResult({
    required this.moved,
    required this.skipped,
    required this.reason,
    required this.plan,
  });

  final bool moved;
  final bool skipped;
  final String reason;
  final PanArchivePlan plan;
}

/// 一条待归档任务（批处理入参）。
class PanArchiveJob {
  const PanArchiveJob({
    required this.providerId,
    required this.itemKey,
    required this.itemId,
    required this.fileName,
    required this.outcome,
    this.fromFolderId = '',
  });

  final String providerId;
  final String itemKey;

  /// 引擎卡片 id 或裸文件 id（执行器内部归一）。
  final String itemId;
  final String fileName;
  final String fromFolderId;
  final PanScrapeOutcome outcome;
}

class PanScrapeArchiver {
  PanScrapeArchiver({
    required this.settings,
    required this.cache,
    required this.executorFor,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PanScrapeSettings settings;

  /// 与刮削服务共用同一份缓存：归档标记打在这里。
  final PanScrapeCache cache;

  /// 按 provider 取执行器（未登录/未接入时回 null）。
  final PanDriveMoveExecutor? Function(String providerId) executorFor;

  final int Function() _nowMs;

  /// 本编排器生命周期内的全部记账（逐条追加）。
  final List<PanArchiveLogEntry> log = <PanArchiveLogEntry>[];

  /// 归档一条。永不抛错：任何异常都落成一条失败记账。
  Future<PanArchiveResult> archiveOne(PanArchiveJob job) async {
    final plan = panArchivePlanFor(
      identity: job.outcome.identity,
      meta: job.outcome.meta,
      complete: job.outcome.complete,
      enabledCategories: settings.enabledCategories,
    );
    try {
      // 幂等闸：缓存标记与目标分类一致 → 已归档过，跳过。
      if (plan.movable) {
        final record = await cache.byItem(job.itemKey);
        if (record != null &&
            record.archivedCategory.isNotEmpty &&
            record.archivedCategory == plan.categoryId) {
          return _record(
            job,
            plan,
            moved: false,
            skipped: true,
            reason: '已归档入「${plan.folderName}」，跳过重复移动',
          );
        }
      }
      final executor = executorFor(job.providerId);
      final attempt = await panTryRealMove(
        realMoveEnabled: settings.realMoveEnabled,
        providerId: job.providerId,
        itemId: job.itemId,
        plan: plan,
        executor: executor,
      );
      var reason = attempt.reason;
      if (!attempt.moved &&
          executor is EnginePanDriveMoveExecutor &&
          executor.lastMoveError != null) {
        // 执行器拿到了接口层的真原因，记账用真原因。
        reason = executor.lastMoveError!;
      }
      if (attempt.moved) {
        await cache.markArchived(job.itemKey, plan.categoryId);
      }
      return _record(
        job,
        plan,
        moved: attempt.moved,
        skipped: false,
        reason: reason,
      );
    } catch (e) {
      return _record(
        job,
        plan,
        moved: false,
        skipped: false,
        reason: '归档失败：$e（文件未移动，仍在原文件夹）',
      );
    }
  }

  /// 批量归档：逐条串行，单条失败不连坐。
  Future<List<PanArchiveResult>> archiveAll(List<PanArchiveJob> jobs) async {
    final results = <PanArchiveResult>[];
    for (final job in jobs) {
      results.add(await archiveOne(job));
    }
    return results;
  }

  PanArchiveResult _record(
    PanArchiveJob job,
    PanArchivePlan plan, {
    required bool moved,
    required bool skipped,
    required String reason,
  }) {
    log.add(
      PanArchiveLogEntry(
        atMs: _nowMs(),
        providerId: job.providerId,
        itemKey: job.itemKey,
        fileName: job.fileName,
        fromFolderId: job.fromFolderId,
        categoryId: plan.categoryId,
        targetFolderName: plan.folderName,
        moved: moved,
        skipped: skipped,
        reason: reason,
      ),
    );
    return PanArchiveResult(
      moved: moved,
      skipped: skipped,
      reason: reason,
      plan: plan,
    );
  }
}
