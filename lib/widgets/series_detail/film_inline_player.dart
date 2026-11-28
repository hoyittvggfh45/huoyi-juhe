import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/media_item.dart';
import '../../services/episode_source_cache.dart';
import '../../services/inline_video_playback.dart';
import '../../services/library_store.dart';
import '../../services/local_media_proxy.dart';
import '../../services/native_player.dart';
import '../../services/player_history.dart';
import '../../services/shell_proxy_url.dart';

/// 影视区详情页顶部的内联播放器：照火蚁TV播放详情页的版式。
///
/// 上面是 16:9 黑色播放器（点海报直接播），下面由详情页接毛玻璃详情区。
/// 播放会话复用短剧信息流那套 [InlineVideoPlayback]（自建实例、自带播放器
/// 池，不碰短剧区那个共享会话），取流走调用方给的 [contentLoader]（影视区
/// 是站客户端的取流，短剧区默认的番茄接口不走这里）。
///
/// 顶栏（返回 / MPV 徽标 / 方向 / 一起看 / 全屏）与底部控制行（倍速 /
/// 画质 / 选集 / 画中画 / 全屏）照目标截图摆；一起看在修仙版还没接通，
/// 点按只给一句实话，不留静默死入口。播放器后端是原生
/// ExoPlayer（MPV 徽标只是照火蚁TV的版式画的标签，引擎没换——第 14 轮
/// 撤 libmpv 时云端门禁要求 Android 保留 ExoPlayer）。
///
/// 2026-11-28 控件九项修法（用户实测火蚁内嵌播放后点名、凡人照单全
/// 收，只动内嵌控件层、全屏控件不动）：返回键与核心徽标缩小、顶栏贴
/// 画面最上边、控件层（顶栏/中央/底栏）整层一起隐一起显、投屏钮整
/// 个删除、触控钮去掉圆形/胶囊深色底板、画中画接通本应用既有的悬浮
/// 窗服务（点钮即把画面搬进悬浮小窗；需悬浮窗权限，无权限给实话）。
class FilmInlinePlayer extends StatefulWidget {
  const FilmInlinePlayer({
    super.key,
    required this.seriesId,
    required this.title,
    required this.coverUrl,
    required this.episodes,
    required this.episodeIndex,
    this.contentLoader,
    this.playerFactory,
    this.onBack,
    this.onFullscreen,
    this.onOpenEpisodes,
  });

  /// 剧 id：历史存档与取流共用这一份。
  final String seriesId;
  final String title;
  final String coverUrl;

  /// 全集目录（选集切换与取流都从这里取）。
  final List<Chapter> episodes;

  /// 当前集下标（父级持有；切集由父级改这个值 + 调 [playEpisode]）。
  final int episodeIndex;

  /// 取流：(itemId, tab) -> 取流响应。影视区传站客户端的取流；
  /// 不传则走番茄接口（短剧默认），影视区不要不传。
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;

  /// 测试缝：注入假播放器。
  final NativePlayer Function()? playerFactory;

  /// 顶栏返回：父级处理（详情页返回上一级）。
  final VoidCallback? onBack;

  /// 全屏：内联会话先存档 + 销毁播放器，再由父级推整页播放器
  /// （整页播放器从历史续看）。
  final VoidCallback? onFullscreen;

  /// 选集按钮：父级把选集区滚到可见处。
  final VoidCallback? onOpenEpisodes;

  @override
  State<FilmInlinePlayer> createState() => FilmInlinePlayerState();
}

