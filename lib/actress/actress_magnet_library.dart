import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_db_import.dart';
import 'actress_db_source.dart';
import 'actress_sql_import.dart';

/// 磁力分类库（移植自魔蚁 d0ef96f，落法按修仙版双库架构调整）：
/// 磁力表格转出的文件并存导入「导入槽」库——导入是往导入槽里
/// 「加」，绝不覆盖/清空已有行；外置只读主库永不写（本层只对
/// 调用方传入的 [Database] 干活，落点由调用方决定）。演员库
/// 分类栏按已导入的分类动态增减（没导入不显示）；删掉某个
/// 分类，它带来的作品随之消失，导入前就有的作品一条不动。
/// 交付形态：一个合集 .sql、分类靠库内 main_category 字段区
/// 分，导入时按分类逐片登记（一类一个文件同样适用，片数=1）。
///
/// 并存的落法是「来源登记」：合并时先把临时库（staging，已由
/// [ActressSqlImporter] 验过并落成标准结构，或 .db 现行验法
/// 过关的副本）里每部作品、每条线路、每位演员、每行分类在
/// 目标库里是否已存在记进 magnet_library_* 登记表，再
/// INSERT OR IGNORE 并进标准表。分类页的口径是「主分类 ∪
/// 来源登记」：同番号作品在目标库已有别的分类时，磁力分类
/// 页照样能看到它（样本里 95.9% 的番号与主库重合，只按
/// video_category 并入的话分类页只剩 4% 新作品）。删库时按
/// 登记表反向删：本库独有（导入前不存在、且没有别的磁力库
/// 也带它）的作品整部删；共享的作品只摘掉本库贡献的线路
/// 与分类行。
///
/// 与魔蚁的差异（汇总重建）：魔蚁合并/删库后调
/// ActressSqlImporter.rebuildRollup 重建 actress_rollup 落表；
/// 修仙版没有这张落表——名单汇总是 SqfliteActressDatabase 按
/// 连接内存现算（2026-11-26 只读化，替代 actress_rollup），
/// 读侧靠「路径+大小+mtime」文件戳失效重开连接后自动重建，
/// 所以本层不做任何汇总重建，合并/删库后调用方只需按现行
/// 口径 notifyChanged / 重载即可。

/// 磁力线路在 video_play_urls.play_from 里的标记值（与转换批
/// 对齐用）。判定主尺是播放地址本身以 magnet: 开头——格式级
/// 事实，不依赖标记；play_from 标记是第二道尺，两道任一命中
/// 都算磁力线路。
const actressMagnetPlayFrom = 'magnet';

bool actressIsMagnetPlayUrl(String url) =>
    url.trim().toLowerCase().startsWith('magnet:');

bool actressIsMagnetPlayFrom(String from) {
  final value = from.trim().toLowerCase();
  return value == actressMagnetPlayFrom ||
      value.startsWith(actressMagnetPlayFrom);
}

/// 一条播放线路（video_play_urls 的一行）。
class ActressPlayLine {
  const ActressPlayLine({required this.url, required this.from});

  final String url;
  final String from;

  bool get isMagnet =>
      actressIsMagnetPlayUrl(url) || actressIsMagnetPlayFrom(from);
}

/// 已导入的一个磁力分类库（一个分类切片）的登记。
class MagnetLibraryRecord {
  const MagnetLibraryRecord({
    required this.id,
    required this.name,
    required this.category,
    required this.sourceName,
    required this.importedAtMillis,
    required this.works,
    required this.playUrls,
  });

  final int id;

  /// 库名＝分类切片名（真分类片是 main_category，兜底片是
  /// 导入文件名去后缀），同名重导＝更新这个库。
  final String name;

  /// 分类名（与 [name] 同值，展示用）。
  final String category;

  /// 来源文件名（展示用）。
  final String sourceName;

  final int importedAtMillis;

  /// 本库带来的作品数（含与目标库重合的）。
  final int works;

  /// 本库带来的线路数。
  final int playUrls;

  /// 契约别名（施工图字段名）。
  int get workCount => works;

  /// 契约别名（施工图字段名）。
  int get importedAtMs => importedAtMillis;
}

/// 并存合并的结果（施工图 MagnetImportOutcome 的超集：多带
/// ok/error/name/categories/totalWorks，供管理页文案与报错）。
class MagnetImportOutcome {
  const MagnetImportOutcome({
    required this.ok,
    this.error,
    this.libraryId = 0,
    this.name = '',
    this.category = '',
    this.categories = const [],
    this.addedWorks = 0,
    this.totalWorks = 0,
    this.addedPlayUrls = 0,
    this.replaced = false,
  });

  final bool ok;
  final String? error;

  /// 第一个分类切片的登记 id（多切片时仅作参考）。
  final int libraryId;
  final String name;

  /// 只有一个分类切片时就是它；多切片时为空，看 [categories]。
  final String category;

  /// 本次导入登记的全部分类（一个文件里有几个主分类就有
  /// 几个，逐个登记、逐个可删）。
  final List<String> categories;

  /// 真正新增进目标库的作品数（导入前不存在的）。
  final int addedWorks;

  /// 本次收录的作品总数（含重合）。
  final int totalWorks;

  /// 真正新增的线路数。
  final int addedPlayUrls;

  /// 同名分类已存在、这次是更新（先删旧登记再并入）。
  final bool replaced;
}

/// 自动补登记的结果（整库导入/打开存量库时用，见
/// [ActressMagnetLibraryStore.ensureAutoRegistered]）。
class MagnetAutoRegisterOutcome {
  const MagnetAutoRegisterOutcome({
    required this.changed,
    this.addedSlices = const [],
    this.registeredWorks = 0,
    this.registeredMagnetUrls = 0,
  });

  /// 这次有没有新建切片（false = 本来就齐 / 不需要登记）。
  final bool changed;

  /// 这次新建的分类切片名（含兜底片，若有）。
  final List<String> addedSlices;

  /// 这次登记的作品总数（只算新建切片名下的）。
  final int registeredWorks;

  /// 这次登记的磁力线路总数（只算新建切片名下的）。
  final int registeredMagnetUrls;
}

/// 删库的结果。
class MagnetRemoveResult {
  const MagnetRemoveResult({
    required this.removedWorks,
    required this.removedPlayUrls,
  });

