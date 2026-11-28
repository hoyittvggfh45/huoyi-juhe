import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

import 'embedded_test_entries.dart';

/// 境界成人分档（内嵌版）：批量转站后核心只剩 hgdj/hgdj58/hgdjv 3 站，
/// 分档改读 adultVideoSiteOrder（删核心前的核心登记顺序 201 站，加上
/// 之后追加的 72 个资源站（zy/* 等），再加 2026-11-24 魔蚁 v63 合入的
/// 5 站（whos/youzidj/yzaikan/one/tgpianku），共 278 站；2026-11-26
/// MissAV 收拢删 missavoff/mirror/missavt 3 站，现 275 站）。
/// 影视区统一表里的行 id（种子 `seed_<id>`、jar `jar:zakatv:<key>`、
/// 核心裸 id）查档位时先归一化成核心站 id。
///
/// 档位按现表下标均分 4 档（档 = min(3, 下标 × 4 ~/ 站总数)），加站
/// 改分母、边界站会下移一档，这是公式本意，不洗牌：2026-11-24 前的
/// 抽查期望值是 201 站旧表时代的，资源站追加（201→273）与魔蚁 v63
/// 合入（273→278）两次改分母后已按现表重算。
/// 原始 19 短剧站本来就不在分档表里，不受影响；从未进过核心的
/// jar/种子站也不分档，按非成人站原样保留。
///
/// 2026-11-28 对齐补齐后本文件期望按 377 站重算：站点库标成人的
/// 96 个 canon id 按名单序追加表尾（总数 281→377），存量 142 站
/// 提前一档；javverse、91sanji 自此有档位（原「不在表里」的断言
/// 改掉）；huangdou 因同 canon 的 jar 行（黄豆短剧）标成人而入
/// 表，从原始短剧站「不在表里」名单里摘出（余 18 站仍不在表里）。
/// 库内成人必在表内的防漏断言在 adult_gate_alignment_test。
void main() {
  /// 原始短剧站（Dart 客户端，不在核心分档表里）。原 19 站里的
  /// huangdou 已于 2026-11-28 因同 canon 的 jar 行标成人而入表，
  /// 不在此列（见文件头注）。
  const original19 = [
    'original',
    'hongguo',
    'hgtv',
    'hgtvmirror',
    'huangju',
    'yeguo',
    'yaguo',
    'maoguo',
    'fanguo',
    'guanguo',
    'heguo',
    'xingguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'wuguo',
    'huangdou_yh',
  ];

  test('分档登记表：377 站、无重复、首站 mjv011、末站 hsvoice31', () {
    expect(adultVideoSiteOrder.length, 377);
    expect(adultVideoSiteOrder.toSet().length, 377);
    expect(adultVideoSiteOrder.first, 'mjv011');
    expect(adultVideoSiteOrder.last, 'hsvoice31');
  });

  test('3 个留站仍在分档里，原始短剧站（huangdou 除外）都不在', () {
    for (final id in ['hgdj', 'hgdj58', 'hgdjv']) {
      expect(adultVideoSiteOrder.contains(id), isTrue);
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNotNull);
    }
    for (final id in original19) {
      expect(adultVideoSiteOrder.contains(id), isFalse);
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNull);
    }
  });

  test('4 档规模：93/94/94/96', () {
    expect(adultTierSiteIds(0, adultVideoSiteOrder).length, 93);
    expect(adultTierSiteIds(1, adultVideoSiteOrder).length, 94);
    expect(adultTierSiteIds(2, adultVideoSiteOrder).length, 94);
    expect(adultTierSiteIds(3, adultVideoSiteOrder).length, 96);
  });

  test('抽查档位与现登记表顺序一致', () {
    // 下标与档位按 adultVideoSiteOrder 顺序算
    // （档 = min(3, 下标 × 4 ~/ 377)；missav/javrate 钉第 4 档）。
    // 2026-11-28 对齐补齐（总数 281→377）后按现表复算：本抽查表里
    // 11 站提前一档（hgdj58/xj/lissavcn/abjav/caoliu 2→1、
    // aiye/av18avmcg/321av/17rip/hjapp/javplay 1→0），其余不变。
    const expected = <String, int>{
      'mjv011': 0,
      'missav': 3,
      'javrate': 3,
      'hgdj': 1,
      'hgdj58': 1,
      'hgdjv': 0,
      'aiye': 0,
      'av18avmcg': 0,
      'xj': 1,
      'xj2': 0,
      'haijiao': 0,
      'haijiao4k': 1,
      'rou': 0,
      'rouvideo': 2,
      'wohs': 2,
      '123av': 0,
      '321av': 0,
      '591av': 0,
      '99jj': 0,
      '17rip': 0,
      '69vj': 0,
      'txfans': 0,
      'hjapp': 0,
      'javplay': 0,
      'lissavcn': 1,
      'hddj': 0,
      'huangguo': 0,
      'hgtvim': 0,
      'abjav': 1,
      'danai': 1,
      'caoliu': 1,
    };
    for (final entry in expected.entries) {
      expect(
        adultTierForSiteId(entry.key, adultVideoSiteOrder),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('统一表行 id 归一化成核心站 id', () {
    expect(adultSiteIdForUnifiedId('seed_abjav'), 'abjav');
    expect(adultSiteIdForUnifiedId('seed_missav'), 'missav');
    expect(adultSiteIdForUnifiedId('seed_yaguo'), 'yaguo');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaMjv011'), 'mjv011');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaMissav'), 'missav');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaJavrate'), 'javrate');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av123'), '123av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av321'), '321av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av591'), '591av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:jj99'), '99jj');
    expect(adultSiteIdForUnifiedId('jar:zakatv:rip17'), '17rip');
    expect(adultSiteIdForUnifiedId('jar:zakatv:vj69'), '69vj');
    expect(adultSiteIdForUnifiedId('jar:zakatv:zaketxfans'), 'txfans');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaWhos'), 'wohs');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaHjApp'), 'hjapp');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaHgdjV'), 'hgdjv');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaLissavCn'), 'lissavcn');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaJavPlay'), 'javplay');
    expect(adultSiteIdForUnifiedId('jar:zakatv:haijiao4k'), 'haijiao4k');
    expect(adultSiteIdForUnifiedId('jar:zakatv:hgdj58'), 'hgdj58');
    expect(adultSiteIdForUnifiedId('jar:zakatv:rouvideo'), 'rouvideo');
    expect(adultSiteIdForUnifiedId('jar:zakatv:wohs'), 'wohs');
    expect(adultSiteIdForUnifiedId('jar:zakatv:xj2'), 'xj2');
    expect(adultSiteIdForUnifiedId('jar:zakatv:dsav'), 'dsav');
    expect(adultSiteIdForUnifiedId('hgdj'), 'hgdj');
    expect(adultSiteIdForUnifiedId('youtube'), 'youtube');
    expect(adultSiteIdForUnifiedId('jar:youtube:youtube'), 'youtube');
    // 2026-11-28 对齐补齐后：javverse（jar 行）、91sanji（种子行）
    // 库内都标成人，已入表有档位；yaguo 库内未标成人，仍不在表里、
    // 查档位是 null。
    expect(
      adultTierForSiteId('jar:zakatv:zakajavverse', adultVideoSiteOrder),
      3,
    );
    expect(
      adultTierForSiteId('seed_91sanji', adultVideoSiteOrder),
      2,
    );
    expect(
      adultTierForSiteId('seed_yaguo', adultVideoSiteOrder),
      isNull,
    );
  });

  test('内嵌站全有档位：站点库条目 + 核心 3 站覆盖分档表（zy360 除外）', () {
    // 站点库批（2026-11-27）适配：登记来源改站点库条目
    // （embeddedTestEntries，按随包名单搭）。分档表 377 个 id 里
    // zy360 的 py 种子按评估剔除令未进站点库、jar 里也没有此站，
    // 该 id 暂成孤儿（种子文件其实在盘上，恢复与否待定版）。
    // 本 helper 按口径不搭 nativeGate 与直播行：2026-11-28 补入的
    // 96 站里，阅读原生独占 17 站（核心阅读站，hysxs 另有 jar 行
    // 已覆盖）与直播独占 25 站（m3u/直播平台，bnzb 另有 jar 行
    // 已覆盖）不在本测试的条目形态内，由 adult_gate_alignment_
    // test 的逐行查档断言覆盖；本测试覆盖数 = 377 − zy360
    // − 17 − 25 = 334。
    final covered = <String>{};
    for (final entry in embeddedTestEntries()) {
      if (adultTierForSiteId(entry.id, adultVideoSiteOrder) != null) {
        covered.add(adultSiteIdForUnifiedId(entry.id));
      }
    }
    covered.addAll(['hgdj', 'hgdj58', 'hgdjv']);
    expect(covered.length, 334);
    expect(
      covered,
      adultVideoSiteOrder.toSet()
        ..remove('zy360')
        ..removeAll(const {
          // 阅读原生独占 17（核心阅读站，另有同名行的 hysxs 除外）
          '1000novel', '69story', 'buliang', 'canovel', 'cheniyo',
          'cjg', 'h528', 'hwg4', 'jywx2', 'lbwen', 'ssxxs', 'yinse',
          '55comics', 'csmanhua', 'ho5ho', 'modu18', 'hsvoice31',
          // 直播独占 25（m3u 22 + user_m3u + 平台 2，bnzb 除外）
          'user_m3u', 'maiyoux', 'xiuguo',
          'm3u_zhubo', 'm3u_luanlun', 'm3u_huayu', 'm3u_guochan',
          'm3u_xuesheng', 'm3u_tanhua', 'm3u_riben', 'm3u_oumei',
          'm3u_heilian', 'm3u_community10', 'm3u_community11',
          'm3u_wuma', 'm3u_wanghong', 'm3u_xingba', 'm3u_chengtou',
          'm3u_zhifu', 'm3u_qunjiao', 'm3u_mingxing', 'm3u_zipai',
          'm3u_avxiongdi', 'm3u_guochanse', 'm3u_riben2',
        }),
    );
  });

  test('影视区可见站表：内嵌行按档位放，门禁开关开/关两态都正常', () {
    final wasDisabled = cultivationAdultTierGateDisabledForTesting;
    addTearDown(
      () => cultivationAdultTierGateDisabledForTesting = wasDisabled,
    );
    final entries = embeddedTestEntries();
    final allIds =
        unifiedVideoZoneSites(entries).map((site) => site.id).toList();
    // 开关开（测试期临时关闭）：修为 0 也全可见。
    cultivationAdultTierGateDisabledForTesting = true;
    expect(
      visibleVideoZoneSites(entries, 0).map((s) => s.id).toList(),
      allIds,
    );
    // 开关关：修为 0 时分档行一个都不露，只剩不分档行。
    cultivationAdultTierGateDisabledForTesting = false;
    final at0 = visibleVideoZoneSites(entries, 0).map((s) => s.id).toSet();
    expect(at0.contains('jar:zakatv:ZakaMjv011'), isFalse);
    expect(at0.contains('seed_missav'), isFalse);
    expect(at0.contains('seed_abjav'), isFalse);
    // javverse 2026-11-28 已入表（第 4 档），修为 0 不再露出
    //（此前不在表里、按非成人站原样保留）。
    expect(at0.contains('jar:zakatv:zakajavverse'), isFalse);
    // 3000 时第 1 档出现（mjv011 是 jar 行），第 4 档还不出现
    //（missav 只剩种子行，钉第 4 档）。
    final at3000 =
        visibleVideoZoneSites(entries, 3000).map((s) => s.id).toSet();
    expect(at3000.contains('jar:zakatv:ZakaMjv011'), isTrue);
    expect(at3000.contains('seed_missav'), isFalse);
    expect(at3000.contains('jar:zakatv:ZakaJavrate'), isFalse);
    // 30000 全开。
    expect(
      visibleVideoZoneSites(entries, 30000).map((s) => s.id).toList(),
      allIds,
    );
  });
}
