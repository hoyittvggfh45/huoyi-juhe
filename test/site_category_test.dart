import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_category.dart';
import 'package:fqapp/services/site_library.dart';

/// 内置站自动分类（2026-11-28 用户令「639 站点列表分类」）验收：
/// 判定规则逐项 + 拿包内真名单 roster.json 全量对账——各类计数
/// 之和必须等于名单总数 639，一站不丢、一站不重，类内保持名单
/// 原序（sort 升序）；成人影视 433 站按来源形态二级拆分对账。
void main() {
  group('siteCategoryOf 判定规则', () {
    test('video 按成人标记拆影视 / 成人影视', () {
      expect(
        siteCategoryOf(zone: 'video', adult: false),
        SiteCategory.film,
      );
      expect(
        siteCategoryOf(zone: 'video', adult: true),
        SiteCategory.adultFilm,
      );
    });

    test('novel / comic / audio 同样按成人标记拆', () {
      expect(siteCategoryOf(zone: 'novel', adult: false), SiteCategory.novel);
      expect(
        siteCategoryOf(zone: 'novel', adult: true),
        SiteCategory.adultNovel,
      );
      expect(siteCategoryOf(zone: 'comic', adult: false), SiteCategory.comic);
      expect(
        siteCategoryOf(zone: 'comic', adult: true),
        SiteCategory.adultComic,
      );
      expect(siteCategoryOf(zone: 'audio', adult: false), SiteCategory.audio);
      expect(
        siteCategoryOf(zone: 'audio', adult: true),
        SiteCategory.adultAudio,
      );
    });

    test('drama 恒短剧、live 恒直播、未知分区落其他', () {
      expect(siteCategoryOf(zone: 'drama', adult: false), SiteCategory.drama);
      expect(siteCategoryOf(zone: 'drama', adult: true), SiteCategory.drama);
      expect(siteCategoryOf(zone: 'live', adult: true), SiteCategory.live);
      expect(siteCategoryOf(zone: 'live', adult: false), SiteCategory.live);
      expect(siteCategoryOf(zone: 'weird', adult: false), SiteCategory.other);
      expect(siteCategoryOf(zone: '', adult: false), SiteCategory.other);
    });
  });

  group('siteKindLabel / 分组纯函数', () {
    test('来源形态显示名', () {
      expect(siteKindLabel('pyImport'), 'Python 站');
      expect(siteKindLabel('jarImport'), 'Jar 站');
      expect(siteKindLabel('legadoImport'), '书源站');
      expect(siteKindLabel('nativeGate'), '原生站');
      expect(siteKindLabel('liveM3u'), '直播源');
      expect(siteKindLabel('livePlatform'), '直播平台');
      expect(siteKindLabel('???'), '其他来源');
    });

    test('分组保持原序、空类不出段、每项恰好一段', () {
      final items = ['a', 'b', 'c', 'd'];
      final meta = {
        'a': (zone: 'video', adult: false, kind: 'pyImport'),
        'b': (zone: 'video', adult: true, kind: 'jarImport'),
        'c': (zone: 'novel', adult: false, kind: 'legadoImport'),
        'd': (zone: 'video', adult: false, kind: 'jarImport'),
      };
      final sections = groupStationsByCategory(items, (item) => meta[item]!);
      expect(
        sections.map((s) => s.category),
        [SiteCategory.film, SiteCategory.adultFilm, SiteCategory.novel],
      );
      // 影视段内 a 在 d 前（输入原序不乱）。
      expect(sections.first.items, ['a', 'd']);
      expect(sections.fold<int>(0, (sum, s) => sum + s.count), items.length);
    });

    test('按来源分组：段序按定稿顺序、未知 kind 落最后', () {
      final items = ['x', 'y', 'z', 'w'];
      final kind = {
        'x': 'legadoImport',
        'y': 'pyImport',
        'z': 'weird',
        'w': 'pyImport',
      };
      final sections = groupStationsByKind(items, (item) => kind[item]!);
      expect(sections.map((s) => s.kind), [
        'pyImport',
        'legadoImport',
        'weird',
      ]);
      expect(sections.first.items, ['y', 'w']);
      expect(sections.last.label, '其他来源');
    });
  });

  group('包内真名单 639 全量对账', () {
    final rosterText = File(
      'assets/site_library/roster.json',
    ).readAsStringSync();
    final roster = parseSiteLibraryRoster(rosterText);

    test('名单总数 639（与站点库 stations 表逐行复核一致）', () {
      expect(roster.length, 639);
      // 名单原始 JSON 的 stations 数组同样是 639 行。
      final decoded = jsonDecode(rosterText) as Map<String, dynamic>;
      expect((decoded['stations'] as List).length, 639);
    });

    test('各类计数定稿：和为 639、不丢不重、其他类为空', () {
      final sections = groupStationsByCategory(
        roster,
        siteCategoryMetaOfRoster,
      );
      final counts = {
        for (final section in sections) section.category: section.count,
      };
      expect(counts, {
        SiteCategory.film: 39,
        SiteCategory.adultFilm: 433,
        SiteCategory.drama: 17,
        SiteCategory.novel: 86,
        SiteCategory.adultNovel: 14,
        SiteCategory.comic: 12,
        SiteCategory.adultComic: 4,
        SiteCategory.audio: 6,
        SiteCategory.adultAudio: 2,
        SiteCategory.live: 26,
      });
      // 其他类为空：没有一站归不进（counts 里根本没有 other 段）。
      expect(counts.containsKey(SiteCategory.other), isFalse);
      // 总和对账 + 不重：分组是划分，段内条目按对象 identity 计数
      // 恰好覆盖全名单。
      expect(counts.values.fold<int>(0, (a, b) => a + b), 639);
      final seen = <SiteLibraryRosterEntry>{};
      for (final section in sections) {
        for (final entry in section.items) {
          expect(seen.add(entry), isTrue, reason: entry.id);
        }
      }
      expect(seen.length, 639);
    });

    test('类内保持名单原序（sort 升序）', () {
      final sections = groupStationsByCategory(
        roster,
        siteCategoryMetaOfRoster,
      );
      for (final section in sections) {
        final sorts = [for (final entry in section.items) entry.sort];
        final sorted = [...sorts]..sort();
        expect(sorts, sorted, reason: section.category.label);
      }
    });

    test('成人影视 433 超过拆分门槛，按来源二级拆分对账', () {
      final sections = groupStationsByCategory(
        roster,
        siteCategoryMetaOfRoster,
      );
      final adultFilm = sections.singleWhere(
        (s) => s.category == SiteCategory.adultFilm,
      );
      expect(adultFilm.count, greaterThan(siteCategoryKindSplitThreshold));
      final kindSections = groupStationsByKind(
        adultFilm.items,
        (entry) => entry.kind,
      );
      expect(
        {for (final s in kindSections) s.kind: s.count},
        {
          'pyImport': 193,
          'jarImport': 234,
          'legadoImport': 3,
          'nativeGate': 3,
        },
      );
      // 其余各类都不超过门槛，不拆分。
      for (final section in sections) {
        if (section.category == SiteCategory.adultFilm) continue;
        expect(
          section.count,
          lessThanOrEqualTo(siteCategoryKindSplitThreshold),
          reason: section.category.label,
        );
      }
    });

    test('构成复核：按 kind 与按 zone 两条轴各自和为 639', () {
      final byKind = groupStationsByKind(roster, (entry) => entry.kind);
      expect(
        {for (final s in byKind) s.kind: s.count},
        {
          'pyImport': 212,
          'legadoImport': 102,
          'jarImport': 248,
          'nativeGate': 51,
          'livePlatform': 3,
          'liveM3u': 23,
        },
      );
      final zoneCounts = <String, int>{};
      for (final entry in roster) {
        zoneCounts[entry.zone] = (zoneCounts[entry.zone] ?? 0) + 1;
      }
      expect(zoneCounts, {
        'video': 472,
        'novel': 100,
        'comic': 16,
        'audio': 8,
        'live': 26,
        'drama': 17,
      });
    });
  });
}
