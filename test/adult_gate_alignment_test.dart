import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/site_library.dart';

/// 成人分档表与库内成人标记对齐（2026-11-28 用户令「补」）：
/// 站点库名单（roster／stations 表 is_adult，两处已逐行核对一致）
/// 标成人的 canon id 必须全在 adultVideoSiteOrder 里，一个不漏；
/// 反过来表里除 zy360（不在名单内、去留待定版的孤儿 id）外，
/// 每个 id 都必须是名单标成人的站，不许混进非成人站。
/// 以后名单加成人站或表里删行，这里会红——先对齐再改测试。
void main() {
  final rosterText = File(
    'assets/site_library/roster.json',
  ).readAsStringSync();
  final roster = parseSiteLibraryRoster(rosterText);
  final adultCanonIds = <String>{
    for (final entry in roster)
      if (entry.adult) entry.id,
  };

  test('名单成人 canon id 全部在分档表内（差集为 0）', () {
    expect(roster.length, 639);
    expect(adultCanonIds.length, 376);
    final missing = adultCanonIds.difference(adultVideoSiteOrder.toSet());
    expect(missing, isEmpty, reason: '不在分档表里的成人站：$missing');
  });

  test('分档表除 zy360 外都是名单标成人的站（不混非成人）', () {
    expect(adultVideoSiteOrder.length, 377);
    expect(adultVideoSiteOrder.toSet().length, 377);
    final extra = adultVideoSiteOrder.toSet().difference(adultCanonIds);
    expect(extra, {'zy360'}, reason: '表里非名单成人的 id：$extra');
  });

  test('479 个成人行逐行按 siteId 查档都有档（归一化不漏一行）', () {
    final decoded = jsonDecode(rosterText) as Map<String, dynamic>;
    final rows = decoded['stations'] as List<dynamic>;
    var adultRows = 0;
    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      if (row['adult'] != true) continue;
      adultRows++;
      final siteId = '${row['siteId']}';
      expect(
        adultTierForSiteId(siteId, adultVideoSiteOrder),
        isNotNull,
        reason: '$siteId（canon ${row['id']}）',
      );
    }
    expect(adultRows, 479);
  });

  test('补入站档位抽查：按名单序追加、公式定档', () {
    // 91sanji / xandaskday 是补入前两站（下标 281/282，总数 377），
    // 按公式落第 3 档（下标 2）；其余补入站落第 4 档（下标 3）。
    expect(adultTierForSiteId('seed_91sanji', adultVideoSiteOrder), 2);
    expect(adultTierForSiteId('seed_xandaskday', adultVideoSiteOrder), 2);
    expect(adultTierForSiteId('jar:zakatv:zakajavverse', adultVideoSiteOrder), 3);
    expect(adultTierForSiteId('m3u_wuma', adultVideoSiteOrder), 3);
    expect(adultTierForSiteId('1000novel', adultVideoSiteOrder), 3);
    expect(adultTierForSiteId('hsvoice31', adultVideoSiteOrder), 3);
    expect(adultVideoSiteOrder.last, 'hsvoice31');
  });
}
