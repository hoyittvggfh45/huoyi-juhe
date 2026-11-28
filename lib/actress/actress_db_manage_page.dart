import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../services/import_debug_log.dart';
import '../services/site_library.dart';
import '../services/sql_text_stream.dart';
import 'actress_database.dart';
import 'actress_db_import.dart';
import 'actress_db_source.dart';
import 'actress_magnet_library.dart';
import 'import_job_service.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'unified_import_page.dart';

/// 统一数据库管理页（2026-11-27 双库批，全树唯一一份）：两个
/// 入口共用——「我的」页的「数据库导入」行、演员库顶栏数据库
/// 管理弹层里的「数据库管理页（导入/激活）」项。
///
/// 激活制（2026-11-27 演员库激活批）：演员库必须经导入激活
/// 才出数据。页内：导入按钮（.db / .sql / .sql.gz，导入成功
/// 即激活，流程见 [ActressDbImportService]）+ 两张库卡：
/// - 外置库卡 = **导入来源**：MYTV/db/女优库.db 放着不生效，
///   卡上能看状态、能授权，点「导入激活」才走结构校验
///   拷进导入库；外置库永不给删、本页不写它一字。
/// - 导入库卡 = 已激活的库：显激活状态、作品数、
///   大小、修改时间；可删除（删完演员库回到未激活）。
/// 没激活时页顶有引导文案；导入失败原因在本页红字区原样
/// 呈现（服务层给的中文原因）。
///
/// 站点已随包内置直显（2026-11-28 取消激活令）：本页不再有
/// 站点卡，导入数据库只管演员库＋磁力，与站点脱钩；用户单独
/// 拿一份站点文件来导，只给「站点已经内置」的中文提示。
///
/// 红线：本页不写外置库；导入失败不毁任何现有可用库（服务层
/// 保证）；读库层靠路径+文件戳机制失效旧连接（见
/// actress_db_source.dart 类注释）。
class ActressDbManagePage extends StatefulWidget {
  const ActressDbManagePage({
    super.key,
    this.source,
    this.importService,
    this.siteLibraryService,
    this.importJobService,
    this.onLibraryChanged,
    this.magnetLibrariesLoader,
  });

  /// 来源层（测试注入假件；默认单例）。
  final ActressDbSource? source;

  /// 导入服务（测试注入假件；默认真服务，校验走真探测）。
  final ActressDbImportService? importService;

  /// 磁力分类库列表加载（测试/预览注入假件；默认只读开导入
  /// 库走数据层 listLibraries——flutter test 里 sqflite 跑不
  /// 起来，列表类断言靠这个缝注入）。
  final Future<List<MagnetLibraryRecord>> Function()? magnetLibrariesLoader;

  /// 站点库服务（测试注入假件；默认单例）。与女优库完全独立：
  /// 本页只是共用一个入口，校验器、落点、删除动作都不相干。
  final SiteLibraryService? siteLibraryService;

  /// 导入任务服务（测试/预览注入假件；默认进程级单例——任务
  /// 与页面解绑，离开页面照常跑）。
  final ImportJobService? importJobService;

  /// 库发生变化（导入成功/切换/删除）后调：默认关主库连接并
  /// 强制重读一次，让演员库各读库入口立刻换到新库。测试可注入
  /// 空实现。
  final Future<void> Function()? onLibraryChanged;

  @override
  State<ActressDbManagePage> createState() => _ActressDbManagePageState();
}

class _ActressDbManagePageState extends State<ActressDbManagePage> {
  ActressDbSource get _source => widget.source ?? ActressDbSource.instance;

  late final ActressDbImportService _importService =
      widget.importService ?? ActressDbImportService(source: _source);

  SiteLibraryService get _siteLibrary =>
      widget.siteLibraryService ?? SiteLibraryService.instance;

  ActressDbSourceStatus? _status;
  final _works = <ActressDbSlot, int?>{};
  var _loading = true;

  // 本页自有动作（外置导入激活/删除/授权）的结果行；统一口
  // 的结果行由导入服务持有（见 _message/_error 合并读法）。
  String? _localMessage;
  String? _localError;
  String? _localUnifiedError;
  var _externalImporting = false;

  /// 已并存导入的磁力分类库登记（在导入库里）：只供状态行
  /// 跟随数据库带出计数（见 _magnetMergedStatus），不再有
  /// 独立区块与逐库删除（2026-11-28 令：磁力绑定数据库）。
  var _magnetLibraries = const <MagnetLibraryRecord>[];

