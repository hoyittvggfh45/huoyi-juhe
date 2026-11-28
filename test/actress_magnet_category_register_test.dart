// 磁力分类自动登记测试（2026-11-28 用户令「修复导入数据库要登记
// 自动显示这些32个分类」）：验合并库形态（有磁力作品与主分类、
// 没有磁力登记表）的库在导入/打开时被自动补登记——切片、逐片
// 作品/线路计数与库内实际对账、幂等、已有登记不动、无磁力不
// 生分类；并验查询层 magnetCategories/magnetWorks 读登记后的
// 结果，与核心版本取消设门后的整库导入放行。
//
// 真库假件与 actress_magnet_library_test.dart 同款：dart:ffi
// 直绑系统 libsqlite3 实现 sqflite 接口（本机无
// sqflite_common_ffi、pub.dev 不可达）。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_version.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';


// ---------------------------------------------------------------------------
// libsqlite3 FFI 绑定（最小集）
// ---------------------------------------------------------------------------

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _PrepareNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Int32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PrepareDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _BindTextNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _BindTextDart =
    int Function(Pointer<Void>, int, Pointer<Utf8>, int, Pointer<Void>);
typedef _BindIntNative = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindIntDart = int Function(Pointer<Void>, int, int);
typedef _BindDoubleNative = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);
typedef _BindNullNative = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);
typedef _BindBlobNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Int32, Pointer<Void>);
typedef _BindBlobDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);
typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ParamCountNative = Int32 Function(Pointer<Void>);
typedef _ParamCountDart = int Function(Pointer<Void>);
typedef _ColCountNative = Int32 Function(Pointer<Void>);
typedef _ColCountDart = int Function(Pointer<Void>);
typedef _ColNameNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColNameDart = Pointer<Utf8> Function(Pointer<Void>, int);
typedef _ColTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColTypeDart = int Function(Pointer<Void>, int);
typedef _ColIntNative = Int64 Function(Pointer<Void>, Int32);
typedef _ColIntDart = int Function(Pointer<Void>, int);
typedef _ColDoubleNative = Double Function(Pointer<Void>, Int32);
typedef _ColDoubleDart = double Function(Pointer<Void>, int);
typedef _ColTextNative = Pointer<Uint8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Uint8> Function(Pointer<Void>, int);
typedef _ColBlobNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _ColBlobDart = Pointer<Void> Function(Pointer<Void>, int);
typedef _ColBytesNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColBytesDart = int Function(Pointer<Void>, int);
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _ChangesNative = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);
typedef _LastRowidNative = Int64 Function(Pointer<Void>);
typedef _LastRowidDart = int Function(Pointer<Void>);

