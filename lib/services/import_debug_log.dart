import 'dart:io';

import 'public_folder.dart';
import 'sql_text_stream.dart';

/// 导入失败的真机定点日志（2026-11-28 第二轮解码修复批）。
///
/// 背景：真机（鸿蒙容器）上的导入失败在桌面复现不出，失败
/// 原因又被中文化映射成一句总括话，靠截图永远定不了点。
/// 本服务把每次导入尝试的失败细节（阶段、异常类型与原文、
/// 解码失败的文件偏移与出错点前后字节十六进制、堆栈头几行）
/// 写到公开目录 MYTV/db/import_debug.log：新一次导入开始时
/// 清空重写（reset），同一次导入内的多条记录按时间追加。
/// 用户把这个文件发回来就能定点，不再靠猜。
///
/// 写日志永不抛错、永不挡导入主流程。
class ImportDebugLog {
  ImportDebugLog._();

  /// 日志文件名（MYTV/db 下）。
  static const fileName = 'import_debug.log';

  /// 给用户看的路径提示（管理页失败文案用）。
  static const pathHintZh = 'MYTV/db/import_debug.log';

  /// MYTV/db 目录解析（测试可注入；生产走 PublicFolder 根目录
  /// 下 MYTV/db，与各导入服务的 mytvDbDirectory 同口径）。
  static Future<Directory> Function()? directoryResolver;

  static Future<Directory> _dir() async {
    final resolver = directoryResolver;
    if (resolver != null) return resolver();
    final root = await PublicFolder.publicRoot();
    return Directory('$root/MYTV/db');
  }

  static Future<File?> _file() async {
    try {
      final dir = await _dir();
      await dir.create(recursive: true);
      return File('${dir.path}/$fileName');
    } catch (_) {
      return null;
    }
  }

  /// 新一次导入尝试开始：清空旧日志、写一行头。
  static Future<void> reset(String what) async {
    final file = await _file();
    if (file == null) return;
    try {
      await file.writeAsString(
        '凡人修仙导入失败定点日志\n'
        '开始：${DateTime.now().toIso8601String()}\n'
        '导入对象：$what\n',
      );
    } catch (_) {}
  }

  /// 记一条失败：阶段名（认库/staging/站点段校验/…，细到
  /// 函数更好）、异常原文、解码定点信息、堆栈前若干行。
  static Future<void> record({
    required String stage,
    required Object error,
    StackTrace? stack,
    String? detail,
  }) async {
    final file = await _file();
    if (file == null) return;
    final buf = StringBuffer()
      ..writeln('---')
      ..writeln('时间：${DateTime.now().toIso8601String()}')
      ..writeln('阶段：$stage')
      ..writeln('异常类型：${error.runtimeType}')
      ..writeln('异常原文：$error');
    if (detail != null && detail.isNotEmpty) {
      buf.writeln('补充：$detail');
    }
    if (error is SqlDecodeFailure) {
      buf
        ..writeln('解码失败行号：${error.lineNumber}')
        ..writeln('行首文件偏移：${error.lineStartOffset}')
        ..writeln('出错字节文件偏移：${error.offset}')
        ..writeln('出错点前后字节(hex)：${error.contextHex}');
    } else if (error is FormatException && error.offset != null) {
      buf.writeln('异常内偏移：${error.offset}');
    }
    if (stack != null) {
      final lines = stack.toString().split('\n').take(10);
      buf.writeln('堆栈（前 10 行）：');
      for (final line in lines) {
        buf.writeln('  $line');
      }
    }
    try {
      await file.writeAsString(
        buf.toString(),
        mode: FileMode.append,
      );
    } catch (_) {}
  }
}