class FilmInlinePlayerState extends State<FilmInlinePlayer>
    with WidgetsBindingObserver {
  static const _speedSteps = <double>[1.0, 1.25, 1.5, 2.0, 0.5];

  late final InlineVideoPlayback _session;
  bool _started = false;
  bool _starting = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  int _generation = 0;

  /// 画中画（悬浮窗）所有者 id：点画中画钮接通后非空；回前台、切集、
  /// 进全屏、控件销毁时都要收掉，避免小窗占着已被换掉的播放器。
  int? _pipOwner;

  /// 拖动预览位置（毫秒，拖进度条或横滑画面时非空）：这段时间里进度
  /// 条与时间文字都以它为准，会话的位置回声（seek 落地前还是旧位置）
  /// 不许把拇指拽回去；松手才真正 seek 一次。此前没有这一层：
  /// onChanged 每动一下就 seek 一次、回声一到进度就弹回旧位置，
  /// 真机上就是「拖不动 / 不能滑动快进」。
  double? _scrubMs;

  /// 横滑起点：先证明横向主导才接管，避免竖着划详情页时误触快进。
  Offset? _swipeOrigin;

  InlineVideoPlayback get session => _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = InlineVideoPlayback(
      contentLoader: widget.contentLoader,
      directoryLoader: (id, tab) async => [widget.episodes],
      playerFactory: widget.playerFactory,
    );
    _session.playing.addListener(_onPlayingChanged);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    final pipOwner = _pipOwner;
    _pipOwner = null;
    if (pipOwner != null) unawaited(NativePlayer.stopFloating(pipOwner));
    _session.playing.removeListener(_onPlayingChanged);
    unawaited(_session.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 悬浮小窗在桌面/其他应用上层播；用户回到本应用就收窗回内嵌面
    // （与整页播放器 _stopFloating 的回程口径一致）。
    if (state == AppLifecycleState.resumed && _pipOwner != null) {
      unawaited(_stopPip());
    }
  }

  /// 收掉画中画悬浮窗（若开着）。原生侧按 owner 退休，迟到的停窗
  /// 不会误伤别的所有者。
  Future<void> _stopPip() async {
    final owner = _pipOwner;
    _pipOwner = null;
    if (owner != null) await NativePlayer.stopFloating(owner);
  }

  /// 画中画：把当前会话播放器搬进系统悬浮小窗（本应用既有的悬浮窗
  /// 服务，与整页播放器切后台小窗同一套）。要悬浮窗权限：没有就打开
  /// 系统设置页并给一句实话，不假装已进小窗。
  Future<void> _enterPip() async {
    if (!_started || !_hasPlayer) {
      _pipSnack('先开始播放，再用画中画');
      return;
    }
    if (_pipOwner != null) {
      _pipSnack('已经在画中画小窗里播放了');
      return;
    }
    final player = _session.player;
    final playerId = player?.playerId;
    if (player == null || playerId == null) {
      _pipSnack('播放器还没就绪，画中画用不了');
      return;
    }
    try {
      if (!await NativePlayer.canDrawOverlays()) {
        await NativePlayer.requestOverlayPermission();
        _pipSnack('画中画需要悬浮窗权限：在系统设置里允许后，再点一次画中画');
        return;
      }
      final owner = await NativePlayer.allocateFloatingOwner();
      final episode = widget.episodes.isEmpty
          ? null
          : widget.episodes[widget.episodeIndex.clamp(
              0,
              widget.episodes.length - 1,
            )];
      final size = _session.videoSize.value;
      await NativePlayer.startFloating(
        owner: owner,
        playerId: playerId,
        title: widget.title,
        episode: episode?.title ?? '',
        playing: _session.playing.value,
        hasPrev: widget.episodeIndex > 0,
        hasNext: widget.episodeIndex + 1 < widget.episodes.length,
        positionMs: _session.position.value.inMilliseconds,
        durationMs: _session.duration.value.inMilliseconds,
        speed: _session.rate.value,
        videoWidth: size.width.round(),
        videoHeight: size.height.round(),
      );
      await NativePlayer.showFloating(owner);
      if (!mounted) {
        await NativePlayer.stopFloating(owner);
        return;
      }
      _pipOwner = owner;
      _showControlsTemporarily();
    } catch (_) {
      _pipSnack('画中画启动失败，这台设备可能不支持悬浮窗');
    }
  }

  void _pipSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _onPlayingChanged() {
    if (_session.playing.value) {
      _armHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  MediaItem get _series => MediaItem(
    id: widget.seriesId,
    seriesId: widget.seriesId,
    title: widget.title,
    cover: widget.coverUrl,
    author: '',
    badge: '',
    ep: '',
    kind: 'video',
  );

  bool get _hasPlayer => _session.hasPlayer;

  /// 从指定集起播（海报播放钮与选集格子都走这里）。
  Future<void> playEpisode(int index) async {
    if (widget.episodes.isEmpty) return;
    // 切集会换播放器：悬浮小窗还占着旧播放器时先收窗。
    await _stopPip();
    final target = index.clamp(0, widget.episodes.length - 1);
    final generation = ++_generation;
    setState(() {
      _started = true;
      _starting = true;
      _controlsVisible = true;
    });
    _armHideTimer();
    Duration? resume;
    try {
      final saved = await PlayerHistory(
        LibraryStore.instance,
      ).load(widget.seriesId);
      if (!mounted || generation != _generation) return;
      final savedIndex = resumeEpisodeIndex(saved, widget.episodes);
      if (savedIndex == target) {
        final raw = saved?['position'];
        if (raw is num && raw.isFinite && raw > 0) {
          resume = Duration(milliseconds: (raw * 1000).round());
        }
      }
    } catch (_) {
      // 本地历史读不到不阻断起播。
    }
    if (!mounted || generation != _generation) return;
    await _session.activate(
      _series,
      startEpisodeIndex: target,
      startPosition: resume,
    );
    if (!mounted || generation != _generation) return;
    setState(() => _starting = false);
    _armHideTimer();
  }

  Future<void> _togglePlay() async {
    if (!_started || _starting) {
      if (!_started) await playEpisode(widget.episodeIndex);
      return;
    }
    if (!_hasPlayer) {
      await playEpisode(widget.episodeIndex);
      return;
    }
    if (_session.playing.value) {
      await _session.pause();
    } else {
      await _session.resume();
    }
    _showControlsTemporarily();
  }

  Future<void> _retry() async {
    await playEpisode(widget.episodeIndex);
  }

  Future<void> _cycleRate() async {
    final current = _session.rate.value;
    final next = _speedSteps[( _speedSteps.indexOf(current) + 1) % _speedSteps.length];
    await _session.selectRate(next);
    _showControlsTemporarily();
  }

  Future<void> _pickQuality() async {
    final variants = _session.variants;
    if (variants.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已是自动画质')));
      }
      return;
    }
    final current = _session.currentVariant;
    final picked = await showModalBottomSheet<EpisodeVariant>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('画质'),
              dense: true,
            ),
            for (final variant in variants)
              ListTile(
                title: Text(variant.name),
                trailing: current?.url == variant.url
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, variant),
              ),
            ListTile(
              title: const Text('自动'),
              trailing: current == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(sheetContext, null),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    // 选「自动」= 回到默认档（variants[0] 是最优档）。
    if (picked != null) {
      await _session.switchVariant(picked);
    } else if (current != null && variants.isNotEmpty) {
      await _session.switchVariant(variants.first);
    }
    _showControlsTemporarily();
  }

  void _openOrientationMenu() {
    showMenu<PlaybackOrientationMode>(
      context: context,
      position: const RelativeRect.fromLTRB(1000, 80, 16, 1000),
      items: const [
        PopupMenuItem(
          value: PlaybackOrientationMode.portrait,
          child: Text('竖屏播放'),
        ),
        PopupMenuItem(
          value: PlaybackOrientationMode.landscape,
          child: Text('横屏全屏'),
        ),
        PopupMenuItem(
          value: PlaybackOrientationMode.auto,
          child: Text('跟随系统'),
        ),
      ],
    ).then((mode) {
      if (mode == null || !mounted) return;
      switch (mode) {
        case PlaybackOrientationMode.portrait:
          unawaited(
            SystemChrome.setPreferredOrientations([
              DeviceOrientation.portraitUp,
            ]),
          );
        case PlaybackOrientationMode.landscape:
          _openFullscreen();
        case PlaybackOrientationMode.auto:
          unawaited(SystemChrome.setPreferredOrientations([]));
      }
    });
  }

  Future<void> _openFullscreen() async {
    if (!_started || !_hasPlayer) {
      widget.onFullscreen?.call();
      return;
    }
    // 全屏要销毁内嵌这台播放器：悬浮小窗先收，免得占着已销毁的实例。
    await _stopPip();
    // 整页播放器自己建一个原生实例：先把内联这台存档 + 销毁，
    // 不然两台 ExoPlayer 并存会抢解码器。
    await _session.disposePlayer();
    if (!mounted) return;
    setState(() {
      _starting = false;
      _controlsVisible = true;
    });
    widget.onFullscreen?.call();
  }

  void _showControlsTemporarily() {
    setState(() => _controlsVisible = true);
    _armHideTimer();
  }

  /// 拖动收尾：预览清掉、真正 seek 只发一次（经会话发，弹幕游标等
  /// 收尾动作都挂在会话的 seek 上，一次到位）。
  void _commitScrub() {
    final scrub = _scrubMs;
    _swipeOrigin = null;
    if (scrub == null) return;
    setState(() => _scrubMs = null);
    unawaited(_session.seek(Duration(milliseconds: scrub.round())));
    _showControlsTemporarily();
  }

  void _cancelScrub() {
    _swipeOrigin = null;
    if (_scrubMs != null) setState(() => _scrubMs = null);
  }

  /// 横滑快进（与主播放页 chrome 同规则：横向位移映射整片时间轴）。
  /// 总时长未知（直播式/未就绪）时不接管，与进度条的禁用门一致。
  void _startSwipeSeek(DragStartDetails details) {
    if (_session.duration.value <= Duration.zero) return;
    _swipeOrigin = details.localPosition;
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  void _updateSwipeSeek(DragUpdateDetails details) {
    final origin = _swipeOrigin;
    if (origin == null) return;
    if (_scrubMs == null) {
      final dx = details.localPosition.dx - origin.dx;
      final dy = details.localPosition.dy - origin.dy;
      if (dx.abs() < kTouchSlop || dx.abs() < dy.abs()) return;
    }
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final total = _session.duration.value.inMilliseconds.toDouble();
    setState(
      () => _scrubMs = (details.localPosition.dx / width).clamp(0.0, 1.0) *
          total,
    );
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    if (!_session.playing.value) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _session.playing.value) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  String _format(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes % 60;
    final seconds = value.inSeconds % 60;
    final tail =
        '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    return hours > 0 ? '$hours:$tail' : tail;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        key: const ValueKey('film-inline-player'),
        color: Colors.black,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _session.textureId,
            _session.firstFrame,
            _session.error,
            _session.playing,
            _session.position,
            _session.duration,
            _session.rate,
            _session.videoSize,
          ]),
          builder: (context, _) => _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final textureId = _session.textureId.value;
    final error = _session.error.value;
    final playing = _session.playing.value;
    final firstFrame = _session.firstFrame.value;
    final loading = _starting || (_started && _hasPlayer && !firstFrame);
    final showPoster = textureId == null || !firstFrame;
    final episode = widget.episodes.isEmpty
        ? null
        : widget.episodes[widget.episodeIndex.clamp(
            0,
            widget.episodes.length - 1,
          )];
    return Stack(
      fit: StackFit.expand,
      children: [
        if (textureId != null)
          _videoTexture(textureId)
        else if (widget.coverUrl.isNotEmpty)
          _poster()
        else
          const ColoredBox(color: Colors.black),
        if (showPoster && widget.coverUrl.isNotEmpty && textureId == null)
          Container(color: Colors.black.withValues(alpha: 0.35)),
        // 手势层在遮罩之下、控制键之下：点画面切控制显隐、双击切播放/暂停；
        // 暂停钮、重试钮与顶栏/底栏都在它上面，各自收自己的点按。
        if (_started && _hasPlayer && error == null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_controlsVisible) {
                  setState(() => _controlsVisible = false);
                  _hideTimer?.cancel();
                } else {
                  _showControlsTemporarily();
                }
              },
              onDoubleTap: _togglePlay,
              onHorizontalDragStart: _startSwipeSeek,
              onHorizontalDragUpdate: _updateSwipeSeek,
              onHorizontalDragEnd: (_) => _commitScrub(),
              onHorizontalDragCancel: _cancelScrub,
              child: const SizedBox.expand(),
            ),
          ),
        if (error != null)
          _errorOverlay(error)
        else if (loading)
          _loadingOverlay(episode)
        // 控件层整层同显同隐（九项修法第 2 项）：中央暂停钮不再自成
        // 一层——未起播时它就是起播入口常驻；起播后跟顶栏/底栏共用
        // 同一个 _controlsVisible，隐时一起隐、显时一起显。
        else if (!_started || (!playing && _controlsVisible))
          _pausedOverlay(episode),
        if (_controlsVisible || !_started) _topBar(),
        if (_controlsVisible && _started && _hasPlayer && error == null)
          _bottomControls(),
      ],
    );
  }

  Widget _videoTexture(int textureId) {
    final size = _session.videoSize.value;
    final aspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : 16 / 9;
    final turns = _session.rotation.value;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: RotatedBox(
          quarterTurns: turns,
          child: Texture(
            key: const ValueKey('film-inline-texture'),
            textureId: textureId,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }

  Widget _poster() {
    // 封面形态不止旧壳代理一种（proxy://、http 明文图、回环不透明
    // 形态都会在手机上失败），统一走 resolveCoverUrl 换地址。
    final resolved = resolveCoverUrl(
      widget.coverUrl,
      proxyBase: LocalMediaProxy.instance.baseUrl,
    );
    return CachedNetworkImage(
      imageUrl: resolved.url,
      httpHeaders: resolved.headers,
      fit: BoxFit.cover,
      errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
      placeholder: (_, _) => const ColoredBox(color: Colors.black),
    );
  }

  Widget _loadingOverlay(Chapter? episode) {
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Color(0xFFFF6B4A),
                ),
              ),
            ),
            if (episode != null) ...[
              const SizedBox(height: 12),
              Text(
                '正在准备播放 · ${episode.title}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pausedOverlay(Chapter? episode) {
    if (widget.episodes.isEmpty) {
      return const Center(
        child: Text(
          '暂无剧集',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
      );
    }
    return Center(
      child: IconButton.filled(
        key: const ValueKey('film-inline-play'),
        tooltip: '播放',
        onPressed: _togglePlay,
        icon: const Icon(Icons.play_arrow_rounded, size: 40),
        style: IconButton.styleFrom(
          minimumSize: const Size(64, 64),
          backgroundColor: Colors.white.withValues(alpha: 0.92),
          foregroundColor: Colors.black87,
        ),
      ),
    );
  }

  Widget _errorOverlay(String message) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.white70,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  key: const ValueKey('film-inline-retry'),
                  onPressed: _retry,
                  child: const Text('重试'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const ValueKey('film-inline-error-fullscreen'),
                  onPressed: _openFullscreen,
                  child: const Text('全屏播放'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 内嵌控件层小触控口径（九项修法第 1/5/7/8/9 项）：按钮触控区
  /// 36dp（IconButton 默认会撑到 48，这里用定尺盒子压住）、图标
  /// 直接落在画面上不要底板。
  Widget _barButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
    double iconSize = 20,
  }) {
    return SizedBox.square(
      dimension: 36,
      child: IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.transparent],
          ),
        ),
        // 第 8 项：顶栏贴画面最上边排布（上内边距 0）。
        padding: const EdgeInsets.fromLTRB(2, 0, 4, 10),
        child: Row(
          children: [
            _barButton(
              key: const ValueKey('film-inline-back'),
              tooltip: '返回',
              onPressed: widget.onBack,
              icon: Icons.arrow_back_ios_new_rounded,
              iconSize: 19,
            ),
            const Spacer(),
            _coreBadge(),
            const SizedBox(width: 2),
            _barButton(
              key: const ValueKey('film-inline-orientation'),
              tooltip: '方向控制',
              onPressed: _openOrientationMenu,
              icon: Icons.screen_rotation_alt_rounded,
            ),
            _barButton(
              key: const ValueKey('film-inline-watchroom'),
              tooltip: '推送到一起看',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('一起看房间还没做好')),
                );
              },
              icon: Icons.home_rounded,
            ),
            _barButton(
              key: const ValueKey('film-inline-fullscreen-top'),
              tooltip: '全屏',
              onPressed: _openFullscreen,
              icon: Icons.fullscreen_rounded,
              iconSize: 21,
            ),
          ],
        ),
      ),
    );
  }

  /// 播放器后端徽标：照火蚁TV的版式画成 MPV（用户点的图就是这个样子）。
  /// 底下真是原生 ExoPlayer——第 14 轮撤 libmpv 时云端门禁要求 Android
  /// 保留 ExoPlayer，引擎没换；点徽标只说明这一点，不切换后端。
  /// 九项修法第 5/9 项：胶囊再缩小一档，且去掉深色底板与描边，字直接
  /// 落在画面上（加一层轻投影保可读）。
  Widget _coreBadge() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('film-inline-core'),
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前播放器：原生 ExoPlayer')),
          );
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Text(
            'MPV',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              shadows: [Shadow(color: Color(0x99000000), blurRadius: 4)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomControls() {
    final position = _session.position.value;
    final duration = _session.duration.value;
    final rate = _session.rate.value;
    final qualityLabel = _qualityLabel();
    final max = duration.inMilliseconds.toDouble();
    final value = max > 0
        ? position.inMilliseconds.toDouble().clamp(0, max).toDouble()
        : 0.0;
    // 拖动中以预览位置为准：进度条与左端时间都跟着手指走，不被会话
    // 的位置回声拽回旧位置。
    final shownMs = _scrubMs ?? value;
    final shownPosition = Duration(milliseconds: shownMs.round());
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _pillButton(
                  key: const ValueKey('film-inline-speed'),
                  label: '${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 1 : 2)}x',
                  tooltip: '倍速',
                  onPressed: _cycleRate,
                ),
                const SizedBox(width: 8),
                _pillButton(
                  key: const ValueKey('film-inline-quality'),
                  label: qualityLabel,
                  tooltip: '画质',
                  onPressed: _pickQuality,
                ),
                const Spacer(),
                _barButton(
                  key: const ValueKey('film-inline-episodes'),
                  tooltip: '选集',
                  onPressed: widget.onOpenEpisodes,
                  icon: Icons.grid_view_rounded,
                ),
                _barButton(
                  key: const ValueKey('film-inline-pip'),
                  tooltip: '画中画',
                  onPressed: () => unawaited(_enterPip()),
                  icon: Icons.picture_in_picture_alt_rounded,
                  iconSize: 19,
                ),
                _barButton(
                  key: const ValueKey('film-inline-fullscreen'),
                  tooltip: '全屏',
                  onPressed: _openFullscreen,
                  icon: Icons.fullscreen_rounded,
                  iconSize: 21,
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  _format(shownPosition),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white38,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: shownMs,
                      max: max > 0 ? max : 1.0,
                      onChangeStart: max > 0
                          ? (v) {
                              _hideTimer?.cancel();
                              setState(() => _scrubMs = v);
                            }
                          : null,
                      onChanged: max > 0
                          ? (v) {
                              // 拖动中只更新预览，不发 seek：每动一下就
                              // seek 一次会把原生侧塞满过期目标，位置
                              // 回声还会把进度拽回旧位置。
                              setState(() => _scrubMs = v);
                            }
                          : null,
                      onChangeEnd: max > 0 ? (_) => _commitScrub() : null,
                    ),
                  ),
                ),
                Text(
                  _format(duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _qualityLabel() {
    final current = _session.currentVariant;
    if (current != null) return current.name;
    return '自动';
  }

  /// 文字钮（倍速/画质）：九项修法第 9 项——去掉胶囊深色底板与描边，
  /// 文字直接落在画面上（轻投影保可读），只留涟漪反馈。
  Widget _pillButton({
    required Key key,
    required String label,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Color(0x99000000), blurRadius: 4)],
            ),
          ),
        ),
      ),
    );
  }
}

/// 方向菜单的三档：竖屏留在详情页、横屏进整页全屏、自动跟随系统。
enum PlaybackOrientationMode { portrait, landscape, auto }
