import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_category.dart';
import 'package:fqapp/services/site_library.dart';

/// 五区（小说 / 漫画 / 听书 / 直播 / 短剧）站点列表分类呈现对账
/// （2026-11-28 分类批的下一批接线验收）：
/// 影视选站弹窗已按分类出段；本批逐区查实其余五区的站点列表 /
/// 选择器形态后定处置，结论靠这组对账钉死——
///
/// - 短剧（17）与直播（26）在分类规则下恒为单一类：短剧选择器
///   （SiteGridDialog 全员短剧组）与直播选源弹窗（内置源一整组）
///   的现状呈现与分类出段等价，不需要、也不应再拆段；
/// - 小说 / 漫画 / 听书按库内成人标记各拆两类（86+14 / 12+4 /
///   6+2），规则全覆盖；三区在软件里没有独立的站点列表 / 选择
///   器可接线（核心站聚合进各 tab 内容、书源站只在站源管理的
///   技术分组里出现），本组只钉规则与计数，不造新页面。
///
/// 对账口径与 site_category_test 的 639 全量对账一致：拿包内真
/// 名单 roster.json，五区子集 167 站分组必须是划分——各类计数
/// 之和 = 167、一站不丢、一站不重、类内保持名单原序。
void main() {
  final rosterText = File(
    'assets/site_library/roster.json',
  ).readAsStringSync();
  final roster = parseSiteLibraryRoster(rosterText);
  final fiveZones = [
    for (final entry in roster)
      if (const {'novel', 'comic', 'audio', 'live', 'drama'}.contains(
        entry.zone,
      ))
        entry,
  ];

  group('五区子集 167 全量对账', () {
    test('五区子集恰好 167 站', () {
      expect(fiveZones.length, 167);
    });

    test('各类计数定稿：和为 167、不丢不重、无其他类', () {
      final sections = groupStationsByCategory(
        fiveZones,
        siteCategoryMetaOfRoster,
      );
      final counts = {
        for (final section in sections) section.category: section.count,
      };
      expect(counts, {
        SiteCategory.drama: 17,
        SiteCategory.novel: 86,
        SiteCategory.adultNovel: 14,
        SiteCategory.comic: 12,
        SiteCategory.adultComic: 4,
        SiteCategory.audio: 6,
        SiteCategory.adultAudio: 2,
        SiteCategory.live: 26,
      });
      expect(counts.containsKey(SiteCategory.other), isFalse);
      expect(counts.values.fold<int>(0, (a, b) => a + b), 167);
      final seen = <SiteLibraryRosterEntry>{};
      for (final section in sections) {
        for (final entry in section.items) {
          expect(seen.add(entry), isTrue, reason: entry.id);
        }
      }
      expect(seen.length, 167);
    });

    test('类内保持名单原序（sort 升序）', () {
      final sections = groupStationsByCategory(
        fiveZones,
        siteCategoryMetaOfRoster,
      );
      for (final section in sections) {
        final sorts = [for (final entry in section.items) entry.sort];
        final sorted = [...sorts]..sort();
        expect(sorts, sorted, reason: section.category.label);
      }
    });

    test('五区各类都未过二级拆分门槛，不按来源再拆', () {
      final sections = groupStationsByCategory(
        fiveZones,
        siteCategoryMetaOfRoster,
      );
      for (final section in sections) {
        expect(
          section.count,
          lessThanOrEqualTo(siteCategoryKindSplitThreshold),
          reason: section.category.label,
        );
      }
    });

    test('五区构成（kind 轴）：书源 92 / 原生 48 / 直播 26 / jar 1', () {
      final byKind = groupStationsByKind(fiveZones, (entry) => entry.kind);
      expect(
        {for (final s in byKind) s.kind: s.count},
        {
          'legadoImport': 92,
          'nativeGate': 48,
          'liveM3u': 23,
          'livePlatform': 3,
          'jarImport': 1,
        },
      );
    });
  });

  group('单类区：分类出段与现有选择器呈现等价', () {
    test('短剧 17 恒一类：短剧选择器单段「短剧」即分类呈现', () {
      final drama = [
        for (final entry in fiveZones)
          if (entry.zone == 'drama') entry,
      ];
      expect(drama.length, 17);
      final sections = groupStationsByCategory(
        drama,
        siteCategoryMetaOfRoster,
      );
      expect(sections.length, 1);
      expect(sections.single.category, SiteCategory.drama);
      expect(sections.single.count, 17);
      // 17 站全是原生核心站（nativeGate），与 dramaSites 裸行同表，
      // 短剧选择器（visibleShortDramaSites）全量收录。
      expect(drama.every((entry) => entry.kind == 'nativeGate'), isTrue);
    });

    test('直播 26 恒一类：选源弹窗内置源一整组即分类呈现', () {
      final live = [
        for (final entry in fiveZones)
          if (entry.zone == 'live') entry,
      ];
      expect(live.length, 26);
      final sections = groupStationsByCategory(
        live,
        siteCategoryMetaOfRoster,
      );
      expect(sections.length, 1);
      expect(sections.single.category, SiteCategory.live);
      expect(sections.single.count, 26);
      // 26 站全由站点库供数（liveM3u 23 + livePlatform 3），与
      // LiveSources.sqlSources 的组装口径逐项对上。
      final kinds = <String, int>{};
      for (final entry in live) {
        kinds[entry.kind] = (kinds[entry.kind] ?? 0) + 1;
      }
      expect(kinds, {'liveM3u': 23, 'livePlatform': 3});
    });
  });

  group('阅读三区：按库内成人标记拆两类', () {
    void checkSplit(
      String zone,
      SiteCategory plain,
      int plainCount,
      SiteCategory adult,
      int adultCount,
    ) {
      final rows = [
        for (final entry in fiveZones)
          if (entry.zone == zone) entry,
      ];
      final sections = groupStationsByCategory(
        rows,
        siteCategoryMetaOfRoster,
      );
      expect(
        {for (final s in sections) s.category: s.count},
        {plain: plainCount, adult: adultCount},
        reason: zone,
      );
      // 成人判定与库内标记逐行一致：成人段全 adult、普通段全非成人。
      for (final section in sections) {
        final shouldBeAdult = section.category == adult;
        for (final entry in section.items) {
          expect(entry.adult, shouldBeAdult, reason: entry.id);
        }
      }
    }

    test('小说 86 + 成人小说 14', () {
      checkSplit('novel', SiteCategory.novel, 86, SiteCategory.adultNovel, 14);
    });

    test('漫画 12 + 成人漫画 4', () {
      checkSplit('comic', SiteCategory.comic, 12, SiteCategory.adultComic, 4);
    });

    test('听书 6 + 成人听书 2', () {
      checkSplit('audio', SiteCategory.audio, 6, SiteCategory.adultAudio, 2);
    });
  });
}
