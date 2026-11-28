import 'dart:convert';

/// SQL 文本的字节级切行解码（2026-11-28 导入解码修复批）。
///
/// 病根：导入链旧写法是 `字节流.transform(utf8.decoder)`——把
/// 解码交给运行时的分块解码器，默认它会自己攒住被块边界切开
/// 的半个汉字。桌面 VM 上确实如此、真文件全程无错；但真机
/// （鸿蒙容器里的安卓运行时）上同一份验好的文件在导入早期抛
/// `FormatException: Unexpected extension byte (at offset
/// 24576)`——偏移是 4096 的整数倍、两条产品线同签名，说明
/// 字节在块边界被切开后没被正确续上，下一块以汉字续字节开头
/// 就炸。运行时改不了，导入链不再依赖分块解码器：
///
/// 改走字节切行——换行字节 0x0A 永远不会出现在多字节 UTF-8
/// 字符内部（多字节字符的每个字节都 ≥ 0x80），所以先按字节
/// 找换行切出完整的一行字节、再对这一行单独 utf8.decode，
/// 无论上游块怎么切都切不坏汉字。行尾的 \r 剥掉（与
/// LineSplitter 对 \r\n 的处理一致）。内存里至多攒一行，
/// 流式口径不变（.dump 的行长有界；无换行的病态文件会攒整
/// 份，与旧 LineSplitter 的行为同级）。
///
/// 第二轮（2026-11-28）：逐行解码失败时抛 [SqlDecodeFailure]，
/// 带行号、行首在文件中的字节偏移、出错字节的文件偏移与出错
/// 点前后字节的十六进制，供 import_debug.log 定点——真机再
/// 失败时不用靠猜是哪一层、哪一段、哪个字节。
Stream<String> sqlTextLines(Stream<List<int>> bytes) async* {
  final pending = <int>[];
  var lineNumber = 0;
  var lineStartOffset = 0;
  var consumed = 0;
  await for (final chunk in bytes) {
    var start = 0;
    while (start < chunk.length) {
      final nl = chunk.indexOf(0x0A, start);
      if (nl < 0) break;
      if (nl > start) pending.addAll(chunk.sublist(start, nl));
      lineNumber++;
      yield _decodeSqlLine(pending, lineNumber, lineStartOffset);
      pending.clear();
      consumed += nl - start + 1;
      lineStartOffset = consumed;
      start = nl + 1;
    }
    if (start < chunk.length) {
      pending.addAll(chunk.sublist(start));
      consumed += chunk.length - start;
    }
  }
  if (pending.isNotEmpty) {
    lineNumber++;
    yield _decodeSqlLine(pending, lineNumber, lineStartOffset);
  }
}

/// 逐行 UTF-8 解码失败（第二轮新增）：仍是 FormatException，
/// 既有的中文化映射照常命中；额外携带定点信息。
class SqlDecodeFailure implements FormatException {
  SqlDecodeFailure({
    required this.message,
    required this.lineNumber,
    required this.lineStartOffset,
    required this.offset,
    required this.contextHex,
  });

  @override
  final String message;

  /// 第几行（从 1 数）。
  final int lineNumber;

  /// 这一行第一个字节在文件（解压后字节流）中的偏移。
  final int lineStartOffset;

  /// 出错字节在文件（解压后字节流）中的偏移。
  @override
  final int offset;

  /// 出错点前后各 32 字节的十六进制（空格分隔）。
  final String contextHex;

  @override
  dynamic get source => null;

  @override
  String toString() =>
      'SqlDecodeFailure: $message (at line $lineNumber, '
      'file offset $offset)';
}

String _decodeSqlLine(List<int> lineBytes, int lineNumber, int lineStart) {
  var bytes = lineBytes;
  if (bytes.isNotEmpty && bytes.last == 0x0D) {
    bytes = bytes.sublist(0, bytes.length - 1);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    final at = (e.offset ?? 0).clamp(0, bytes.length);
    final from = (at - 32).clamp(0, bytes.length);
    final to = (at + 32).clamp(0, bytes.length);
    final hex = [
      for (var i = from; i < to; i++)
        bytes[i].toRadixString(16).padLeft(2, '0'),
    ].join(' ');
    throw SqlDecodeFailure(
      message: e.message,
      lineNumber: lineNumber,
      lineStartOffset: lineStart,
      offset: lineStart + at,
      contextHex: hex,
    );
  }
}

/// 导入失败给用户看的中文原因：解码类异常（FormatException，
/// 如 UTF-8 解码失败）统一转成中文说法，原始英文异常只由
/// 调用方另行记日志，不许再甩到用户脸上；其它异常取首行
/// （与历史口径一致，多为已中文化的 StateError 文案）。
String importFailureZh(Object error) {
  if (error is FormatException) {
    return '文件内容有损坏或编码不对，导入已停止（现有数据库没有改动）';
  }
  return error.toString().split('\n').first;
}