  /// 整部删掉的作品数（本库独有的）。
  final int removedWorks;

  /// 摘掉的线路数（含共享作品上本库贡献的磁力线路）。
  final int removedPlayUrls;
}

/// 库名＝文件名去后缀（.sql / .sql.gz / .gz 都剥）。
String magnetLibraryNameOfFile(String path) {
  var name = path.split('/').last.split('\\').last;
  final lower = name.toLowerCase();
  if (lower.endsWith('.sql.gz')) {
    name = name.substring(0, name.length - 7);
  } else if (lower.endsWith('.sql')) {
    name = name.substring(0, name.length - 4);
  } else if (lower.endsWith('.gz')) {
    name = name.substring(0, name.length - 3);
  }
  return name.trim();
}

/// 来源登记表建表语句（落在目标库里，与标准表同库）。
const magnetLibraryDdl = <String>[
  'CREATE TABLE IF NOT EXISTS magnet_libraries ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL UNIQUE, '
      "category TEXT NOT NULL DEFAULT '', "
      "source_name TEXT NOT NULL DEFAULT '', "
      'imported_at INTEGER NOT NULL DEFAULT 0, '
      'works INTEGER NOT NULL DEFAULT 0, '
      'play_urls INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE IF NOT EXISTS magnet_library_works ('
      'library_id INTEGER NOT NULL, '
      'vod_id TEXT NOT NULL, '
      'was_existing INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (library_id, vod_id))',
  'CREATE TABLE IF NOT EXISTS magnet_library_play_urls ('
      'library_id INTEGER NOT NULL, '
      'vod_id TEXT NOT NULL, '
      'play_url TEXT NOT NULL, '
      'was_existing INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (library_id, vod_id, play_url))',
  'CREATE TABLE IF NOT EXISTS magnet_library_actresses ('
      'library_id INTEGER NOT NULL, '
      'cate_id TEXT NOT NULL, '
      'was_existing INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (library_id, cate_id))',
  // 分类行也要登记来源：目标库里原本没有分类行的共享作品，
  // 并入时会吃进本库的分类行；删库时不摘掉它，这个分类就
  // 会在分类栏里阴魂不散（删库分类必须消失）。
  'CREATE TABLE IF NOT EXISTS magnet_library_categories ('
      'library_id INTEGER NOT NULL, '
      'vod_id TEXT NOT NULL, '
      "main_category TEXT NOT NULL DEFAULT '', "
      'was_existing INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (library_id, vod_id))',
];

Future<void> ensureMagnetLibraryTables(DatabaseExecutor db) async {
  for (final ddl in magnetLibraryDdl) {
    await db.execute(ddl);
  }
}

/// 磁力分类库数据层：全部方法都对调用方传入的 [Database]
/// 干活（生产落点是导入槽库文件，由调用方打开），本类不开
/// 自己的连接、不决定落点。
class ActressMagnetLibraryStore {
  const ActressMagnetLibraryStore();

  /// 建五张登记表（幂等）。
  static Future<void> ensureSchema(Database db) =>
      ensureMagnetLibraryTables(db);

  /// 已导入的磁力分类库（按导入时间倒序）。
  Future<List<MagnetLibraryRecord>> listLibraries(Database db) async {
    await ensureMagnetLibraryTables(db);
    final rows = await db.query(
      'magnet_libraries',
      orderBy: 'imported_at DESC, id DESC',
    );
    return [for (final row in rows) _recordFromRow(row)];
  }

  MagnetLibraryRecord _recordFromRow(Map<String, Object?> row) =>
      MagnetLibraryRecord(
        id: (row['id'] as num?)?.toInt() ?? 0,
        name: row['name']?.toString() ?? '',
        category: row['category']?.toString() ?? '',
        sourceName: row['source_name']?.toString() ?? '',
        importedAtMillis: (row['imported_at'] as num?)?.toInt() ?? 0,
        works: (row['works'] as num?)?.toInt() ?? 0,
        playUrls: (row['play_urls'] as num?)?.toInt() ?? 0,
      );

  Future<bool> _tableExists(
    DatabaseExecutor db,
    String table, {
    String schema = '',
  }) async {
    final rows = await db.rawQuery(
      "SELECT name FROM ${schema}sqlite_master "
      "WHERE type = 'table' AND name = ? LIMIT 1",
      [table],
    );
    return rows.isNotEmpty;
  }

  /// 两道尺数磁力线路：地址尺（play_url 以 magnet: 开头）为
  /// 主，标记尺（play_from = 'magnet'）兜底。查的是 [schema]
  /// 前缀下的 video_play_urls（'' = 本库，'mstage.' = 已
  /// ATTACH 的临时库）。表不存在回 0。
  Future<int> _magnetUrlCount(
    DatabaseExecutor db, {
    String schema = '',
  }) async {
    if (!await _tableExists(db, 'video_play_urls', schema: schema)) {
      return 0;
    }
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${schema}video_play_urls '
      "WHERE LOWER(TRIM(play_url)) LIKE 'magnet:%'",
    );
    var count = (rows.first['c'] as num?)?.toInt() ?? 0;
    if (count == 0) {
      // 第二道尺：play_from 标记（地址形态异常时兜底）。
      try {
        final marked = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM ${schema}video_play_urls '
          'WHERE LOWER(TRIM(play_from)) = ?',
          [actressMagnetPlayFrom],
        );
        count = (marked.first['c'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // play_from 列都没有：按地址尺的结论走。
      }
    }
    return count;
  }

  /// 临时库是不是磁力分类库（两道尺任一命中）：开只读连接
  /// 查 video_play_urls，两道都为 0（或没这张表）回 false。
  /// [openReadOnly] 仅供测试注入，生产走 sqflite 只读开库。
  static Future<bool> stagingIsMagnetLibrary(
    String stagingPath, {
    Future<Database> Function(String path)? openReadOnly,
  }) async {
    final db = await (openReadOnly ??
        (p) => openDatabase(p, readOnly: true, singleInstance: false))(
      stagingPath,
    );
    try {
      return await const ActressMagnetLibraryStore()._magnetUrlCount(db) > 0;
    } finally {
      await db.close();
    }
  }

