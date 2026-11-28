/// 网盘刮削识别层：文件名 → 分型 + 钥匙（番号/cid/片名）。
///
/// 顺序照调查口径（xiuxian_scraper_survey_20261128 §3.1/§4.2）：
/// 先剥噪声（ignore 词表＋正则：分辨率/编码/发布组/站点广告
/// 域名），再按形态分型——FC2、无码、有码番号、连写 cid、
/// 国产、普通影视，各走各链。番号提取复用既有
/// [panCoverExtractCode]（星辰115 提取器等价实现＋窄口径救
/// 援），不另写第二套番号规则；本层只补它不覆盖的形态判别
/// （无码标记、连写 cid、国产前缀）与 DMM cid 换算。
library;

import 'cloud_cover_scrape.dart';
import 'cloud_filename.dart';

/// 刮削分型（决定走哪条站点链）。
enum PanScrapeKind {
  /// 普通影视（剧名+季集+年份，走 TMDB→豆瓣）。
  film,

  /// 有码番号（字母-数字）。
  coded,

  /// 无码（无码前缀厂牌或文件名带无码标记）。
  uncensored,

  /// FC2（FC2-PPV-数字）。
  fc2,

  /// 连写 cid（无横杠的 DMM content_id 形态，如 ssni00321、
  /// 259luxu0123、h_1234abcd00012）。
  cid,

  /// 国产（麻豆系等国产前缀/标记）。
  domestic,
}

/// 识别结果：分型 + 该型的刮削钥匙 + 影视解析（film 型用）。
class PanScrapeIdentity {
  const PanScrapeIdentity({
    required this.kind,
    required this.rawName,
    this.code,
    this.cid,
    this.parsed,
  });

  final PanScrapeKind kind;

  /// 原始文件名/文件夹名（展示回落用，一个字不改）。
  final String rawName;

  /// 番号（coded/uncensored/fc2 型；大写横杠形态）。
  final String? code;

  /// DMM content_id（cid 型为识别出的连写值；coded 型可由
  /// [dmmCidForCode] 换算，不在此存）。
  final String? cid;

  /// 普通影视的文件名解析（film 型；其余型为 null）。
  final ParsedCloudFileName? parsed;

  /// 链键（对 PanScrapeSettings.chains 的键）。
  String get chainKey => switch (kind) {
    PanScrapeKind.film => 'film',
    PanScrapeKind.coded => 'coded',
    PanScrapeKind.uncensored => 'uncensored',
    PanScrapeKind.fc2 => 'fc2',
    PanScrapeKind.cid => 'cid',
    PanScrapeKind.domestic => 'domestic',
  };

  /// 缓存/去重用的稳定钥匙：番号型用番号、cid 用 cid、
  /// film 用归一剧名+年份+季。
  String get stableKey => switch (kind) {
    PanScrapeKind.coded ||
    PanScrapeKind.uncensored ||
    PanScrapeKind.fc2 => 'code:${code ?? ''}',
    PanScrapeKind.cid => 'cid:${cid ?? ''}',
    PanScrapeKind.domestic => 'code:${code ?? ''}',
    PanScrapeKind.film =>
      'film:${parsed?.normalizedKey ?? ''}|${parsed?.year ?? ''}|${parsed?.season ?? ''}',
  };
}

/// 无码厂牌前缀（调查 §1.1/§3.2：AVSOX 无码专站覆盖的厂牌
/// 与 AVDC 无码路由表）。命中即无码型，不等「无码」字样。
const panUncensoredPrefixes = {
  '1PONDO',
  '1PON',
  'CARIBBEANCOM',
  'CARIB',
  'CARIBBEAN',
  'HEYZO',
  '10MUSUME',
  'PACOPACOMAMA',
  'PACO',
  'TOKYOHOT',
  'TOKYO-HOT',
  'XXXAV',
  'XXX-AV',
  'KIN8',
  'H4610',
  'H0930',
  'C0930',
  'H0930PLA',
  'MESUVI',
  'SM3D2DBD',
  'FC2',
};

