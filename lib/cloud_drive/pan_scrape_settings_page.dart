/// 网盘刮削设置页（2026-11-28 20:16 追加令：网盘界面留
/// 刮削设置区、站点可勾选）：打开就是出厂预置好的那套值
/// （主链全勾、冷门不勾），不是空设置等用户填。
///
/// 结构：
/// - 开关区（勾选式）：自动刮削、成人链、分类视图、真实
///   移动（默认关＋防误移说明）、JavDB 无水印图通道；
/// - JavDB Cookie 输入（网页版无码内容用，可空）；
/// - 分类文件夹区：定稿 12 类逐个勾选；
/// - 站点区两组勾选：番号链组（本地/JavDB/DMM/JavBus/
///   JavLibrary/FC2 与无码各站＋MDCx 全名单）与影视库组
///   （TMDB/豆瓣/Bangumi）；每条链可展开调序（上移/下移）；
/// - 恢复默认一键回出厂档。
/// 改动即落盘（PanScrapeSettingsStore），返回时把新设置
/// 带回多媒体页即时生效。
library;

import 'package:flutter/material.dart';

import 'pan_scrape_adapter.dart';
import 'pan_scrape_archive.dart';
import 'pan_scrape_settings.dart';

class PanScrapeSettingsPage extends StatefulWidget {
  const PanScrapeSettingsPage({super.key, required this.initial, this.store});

  final PanScrapeSettings initial;
  final PanScrapeSettingsStore? store;

  @override
  State<PanScrapeSettingsPage> createState() => _PanScrapeSettingsPageState();
}

class _PanScrapeSettingsPageState extends State<PanScrapeSettingsPage> {
  late PanScrapeSettings _settings = widget.initial;
  late final _store = widget.store ?? PanScrapeSettingsStore();
  late final _cookieController = TextEditingController(
    text: widget.initial.javdbCookie,
  );

  static const _chainLabels = {
    'coded': '有码链',
    'uncensored': '无码链',
    'fc2': 'FC2 链',
    'cid': '连写 cid 链',
    'film': '普通影视链',
    'domestic': '国产成人链',
  };