class _Sqlite {
  _Sqlite._() {
    final lib = DynamicLibrary.open('libsqlite3.so.0');
    open = lib.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open');
    close = lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close');
    prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>(
      'sqlite3_prepare_v2',
    );
    bindText = lib.lookupFunction<_BindTextNative, _BindTextDart>(
      'sqlite3_bind_text',
    );
    bindInt = lib.lookupFunction<_BindIntNative, _BindIntDart>(
      'sqlite3_bind_int64',
    );
    bindDouble = lib.lookupFunction<_BindDoubleNative, _BindDoubleDart>(
      'sqlite3_bind_double',
    );
    bindNull = lib.lookupFunction<_BindNullNative, _BindNullDart>(
      'sqlite3_bind_null',
    );
    bindBlob = lib.lookupFunction<_BindBlobNative, _BindBlobDart>(
      'sqlite3_bind_blob',
    );
    step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step');
    finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
      'sqlite3_finalize',
    );
    paramCount = lib.lookupFunction<_ParamCountNative, _ParamCountDart>(
      'sqlite3_bind_parameter_count',
    );
    colCount = lib.lookupFunction<_ColCountNative, _ColCountDart>(
      'sqlite3_column_count',
    );
    colName = lib.lookupFunction<_ColNameNative, _ColNameDart>(
      'sqlite3_column_name',
    );
    colType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>(
      'sqlite3_column_type',
    );
    colInt = lib.lookupFunction<_ColIntNative, _ColIntDart>(
      'sqlite3_column_int64',
    );
    colDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>(
      'sqlite3_column_double',
    );
    colText = lib.lookupFunction<_ColTextNative, _ColTextDart>(
      'sqlite3_column_text',
    );
    colBlob = lib.lookupFunction<_ColBlobNative, _ColBlobDart>(
      'sqlite3_column_blob',
    );
    colBytes = lib.lookupFunction<_ColBytesNative, _ColBytesDart>(
      'sqlite3_column_bytes',
    );
    errmsg = lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg');
    changes = lib.lookupFunction<_ChangesNative, _ChangesDart>(
      'sqlite3_changes',
    );
    lastRowid = lib.lookupFunction<_LastRowidNative, _LastRowidDart>(
      'sqlite3_last_insert_rowid',
    );
  }

  static final instance = _Sqlite._();

  late final _OpenDart open;
  late final _CloseDart close;
  late final _PrepareDart prepare;
  late final _BindTextDart bindText;
  late final _BindIntDart bindInt;
  late final _BindDoubleDart bindDouble;
  late final _BindNullDart bindNull;
  late final _BindBlobDart bindBlob;
  late final _StepDart step;
  late final _FinalizeDart finalize;
  late final _ParamCountDart paramCount;
  late final _ColCountDart colCount;
  late final _ColNameDart colName;
  late final _ColTypeDart colType;
  late final _ColIntDart colInt;
  late final _ColDoubleDart colDouble;
  late final _ColTextDart colText;
  late final _ColBlobDart colBlob;
  late final _ColBytesDart colBytes;
  late final _ErrmsgDart errmsg;
  late final _ChangesDart changes;
  late final _LastRowidDart lastRowid;
}

const _sqliteRow = 100;
const _sqliteDone = 101;

/// 真 SQLite 文件上的 sqflite Database 假件（测试专用）。
class FfiDatabase implements Database, Transaction {
  FfiDatabase._(this._handle, this.path);

  final Pointer<Void> _handle;

  @override
  final String path;

  var _open = true;
  var _txnDepth = 0;

