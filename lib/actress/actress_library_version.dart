import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_database.dart' show applyActressDbReadPragmas;

/// 女优库版本字段读取（留痕用）：库内 `schema_meta` 表（key/value）
/// 里的 `format` / `format_version` / `core_version` /
/// `library_version` 四个字段，导入成功后回读出来随激活记录存
/// 一份备查，仅此而已。
///
/// **数据库版本门已全拆（2026-11-28 用户令：取消整套激活方案、
/// 数据库版本彻底取消）**：format_version 缺失、写任意值，都
/// 不再据此拒收或比对；本文件不再有任何判定函数。导入收不收
/// 只看结构完整性（表/列缺失、文件打不开、作品数等），在各
/// 导入链自己的校验段里把关。版本字段仍是文件格式的一部分
/// （双边通用口径），读到什么记什么、读不到记空，不参与判定、
/// 不上屏显示。

/// 女优库 schema_meta 的 format 标识值（文件格式的一部分，
/// 仅作记录字段的取值说明，不作判定）。
const actressLibraryMetaFormat = 'actress_library';

/// 从一个库里读到的版本信息（读不到的字段为空字符串）。
/// 纯留痕数据：随激活记录落盘备查，不参与任何判定。
class ActressLibraryVersionInfo {
  const ActressLibraryVersionInfo({
    this.format = '',
    this.formatVersion = '',
    this.coreVersion = '',
    this.libraryVersion = '',
  });

  final String format;
  final String formatVersion;
  final String coreVersion;
  final String libraryVersion;
}

/// 查询函数形态：给一句 SQL 回行（与 SqlImportExecutor.query /
/// sqflite rawQuery 同形状）。
typedef ActressMetaQuery = Future<List<Map<String, Object?>>> Function(
  String sql,
);

/// 从任意查询通道读 schema_meta（表不存在/查不动回全空信息，
/// 不抛错——留痕读不到不挡导入）。
Future<ActressLibraryVersionInfo> readActressLibraryVersion(
  ActressMetaQuery query,
) async {
  try {
    final tables = await query(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='schema_meta'",
    );
    if (tables.isEmpty) return const ActressLibraryVersionInfo();
    final rows = await query('SELECT key, value FROM schema_meta');
    final map = <String, String>{
      for (final row in rows)
        '${row['key'] ?? ''}': '${row['value'] ?? ''}',
    };
    return ActressLibraryVersionInfo(
      format: map['format'] ?? '',
      formatVersion: map['format_version'] ?? '',
      coreVersion: map['core_version'] ?? '',
      libraryVersion: map['library_version'] ?? '',
    );
  } catch (_) {
    return const ActressLibraryVersionInfo();
  }
}

/// 回读一个 .db 文件的版本信息（只读打开读 schema_meta 即关，
/// 绝不写文件），供导入成功后落激活记录留痕。顺带报文件层
/// 问题：文件不存在/为空、打不开时 [error] 非空（这是结构/
/// 文件问题、不是版本判定）；调用方只拿 [info] 落记录，
/// [error] 不再作任何拒收依据。
Future<({ActressLibraryVersionInfo info, String? error})>
checkActressDbFileVersion(String dbPath) async {
  final file = File(dbPath);
  if (!file.existsSync() || file.lengthSync() == 0) {
    return (
      info: const ActressLibraryVersionInfo(),
      error: '选中的文件读不到或为空',
    );
  }
  Database? db;
  try {
    db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
      onOpen: applyActressDbReadPragmas,
    );
    final info = await readActressLibraryVersion(
      (sql) => db!.rawQuery(sql),
    );
    return (info: info, error: null);
  } catch (e) {
    return (
      info: const ActressLibraryVersionInfo(),
      error: '这个数据库打不开：${e.toString().split('\n').first}',
    );
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}
