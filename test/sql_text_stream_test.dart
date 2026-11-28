// Boundary tests for the byte-level SQL line decoder
// (2026-11-28 import UTF-8 fix). The phone failure mode: a
// multi-byte Chinese character straddling a read-chunk boundary
// killed the chunked UTF-8 decoder with
// "FormatException: Unexpected extension byte". The production
// staging paths now split bytes on 0x0A first and decode whole
// lines only, so any upstream chunking must be harmless. The
// control case proves the crafted data really does break naive
// per-chunk decoding (i.e. the sample is not vacuous).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sql_text_stream.dart';

Stream<List<int>> chunked(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size > bytes.length ? bytes.length : i + size;
    yield bytes.sublist(i, end);
  }
}

void main() {
  // Lines heavy in 3-byte Chinese characters plus a 4-byte emoji
  // and an escaped quote, shaped like .dump INSERT rows.
  final lines = <String>[
    "INSERT INTO videos VALUES('IPX-177','橘優花と神宮寺ナオの作品',"
        "'https://example.com/封面.jpg');",
    "INSERT INTO actresses VALUES('七沢みあ','森日向子','綾波アスカ');",
    "INSERT INTO video_tag VALUES('x','全中文标签🎬尾');",
    '-- 注释行',
    "INSERT INTO t VALUES('it''s 餌食牝 -- 北上尚子');",
  ];
  final text = '${lines.join('\n')}\n';
  final bytes = utf8.encode(text);

  for (final size in [1, 2, 3, 7, 4096, 8192, 24576, 65536]) {
    test('chunk size $size decodes identical lines', () async {
      final out = await sqlTextLines(chunked(bytes, size)).toList();
      expect(out, lines);
    });
  }

  test('control: per-chunk decode of the same data throws', () {
    // A 3-byte character placed so it straddles the 24576 chunk
    // boundary: first slice ends on its lead byte, next slice
    // starts on a continuation byte.
    final buf = <int>[
      ...List<int>.filled(24575, 0x61),
      ...utf8.encode('漢'),
      ...List<int>.filled(100, 0x62),
    ];
    var threw = 0;
    for (var off = 0; off + 24576 <= buf.length; off += 24576) {
      try {
        utf8.decode(buf.sublist(off, off + 24576));
      } on FormatException {
        threw++;
      }
    }
    expect(threw, greaterThan(0));
    // And the byte-level line decoder takes the same bytes fine.
    return expectLater(
      sqlTextLines(chunked(buf, 24576)).toList(),
      completion(hasLength(1)),
    );
  });

  test('crlf endings and trailing partial line', () async {
    final data = utf8.encode('第一行\r\n第二行');
    final out = await sqlTextLines(chunked(data, 3)).toList();
    expect(out, ['第一行', '第二行']);
  });

  test('importFailureZh hides raw FormatException text', () {
    final zh = importFailureZh(
      const FormatException('Unexpected extension byte', null, 24576),
    );
    expect(zh, contains('编码不对'));
    expect(zh, isNot(contains('FormatException')));
    expect(zh, isNot(contains('extension byte')));
    // Non-decode errors keep their (already Chinese) first line.
    expect(
      importFailureZh(StateError('站点库结构不完整：缺表')),
      contains('站点库结构不完整'),
    );
  });
}