  static Future<FfiDatabase> open(String path) async {
    final s = _Sqlite.instance;
    final namePtr = path.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final rc = s.open(namePtr, out);
      if (rc != 0) {
        throw StateError('sqlite3_open($path) 失败 rc=$rc');
      }
      return FfiDatabase._(out.value, path);
    } finally {
      calloc.free(namePtr);
      calloc.free(out);
    }
  }

  @override
  bool get isOpen => _open;

  String get _errorMessage => _Sqlite.instance.errmsg(_handle).toDartString();

  Pointer<Void> _prepare(String sql, List<Object?>? arguments) {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    final stmtOut = calloc<Pointer<Void>>();
    try {
      final rc = s.prepare(_handle, sqlPtr, -1, stmtOut, nullptr);
      if (rc != 0) {
        throw StateError('SQL 失败：$_errorMessage ← $sql');
      }
      final stmt = stmtOut.value;
      final count = s.paramCount(stmt);
      final args = arguments ?? const [];
      if (args.length > count) {
        s.finalize(stmt);
        throw StateError('参数个数多于占位符：$sql');
      }
      for (var i = 0; i < args.length; i++) {
        _bind(stmt, i + 1, args[i]);
      }
      return stmt;
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtOut);
    }
  }

  void _bind(Pointer<Void> stmt, int index, Object? value) {
    final s = _Sqlite.instance;
    if (value == null) {
      s.bindNull(stmt, index);
    } else if (value is int) {
      s.bindInt(stmt, index, value);
    } else if (value is bool) {
      s.bindInt(stmt, index, value ? 1 : 0);
    } else if (value is double) {
      s.bindDouble(stmt, index, value);
    } else if (value is Uint8List) {
      final ptr = calloc<Uint8>(value.isEmpty ? 1 : value.length);
      try {
        ptr.asTypedList(value.length).setAll(0, value);
        // SQLITE_STATIC（nullptr 析构）：step 在 free 前已跑完。
        s.bindBlob(stmt, index, ptr.cast<Void>(), value.length, nullptr);
      } finally {
        // blob 字节在 step 前不能释放：本假件 step 紧随其后且
        // 同步执行完才返回，释放放在 _run 里做不到，改为泄漏
        // 这一小块（测试进程短命，可接受）。
      }
    } else {
      final ptr = value.toString().toNativeUtf8();
      s.bindText(stmt, index, ptr, -1, nullptr);
      // SQLITE_STATIC：step 同步跑完后才释放（见 _run 的同步性）。
      _pendingFree.add(ptr);
    }
  }

  final _pendingFree = <Pointer<Utf8>>[];

  void _flushPendingFree() {
    for (final ptr in _pendingFree) {
      calloc.free(ptr);
    }
    _pendingFree.clear();
  }

  /// 同步跑完一条语句：查询回全部行，非查询回受影响行数。
  ({List<Map<String, Object?>> rows, int changes, int rowId}) _run(
    String sql,
    List<Object?>? arguments,
  ) {
    final s = _Sqlite.instance;
    final stmt = _prepare(sql, arguments);
    try {
      final rows = <Map<String, Object?>>[];
      while (true) {
        final rc = s.step(stmt);
        if (rc == _sqliteRow) {
          final row = <String, Object?>{};
          final n = s.colCount(stmt);
          for (var i = 0; i < n; i++) {
            row[s.colName(stmt, i).toDartString()] = _column(stmt, i);
          }
          rows.add(row);
        } else if (rc == _sqliteDone) {
          break;
        } else {
          throw StateError('SQL 失败：$_errorMessage ← $sql');
        }
      }
      return (
        rows: rows,
        changes: s.changes(_handle),
        rowId: s.lastRowid(_handle),
      );
    } finally {
      s.finalize(stmt);
      _flushPendingFree();
    }
  }

  Object? _column(Pointer<Void> stmt, int i) {
    final s = _Sqlite.instance;
    switch (s.colType(stmt, i)) {
      case 1:
        return s.colInt(stmt, i);
      case 2:
        return s.colDouble(stmt, i);
      case 3:
        final ptr = s.colText(stmt, i);
        if (ptr == nullptr) return '';
        return ptr.cast<Utf8>().toDartString(length: s.colBytes(stmt, i));
      case 4:
        final bytes = s.colBytes(stmt, i);
        final ptr = s.colBlob(stmt, i);
        if (ptr == nullptr || bytes == 0) return Uint8List(0);
        return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(bytes));
      default:
        return null;
    }
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    _run(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => _run(sql, arguments).rows;

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).changes;

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).changes;

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).rowId;

  String _conflict(ConflictAlgorithm? algorithm) => switch (algorithm) {
    ConflictAlgorithm.ignore => ' OR IGNORE',
    ConflictAlgorithm.replace => ' OR REPLACE',
    ConflictAlgorithm.rollback => ' OR ROLLBACK',
    ConflictAlgorithm.abort => ' OR ABORT',
    ConflictAlgorithm.fail => ' OR FAIL',
    null => '',
  };

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final columns = values.keys.toList();
    final sql =
        'INSERT${_conflict(conflictAlgorithm)} INTO $table '
        '(${columns.join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})';
    return _run(sql, values.values.toList()).rowId;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final sets = [for (final key in values.keys) '$key = ?'].join(', ');
    final sql =
        'UPDATE${_conflict(conflictAlgorithm)} $table SET $sets'
        '${where == null ? '' : ' WHERE $where'}';
    return _run(sql, [...values.values, ...?whereArgs]).changes;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final sql = 'DELETE FROM $table${where == null ? '' : ' WHERE $where'}';
    return _run(sql, whereArgs).changes;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final buffer = StringBuffer(
      'SELECT ${distinct == true ? 'DISTINCT ' : ''}'
      '${columns == null || columns.isEmpty ? '*' : columns.join(', ')} '
      'FROM $table',
    );
    if (where != null) buffer.write(' WHERE $where');
    if (groupBy != null) buffer.write(' GROUP BY $groupBy');
    if (having != null) buffer.write(' HAVING $having');
    if (orderBy != null) buffer.write(' ORDER BY $orderBy');
    if (limit != null) buffer.write(' LIMIT $limit');
    if (offset != null) buffer.write(' OFFSET $offset');
    return _run(buffer.toString(), whereArgs).rows;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    if (_txnDepth > 0) return action(this);
    await execute(exclusive == false ? 'BEGIN' : 'BEGIN EXCLUSIVE');
    _txnDepth++;
    try {
      final result = await action(this);
      await execute('COMMIT');
      return result;
    } catch (e) {
      try {
        await execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    } finally {
      _txnDepth--;
    }
  }

  @override
  Batch batch() => _FfiBatch(this);

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _Sqlite.instance.close(_handle);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FfiDatabase 未实现：${invocation.memberName}');
}