/// 国产前缀/标记（MDCx 国产三站 cnmdb/madouqu/mdtv 覆盖的
/// 麻豆系番号形态）。
const panDomesticPrefixes = {'MD', 'MKY', 'PMC', 'MAD', 'MDX', 'MDHG'};

/// 国产成人厂牌词表（2026-11-28 20:16 追加令：国产多无番
/// 号，识别走中文标题/厂商特征）：收录的是公开可查的国产
/// 成人厂牌名（麻豆/天美/星空/果冻/兔子先生/蜜桃/香蕉/
/// 草莓/糖心/精东/皇家华人/爱豆/SWAG/JVID/91传媒 等），
/// 标题含其一即判国产成人型。词表来源＝业内公开厂牌名录
/// 与 MDCx 国产爬虫（madouqu/mdtv/cnmdb）的覆盖对象；查
/// 不到出处的野词不收，避免误判普通影视。
const panDomesticBrandWords = [
  '麻豆传媒',
  '麻豆',
  '天美传媒',
  '星空传媒',
  '果冻传媒',
  '兔子先生',
  '蜜桃传媒',
  '香蕉传媒',
  '草莓传媒',
  '糖心',
  '精东影业',
  '精东',
  '皇家华人',
  '爱豆传媒',
  '91传媒',
  'SWAG',
  'JVID',
  '西瓜传媒',
  '葡萄传媒',
  '乐播传媒',
];

/// 标题是否带国产厂牌特征。
bool panHasDomesticBrand(String name) {
  final upper = name.toUpperCase();
  for (final word in panDomesticBrandWords) {
    if (upper.contains(word.toUpperCase())) return true;
  }
  return false;
}

/// 站点广告/噪声域名正则（JavSP 的 ignore 思路，调查 §1.2：
/// 番号提取前先剥站点广告）。匹配独立出现的域名片段。
final _adDomainPattern = RegExp(
  r'[\w-]+(?:\.[\w-]+)*\.(?:com|net|org|cc|xyz|tv|la|app|club|site|info|io|me|co)(?:\.cn)?',
  caseSensitive: false,
);

/// 发布噪声词（在 cloud_filename 的发布标签之外，补成人资源
/// 圈常见词：素人/无码/流出/广告尾巴等——只剥独立成词者）。
final _noiseTokens = <RegExp>[
  RegExp(
    r'(?:^|[\s._\-－—\[\]()（）])(uncensored|leak|leaked|无码|有码|破解|流出|字幕|中文字幕|中文配音|高清|超清|原版|完整版|未删减)(?=$|[\s._\-－—\[\]()（）])',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(720p|1080p|2160p|480p|4k|8k|fhd|uhd|hd|sd)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(x264|x265|h264|h265|hevc|avc|aac|mp4|mkv|avi|wmv|ts|rmvb)\b',
    caseSensitive: false,
  ),
  RegExp(r'[@＠][\w.-]+'),
];

