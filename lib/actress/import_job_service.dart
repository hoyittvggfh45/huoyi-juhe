import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/import_debug_log.dart';
import '../services/sql_text_stream.dart';
import '../services/site_library.dart';
import '../services/source_registry.dart';
import '../services/unified_import.dart';
import 'actress_database.dart';
import 'actress_db_import.dart';
import 'actress_db_source.dart';
import 'actress_magnet_library.dart';

/// 导入任务状态机（2026-11-28 后台导入批）：导入不再绑在管理
/// 页的 State 上——页面只是发起者与订阅者，任务本体由本服务
/// （进程级单例）持有：页面 dispose、切后台、锁屏都不取消任
/// 务；进度经 [ImportJobService.state] 暴露，回到页面即可看到
/// 实时进度与最终结果。
enum ImportJobPhase { idle, running, succeeded, failed, interrupted }

/// 统一进度（口径与原管理页进度文案一致）：阶段名 + 已处理
/// 条数 + 0..1 分数。[kind] 区分三路尾段（actress/site/
/// magnet/sniff），页面据此沿用原有进度条与取消钮的 key。
class ImportJobProgress {
  const ImportJobProgress({
    required this.kind,
    required this.phaseLabel,
    required this.statements,
    required this.fraction,
  });

  final String kind;
  final String phaseLabel;
  final int statements;
  final double fraction;
}

class ImportJobState {
  const ImportJobState({
    this.phase = ImportJobPhase.idle,
    this.progress,
    this.message,
    this.error,
    this.detailMessage,
    this.detailError,
    this.sourceName,
    this.kindLabel,
  });

  final ImportJobPhase phase;
  final ImportJobProgress? progress;

  /// 统一口汇总行（带库名，页面 unified-import-result/error）。
  final String? message;
  final String? error;

  /// 各库尾段自己的结果行（页面 dual-message/dual-error）。
  final String? detailMessage;
  final String? detailError;
  final String? sourceName;
  final String? kindLabel;

  bool get running => phase == ImportJobPhase.running;
}

/// 一次导入任务的结果（runner 产出，服务据此落状态）。
class ImportJobOutcome {
  const ImportJobOutcome({
    required this.ok,
    this.message,
    this.error,
    this.detailMessage,
    this.detailError,
    this.needsRefresh = false,
  });

  final bool ok;

  /// 统一口汇总行。
  final String? message;
  final String? error;

  /// 尾段自己的结果行。
  final String? detailMessage;
  final String? detailError;

  /// 成功且库已换动：页面收到后应刷新状态并通知读库层重读。
  final bool needsRefresh;
}

/// 任务执行体：进度回调与取消口径（服务持有取消标志，页面
/// 销毁不影响；只有用户在页面上点「取消」才置真）。
typedef ImportJobRunner =
    Future<ImportJobOutcome> Function(
      void Function(ImportJobProgress) onProgress,
      bool Function() isCancelled,
    );

/// 前台服务桥（安卓侧 ImportForegroundService）：全部调用
/// fail-soft——通道缺失/抛错只吞掉，绝不影响导入本身。
abstract class ImportForegroundBridge {
  Future<void> start(String text);
  Future<void> update(String text, double fraction);
  Future<void> stop({required bool success, required String text});
}

/// MethodChannel 实现＋进度节流：进度通知更新至少间隔 2 秒
/// 或进度推进 ≥5% 才发一次；start/stop 各只发一次（由服务
/// 的调用时机保证）。[invoke] 与 [now] 可注入供测试。
class MethodChannelImportForegroundBridge implements ImportForegroundBridge {
  MethodChannelImportForegroundBridge({
    Future<dynamic> Function(String method, Map<String, dynamic> args)?
    invoke,
    DateTime Function()? now,
  }) : _invoke = invoke ?? _channelInvoke,
       _now = now ?? DateTime.now;

  static const channelName = 'fqapp/import_foreground';
  static const _channel = MethodChannel(channelName);

  static Future<dynamic> _channelInvoke(
    String method,
    Map<String, dynamic> args,
  ) => _channel.invokeMethod<dynamic>(method, args);

  final Future<dynamic> Function(String method, Map<String, dynamic> args)
  _invoke;
  final DateTime Function() _now;

  DateTime? _lastUpdateAt;
  double _lastFraction = -1;

  @override
  Future<void> start(String text) async {
    _lastUpdateAt = null;
    _lastFraction = -1;
    try {
      await _invoke('start', {'text': text});
    } catch (_) {
      // fail-soft：通道缺失（桌面/测试/容器不支持）不挡导入。
    }
  }

