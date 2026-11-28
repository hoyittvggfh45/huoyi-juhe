// 网盘刮削识别层（xiuxian_wangpan_scrape_20261128）：噪声
// 剥离、六型分流、番号/cid 提取、DMM cid 换算、占位图尺
// 寸过滤、国产生牌识别。样本形态照调查报告 §3.1/§4.2。
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/cloud_drive/pan_scrape_identify.dart';

void main() {
  group('分型与番号提取', () {
    test('广告域名+分辨率+字幕噪声剥后认有码番号', () {
      final id = panIdentify('[hhd800.com] SSIS-001 1080p 中文字幕.mkv');
      expect(id.kind, PanScrapeKind.coded);
      expect(id.code, 'SSIS-001');
    });

    test('无码标记（无码字样）归无码型', () {
      final id = panIdentify('ABC-123 无码流出.mp4');
      expect(id.kind, PanScrapeKind.uncensored);
      expect(id.code, 'ABC-123');
    });

    test('HEYZO 厂牌归无码型', () {
      final id = panIdentify('HEYZO-1234 高清.mp4');
      expect(id.kind, PanScrapeKind.uncensored);
      expect(id.code, 'HEYZO-1234');
    });

    test('FC2-PPV 归 FC2 型', () {
      final id = panIdentify('FC2-PPV-1234567.mp4');
      expect(id.kind, PanScrapeKind.fc2);
      expect(id.code, 'FC2-PPV-1234567');
    });

    test('fc2ppv 小写连写归 FC2 型', () {
      final id = panIdentify('fc2ppv-7654321.mkv');
      expect(id.kind, PanScrapeKind.fc2);
      expect(id.code, 'FC2-PPV-7654321');
    });

    test('连写番号：提取器归一为横杠番号走番号链', () {
      // 星辰提取器自带连写归一（ssni00321 → SSNI-00321），
      // 这类归有码型走番号链，比 cid 直查更稳。
      final id = panIdentify('ssni00321.mp4');
      expect(id.kind, PanScrapeKind.coded);
      expect(id.code, 'SSNI-00321');
    });

    test('连写 cid 直提：纯 cid 形态解析', () {
      expect(panExtractCid('ssni00321'), 'ssni00321');
      expect(panExtractCid('h_1234abcd00012'), 'h_1234abcd00012');
    });

    test('连写 cid：数字前缀素人系', () {
      final id = panIdentify('259luxu0123.mp4');
      expect(id.kind, PanScrapeKind.cid);
      expect(id.cid, '259luxu0123');
    });

    test('普通电影：剧名+年份+季集解析', () {
      final id = panIdentify('流浪地球2.2023.2160p.WEB-DL.x265.mkv');
      expect(id.kind, PanScrapeKind.film);
      expect(id.parsed?.searchTitle, contains('流浪地球'));
      expect(id.parsed?.year, '2023');
    });

    test('普通剧集：第X季第Y集', () {
      final id = panIdentify('庆余年 第二季 第05集.mp4');
      expect(id.kind, PanScrapeKind.film);
      expect(id.parsed?.season, 2);
      expect(id.parsed?.episode, 5);
    });

    test('国产：麻豆番号前缀归国产型', () {
      final id = panIdentify('麻豆传媒 MD-0123 某标题.mp4');
      expect(id.kind, PanScrapeKind.domestic);
    });

    test('国产：厂牌词+自编番号仍归国产（不串有码链）', () {
      final id = panIdentify('星空传媒 XK-9527 女主播的故事.mp4');
      expect(id.kind, PanScrapeKind.domestic);
      expect(id.code, 'XK-9527');
    });

    test('国产：无番号纯厂牌标题归国产型、带标题解析', () {
      final id = panIdentify('天美传媒 姐姐的秘密.mp4');
      expect(id.kind, PanScrapeKind.domestic);
      expect(id.code, isNull);
      expect(id.parsed?.searchTitle, contains('姐姐的秘密'));
    });

    test('国产厂牌词表含主流厂牌', () {
      for (final word in [
        '麻豆',
        '天美传媒',
        '星空传媒',
        '果冻传媒',
        '兔子先生',
        '糖心',
        'SWAG',
        'JVID',
      ]) {
        expect(panDomesticBrandWords, contains(word), reason: word);
      }
    });
  });

  group('DMM cid 换算与图链', () {
    test('常规番号补零至 5 位', () {
      expect(dmmCidForCode('SSIS-001'), 'ssis00001');
      expect(dmmCidForCode('MIDV-123'), 'midv00123');
      expect(dmmCidForCode('ABC-123'), 'abc00123');
    });

    test('非标准番号换算不出回 null', () {
      expect(dmmCidForCode('FC2-PPV-123456'), isNull);
      expect(dmmCidForCode('某片名'), isNull);
    });

    test('封面/海报直链形态', () {
      expect(
        dmmCoverUrl('ssis00001'),
        'https://pics.dmm.co.jp/digital/video/ssis00001/ssis00001pl.jpg',
      );
      expect(
        dmmPosterUrl('ssis00001'),
        'https://pics.dmm.co.jp/digital/video/ssis00001/ssis00001ps.jpg',
      );
    });

    test('占位图门槛常量 = 700（MDCx 口径）', () {
      expect(panMinRealCoverWidth, 700);
    });
  });

  group('图片尺寸头解析（占位过滤用）', () {
    test('PNG IHDR 读宽高', () {
      final bytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
        0, 0, 0x08, 0xAE, 0, 0, 0x05, 0xC0, // 2222 x 1472
      ];
      final size = panImageSizeOf(bytes);
      expect(size?.width, 2222);
      expect(size?.height, 1472);
    });

    test('JPEG SOF0 读宽高', () {
      final bytes = <int>[
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, // APP0 len 16
        ...List.filled(14, 0),
        0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, h=0x05C0? 见下
        0x05, 0xC0, 0x08, 0xAE,
      ];
      final size = panImageSizeOf(bytes);
      expect(size?.height, 0x05C0);
      expect(size?.width, 0x08AE);
    });

    test('非图片字节回 null', () {
      expect(panImageSizeOf([1, 2, 3]), isNull);
    });
  });
}