  /// 把已落盘的临时库（stagingPath，标准结构）并存合并进
  /// [target]：ATTACH + 单事务，登记 was_existing 后只新增
  /// 不覆盖。不是磁力库（一条磁力线路都没有）时 ok=false、
  /// 目标库一字不动。[name] 不传时按 [sourceName] 去后缀取。
  Future<MagnetImportOutcome> mergeStaging(
    Database target,
    String stagingPath, {
    required String sourceName,
    String? name,
  }) async {
    final libraryName = name ?? magnetLibraryNameOfFile(sourceName);
    await target.execute('ATTACH DATABASE ? AS mstage', [stagingPath]);
    try {
      // 护栏（2026-11-28 取消激活批 C2）：staging 自报全量
      // 女优库形态（schema_meta 的 format='actress_library')
      // → 这是完整女优库文件、不是磁力增量，整单中止、目标
      // 库一字不动，提示走女优库导入。合并库（女优全量＋磁
      // 力线路）正是这个形态：旧实现把它按磁力并入，只并 6
      // 张标准表、其余表全丢，工作库被残化（诊断 §2）。
      if (await _tableExists(target, 'schema_meta', schema: 'mstage.')) {
        try {
          final metaRows = await target.rawQuery(
            "SELECT value FROM mstage.schema_meta "
            "WHERE key = 'format' LIMIT 1",
          );
          final format = metaRows.isEmpty
              ? ''
              : metaRows.first['value']?.toString() ?? '';
          if (format.trim().toLowerCase() == 'actress_library') {
            return const MagnetImportOutcome(
              ok: false,
              error: '这个文件是完整的女优库数据库（作品、分类都在里面），'
                  '不能当磁力库合并；请用「导入数据库」走女优库导入',
            );
          }
        } catch (_) {
          // schema_meta 形态异常（没 key/value 列等）：护栏查
          // 不清就不拦，往下走原有两道尺判定。
        }
      }
      // 先验：临时库里得有磁力线路，否则这不是磁力分类库，
      // 整库文件走「导入数据库」的替换路，别在这里并掉。
      final magnetCount = await _magnetUrlCount(target, schema: 'mstage.');
      if (magnetCount == 0) {
        return const MagnetImportOutcome(
          ok: false,
          error: '这个文件里没有磁力链接，不是磁力分类库；'
              '整库数据库请用上面的「导入数据库」',
        );
      }
      // 结构先验：合并 SQL 按标准表写，临时库缺标准表直接
      // 拦下（.db 通用结构文件会走到这里），不开事务。
      for (final table in ['videos', 'actresses', 'video_actress']) {
        if (!await _tableExists(target, table, schema: 'mstage.')) {
          return const MagnetImportOutcome(
            ok: false,
            error: '这个文件的结构不是女优库标准结构，没法并入磁力分类库',
          );
        }
      }
      // 分类切片（交付形态是一个合集文件、分类靠库内字段区
      // 分）：临时库里有几个主分类就切几个片、逐片登记，删
      // 的时候也逐片删；一类一个文件时只有一个片。没有分类
      // 行的作品归以文件名命名的兜底片。
      final realCategories = <String>[];
      if (await _tableExists(target, 'video_category', schema: 'mstage.')) {
        final rows = await target.rawQuery(
          'SELECT main_category FROM mstage.video_category '
          "WHERE TRIM(COALESCE(main_category, '')) <> '' "
          'GROUP BY main_category ORDER BY main_category',
        );
        realCategories.addAll([
          for (final row in rows) row['main_category'].toString(),
        ]);
      }
      var hasUncategorized = realCategories.isEmpty;
      if (!hasUncategorized) {
        final rows = await target.rawQuery(
          'SELECT COUNT(*) AS c FROM mstage.videos s '
          'LEFT JOIN mstage.video_category c ON c.vod_id = s.vod_id '
          "WHERE c.vod_id IS NULL "
          "OR TRIM(COALESCE(c.main_category, '')) = ''",
        );
        hasUncategorized = ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
      }
      final slices = <String>[...realCategories];
      if (hasUncategorized && !slices.contains(libraryName)) {
        slices.add(libraryName);
      }
      if (slices.isEmpty) slices.add(libraryName);

      late MagnetImportOutcome result;
      await target.transaction((txn) async {
        await ensureMagnetLibraryTables(txn);
        // 同名分类重导＝更新那个分类：先按删库语义摘掉旧的。
        var replaced = false;
        final libraryIds = <String, int>{};
        final importedAt = DateTime.now().millisecondsSinceEpoch;
        for (final slice in slices) {
          final existing = await txn.query(
            'magnet_libraries',
            columns: ['id'],
            where: 'name = ?',
            whereArgs: [slice],
          );
          if (existing.isNotEmpty) {
            await _removeLibraryInTxn(
              txn,
              (existing.first['id'] as num).toInt(),
            );
            replaced = true;
          }
          libraryIds[slice] = await txn.insert('magnet_libraries', {
            'name': slice,
            'category': slice,
            'source_name': sourceName,
            'imported_at': importedAt,
          });
        }
        // 来源登记：并入前先记下每行在目标库里是否已存在。
        // 作品按它在临时库里的主分类归片；线路/演员/分类行
        // 跟着作品的归片走。
        for (final entry in libraryIds.entries) {
          final slice = entry.key;
          final libraryId = entry.value;
          final isRealSlice = realCategories.contains(slice);
          if (isRealSlice) {
            await txn.execute(
              'INSERT OR IGNORE INTO magnet_library_works '
              '(library_id, vod_id, was_existing) '
              'SELECT ?, s.vod_id, CASE WHEN EXISTS ('
              'SELECT 1 FROM videos v WHERE v.vod_id = s.vod_id'
              ') THEN 1 ELSE 0 END FROM mstage.videos s '
              'JOIN mstage.video_category c ON c.vod_id = s.vod_id '
              'WHERE c.main_category = ?',
              [libraryId, slice],
            );
          }
          if (!isRealSlice || slice == libraryName) {
            // 兜底片（以及与文件名同名的真分类片）收没有
            // 分类行的作品。
            await txn.execute(
              'INSERT OR IGNORE INTO magnet_library_works '
              '(library_id, vod_id, was_existing) '
              'SELECT ?, s.vod_id, CASE WHEN EXISTS ('
              'SELECT 1 FROM videos v WHERE v.vod_id = s.vod_id'
              ') THEN 1 ELSE 0 END FROM mstage.videos s '
              'LEFT JOIN mstage.video_category c '
              'ON c.vod_id = s.vod_id '
              "WHERE c.vod_id IS NULL "
              "OR TRIM(COALESCE(c.main_category, '')) = ''",
              [libraryId],
            );
          }
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_play_urls '
            '(library_id, vod_id, play_url, was_existing) '
            'SELECT ?, s.vod_id, s.play_url, CASE WHEN EXISTS ('
            'SELECT 1 FROM video_play_urls u '
            'WHERE u.vod_id = s.vod_id AND u.play_url = s.play_url'
            ') THEN 1 ELSE 0 END FROM mstage.video_play_urls s '
            'JOIN magnet_library_works w '
            'ON w.library_id = ? AND w.vod_id = s.vod_id',
            [libraryId, libraryId],
          );
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_actresses '
            '(library_id, cate_id, was_existing) '
            'SELECT ?, va.cate_id, CASE WHEN EXISTS ('
            'SELECT 1 FROM actresses a WHERE a.cate_id = va.cate_id'
            ') THEN 1 ELSE 0 END '
            'FROM (SELECT DISTINCT cate_id, vod_id '
            'FROM mstage.video_actress) va '
            'JOIN magnet_library_works w '
            'ON w.library_id = ? AND w.vod_id = va.vod_id',
            [libraryId, libraryId],
          );
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_categories '
            '(library_id, vod_id, main_category, was_existing) '
            'SELECT ?, s.vod_id, s.main_category, CASE WHEN EXISTS ('
            'SELECT 1 FROM video_category c WHERE c.vod_id = s.vod_id'
            ') THEN 1 ELSE 0 END FROM mstage.video_category s '
            'JOIN magnet_library_works w '
            'ON w.library_id = ? AND w.vod_id = s.vod_id',
            [libraryId, libraryId],
          );
        }
        // 并入标准表：已有的行一律不覆盖（目标库为准）。
        await txn.execute(
          'INSERT OR IGNORE INTO actresses '
          '(cate_id, name, avatar, created_at, sex, roster_id, claimed) '
          'SELECT cate_id, name, avatar, created_at, sex, roster_id, '
          'claimed FROM mstage.actresses',
        );
        await txn.execute(
          'INSERT OR IGNORE INTO videos '
          '(vod_id, title, pic_url, m3u8_url, vod_remarks, vod_pubdate, '
          'vod_area, vod_year, vod_content, vod_play_from, vod_play_url, '
          'type_name, created_at) '
          'SELECT vod_id, title, pic_url, m3u8_url, vod_remarks, '
          'vod_pubdate, vod_area, vod_year, vod_content, vod_play_from, '
          'vod_play_url, type_name, created_at FROM mstage.videos',
        );
        await txn.execute(
          'INSERT OR IGNORE INTO video_actress (vod_id, cate_id) '
          'SELECT vod_id, cate_id FROM mstage.video_actress',
        );
        await txn.execute(
          'INSERT OR IGNORE INTO video_play_urls '
          '(vod_id, play_url, play_from) '
          'SELECT vod_id, play_url, play_from FROM mstage.video_play_urls',
        );
        await txn.execute(
          'INSERT OR IGNORE INTO video_category (vod_id, main_category) '
          'SELECT vod_id, main_category FROM mstage.video_category',
        );
        if (await _tableExists(txn, 'video_tag') &&
            await _tableExists(txn, 'video_tag', schema: 'mstage.')) {
          await txn.execute(
            'INSERT OR IGNORE INTO video_tag (vod_id, tag_name) '
            'SELECT vod_id, tag_name FROM mstage.video_tag',
          );
        }
        // 保全合并（2026-11-28 取消激活批 C2）：标准 6 表之
        // 外，staging 与目标库共有的表逐表并入，目标库独有
        // 的表与数据原样保留；staging 有而目标库没有的表按
        // staging 自己的建表语句补建再并入——绝不以子集库
        // 换掉工作库（旧实现只并 6 表，index_categories /
        // tags / video_ranking / actor_ranking / schema_meta
        // 被整表丢弃，工作库残化，诊断 §2/§3）。
        await _mergeRemainingTables(txn);
        var totalWorks = 0;
        var addedWorks = 0;
        var addedUrls = 0;
        for (final libraryId in libraryIds.values) {
          final sliceWorks = await _countWhere(
            txn,
            'magnet_library_works',
            libraryId,
          );
          final sliceUrls = await _countWhere(
            txn,
            'magnet_library_play_urls',
            libraryId,
          );
          totalWorks += sliceWorks;
          addedWorks += await _countWhere(
            txn,
            'magnet_library_works',
            libraryId,
            onlyNew: true,
          );
          addedUrls += await _countWhere(
            txn,
            'magnet_library_play_urls',
            libraryId,
            onlyNew: true,
          );
          await txn.update(
            'magnet_libraries',
            {'works': sliceWorks, 'play_urls': sliceUrls},
            where: 'id = ?',
            whereArgs: [libraryId],
          );
        }
        result = MagnetImportOutcome(
          ok: true,
          libraryId: libraryIds.values.first,
          name: libraryName,
          category: slices.length == 1 ? slices.single : '',
          categories: slices,
          addedWorks: addedWorks,
          totalWorks: totalWorks,
          addedPlayUrls: addedUrls,
          replaced: replaced,
        );
      });
      // 汇总重建：修仙版名单汇总是读侧内存现算（见文件头），
      // 这里没有落表要重建，调用方 notifyChanged/重载即可。
      return result;
    } finally {
      try {
        await target.execute('DETACH DATABASE mstage');
      } catch (_) {
        // 没挂上/已卸下：不用管。
      }
    }
  }

  Future<int> _countWhere(
    DatabaseExecutor db,
    String table,
    int libraryId, {
    bool onlyNew = false,
  }) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table WHERE library_id = ?'
      '${onlyNew ? ' AND was_existing = 0' : ''}',
      [libraryId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 保全合并已由标准合并段与登记段处理的表：标准 6 表走
  /// 各自的显式列清单、登记 5 表是目标库自己的账，都不进
  /// [_mergeRemainingTables] 的通用并入。
  static const _mergeHandledTables = <String>{
    'videos',
    'actresses',
    'video_actress',
    'video_play_urls',
    'video_category',
    'video_tag',
    'magnet_libraries',
    'magnet_library_works',
    'magnet_library_play_urls',
    'magnet_library_actresses',
    'magnet_library_categories',
  };

  Future<List<String>> _tableNames(
    DatabaseExecutor db, {
    String schema = '',
  }) async {
    final rows = await db.rawQuery(
      "SELECT name FROM ${schema}sqlite_master "
      "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    return [for (final row in rows) row['name'].toString()];
  }

  Future<List<String>> _columnNames(
    DatabaseExecutor db,
    String table, {
    String schema = '',
  }) async {
    final escaped = table.replaceAll("'", "''");
    final rows = await db.rawQuery(
      "PRAGMA ${schema}table_info('$escaped')",
    );
    return [for (final row in rows) row['name'].toString()];
  }

  static String _quotedIdent(String name) =>
      '"${name.replaceAll('"', '""')}"';

  /// 通用保全并入（mergeStaging 事务内、标准表并完后调）：
  /// staging（mstage）里除 [_mergeHandledTables] 外的每张
  /// 表——目标库已有同名表：按两边共有列 INSERT OR IGNORE
  /// 逐行并入（目标行优先、一条不覆盖）；目标库没有：用
  /// staging 在 sqlite_master 里存的建表语句原样补建（与女
  /// 优库导入器落 staging 时同一份 DDL，即真库的完整建表
  /// 口径）再整表并入。目标库独有的表本方法根本不碰。
  Future<void> _mergeRemainingTables(Transaction txn) async {
    final stagingTables = await _tableNames(txn, schema: 'mstage.');
    final targetTables = (await _tableNames(txn)).toSet();
    for (final table in stagingTables) {
      if (_mergeHandledTables.contains(table)) continue;
      final ident = _quotedIdent(table);
      if (!targetTables.contains(table)) {
        final ddlRows = await txn.rawQuery(
          "SELECT sql FROM mstage.sqlite_master "
          "WHERE type = 'table' AND name = ?",
          [table],
        );
        final ddl = ddlRows.isEmpty
            ? null
            : ddlRows.first['sql']?.toString();
        if (ddl == null || ddl.trim().isEmpty) continue;
        await txn.execute(ddl);
      }
      final stagingCols = await _columnNames(txn, table, schema: 'mstage.');
      final targetCols = (await _columnNames(txn, table)).toSet();
      final common = [
        for (final col in stagingCols)
          if (targetCols.contains(col)) col,
      ];
      if (common.isEmpty) continue;
      final colList = common.map(_quotedIdent).join(', ');
      await txn.execute(
        'INSERT OR IGNORE INTO $ident ($colList) '
        'SELECT $colList FROM mstage.$ident',
      );
    }
  }

  /// 删除一个已导入的磁力分类库（语义见文件头）：独有作品
  /// 整部删、共享作品只摘本库贡献的线路与分类行、演员按
  /// 「别库没带＋无人挂」才删。
  Future<MagnetRemoveResult> removeLibrary(Database db, int libraryId) async {
    await ensureMagnetLibraryTables(db);
    late MagnetRemoveResult result;
    await db.transaction((txn) async {
      result = await _removeLibraryInTxn(txn, libraryId);
    });
    // 汇总重建同 mergeStaging：读侧内存现算，无落表要重建。
    return result;
  }

  /// 删库语义（事务内）：本库独有作品整部删；共享作品只摘
  /// 本库贡献的线路；本库带来的演员在没作品后删行。
  Future<MagnetRemoveResult> _removeLibraryInTxn(
    Transaction txn,
    int libraryId,
  ) async {
    final rows = await txn.query(
      'magnet_libraries',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [libraryId],
    );
    if (rows.isEmpty) {
      return const MagnetRemoveResult(removedWorks: 0, removedPlayUrls: 0);
    }
    // 本库独有作品（导入前不存在、别的磁力库也没带）落临时表。
    await txn.execute(
      'CREATE TEMP TABLE IF NOT EXISTS magnet_doomed '
      '(vod_id TEXT PRIMARY KEY)',
    );
    await txn.execute('DELETE FROM magnet_doomed');
    await txn.execute(
      'INSERT INTO magnet_doomed (vod_id) '
      'SELECT vod_id FROM magnet_library_works '
      'WHERE library_id = ? AND was_existing = 0 '
      'AND vod_id NOT IN (SELECT vod_id FROM magnet_library_works '
      'WHERE library_id <> ?)',
      [libraryId, libraryId],
    );
    var removedUrls = 0;
    removedUrls += await txn.rawUpdate(
      'DELETE FROM video_play_urls WHERE vod_id IN '
      '(SELECT vod_id FROM magnet_doomed)',
    );
    // 共享作品上本库贡献的线路（别的磁力库也带了同一条的不摘）。
    removedUrls += await txn.rawUpdate(
      'DELETE FROM video_play_urls WHERE (vod_id, play_url) IN '
      '(SELECT vod_id, play_url FROM magnet_library_play_urls '
      'WHERE library_id = ? AND was_existing = 0) '
      'AND vod_id NOT IN (SELECT vod_id FROM magnet_doomed) '
      'AND (vod_id, play_url) NOT IN '
      '(SELECT vod_id, play_url FROM magnet_library_play_urls '
      'WHERE library_id <> ?)',
      [libraryId, libraryId],
    );
    await txn.execute(
      'DELETE FROM video_actress WHERE vod_id IN '
      '(SELECT vod_id FROM magnet_doomed)',
    );
    await txn.execute(
      'DELETE FROM video_category WHERE vod_id IN '
      '(SELECT vod_id FROM magnet_doomed)',
    );
    // 幸存作品上本库贡献的分类行（导入前它没有分类行）也摘
    // 掉；别的磁力库给同一作品贡献了同一分类的不摘。
    await txn.execute(
      'DELETE FROM video_category WHERE (vod_id, main_category) IN '
      '(SELECT vod_id, main_category FROM magnet_library_categories '
      'WHERE library_id = ? AND was_existing = 0) '
      'AND vod_id NOT IN (SELECT vod_id FROM magnet_doomed) '
      'AND (vod_id, main_category) NOT IN '
      '(SELECT vod_id, main_category FROM magnet_library_categories '
      'WHERE library_id <> ?)',
      [libraryId, libraryId],
    );
    if (await _tableExists(txn, 'video_tag')) {
      await txn.execute(
        'DELETE FROM video_tag WHERE vod_id IN '
        '(SELECT vod_id FROM magnet_doomed)',
      );
    }
    final removedWorks = await txn.rawUpdate(
      'DELETE FROM videos WHERE vod_id IN '
      '(SELECT vod_id FROM magnet_doomed)',
    );
    // 本库带来的演员：别的库没带、删完作品后没人挂的删行。
    await txn.execute(
      'DELETE FROM actresses WHERE cate_id IN '
      '(SELECT cate_id FROM magnet_library_actresses '
      'WHERE library_id = ? AND was_existing = 0) '
      'AND cate_id NOT IN (SELECT cate_id FROM '
      'magnet_library_actresses WHERE library_id <> ?) '
      'AND cate_id NOT IN (SELECT cate_id FROM video_actress)',
      [libraryId, libraryId],
    );
    await txn.execute(
      'DELETE FROM magnet_library_works WHERE library_id = ?',
      [libraryId],
    );
    await txn.execute(
      'DELETE FROM magnet_library_play_urls WHERE library_id = ?',
      [libraryId],
    );
    await txn.execute(
      'DELETE FROM magnet_library_actresses WHERE library_id = ?',
      [libraryId],
    );
    await txn.execute(
      'DELETE FROM magnet_library_categories WHERE library_id = ?',
      [libraryId],
    );
    await txn.execute('DELETE FROM magnet_libraries WHERE id = ?', [
      libraryId,
    ]);
    await txn.execute('DROP TABLE IF EXISTS magnet_doomed');
    return MagnetRemoveResult(
      removedWorks: removedWorks,
      removedPlayUrls: removedUrls,
    );
  }

  Future<bool> _columnExists(
    DatabaseExecutor db,
    String table,
    String column,
  ) async {
    // 表名只来自本文件内的固定字面量，无注入面。
    final rows = await db.rawQuery(
      "SELECT name FROM pragma_table_info('$table')",
    );
    return rows.any((row) => row['name']?.toString() == column);
  }

  /// 自动补登记（2026-11-28 用户令「修复导入数据库要登记自动
  /// 显示这些32个分类」）：整库导入（女优库 .db/.sql、合并文件
  /// 演员段）落进导入槽的库，自带磁力作品与主分类，却没有磁力
  /// 登记——合并库就是这个形态。演员库分类栏与管理页登记列表
  /// 都读登记表，没登记就什么都不显示（用户实况）。本方法从
  /// 目标库自身数据派生登记：切片 = 库内全部主分类（video_
  /// category 去重非空）＋无分类磁力作品的兜底片（名按来源
  /// 文件名取，缺省「未分类」；兜底名与真分类同名时并进那个
  /// 真分类片，与 [mergeStaging] 同口径）；每片只登记该分类
  /// 下**带磁力线路的作品**（两道尺，与查询层成员尺一致）、
  /// 这些作品的磁力线路、关联演员与分类行。成员只认磁力作
  /// 品这一条与 mergeStaging 不同，是有意的：mergeStaging
  /// 的临时库本身就是磁力合集、作品全是合集成员；本方法面
  /// 对的是整本女优库，若按分类把全部作品登记进来，磁力分
  /// 类计数会吞掉整库（与无登记时查询层按磁力线路现算的口
  /// 径打架）。无磁力作品的分类也照样建片（计数 0），保证
  /// 分类齐现——合并库实测对账：31 个主分类＋兜底片共 32
  /// 片、登记磁力作品 94,699 部、磁力线路 99,301 条。
  ///
  /// 只补缺：登记表里已有的同名切片（磁力文件正经导入登记
  /// 的）一律不动；已齐时整件跳过（幂等，重复调用无副作用）。
  /// 登记行 was_existing 全记 1——这些作品与线路本来就是这本
  /// 库自带的，不是哪个磁力文件「带来」的：日后按勾选删这个
  /// 分类，删库语义只摘登记、本库作品与线路一条不动。
  ///
  /// 触发门：标准表不全（通用结构库等）或库里一条磁力线路
  /// 都没有（纯女优库）→ 直接跳过，不建登记表、不生分类。
  Future<MagnetAutoRegisterOutcome> ensureAutoRegistered(
    Database db, {
    String sourceName = '',
  }) async {
    for (final table in ['videos', 'video_category', 'video_play_urls']) {
      if (!await _tableExists(db, table)) {
        return const MagnetAutoRegisterOutcome(changed: false);
      }
    }
    if (await _magnetUrlCount(db) == 0) {
      return const MagnetAutoRegisterOutcome(changed: false);
    }
    await ensureMagnetLibraryTables(db);
    final existingRows = await db.query('magnet_libraries', columns: ['name']);
    final existing = {
      for (final row in existingRows) row['name'].toString(),
    };
    final categoryRows = await db.rawQuery(
      'SELECT main_category FROM video_category '
      "WHERE TRIM(COALESCE(main_category, '')) <> '' "
      'GROUP BY main_category ORDER BY main_category',
    );
    final namedSlices = [
      for (final row in categoryRows) row['main_category'].toString(),
    ];
    // 磁力作品谓词（两道尺，与查询层 _magnetUrlScopeSql 同
    // 口径）：登记成员只认带磁力线路的作品。
    final hasPlayFrom = await _columnExists(db, 'video_play_urls', 'play_from');
    final magnetWork =
        'EXISTS (SELECT 1 FROM video_play_urls u '
        'WHERE u.vod_id = v.vod_id AND '
        "(LOWER(TRIM(u.play_url)) LIKE 'magnet:%'"
        "${hasPlayFrom ? " OR LOWER(TRIM(COALESCE(u.play_from, ''))) = 'magnet'" : ''}))";
    final uncategorizedRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM videos v '
      'LEFT JOIN video_category c ON c.vod_id = v.vod_id '
      "WHERE (c.vod_id IS NULL "
      "OR TRIM(COALESCE(c.main_category, '')) = '') "
      'AND $magnetWork',
    );
    final hasUncategorized =
        ((uncategorizedRows.first['c'] as num?)?.toInt() ?? 0) > 0;
    // 兜底片名按来源文件名取并剥常见后缀（magnetLibraryName
    // OfFile 剥 .sql/.gz 但不剥 .db，这里补上，免得片名带个
    // 「.db」尾巴）；来源名缺省时就叫「未分类」。
    var sourceBase = sourceName.trim();
    if (sourceBase.toLowerCase().endsWith('.db')) {
      sourceBase = sourceBase.substring(0, sourceBase.length - 3);
    }
    final fallbackName = sourceBase.isEmpty
        ? '未分类'
        : magnetLibraryNameOfFile(sourceBase);
    // 兜底名撞真分类名：并进那个真分类片（它若已登记则守
    // 「已有不动」，无分类作品这次不补）；撞已登记的其它名
    // 字同样不补兜底片。
    final foldInto = hasUncategorized && namedSlices.contains(fallbackName)
        ? fallbackName
        : null;
    final toCreate = <String>[
      for (final name in namedSlices)
        if (!existing.contains(name)) name,
    ];
    final createFallback =
        hasUncategorized &&
        foldInto == null &&
        !existing.contains(fallbackName);
    if (toCreate.isEmpty && !createFallback) {
      return const MagnetAutoRegisterOutcome(changed: false);
    }
    var registeredWorks = 0;
    var registeredUrls = 0;
    final added = <String>[];
    await db.transaction((txn) async {
      await ensureMagnetLibraryTables(txn);
      // 事务内复查已登记集，防并发重复建同名片撞 UNIQUE。
      final nowRows = await txn.query('magnet_libraries', columns: ['name']);
      final nowExisting = {
        for (final row in nowRows) row['name'].toString(),
      };
      final importedAt = DateTime.now().millisecondsSinceEpoch;
      final hasActressLink = await _tableExists(txn, 'video_actress');
      for (final slice in [
        ...toCreate,
        if (createFallback) fallbackName,
      ]) {
        if (nowExisting.contains(slice)) continue;
        final libraryId = await txn.insert('magnet_libraries', {
          'name': slice,
          'category': slice,
          'source_name': sourceName,
          'imported_at': importedAt,
        });
        final isFallback = createFallback && slice == fallbackName;
        if (!isFallback) {
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_works '
            '(library_id, vod_id, was_existing) '
            'SELECT ?, v.vod_id, 1 FROM videos v '
            'JOIN video_category c ON c.vod_id = v.vod_id '
            'WHERE c.main_category = ? AND $magnetWork',
            [libraryId, slice],
          );
        }
        if (isFallback || slice == foldInto) {
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_works '
            '(library_id, vod_id, was_existing) '
            'SELECT ?, v.vod_id, 1 FROM videos v '
            'LEFT JOIN video_category c ON c.vod_id = v.vod_id '
            "WHERE (c.vod_id IS NULL "
            "OR TRIM(COALESCE(c.main_category, '')) = '') "
            'AND $magnetWork',
            [libraryId],
          );
        }
        // 线路登记只记磁力线路（两道尺，与计数口径一致）：
        // 普通线路不是磁力库带来的，不进登记。
        await txn.execute(
          'INSERT OR IGNORE INTO magnet_library_play_urls '
          '(library_id, vod_id, play_url, was_existing) '
          'SELECT ?, w.vod_id, u.play_url, 1 '
          'FROM magnet_library_works w '
          'JOIN video_play_urls u ON u.vod_id = w.vod_id '
          'WHERE w.library_id = ? AND '
          "(LOWER(TRIM(u.play_url)) LIKE 'magnet:%'"
          "${hasPlayFrom ? " OR LOWER(TRIM(COALESCE(u.play_from, ''))) = 'magnet'" : ''})",
          [libraryId, libraryId],
        );
        if (hasActressLink) {
          await txn.execute(
            'INSERT OR IGNORE INTO magnet_library_actresses '
            '(library_id, cate_id, was_existing) '
            'SELECT ?, va.cate_id, 1 '
            'FROM (SELECT DISTINCT cate_id, vod_id '
            'FROM video_actress) va '
            'JOIN magnet_library_works w '
            'ON w.library_id = ? AND w.vod_id = va.vod_id',
            [libraryId, libraryId],
          );
        }
        await txn.execute(
          'INSERT OR IGNORE INTO magnet_library_categories '
          '(library_id, vod_id, main_category, was_existing) '
          'SELECT ?, c.vod_id, c.main_category, 1 '
          'FROM video_category c '
          'JOIN magnet_library_works w '
          'ON w.library_id = ? AND w.vod_id = c.vod_id',
          [libraryId, libraryId],
        );
        final works = await _countWhere(
          txn,
          'magnet_library_works',
          libraryId,
        );
        final urls = await _countWhere(
          txn,
          'magnet_library_play_urls',
          libraryId,
        );
        await txn.update(
          'magnet_libraries',
          {'works': works, 'play_urls': urls},
          where: 'id = ?',
          whereArgs: [libraryId],
        );
        registeredWorks += works;
        registeredUrls += urls;
        added.add(slice);
      }
    });
    return MagnetAutoRegisterOutcome(
      changed: added.isNotEmpty,
      addedSlices: added,
      registeredWorks: registeredWorks,
      registeredMagnetUrls: registeredUrls,
    );
  }

  /// 已登记的磁力分类名（去重、非空）：演员库分类栏的磁力
  /// 分类组数据源。登记表不在（还没导入过）回空。
  Future<List<String>> magnetCategories(Database db) async {
    if (!await _tableExists(db, 'magnet_libraries')) return const [];
    final rows = await db.rawQuery(
      "SELECT DISTINCT category FROM magnet_libraries "
      "WHERE TRIM(category) <> '' ORDER BY category",
    );
    return [for (final row in rows) row['category'].toString()];
  }

  /// 一批作品的磁力地址（vod_id → 磁力地址列表）：按 400 条
  /// 一批查 video_play_urls，只留两道尺命中的行。某批异常
  /// 返回已累积结果（读不到不拖垮列表页）。
  Future<Map<String, List<String>>> magnetUrlsForWorks(
    Database db,
    List<String> vodIds,
  ) async {
    final result = <String, List<String>>{};
    if (vodIds.isEmpty) return result;
    const batchSize = 400;
    for (var i = 0; i < vodIds.length; i += batchSize) {
      final batch = vodIds.sublist(
        i,
        i + batchSize > vodIds.length ? vodIds.length : i + batchSize,
      );
      final placeholders = List.filled(batch.length, '?').join(', ');
      try {
        final rows = await db.rawQuery(
          'SELECT vod_id, play_url, play_from FROM video_play_urls '
          'WHERE vod_id IN ($placeholders)',
          batch,
        );
        for (final row in rows) {
          final line = ActressPlayLine(
            url: row['play_url']?.toString() ?? '',
            from: row['play_from']?.toString() ?? '',
          );
          if (!line.isMagnet || line.url.isEmpty) continue;
          result
              .putIfAbsent(row['vod_id'].toString(), () => <String>[])
              .add(line.url);
        }
      } catch (_) {
        return result;
      }
    }
    return result;
  }
}