  // ── 后台导入（2026-11-28 批）：任务本体在 [ImportJobService]
  // 单例里，页面只是订阅者＋发起者。dispose 只退订，绝不取消
  // 任务；进度/结果都从服务状态读，回到页面即见实时状态。
  ImportJobService get _jobService =>
      widget.importJobService ?? ImportJobService.instance;
  ImportJobState get _job => _jobService.state.value;
  ImportJobPhase _lastJobPhase = ImportJobPhase.idle;

  String? get _message => _localMessage ?? _job.detailMessage;
  String? get _error => _localError ?? _job.detailError;
  String? get _unifiedMessage => _job.message;
  String? get _unifiedError => _localUnifiedError ?? _job.error;

  bool get _anyImporting => _job.running || _externalImporting;

  @override
  void initState() {
    super.initState();
    _source.revision.addListener(_onRevision);
    _jobService.state.addListener(_onJobState);
    _lastJobPhase = _job.phase;
    // 启动识别：上次导入被中断（标记残留）时给中文提示。
    _jobService.ensureStartupChecked();
    _refresh();
  }

  @override
  void dispose() {
    _source.revision.removeListener(_onRevision);
    // 只退订导入服务：任务在服务里继续跑，页面销毁不取消。
    _jobService.state.removeListener(_onJobState);
    super.dispose();
  }

  void _onJobState() {
    if (!mounted) return;
    setState(() {});
    // 任务刚成功收尾：刷新本页库状态（作品数/激活态）。
    if (_job.phase == ImportJobPhase.succeeded &&
        _lastJobPhase == ImportJobPhase.running) {
      _refresh();
    }
    _lastJobPhase = _job.phase;
  }