  @override
  Future<void> update(String text, double fraction) async {
    final now = _now();
    final last = _lastUpdateAt;
    final dueByTime =
        last == null || now.difference(last) >= const Duration(seconds: 2);
    final dueByProgress = (fraction - _lastFraction).abs() >= 0.05;
    if (!dueByTime && !dueByProgress) return;
    _lastUpdateAt = now;
    _lastFraction = fraction;
    try {
      await _invoke('update', {'text': text, 'fraction': fraction});
    } catch (_) {}
  }

  @override
  Future<void> stop({required bool success, required String text}) async {
    try {
      await _invoke('stop', {'success': success, 'text': text});
    } catch (_) {}
  }
}

/// 无操作桥（测试/桌面缺省注入用）。
class NoopImportForegroundBridge implements ImportForegroundBridge {
  @override
  Future<void> start(String text) async {}
  @override
  Future<void> update(String text, double fraction) async {}
  @override
  Future<void> stop({required bool success, required String text}) async {}
}

/// 导入服务：进程级单例，持有任务状态机、取消标志、未完成
/// 标记与前台服务桥。页面只订阅 [state] 与发起任务。
class ImportJobService {
  ImportJobService({
    Future<Directory> Function()? supportDirectoryProvider,
    ImportForegroundBridge? foreground,
    // ignore: prefer_initializing_formals
    Future<List<String>> Function()? stagingPathsProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory,
       _foreground = foreground ?? MethodChannelImportForegroundBridge(),
       // ignore: prefer_initializing_formals
       _stagingPathsProvider = stagingPathsProvider;

  static final ImportJobService instance = ImportJobService();

  final Future<Directory> Function() _supportDirectoryProvider;
  final ImportForegroundBridge _foreground;

  /// 中断时要清的 staging 路径提供者（生产由分发器依赖算出；
  /// 测试可注入）。缺省按已知口径扫支持目录与导入库同目录。
  final Future<List<String>> Function()? _stagingPathsProvider;

  final ValueNotifier<ImportJobState> state = ValueNotifier(
    const ImportJobState(),
  );

  var _cancelled = false;
  var _startupChecked = false;

  bool get isRunning => state.value.running;

  /// 「导入进行中」标记文件名（应用支持目录）。
  static const markerFileName = 'import_in_progress.json';

  /// 未完成提示文案（中断识别后管理页显示）。
  static const interruptedHintZh =
      '上次导入没完成（可能被系统中断），现有数据库没变，可以重新导入';

  Future<File> _markerFile() async {
    final dir = await _supportDirectoryProvider();
    return File('${dir.path}/$markerFileName');
  }

  /// 发起一次任务。已在跑时直接拒绝（返回 false），状态机
  /// 不动——防重复导入口径。
  Future<bool> start({
    required String sourceName,
    required ImportJobRunner runner,
  }) async {
    if (isRunning) return false;
    _cancelled = false;
    state.value = ImportJobState(
      phase: ImportJobPhase.running,
      sourceName: sourceName,
    );
    await _writeMarker(sourceName);
    unawaited(_foreground.start('正在导入数据库：$sourceName'));
    try {
      final outcome = await runner(
        (progress) {
          if (!isRunning) return;
          state.value = ImportJobState(
            phase: ImportJobPhase.running,
            progress: progress,
            sourceName: sourceName,
          );
          unawaited(
            _foreground.update(
              '${progress.phaseLabel}…已处理 ${progress.statements} 条',
              progress.fraction,
            ),
          );
        },
        () => _cancelled,
      );
      await _clearMarker();
      state.value = ImportJobState(
        phase: outcome.ok
            ? ImportJobPhase.succeeded
            : ImportJobPhase.failed,
        message: outcome.message,
        error: outcome.error,
        detailMessage: outcome.detailMessage,
        detailError: outcome.detailError,
        sourceName: sourceName,
      );
      unawaited(
        _foreground.stop(
          success: outcome.ok,
          text: outcome.ok ? '数据库导入完成' : '数据库导入失败',
        ),
      );
    } catch (e, stack) {
      await ImportDebugLog.record(
        stage: '导入服务任务执行',
        error: e,
        stack: stack,
      );
      await _clearMarker();
      state.value = ImportJobState(
        phase: ImportJobPhase.failed,
        error: '导入失败：${importFailureZh(e)}',
        sourceName: sourceName,
      );
      unawaited(_foreground.stop(success: false, text: '数据库导入失败'));
    }
    return true;
  }

  /// 用户取消：只置服务持有的取消标志，各导入器在执行间隙
  /// 检查后自行收尾（半成品不生效的先验后换口径不变）。
  void cancel() {
    if (isRunning) _cancelled = true;
  }

  /// 关掉结果提示（成功/失败/中断提示保留到下一次发起或
  /// 用户关掉为止）。
  void dismissResult() {
    final current = state.value;
    if (current.phase == ImportJobPhase.running) return;
    state.value = const ImportJobState();
  }

  /// 启动识别：标记残留且无任务在跑 → 上次导入未完成。清
  /// 残留 staging（只清临时文件口径，正式库一字不动），状态
  /// 置 interrupted。重复调用只查一次。
  Future<void> ensureStartupChecked() async {
    if (_startupChecked) return;
    _startupChecked = true;
    if (isRunning) return;
    try {
      final marker = await _markerFile();
      if (!await marker.exists()) return;
      await _cleanupStaging();
      try {
        await marker.delete();
      } catch (_) {}
      state.value = const ImportJobState(
        phase: ImportJobPhase.interrupted,
        error: interruptedHintZh,
      );
    } catch (_) {
      // 识别失败不挡启动：最坏情况是少一条提示。
    }
  }

  Future<void> _writeMarker(String sourceName) async {
    try {
      final marker = await _markerFile();
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        jsonEncode({
          'sourceName': sourceName,
          'startedAt': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearMarker() async {
    try {
      final marker = await _markerFile();
      if (await marker.exists()) await marker.delete();
    } catch (_) {}
  }

  /// 清残留 staging：只删既有临时文件命名口径的残件
  /// （*.importing / *.importing-db / .magnet-staging.db 及
  /// 其 -wal/-journal/.bak 兄弟），正式库文件不在名单里。
  Future<void> _cleanupStaging() async {
    var paths = <String>[];
    final provider = _stagingPathsProvider;
    if (provider != null) {
      try {
        paths = await provider();
      } catch (_) {}
    } else {
      try {
        paths = await _defaultStagingPaths();
      } catch (_) {}
    }
    for (final base in paths) {
      for (final suffix in ['', '-wal', '-journal', '.bak']) {
        try {
          final file = File('$base$suffix');
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<List<String>> _defaultStagingPaths() async {
    final out = <String>[];
    try {
      final importedPath = await ActressDbSource.instance.importedDbPath();
      if (importedPath.isNotEmpty) {
        out.add('$importedPath.importing');
        out.add('$importedPath.importing-db');
        out.add(magnetStagingPathFor(importedPath));
      }
    } catch (_) {}
    try {
      final dir = await _supportDirectoryProvider();
      out.add('${dir.path}/site_library/site_library.db.importing');
    } catch (_) {}
    return out;
  }
}

/// 统一导入分发（原管理页 _runUnifiedImport 与三路尾段整体
/// 搬入）：认库 → 按 kind 调原尾段。各路导入的落位原子性、
/// 先验后换、分类登记、兜底行为一字不改，只是换驱动者——
/// 进度与取消都走服务给的回调，不引用任何页面 State。
class UnifiedImportDispatch {
  UnifiedImportDispatch({
    required this.source,
    required this.importService,
    required this.siteLibrary,
    this.onLibraryChanged,
  });

  final ActressDbSource source;
  final ActressDbImportService importService;
  final SiteLibraryService siteLibrary;

  /// 库换动后通知读库层重读（缺省关主库连接强制重读）。
  final Future<void> Function()? onLibraryChanged;

  Future<void> _notifyLibraryChanged() async {
    final hook = onLibraryChanged;
    if (hook != null) {
      await hook();
      return;
    }
    try {
      await SqfliteActressDatabase.instance.reloadIfChanged(force: true);
    } catch (_) {}
  }

  /// 认库＋分发，产出统一口汇总结果。
  Future<ImportJobOutcome> run({
    required String path,
    required String sourceName,
    required bool deleteAfter,
    required void Function(ImportJobProgress) onProgress,
    required bool Function() isCancelled,
  }) async {
    onProgress(
      const ImportJobProgress(
        kind: 'sniff',
        phaseLabel: '正在认这份文件是什么库',
        statements: 0,
        fraction: 0,
      ),
    );
    final kind = await UnifiedImportSniffer.sniff(path);
    try {
      switch (kind) {
        case UnifiedImportKind.siteLibrary:
          return const ImportJobOutcome(
            ok: true,
            message: '站点已经内置在软件里，不用单独导入',
          );
        case UnifiedImportKind.bundle:
          final tail = await _runSiteImport(
            File(path),
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          return ImportJobOutcome(
            ok: tail.ok,
            message: tail.ok
                ? '数据库导入成功，已激活：${tail.text ?? ''}'
                : null,
            error: tail.ok ? null : '数据库没有导入：${tail.text ?? '未知原因'}',
            needsRefresh: tail.ok,
          );
        case UnifiedImportKind.actressDb:
        case UnifiedImportKind.actressSql:
          final tail = await _runActressImport(
            path,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          return _mirror(kind, tail);
        case UnifiedImportKind.magnetSql:
          final tail = await _runMagnetImport(
            path,
            sourceName: sourceName,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          return _mirror(kind, tail);
        case UnifiedImportKind.unknown:
          return const ImportJobOutcome(
            ok: false,
            error:
                '未知文件：这份文件认不出是什么库（不是站点库、女优库、'
                '磁力库，也不是三库合并文件），没有导入。'
                '请确认文件没下错、没下坏。',
          );
      }
    } finally {
      if (deleteAfter) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  ImportJobOutcome _mirror(
    UnifiedImportKind kind,
    ({String? message, String? error, bool needsRefresh}) tail,
  ) {
    return ImportJobOutcome(
      ok: tail.error == null,
      message: tail.message == null
          ? null
          : '${kind.labelZh}：${tail.message}',
      error: tail.error == null ? null : '${kind.labelZh}：${tail.error}',
      detailMessage: tail.message,
      detailError: tail.error,
      needsRefresh: tail.needsRefresh,
    );
  }

  /// 女优库导入尾段（原管理页同名方法）：进度、结果、重读。
  Future<({String? message, String? error, bool needsRefresh})>
  _runActressImport(
    String localPath, {
    required void Function(ImportJobProgress) onProgress,
    required bool Function() isCancelled,
  }) async {
    try {
      final outcome = await importService.importLocalFile(
        localPath: localPath,
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
        onProgress: (progress) {
          onProgress(
            ImportJobProgress(
              kind: 'actress',
              phaseLabel: progress.phase,
              statements: progress.statements,
              fraction: progress.fraction,
            ),
          );
        },
        isCancelled: isCancelled,
      );
      if (outcome.needsReload) await _notifyLibraryChanged();
      if (outcome.ok) {
        return (
          message: outcome.videos > 0
              ? '导入成功，已激活：${outcome.videos} 部作品'
                    '${outcome.warnings.isEmpty ? '' : '\n${outcome.warnings.join('\n')}'}'
              : '导入成功，已激活',
          error: null,
          needsRefresh: true,
        );
      }
      return (
        message: null,
        error: outcome.error ?? '导入失败',
        needsRefresh: false,
      );
    } catch (e, stack) {
      await ImportDebugLog.record(
        stage: '女优库导入尾段（导入服务）',
        error: e,
        stack: stack,
      );
      return (
        message: null,
        error: '导入失败（女优库导入尾段）：${importFailureZh(e)}',
        needsRefresh: false,
      );
    }
  }

  /// 空目标库的标准表 DDL（与 actress_sql_import.dart 的
  /// _standardTableDdl 逐字一致，原管理页同名常量搬入）。
  static const _emptyTargetDdl = <String>[
    'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
    'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
    'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
    'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
    'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
    'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
  ];

  Future<Database> _openMagnetTarget() async {
    final importedPath = await source.importedDbPath();
    final file = File(importedPath);
    final existed = file.existsSync() && file.lengthSync() > 0;
    if (!existed) {
      await file.parent.create(recursive: true);
    }
    try {
      await SqfliteActressDatabase.instance.close();
    } catch (_) {}
    final db = await openDatabase(importedPath, singleInstance: false);
    if (!existed) {
      for (final ddl in _emptyTargetDdl) {
        await db.execute(ddl);
      }
    }
    await ActressMagnetLibraryStore.ensureSchema(db);
    return db;
  }

  /// 磁力导入尾段（原管理页同名方法）。
  Future<({String? message, String? error, bool needsRefresh})>
  _runMagnetImport(
    String localPath, {
    required String sourceName,
    required void Function(ImportJobProgress) onProgress,
    required bool Function() isCancelled,
  }) async {
    String? stagingPath;
    try {
      final importedPath = await source.importedDbPath();
      if (importedPath.isEmpty) {
        throw StateError('导入库路径不可用，没法导入磁力分类库');
      }
      await File(importedPath).parent.create(recursive: true);
      stagingPath = magnetStagingPathFor(importedPath);
      final staging = await buildMagnetStagingDb(
        localPath,
        stagingPath: stagingPath,
        isCancelled: isCancelled,
        onProgress: (progress) {
          onProgress(
            ImportJobProgress(
              kind: 'magnet',
              phaseLabel: '正在导入磁力库',
              statements: progress.statements,
              fraction: progress.fraction,
            ),
          );
        },
      );
      if (!staging.ok) {
        throw StateError(staging.error ?? '文件校验没通过');
      }
      if (!await ActressMagnetLibraryStore.stagingIsMagnetLibrary(
        stagingPath,
      )) {
        throw StateError('这个文件里没有磁力链接，不是磁力分类库；整库数据库请用上面的「导入数据库」');
      }
      final db = await _openMagnetTarget();
      MagnetImportOutcome outcome;
      try {
        outcome = await ActressMagnetLibraryStore().mergeStaging(
          db,
          stagingPath,
          sourceName: sourceName,
        );
      } finally {
        await db.close();
      }
      if (!outcome.ok) {
        throw StateError(outcome.error ?? '导入失败');
      }
      source.notifyChanged();
      await _notifyLibraryChanged();
      return (
        message: _magnetImportResultText(outcome),
        error: null,
        needsRefresh: true,
      );
    } catch (e, stack) {
      await ImportDebugLog.record(
        stage: '磁力库导入尾段（导入服务）',
        error: e,
        stack: stack,
      );
      return (
        message: null,
        error: '磁力分类库导入失败：${importFailureZh(e)}',
        needsRefresh: false,
      );
    } finally {
      if (stagingPath != null) {
        for (final suffix in ['', '.bak', '-wal', '-journal']) {
          try {
            final staging = File('$stagingPath$suffix');
            if (await staging.exists()) await staging.delete();
          } catch (_) {}
        }
      }
    }
  }

  String _magnetImportResultText(MagnetImportOutcome outcome) {
    final String text;
    if (outcome.categories.length > 1) {
      text =
          '已导入 ${outcome.categories.length} 个分类'
          '（${outcome.categories.join('、')}）：'
          '新增 ${outcome.addedWorks} 部作品'
          '（共收录 ${outcome.totalWorks} 部）';
    } else if (outcome.category.isNotEmpty) {
      text =
          '已导入分类「${outcome.category}」：'
          '新增 ${outcome.addedWorks} 部作品'
          '（这个分类共 ${outcome.totalWorks} 部）';
    } else {
      text = '已导入磁力分类库：新增 ${outcome.addedWorks} 部作品';
    }
    return outcome.replaced ? '$text；同名分类已更新为这一版' : text;
  }

  Future<void> _syncSqlSites() async {
    try {
      await (SourceRegistry.instance as dynamic).syncSqlSites();
    } catch (_) {}
  }

  /// 合并文件（整份数据库）导入尾段（原管理页 _runSiteImport）。
  Future<({bool ok, String? text})> _runSiteImport(
    File file, {
    required void Function(ImportJobProgress) onProgress,
    required bool Function() isCancelled,
  }) async {
    try {
      final outcome = await siteLibrary.importLocalFile(
        localPath: file.path,
        onProgress: (progress) {
          onProgress(
            ImportJobProgress(
              kind: 'site',
              phaseLabel: progress.phase,
              statements: progress.statements,
              fraction: progress.fraction,
            ),
          );
        },
        isCancelled: isCancelled,
      );
      if (outcome.ok) await _syncSqlSites();
      return (
        ok: outcome.ok,
        text: outcome.ok
            ? (outcome.segmentResults.isNotEmpty
                  ? [
                      for (final r in outcome.segmentResults)
                        if (r.ok) '${r.segmentLabel} ${r.detail ?? '已导入'}',
                    ].join('；')
                  : '已导入')
            : (outcome.error ?? '未知原因'),
      );
    } catch (e, stack) {
      await ImportDebugLog.record(
        stage: '合并文件导入尾段（导入服务）',
        error: e,
        stack: stack,
      );
      return (ok: false, text: '导入失败：${importFailureZh(e)}');
    }
  }
}