/// [buildMagnetStagingDb] 的结果：成功带 staging 文件路径，
/// 失败带中文原因（stagingPath 为 null）。
class MagnetStagingOutcome {
  const MagnetStagingOutcome({this.stagingPath, this.error});

  final String? stagingPath;
  final String? error;

  bool get ok => stagingPath != null;
}

/// 把用户选的文件落成归一化 staging 库文件（合并前的临时
/// 库）：.sql/.sql.gz 走现行 [ActressSqlImporter]（以
/// [stagingPath] 冒充 dbPath 落盘，closeDatabase 传空函数，
/// 不碰目标库）；.db 走现行 [validateActressDbFile] 验法
/// （文件头＋结构探测＋作品数>0），过关后整文件复制为
/// staging。失败回 ok=false 并带原因，staging 不留残件由
/// 调用方清理。[importer] / [dbValidator] 仅供测试注入
/// （与 ActressDbImportService 的注入点同口径），生产走
/// 缺省实现。
Future<MagnetStagingOutcome> buildMagnetStagingDb(
  String sourcePath, {
  required String stagingPath,
  void Function(ActressSqlImportProgress)? onProgress,
  bool Function()? isCancelled,
  ActressSqlImporter? importer,
  ActressDbValidator? dbValidator,
}) async {
  final lower = sourcePath.toLowerCase();
  if (lower.endsWith('.sql') || lower.endsWith('.gz')) {
    // 组装接缝（20261127+3）：激活批把女优库版本门放进了共享
    // 导入器缺省路径；磁力库不是女优库、没有也不该有女优库版本
    // 字段，它的校验走磁力自己的两道尺（stagingIsMagnetLibrary
    // 与合并内兜底）。这里只借导入器落 staging 的能力，版本门
    // 传放行件，免得磁力 .sql 被女优库的门误拒。
    final result = await (importer ?? ActressSqlImporter()).importFile(
      sqlPath: sourcePath,
      dbPath: stagingPath,
      closeDatabase: () async {},
      onProgress: onProgress ?? (_) {},
      isCancelled: isCancelled,
    );
    if (!result.ok) {
      return MagnetStagingOutcome(error: result.error ?? '文件校验没通过');
    }
    return MagnetStagingOutcome(stagingPath: stagingPath);
  }
  if (lower.endsWith('.db')) {
    final validation = await (dbValidator ?? validateActressDbFile)(
      sourcePath,
    );
    if (!validation.ok) {
      return MagnetStagingOutcome(error: validation.error ?? '文件校验没通过');
    }
    try {
      final stagingFile = File(stagingPath);
      await stagingFile.parent.create(recursive: true);
      if (await stagingFile.exists()) await stagingFile.delete();
      await File(sourcePath).copy(stagingPath);
    } catch (e) {
      return MagnetStagingOutcome(error: '临时库落盘失败：$e');
    }
    return MagnetStagingOutcome(stagingPath: stagingPath);
  }
  return const MagnetStagingOutcome(error: '只认 .db、.sql 或 .sql.gz 文件');
}