  void _onRevision() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    final status = await _source.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
    for (final slot in ActressDbSlot.values) {
      final count = await _source.countWorks(status.infoOf(slot));
      if (!mounted) return;
      setState(() => _works[slot] = count);
    }
    final libraries = await _loadMagnetLibraries();
    if (!mounted) return;
    setState(() => _magnetLibraries = libraries);
  }

  /// 磁力登记列表：只读开导入库取登记；导入库文件不存在就不
  /// 开（开库会把空文件建出来）、读失败按没有处理，不挡管理页。
  Future<List<MagnetLibraryRecord>> _loadMagnetLibraries() async {
    final loader = widget.magnetLibrariesLoader;
    if (loader != null) {
      try {
        return await loader();
      } catch (_) {
        return const [];
      }
    }
    try {
      final importedPath = await _source.importedDbPath();
      if (importedPath.isEmpty) return const [];
      final file = File(importedPath);
      if (!file.existsSync() || file.lengthSync() == 0) return const [];
      final db = await openDatabase(
        importedPath,
        readOnly: true,
        singleInstance: false,
      );
      try {
        return await ActressMagnetLibraryStore().listLibraries(db);
      } finally {
        await db.close();
      }
    } catch (_) {
      return const [];
    }
  }

  Future<void> _notifyLibraryChanged() async {
    final hook = widget.onLibraryChanged;
    if (hook != null) {
      await hook();
      return;
    }
    try {
      await SqfliteActressDatabase.instance.reloadIfChanged(force: true);
    } catch (_) {
      // 重读失败不挡管理页：读库层下次打开会按生效路径再试。
    }
  }

  /// 外置文件导入激活：走导入服务的 .db 同一条链（结构校验
  /// ＋拷入导入库＋落激活记录），外置文件只读不写。
  Future<void> _importExternal() async {
    if (_externalImporting) return;
    setState(() {
      _externalImporting = true;
      _localMessage = null;
      _localError = null;
    });
    try {
      final outcome = await _importService.importExternalFile(
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
      );
      if (!mounted) return;
      setState(() {
        _externalImporting = false;
        if (outcome.ok) {
          _localMessage = outcome.videos > 0
              ? '外置库导入成功，已激活：${outcome.videos} 部作品'
              : '外置库导入成功，已激活';
          _localError = null;
        } else {
          _localError = outcome.error ?? '导入失败';
        }
      });
      if (outcome.needsReload) await _notifyLibraryChanged();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _externalImporting = false;
        _localError = '导入失败：${importFailureZh(e)}';
      });
    }
  }

  Future<void> _deleteImported() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.surface,
        title: const Text('删除导入库', style: TextStyle(color: Neon.text)),
        content: const Text(
          '删除后演员库回到未激活状态，要重新导入才能用。外置库不受影响（它只是导入来源）。',
          style: TextStyle(color: Neon.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('dual-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: Neon.pink)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _source.deleteImported();
    await _notifyLibraryChanged();
    if (!mounted) return;
    setState(() {
      _localMessage = '导入库已删除，演员库已回到未激活状态';
      _localError = null;
    });
    await _refresh();
  }

  /// 统一导入口（2026-11-28 统一导入口批）：全页唯一的导入
  /// 入口。点开选文件页（MYTV/db 全部可导文件＋页尾「选择其他
  /// 文件」），选定后由 [UnifiedImportSniffer] 按内容认库，再
  /// 分发到各自原有的导入尾段（女优/磁力走原导入链；合并文件
  /// 走整库导入；单独的站点文件不再导入——站点已内置，只给
  /// 提示）。原先散在三个区的六个导入按钮已全撤。
  Future<void> _startUnifiedImport() async {
    if (_anyImporting) return;
    final files = await _importService.listMytvDbImportFiles();
    if (!mounted) return;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => UnifiedImportListPage(files: files),
      ),
    );
    if (!mounted || result == null) return;
    if (result == UnifiedImportListPage.pickOtherFile) {
      await _pickOtherFileForUnifiedImport();
      return;
    }
    final file = result as ({String name, String path, int sizeBytes});
    await _runUnifiedImport(
      path: file.path,
      sourceName: file.name,
      deleteAfter: false,
    );
  }

  /// 统一口里的次要方式：系统选择器选其他位置的文件（只适合
  /// 小文件；大文件走 MYTV/db 直读）。选中先拷进收件文件再认
  /// 库分发，导完删收件副本。
  Future<void> _pickOtherFileForUnifiedImport() async {
    if (_anyImporting) return;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '数据库文件', extensions: ['db', 'sql', 'gz']),
      ],
    );
    if (picked == null || !mounted) return;
    File inbox;
    try {
      inbox = await _importService.inboxFileFor(picked.name);
      final sink = inbox.openWrite();
      try {
        await sink.addStream(picked.openRead());
      } finally {
        await sink.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _localUnifiedError = '导入失败：${importFailureZh(e)}';
      });
      return;
    }
    await _runUnifiedImport(
      path: inbox.path,
      sourceName: picked.name,
      deleteAfter: true,
    );
  }

  /// 发起统一导入：认库＋分发整体在 [UnifiedImportDispatch]
  /// 里、由 [ImportJobService] 驱动（与页面解绑）。页面只把
  /// 本页注入的服务依赖交给分发器，进度与结果订阅服务状态。
  Future<void> _runUnifiedImport({
    required String path,
    required String sourceName,
    required bool deleteAfter,
  }) async {
    if (_job.running) return;
    setState(() {
      _localUnifiedError = null;
      _localMessage = null;
      _localError = null;
    });
    final dispatch = UnifiedImportDispatch(
      source: _source,
      importService: _importService,
      siteLibrary: _siteLibrary,
      onLibraryChanged: _notifyLibraryChanged,
    );
    await _jobService.start(
      sourceName: sourceName,
      runner: (onProgress, isCancelled) => dispatch.run(
        path: path,
        sourceName: sourceName,
        deleteAfter: deleteAfter,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.text,
        title: const Text('数据库管理', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _importSection(),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const ValueKey('dual-message'),
                style: const TextStyle(color: Neon.cyan, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('dual-error'),
                style: const TextStyle(color: Neon.pink, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                '详细原因已存到 ${ImportDebugLog.pathHintZh}。',
                style: TextStyle(color: Neon.textDim, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            if (_loading || status == null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: Text(
                    '正在读取数据库状态…',
                    style: TextStyle(color: Neon.textDim),
                  ),
                ),
              )
            else ...[
              if (!status.activated) ...[
                Container(
                  key: const ValueKey('activation-guide'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Neon.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Neon.pink.withValues(alpha: .55)),
                  ),
                  child: Text(
                    status.fallbackActive
                        ? '导入未成功，当前使用外置库兜底（只读）：'
                              '演员库数据来自 MYTV/db/女优库.db，列表、'
                              '详情、播放照常可用；导入成功后导入库会'
                              '自动接管，兜底退场。'
                        : '演员库还没激活：导入一个女优库'
                              '（.db / .sql）完成激活后才能用；也可以在'
                              '下面外置库卡上点「导入激活」。',
                    style: const TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _slotCard(
                slot: ActressDbSlot.external,
                title: '外置库（导入来源）',
                subtitle: 'MYTV/db/女优库.db（导入来源；未激活时结构过关会自动兜底出数据，点导入激活可正式收编；只读，不会被改动）',
                status: status,
              ),
              const SizedBox(height: 12),
              _slotCard(
                slot: ActressDbSlot.imported,
                title: '导入库（已激活）',
                subtitle: '通过本页导入激活的 .db / .sql 落成的库',
                status: status,
              ),
            ],
            _magnetMergedStatus(),
          ],
        ),
      ),
    );
  }

  /// 磁力状态行（2026-11-28 用户令：磁力不单独显示、绑定
  /// 数据库激活）：不再有独立的「磁力分类库」区块——磁力是
  /// 作品的属性，随这本数据库一起生效，状态只在这里跟随导
  /// 入库一行带出（分类数 + 登记作品数）；磁力链接本体在演
  /// 员库作品详情里看。没有磁力登记时整行不出。
  Widget _magnetMergedStatus() {
    if (_magnetLibraries.isEmpty) return const SizedBox.shrink();
    final works = _magnetLibraries.fold<int>(
      0,
      (sum, record) => sum + record.workCount,
    );
    return Padding(
      key: const ValueKey('magnet-merged-status'),
      padding: const EdgeInsets.only(top: 10, left: 4, right: 4),
      child: Text(
        '磁力已随数据库生效：${_magnetLibraries.length} 个分类 · '
        '登记作品 $works 部（磁力链接在演员库作品详情里看）',
        style: const TextStyle(color: Neon.textDim, fontSize: 12),
      ),
    );
  }

  /// 统一导入区（2026-11-28 统一导入口批）：全页唯一的导入
  /// 入口区块。一个按钮点开选文件页，认库分发在软件里完成；
  /// 三个库的导入进度与汇总结果都显示在这一个口里。
  Widget _importSection() {
    return Container(
      key: const ValueKey('unified-import-section'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.violet.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导入数据库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '所有数据都从这一个口导入：把文件放进 MYTV/db，点下面按钮选文件，'
            '软件会按文件内容自动认库。三库合并文件就是一整份数据库，'
            '一次导入、一次激活，演员库、磁力一起生效'
            '（会先做结构校验，导入失败时现有库原样不动）。'
            '站点已经内置在软件里，不用单独导入。'
            '文件不在 MYTV/db 里的小文件，在选文件页里点「选择其他文件」。',
            style: TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (_unifiedMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _unifiedMessage!,
              key: const ValueKey('unified-import-result'),
              style: const TextStyle(color: Neon.cyan, fontSize: 13),
            ),
          ],
          if (_unifiedError != null &&
              _job.phase != ImportJobPhase.interrupted) ...[
            const SizedBox(height: 8),
            Text(
              _unifiedError!,
              key: const ValueKey('unified-import-error'),
              style: const TextStyle(color: Neon.pink, fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              '详细原因已存到 ${ImportDebugLog.pathHintZh}，把这个文件发给开发者就能定点。',
              key: ValueKey('unified-import-debug-hint'),
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ],
          if (_job.phase == ImportJobPhase.interrupted) ...[
            const SizedBox(height: 8),
            const Text(
              ImportJobService.interruptedHintZh,
              key: ValueKey('unified-import-interrupted'),
              style: TextStyle(color: Neon.pink, fontSize: 13),
            ),
          ],
          if (_job.running) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _job.progress == null ||
                      _job.progress!.kind == 'sniff'
                  ? null
                  : (_job.progress!.fraction).clamp(0, 1),
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            if (_job.progress == null ||
                _job.progress!.kind == 'sniff') ...[
              const Text(
                '正在认这份文件是什么库…',
                key: ValueKey('unified-import-sniffing'),
                style: TextStyle(color: Neon.textDim, fontSize: 12),
              ),
            ] else if (_job.progress!.kind == 'magnet') ...[
              Text(
                '正在导入磁力库…已处理 '
                '${_job.progress!.statements} 条'
                '（${(_job.progress!.fraction * 100).toStringAsFixed(0)}%）',
                key: const ValueKey('magnet-import-progress'),
                style: const TextStyle(color: Neon.textDim, fontSize: 12),
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _job.progress!.kind == 'site' &&
                              _job.progress!.statements == 0
                          ? '正在导入数据库…'
                          : '${_job.progress!.phaseLabel}…已处理 ${_job.progress!.statements} 条',
                      style: const TextStyle(
                        color: Neon.textDim,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey(
                      _job.progress!.kind == 'site'
                          ? 'site-import-cancel'
                          : 'dual-import-cancel',
                    ),
                    onPressed: () => _jobService.cancel(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('dual-import-button'),
                onPressed: null,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('导入进行中…'),
              ),
            ),
          ] else ...[
            if (_job.phase == ImportJobPhase.succeeded ||
                _job.phase == ImportJobPhase.failed ||
                _job.phase == ImportJobPhase.interrupted)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('unified-import-dismiss'),
                  onPressed: () => _jobService.dismissResult(),
                  child: const Text('关闭提示'),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('dual-import-button'),
                onPressed: _startUnifiedImport,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('从 MYTV/db 导入'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _slotCard({
    required ActressDbSlot slot,
    required String title,
    required String subtitle,
    required ActressDbSourceStatus status,
  }) {
    final info = status.infoOf(slot);
    final isCurrent = status.isEffective(slot);
    final works = _works[slot];
    return Container(
      key: ValueKey('dual-card-${slot.wire}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? Neon.cyan.withValues(alpha: .7)
              : Neon.violet.withValues(alpha: .45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, color: Neon.textDim, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Neon.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isCurrent)
                Container(
                  key: ValueKey('dual-current-${slot.wire}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Neon.cyan.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '当前使用中',
                    style: TextStyle(color: Neon.cyan, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(color: Neon.textFaint, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            '状态：${info.statusText}'
            ' · 作品数：${works ?? '—'}'
            ' · 大小：${info.exists ? _formatSize(info.sizeBytes) : '—'}'
            ' · 修改时间：${info.modified == null ? '—' : _formatTime(info.modified!)}',
            style: const TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (slot == ActressDbSlot.imported) ...[
            const SizedBox(height: 4),
            Text(
              status.activated
                  ? '激活：已激活 · ${status.activation!.describe}'
                  : status.fallbackActive
                  ? '激活：未激活（当前由外置库兜底出数据，导入成功后自动接管）'
                  : '激活：未激活（导入成功后自动激活）',
              key: const ValueKey('dual-activation-line'),
              style: TextStyle(
                color: status.activated ? Neon.cyan : Neon.textDim,
                fontSize: 12,
              ),
            ),
          ],
          if (slot == ActressDbSlot.external && info.exists) ...[
            const SizedBox(height: 4),
            const Text(
              '这个文件是导入来源：点下面「导入激活」会校验结构并拷进导入库正式生效；'
              '未激活时只要它结构过关，演员库会自动拿它只读兜底出数据。'
              '它显示的作品数和修改时间是这份文件本身的；'
              '老库也能直接导入，不用换文件。',
              style: TextStyle(color: Neon.textFaint, fontSize: 11),
            ),
          ],
          if (info.dbPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              info.dbPath,
              style: const TextStyle(color: Neon.textFaint, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (slot == ActressDbSlot.external && info.exists)
                OutlinedButton(
                  key: const ValueKey('dual-import-external'),
                  onPressed: _anyImporting ? null : _importExternal,
                  child: const Text('导入激活'),
                ),
              if (slot == ActressDbSlot.imported && info.exists)
                OutlinedButton(
                  key: const ValueKey('dual-delete-imported'),
                  onPressed: _deleteImported,
                  child: const Text(
                    '删除导入库',
                    style: TextStyle(color: Neon.pink),
                  ),
                ),
              if (slot == ActressDbSlot.external && Platform.isAndroid) ...[
                OutlinedButton(
                  key: const ValueKey('dual-grant-folder'),
                  onPressed: () async {
                    final granted = await ActressMytvBind.instance
                        .grantFolderAccess();
                    if (!mounted) return;
                    setState(() {
                      _localMessage = granted
                          ? '已取得文件夹授权，正在重新读取'
                          : '没有选择文件夹，或系统选择器打不开';
                      _localError = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(refresh: true);
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权文件夹读取'),
                ),
                OutlinedButton(
                  key: const ValueKey('dual-grant-file'),
                  onPressed: () async {
                    final granted = await ActressMytvBind.instance
                        .grantFileAccess();
                    if (!mounted) return;
                    setState(() {
                      _localMessage = granted
                          ? '已取得文件授权，正在重新读取'
                          : '没有选择文件，或系统选择器打不开';
                      _localError = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(refresh: true);
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权单个数据库文件'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