class _FfiBatch implements Batch {
  _FfiBatch(this._db);

  final FfiDatabase _db;
  final _ops = <(String, List<Object?>?)>[];

  @override
  void execute(String sql, [List<Object?>? arguments]) {
    _ops.add((sql, arguments));
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    final ops = List.of(_ops);
    _ops.clear();
    await _db.transaction((txn) async {
      for (final (sql, args) in ops) {
        await txn.execute(sql, args);
      }
    });
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FfiBatch 未实现：${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// 夹具：合并库形态（有磁力作品与主分类、没有磁力登记表）
// ---------------------------------------------------------------------------

const _ddl = <String>[
  'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
  'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
  'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
  'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
  'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
];

const _fallbackName = '女优库-磁力合并-20261128';
const _sourceFileName = '女优库-磁力合并-20261128.db';

String _magnet(int n) => 'magnet:?xt=urn:btih:REG$n';

late Directory _dir;
const _store = ActressMagnetLibraryStore();

Future<void> _seedWork(
  Database db,
  String vodId, {
  String? category,
  List<String> magnetUrls = const [],
  List<String> httpUrls = const [],
  List<String> actresses = const [],
}) async {
  await db.insert('videos', {
    'vod_id': vodId,
    'title': '标题$vodId',
    'pic_url': 'https://img/$vodId.jpg',
    'vod_play_from': 'whos',
    'type_name': '有码',
  });
  if (category != null) {
    await db.insert('video_category', {
      'vod_id': vodId,
      'main_category': category,
    });
  }
  for (final url in magnetUrls) {
    await db.insert('video_play_urls', {
      'vod_id': vodId,
      'play_url': url,
      'play_from': 'magnet',
    });
  }
  for (final url in httpUrls) {
    await db.insert('video_play_urls', {
      'vod_id': vodId,
      'play_url': url,
      'play_from': 'whos',
    });
  }
  for (final cateId in actresses) {
    await db.insert('video_actress', {'vod_id': vodId, 'cate_id': cateId});
  }
}

/// 合并库缩放夹具：8 部作品、磁力线路 6 条、具名分类 4 个
/// （国产原创/4K/有码＋无磁力作品的欧美——建空片保分类齐
/// 现）＋无分类作品 2 部（其中 1 部带磁力、归兜底片）。登
/// 记口径：只登记带磁力线路的作品——磁力作品 5 部、磁力线
/// 路 6 条。
Future<void> _seedMerged(Database db) async {
  for (final ddl in _ddl) {
    await db.execute(ddl);
  }
  await db.insert('actresses', {'cate_id': 'a1', 'name': '甲', 'sex': '女'});
  await db.insert('actresses', {'cate_id': 'a2', 'name': '乙', 'sex': '女'});
  await _seedWork(
    db,
    'mag-001',
    category: '国产原创',
    magnetUrls: [_magnet(1), _magnet(2)],
    actresses: ['a1'],
  );
  await _seedWork(db, 'mag-002', category: '国产原创', magnetUrls: [_magnet(3)]);
  await _seedWork(
    db,
    'mag-003',
    category: '4K',
    magnetUrls: [_magnet(4)],
    actresses: ['a2'],
  );
  await _seedWork(
    db,
    'jav-001',
    category: '有码',
    httpUrls: ['https://cdn/jav-001.m3u8'],
  );
  await _seedWork(
    db,
    'jav-002',
    category: '有码',
    httpUrls: ['https://cdn/jav-002.m3u8'],
    magnetUrls: [_magnet(5)],
  );
  await _seedWork(db, 'unc-001', magnetUrls: [_magnet(6)]);
  await _seedWork(db, 'unc-002', category: '', httpUrls: ['https://cdn/u2.m3u8']);
  await _seedWork(
    db,
    'eur-001',
    category: '欧美',
    httpUrls: ['https://cdn/eur-001.m3u8'],
  );
}

Future<File> _mergedFile(String name) async {
  final file = File(path.join(_dir.path, name));
  final db = await FfiDatabase.open(file.path);
  await _seedMerged(db);
  await db.close();
  return file;
}

Future<Map<String, Map<String, Object?>>> _librariesByName(
  Database db,
) async {
  final rows = await db.query('magnet_libraries');
  return {for (final row in rows) row['name'].toString(): row};
}

Future<Set<String>> _worksOfSlice(Database db, int libraryId) async => {
  for (final row in await db.rawQuery(
    'SELECT vod_id FROM magnet_library_works WHERE library_id = ?',
    [libraryId],
  ))
    row['vod_id'].toString(),
};

Future<int> _scalar(Database db, String sql, [List<Object?>? args]) async {
  final rows = await db.rawQuery(sql, args);
  return (rows.first['c'] as num).toInt();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _dir = Directory.systemTemp.createTempSync('magnet_register_');
  });

  tearDown(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('合并库形态：按实际分类补登记，逐片作品/线路计数对账', () async {
    final file = await _mergedFile('merged.db');
    final db = await FfiDatabase.open(file.path);
    final outcome = await _store.ensureAutoRegistered(
      db,
      sourceName: _sourceFileName,
    );
    expect(outcome.changed, isTrue);
    expect(
      outcome.addedSlices.toSet(),
      {'国产原创', '4K', '有码', '欧美', _fallbackName},
    );
    // 只登记带磁力线路的作品：5 部（jav-001/unc-002/eur-001
    // 无磁力不登记）、磁力线路 6 条全登记。
    expect(outcome.registeredWorks, 5);
    expect(outcome.registeredMagnetUrls, 6);

    final libs = await _librariesByName(db);
    expect(libs.keys.toSet(), {'国产原创', '4K', '有码', '欧美', _fallbackName});
    expect(libs['国产原创']!['works'], 2);
    expect(libs['国产原创']!['play_urls'], 3);
    expect(libs['4K']!['works'], 1);
    expect(libs['4K']!['play_urls'], 1);
    expect(libs['有码']!['works'], 1);
    expect(libs['有码']!['play_urls'], 1);
    // 欧美没有磁力作品：建空片保分类齐现，计数 0。
    expect(libs['欧美']!['works'], 0);
    expect(libs['欧美']!['play_urls'], 0);
    expect(libs[_fallbackName]!['works'], 1);
    expect(libs[_fallbackName]!['play_urls'], 1);

    expect(
      await _worksOfSlice(db, libs['国产原创']!['id'] as int),
      {'mag-001', 'mag-002'},
    );
    expect(
      await _worksOfSlice(db, libs['有码']!['id'] as int),
      {'jav-002'},
    );
    expect(
      await _worksOfSlice(db, libs[_fallbackName]!['id'] as int),
      {'unc-001'},
    );
    // 演员关联与分类行跟登记走；was_existing 全 1（删这类只
    // 摘登记、不动本库作品与线路）。
    expect(
      await _scalar(
        db,
        'SELECT COUNT(*) AS c FROM magnet_library_actresses '
        'WHERE library_id = ? AND cate_id = ?',
        [libs['国产原创']!['id'], 'a1'],
      ),
      1,
    );
    expect(
      await _scalar(
        db,
        'SELECT COUNT(*) AS c FROM magnet_library_categories',
      ),
      4, // 登记的 5 部磁力作品中 4 部有分类行（unc-001 无）
    );
    for (final table in [
      'magnet_library_works',
      'magnet_library_play_urls',
      'magnet_library_actresses',
      'magnet_library_categories',
    ]) {
      expect(
        await _scalar(
          db,
          'SELECT COUNT(*) AS c FROM $table WHERE was_existing <> 1',
        ),
        0,
        reason: '$table 的自动登记行 was_existing 必须全为 1',
      );
    }
    await db.close();
  });

  test('幂等：登记齐后再调，changed=false、登记原样', () async {
    final file = await _mergedFile('merged.db');
    final db = await FfiDatabase.open(file.path);
    await _store.ensureAutoRegistered(db, sourceName: _sourceFileName);
    final before = await db.query('magnet_libraries', orderBy: 'id');
    final again = await _store.ensureAutoRegistered(
      db,
      sourceName: _sourceFileName,
    );
    expect(again.changed, isFalse);
    expect(again.addedSlices, isEmpty);
    final after = await db.query('magnet_libraries', orderBy: 'id');
    expect(after, before);
    await db.close();
  });

  test('查询层：登记后分类栏四类齐现、计数与成员同尺、逐类作品对得上',
      () async {
    final file = await _mergedFile('merged.db');
    final seed = await FfiDatabase.open(file.path);
    await _store.ensureAutoRegistered(seed, sourceName: _sourceFileName);
    await seed.close();

    final lib = ActressLibraryDbFallback(
      pathResolver: () async => file.path,
      opener: (p) async => (await FfiDatabase.open(p)).rawQuery,
    );
    final cats = await lib.handle({'op': 'magnetCategories'});
    expect(cats['ok'], isTrue);
    final byName = {
      for (final c in (cats['categories'] as List).cast<Map>())
        c['name'].toString(): (c['count'] as num).toInt(),
    };
    // 计数与磁力可见批同一把尺：成员 = 带磁力线路 ∪ 已登记，
    // 自动登记只登记磁力作品，故计数与无登记时按磁力线路现
    // 算的口径完全一致（有码只数 jav-002、无磁力的 jav-001
    // 不进来；欧美空片计数 0）。
    expect(byName, {'国产原创': 2, '4K': 1, '有码': 1, '欧美': 0, _fallbackName: 1});

    Future<List<String>> worksOf(String category) async {
      final res = await lib.handle({'op': 'magnetWorks', 'category': category});
      return [
        for (final w in (res['items'] as List).cast<Map>())
          w['vodId'].toString(),
      ]..sort();
    }

    expect(await worksOf('国产原创'), ['mag-001', 'mag-002']);
    expect(await worksOf('有码'), ['jav-002']);
    expect(await worksOf(_fallbackName), ['unc-001']);
    expect(await worksOf(''), [
      'jav-002',
      'mag-001',
      'mag-002',
      'mag-003',
      'unc-001',
    ]);
  });

  test('已有登记不动：磁力导入登记过的片原样，其余分类补建', () async {
    final target = await _mergedFile('merged.db');
    // 先用正经磁力导入路登记一个「国产原创」片（带一部新作品）。
    final stagingFile = File(path.join(_dir.path, 'staging.db'));
    final staging = await FfiDatabase.open(stagingFile.path);
    for (final ddl in _ddl) {
      await staging.execute(ddl);
    }
    await _seedWork(
      staging,
      'pre-001',
      category: '国产原创',
      magnetUrls: [_magnet(90)],
    );
    await staging.close();
    final db = await FfiDatabase.open(target.path);
    final merged = await _store.mergeStaging(
      db,
      stagingFile.path,
      sourceName: '国产原创.txt',
    );
    expect(merged.ok, isTrue);
    final beforeLibs = await _librariesByName(db);
    expect(beforeLibs.keys.toSet(), {'国产原创'});
    expect(beforeLibs['国产原创']!['works'], 1);

    final outcome = await _store.ensureAutoRegistered(
      db,
      sourceName: _sourceFileName,
    );
    expect(outcome.changed, isTrue);
    expect(outcome.addedSlices, isNot(contains('国产原创')));
    final afterLibs = await _librariesByName(db);
    expect(afterLibs.keys.toSet(), {'国产原创', '4K', '有码', '欧美', _fallbackName});
    // 已登记片原样：id 与计数都没被自动登记改动（mag-001/002
    // 没有被塞进这个片——护老磁力导入的既有口径）。
    expect(afterLibs['国产原创']!['id'], beforeLibs['国产原创']!['id']);
    expect(afterLibs['国产原创']!['works'], 1);
    expect(afterLibs['国产原创']!['play_urls'], 1);
    await db.close();
  });

  test('无磁力作品的库：不登记、不建登记表', () async {
    final file = File(path.join(_dir.path, 'plain.db'));
    final db = await FfiDatabase.open(file.path);
    for (final ddl in _ddl) {
      await db.execute(ddl);
    }
    await _seedWork(
      db,
      'jav-001',
      category: '有码',
      httpUrls: ['https://cdn/jav-001.m3u8'],
    );
    final outcome = await _store.ensureAutoRegistered(
      db,
      sourceName: '女优库.db',
    );
    expect(outcome.changed, isFalse);
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name = 'magnet_libraries'",
    );
    expect(tables, isEmpty);
    await db.close();
  });

  test('删自动登记的分类：只摘登记，本库作品与线路一条不动', () async {
    final file = await _mergedFile('merged.db');
    final db = await FfiDatabase.open(file.path);
    await _store.ensureAutoRegistered(db, sourceName: _sourceFileName);
    final libs = await _librariesByName(db);
    final result = await _store.removeLibrary(
      db,
      libs[_fallbackName]!['id'] as int,
    );
    expect(result.removedWorks, 0);
    expect(result.removedPlayUrls, 0);
    expect(await _scalar(db, 'SELECT COUNT(*) AS c FROM videos'), 8);
    expect(
      await _scalar(db, 'SELECT COUNT(*) AS c FROM video_play_urls'),
      10, // 6 条磁力 + 4 条普通线路全在
    );
    final after = await _librariesByName(db);
    expect(after.keys.toSet(), {'国产原创', '4K', '有码', '欧美'});
    await db.close();
  });

  test('导入路：合并形态 .db 整库导入后自动登记（核心版本 2099 放行）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final picked = await _mergedFile('picked.db');
    final importedPath = path.join(_dir.path, 'slot', 'imported.db');
    Directory(path.dirname(importedPath)).createSync(recursive: true);
    final source = ActressDbSource(
      externalPath: () async => '',
      importedPath: () async => importedPath,
      worksCounter: (_) async => 7,
      isIOS: () => false,
    );
    const futureInfo = ActressLibraryVersionInfo(
      format: 'actress_library',
      formatVersion: '1',
      coreVersion: '2099.01.01',
      libraryVersion: '2099v1',
    );
    final service = ActressDbImportService(
      source: source,
      dbValidator: (_) async => const ActressDbValidation(ok: true, works: 7),
      dbVersionChecker: (_) async => (
        info: futureInfo,
        error: actressLibraryVersionError(futureInfo),
      ),
      magnetDbOpener: (p) => FfiDatabase.open(p),
    );
    final outcome = await service.importLocalFile(
      localPath: picked.path,
      closeDatabase: () async {},
    );
    expect(outcome.ok, isTrue);
    expect(outcome.error, isNull);
    final db = await FfiDatabase.open(importedPath);
    final libs = await _librariesByName(db);
    expect(libs.keys.toSet(), {'国产原创', '4K', '有码', '欧美', 'picked'});
    expect(libs['国产原创']!['works'], 2);
    expect(libs['国产原创']!['play_urls'], 3);
    await db.close();
  });