/// staging 文件与目标库同目录时的缺省名（与魔蚁同名口径）。
String magnetStagingPathFor(String targetDbPath) =>
    path.join(path.dirname(targetDbPath), '.magnet-staging.db');

/// 打开一个库文件跑自动补登记（整库导入尾段用）：开读写连接
/// → [ActressMagnetLibraryStore.ensureAutoRegistered] → 关连
/// 接。失败原样抛给调用方决定（导入尾段记警告、打开兜底吞
/// 掉）。[openDb] 仅供测试注入，生产走 sqflite 本体。
Future<MagnetAutoRegisterOutcome> autoRegisterMagnetCategoriesInDbFile(
  String dbPath, {
  String sourceName = '',
  Future<Database> Function(String path)? openDb,
}) async {
  final db = await (openDb ??
      (p) => openDatabase(p, singleInstance: false))(dbPath);
  try {
    return await const ActressMagnetLibraryStore().ensureAutoRegistered(
      db,
      sourceName: sourceName,
    );
  } finally {
    await db.close();
  }
}

/// 打开演员库时的存量补登记（2026-11-28 用户令的「已导入」
/// 路）：导入槽里的库若有磁力作品却没登记（例如旧版走女优库
/// 激活路导入的合并库，用户实况），读库层打开它之前自动补一
/// 次，用户不用重导。只写导入槽文件——外置库永不写（生效路
/// 径是外置兜底时也不碰它）。按文件戳在本进程内只试一次
/// （补完文件戳会变、新戳下再查一次、查到已齐即跳过）；任何
/// 失败都吞掉，绝不挡读库。
class ActressMagnetAutoRegistration {
  ActressMagnetAutoRegistration._();

  static String? _attemptedStamp;

  /// 测试用：清掉进程内已试戳记。
  static void resetForTest() => _attemptedStamp = null;

  static Future<void> backfillImportedSlot({
    ActressDbSource? source,
    Future<Database> Function(String path)? openDb,
  }) async {
    try {
      final src = source ?? ActressDbSource.instance;
      final importedPath = await src.importedDbPath();
      if (importedPath.isEmpty) return;
      final file = File(importedPath);
      if (!file.existsSync() || file.lengthSync() == 0) return;
      final stat = file.statSync();
      final stamp =
          '$importedPath|${stat.size}|'
          '${stat.modified.millisecondsSinceEpoch}';
      if (_attemptedStamp == stamp) return;
      _attemptedStamp = stamp;
      await autoRegisterMagnetCategoriesInDbFile(
        importedPath,
        openDb: openDb,
      );
    } catch (_) {
      // 补登记是兜底动作：失败不挡演员库打开；文件再变化
      // （重导/换库）时还会再试。
    }
  }
}