/// 剥噪声：去扩展名、广告域名、方括号段、噪声词。番号提取与
/// 分型都在剥后文本上做（调查 §3.1「ignore 词表先剥」）。
String panStripNoise(String name) {
  var text = name.trim();
  final dot = text.lastIndexOf('.');
  if (dot > 0) text = text.substring(0, dot);
  text = text.replaceAll(RegExp(r'\[[^\[\]]*\]'), ' ');
  text = text.replaceAll(RegExp(r'【[^】]*】'), ' ');
  text = text.replaceAll(_adDomainPattern, ' ');
  for (final token in _noiseTokens) {
    text = text.replaceAll(token, ' ');
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 连写 cid 识别：无横杠的字母数字连写，且符合 DMM
/// content_id 常见形态——
/// 1. `h_` 前缀型：h_1234abcd00012（厂商数字码+字母+数字）；
/// 2. 数字前缀系列：259luxu0123、300mium-…（3 位数字+字母+
/// 数字，MGStage 素人系）；
/// 3. 字母前缀连写：ssni00321、midv00123（字母 2–8 位+数字
/// 4–6 位、数字带前导零或总长 ≥7）——与普通英文单词区分
/// 的关键是尾部数字长度与前导零。
String? panExtractCid(String strippedName) {
  final compact = strippedName.toUpperCase().replaceAll(
    RegExp(r'[\s._-]+'),
    '',
  );
  final hForm = RegExp(
    r'^(H_\d{3,5}[A-Z]{2,8}\d{3,6})$',
  ).firstMatch(strippedName.toUpperCase().replaceAll(RegExp(r'[\s.]+'), ''));
  if (hForm != null) return hForm.group(1)!.toLowerCase();
  final numericPrefix = RegExp(
    r'^(\d{3}[A-Z]{3,8}\d{3,5})(?!\d)',
  ).firstMatch(compact);
  if (numericPrefix != null) return numericPrefix.group(1)!.toLowerCase();
  final alphaPrefix = RegExp(
    r'^([A-Z]{2,8})(0\d{3,5}|\d{5,6})$',
  ).firstMatch(compact);
  if (alphaPrefix != null) {
    return '${alphaPrefix.group(1)!.toLowerCase()}${alphaPrefix.group(2)!}';
  }
  return null;
}

/// 主识别：文件名/文件夹名 → 分型与钥匙。
PanScrapeIdentity panIdentify(String rawName) {
  final stripped = panStripNoise(rawName);
  final upper = stripped.toUpperCase();

  // 1) 番号提取（既有提取器，内含 FC2/HEYZO/日期素人等形态）。
  final code = panCoverExtractCode(rawName);
  if (code != null && code.isNotEmpty) {
    if (code.startsWith('FC2')) {
      return PanScrapeIdentity(
        kind: PanScrapeKind.fc2,
        rawName: rawName,
        code: code,
      );
    }
    // 国产厂牌词优先于番号前缀分型：带厂牌的国产片哪怕
    // 有自编番号（星空 XK- 等）也归国产成人链，不串有码链。
    if (panHasDomesticBrand(rawName)) {
      return PanScrapeIdentity(
        kind: PanScrapeKind.domestic,
        rawName: rawName,
        code: code,
        parsed: parseCloudFileName(rawName),
      );
    }
    final prefix = code.split('-').first;
    if (panDomesticPrefixes.contains(prefix)) {
      return PanScrapeIdentity(
        kind: PanScrapeKind.domestic,
        rawName: rawName,
        code: code,
        parsed: parseCloudFileName(rawName),
      );
    }
    // 无码判别：厂牌前缀命中，或原名带无码标记（-U/UC 后缀、
    // UNCENSORED/无码 字样——提取器会把 -UC 吃掉，故查原名）。
    final uncensoredMarked =
        RegExp(r'uncensored|无码', caseSensitive: false).hasMatch(rawName) ||
        RegExp(
          r'[-_](UC|U)(?=[-_\s.]|$)',
          caseSensitive: false,
        ).hasMatch(upper);
    if (panUncensoredPrefixes.contains(prefix) || uncensoredMarked) {
      return PanScrapeIdentity(
        kind: PanScrapeKind.uncensored,
        rawName: rawName,
        code: code,
      );
    }
    return PanScrapeIdentity(
      kind: PanScrapeKind.coded,
      rawName: rawName,
      code: code,
    );
  }

  // 2) 连写 cid（番号提取器不认无横杠形态）。
  final cid = panExtractCid(stripped);
  if (cid != null) {
    return PanScrapeIdentity(
      kind: PanScrapeKind.cid,
      rawName: rawName,
      cid: cid,
    );
  }

  // 3) 国产标记（无标准番号形态时按词判）。
  if (panHasDomesticBrand(rawName)) {
    return PanScrapeIdentity(
      kind: PanScrapeKind.domestic,
      rawName: rawName,
      parsed: parseCloudFileName(rawName),
    );
  }

  // 4) 普通影视：文件名解析（剧名/季集/年份）。
  return PanScrapeIdentity(
    kind: PanScrapeKind.film,
    rawName: rawName,
    parsed: parseCloudFileName(rawName),
  );
}

// ---------------------------------------------------------------------------
// 番号 → DMM cid 换算（DMM 高清封面升级链的钥匙，调查 §3.3）
// ---------------------------------------------------------------------------

/// 特殊前缀映射：默认规则（小写前缀＋数字补零至 5 位）不成立
/// 的系列。结构照 MDCx dmm 爬虫的 cid 生成口径建表：值是
/// 「cid 前缀」，数字段仍按补零规则拼。未逐字取到 MDCx 全量
/// 前缀表（其表内嵌在各爬虫代码里、无独立数据文件），本表
/// 收录的是可由公开样本验证的常见系列＋规则推导，报告里已
/// 标注来源口径。
const panDmmCidPrefixOverrides = <String, String>{
  // S1 系旧作 cid 用 ssni/ssni 数字段 3 位起，样本 SSIS-001 →
  // ssis00001 已实拉验证（2026-11-28 本机 pics.dmm.co.jp 200）。
  'SSIS': 'ssis',
  // TMA/民间连写系：数字段不补到 5 位、保持 3 位的已知系列。
  'T28': 't28',
  'MKBD': 'mkbd',
};

/// 数字段补零位数特例（默认 5 位）。
const panDmmCidDigitWidthOverrides = <String, int>{'T28': 3, 'MKBD': 4};

/// 番号 → DMM content_id。换算不出（无标准番号形态）回 null。
/// 规则：前缀小写（或查特例表）＋数字段补零至 5 位（或特例
/// 位数）。例：SSIS-001 → ssis00001、MIDV-123 → midv00123
/// （调查 §1.1 的 DMM 映射例）。
String? dmmCidForCode(String code) {
  final match = RegExp(
    r'^([A-Z]+)-(\d+)$',
  ).firstMatch(code.trim().toUpperCase());
  if (match == null) return null;
  final prefix = match.group(1)!;
  final digits = match.group(2)!;
  final cidPrefix = panDmmCidPrefixOverrides[prefix] ?? prefix.toLowerCase();
  final width = panDmmCidDigitWidthOverrides[prefix] ?? 5;
  final padded = digits.length >= width ? digits : digits.padLeft(width, '0');
  return '$cidPrefix$padded';
}

/// DMM 官方图床封面地址（调查 §3.3：awsimgsrc/pics 直链，
/// 竖版 ps/pl 与横版 pl 的命名口径——pl=大图横版约
/// 2184×1469 级、ps=竖版海报）。
String dmmCoverUrl(String cid) =>
    'https://pics.dmm.co.jp/digital/video/$cid/${cid}pl.jpg';

String dmmPosterUrl(String cid) =>
    'https://pics.dmm.co.jp/digital/video/$cid/${cid}ps.jpg';

/// 占位图过滤（MDCx 口径，调查 §3.3）：宽 < 700 的图视为
/// 占位/低清，不认作真封面。
const int panMinRealCoverWidth = 700;

/// 从图片字节头读宽高（JPEG SOF / PNG IHDR / GIF 头，纯解析
/// 不解码整图）：读不出回 null。供 DMM 直链图的占位过滤用。
({int width, int height})? panImageSizeOf(List<int> bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    final width =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final height =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    return (width: width, height: height);
  }
  if (bytes.length >= 10 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var i = 2;
    while (i + 8 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
        final height = (bytes[i + 5] << 8) | bytes[i + 6];
        final width = (bytes[i + 7] << 8) | bytes[i + 8];
        return (width: width, height: height);
      }
      final length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length < 2) break;
      i += 2 + length;
    }
  }
  return null;
}