  test('存量补登记：导入槽未登记库打开时自动补、重复打开不重复登记',
      () async {
    final importedPath = path.join(_dir.path, 'slot2', 'imported.db');
    Directory(path.dirname(importedPath)).createSync(recursive: true);
    final seedFile = await _mergedFile('seed.db');
    await seedFile.copy(importedPath);
    final source = ActressDbSource(
      externalPath: () async => '',
      importedPath: () async => importedPath,
      worksCounter: (_) async => 7,
      isIOS: () => false,
    );
    ActressMagnetAutoRegistration.resetForTest();
    await ActressMagnetAutoRegistration.backfillImportedSlot(
      source: source,
      openDb: (p) => FfiDatabase.open(p),
    );
    final db = await FfiDatabase.open(importedPath);
    final libs = await _librariesByName(db);
    expect(libs.keys.toSet(), {'国产原创', '4K', '有码', '欧美', '未分类'});
    final before = await db.query('magnet_libraries', orderBy: 'id');
    await db.close();

    // 文件戳守卫之外再强制试一次：登记已齐 → 原样不动。
    ActressMagnetAutoRegistration.resetForTest();
    await ActressMagnetAutoRegistration.backfillImportedSlot(
      source: source,
      openDb: (p) => FfiDatabase.open(p),
    );
    final db2 = await FfiDatabase.open(importedPath);
    final after = await db2.query('magnet_libraries', orderBy: 'id');
    expect(after, before);
    await db2.close();
  });
}