  @override
  void dispose() {
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _apply(PanScrapeSettings next) async {
    setState(() => _settings = next);
    await _store.save(next);
  }

  Future<void> _resetDefaults() async {
    await _store.reset();
    setState(() {
      _settings = PanScrapeDefaults.settings;
      _cookieController.text = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_settings);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('刮削设置')),
        body: ListView(
          key: const ValueKey('pan-scrape-settings'),
          children: [
            _sectionTitle('刮削开关'),
            CheckboxListTile(
              key: const ValueKey('pan-setting-auto'),
              title: const Text('自动刮削'),
              subtitle: const Text('进文件夹后后台增量刮，不挡浏览和播放'),
              value: _settings.autoScrape,
              onChanged: (v) =>
                  _apply(_settings.copyWith(autoScrape: v ?? true)),
            ),
            CheckboxListTile(
              key: const ValueKey('pan-setting-adult'),
              title: const Text('成人（番号）链'),
              subtitle: const Text('关掉后番号/无码/FC2/国产条目不再刮削'),
              value: _settings.adultChainEnabled,
              onChanged: (v) =>
                  _apply(_settings.copyWith(adultChainEnabled: v ?? true)),
            ),
            CheckboxListTile(
              key: const ValueKey('pan-setting-archive-view'),
              title: const Text('刮后分类视图'),
              subtitle: const Text('多媒体页按分类筛选（虚拟归档，不动网盘文件）'),
              value: _settings.archiveViewEnabled,
              onChanged: (v) =>
                  _apply(_settings.copyWith(archiveViewEnabled: v ?? true)),
            ),
            CheckboxListTile(
              key: const ValueKey('pan-setting-real-move'),
              title: const Text('真实建夹移动'),
              subtitle: const Text(
                '把刮成的条目移进网盘里的分类文件夹（会改动网盘文件）。'
                '只移刮成且分类明确的，未识别不动；五家网盘（115/夸克/'
                '阿里/百度/移动云盘）均已支持建夹与移动，真账号实移'
                '待真机验证',
              ),
              value: _settings.realMoveEnabled,
              onChanged: (v) =>
                  _apply(_settings.copyWith(realMoveEnabled: v ?? false)),
            ),
            CheckboxListTile(
              key: const ValueKey('pan-setting-cdn-rewrite'),
              title: const Text('JavDB 无水印图通道'),
              subtitle: const Text('封面图走 tp.spfcas.com（未实证，默认关）'),
              value: _settings.javdbImageCdnRewrite,
              onChanged: (v) =>
                  _apply(_settings.copyWith(javdbImageCdnRewrite: v ?? false)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                key: const ValueKey('pan-setting-cookie'),
                controller: _cookieController,
                decoration: const InputDecoration(
                  labelText: 'JavDB 网页版 Cookie（可空）',
                  hintText: '无码内容网页版需要；接口路不用填',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _apply(_settings.copyWith(javdbCookie: v)),
              ),
            ),
            _sectionTitle('分类文件夹（刮后归档）'),
            for (final category in panScrapeCategories)
              CheckboxListTile(
                key: ValueKey('pan-setting-category-${category.id}'),
                title: Text(category.label),
                value: _settings.enabledCategories.contains(category.id),
                onChanged: (v) {
                  final next = Set<String>.from(_settings.enabledCategories);
                  if (v ?? false) {
                    next.add(category.id);
                  } else {
                    next.remove(category.id);
                  }
                  _apply(_settings.copyWith(enabledCategories: next));
                },
              ),
            _sectionTitle('站点（按类型自动分组，组级可整组启停）'),
            for (final group in panSiteGroups) ...[
              _groupHeader(group),
              for (final spec in panGroupedSiteSpecs()[group.id]!)
                _siteTile(spec),
            ],
            _sectionTitle('站点链顺序（展开调序）'),
            for (final entry in _settings.chains.entries)
              _chainTile(entry.key, entry.value),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                key: const ValueKey('pan-setting-reset'),
                onPressed: _resetDefaults,
                child: const Text('恢复默认设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 组头：组名＋站数＋整组勾选（全勾才算勾，点一下整组
  /// 开/关）。组别由适配器自描述自动归（panSiteGroupOf），
  /// 新加的站自动进组，这里不维护任何人工名单。
  Widget _groupHeader(PanSiteGroup group) {
    final specs = panGroupedSiteSpecs()[group.id]!;
    if (specs.isEmpty) return const SizedBox.shrink();
    final allEnabled = specs.every(
      (spec) => _settings.enabledSites.contains(spec.id),
    );
    return CheckboxListTile(
      key: ValueKey('pan-setting-group-${group.id}'),
      title: Text(
        '${group.label}（${specs.length} 站）',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      value: allEnabled,
      onChanged: (v) {
        final next = Set<String>.from(_settings.enabledSites);
        if (v ?? false) {
          next.addAll(specs.map((spec) => spec.id));
        } else {
          next.removeAll(specs.map((spec) => spec.id));
        }
        _apply(_settings.copyWith(enabledSites: next));
      },
    );
  }

  Widget _siteTile(PanScrapeSiteSpec spec) {
    final enabled = _settings.enabledSites.contains(spec.id);
    final cross = panSiteCrossGroupsOf(spec);
    final subtitleParts = [
      if (cross.isNotEmpty) '兼属：${cross.join('、')}',
      if (spec.note.isNotEmpty) spec.note,
    ];
    return CheckboxListTile(
      key: ValueKey('pan-setting-site-${spec.id}'),
      title: Text(spec.name),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join('；')),
      value: enabled,
      onChanged: (v) {
        final next = Set<String>.from(_settings.enabledSites);
        if (v ?? false) {
          next.add(spec.id);
        } else {
          next.remove(spec.id);
        }
        _apply(_settings.copyWith(enabledSites: next));
      },
    );
  }

  Widget _chainTile(String chainKey, List<String> chain) {
    return ExpansionTile(
      key: ValueKey('pan-setting-chain-$chainKey'),
      title: Text(_chainLabels[chainKey] ?? chainKey),
      children: [
        for (var i = 0; i < chain.length; i++)
          ListTile(
            key: ValueKey('pan-setting-chain-$chainKey-${chain[i]}'),
            dense: true,
            title: Text(
              '${i + 1}. ${panScrapeSiteSpecs[chain[i]]?.name ?? chain[i]}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: i == 0 ? null : () => _move(chainKey, i, -1),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: i == chain.length - 1
                      ? null
                      : () => _move(chainKey, i, 1),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _move(String chainKey, int index, int delta) {
    final chains = {
      for (final entry in _settings.chains.entries)
        entry.key: List<String>.from(entry.value),
    };
    final list = chains[chainKey]!;
    final target = index + delta;
    if (target < 0 || target >= list.length) return;
    final item = list.removeAt(index);
    list.insert(target, item);
    _apply(_settings.copyWith(chains: chains));
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }
}
