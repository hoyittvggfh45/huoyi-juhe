// 内嵌播放器控件九项修法（2026-11-28 用户实测火蚁内嵌播放后点名、
// 凡人照单全收）逐项断言。只针对内嵌控件层（片库 FilmInlinePlayer
// 与演员 ActressInlinePlayer）；全屏控件（VideoPlayerChrome）的
// 回归由 player_fullscreen_return_test 等既有组护住，本文件不碰。
//
// 片库侧全部断言挤在一个用例里、只起播一次：FilmInlinePlayer 起播
// 前经 PlayerHistory 读 LibraryStore 单例，首个用例拆台时的存档写
// 链（挂在该单例的静态写队列上）若落进已死的假时钟区就永不落定，
// 后续用例的 load() 会等它等不到头、永远走不到建播放器（双用例
// 探针实证）。一个用例内顺序验完九项就没有第二次起播。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/actress/actress_inline_player.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/series_detail/film_inline_player.dart';

import 'support/controlled_player.dart';

Widget _filmHost(List<ControlledNativePlayer> players) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 800,
          child: FilmInlinePlayer(
            seriesId: 'film-nine',
            title: '抽象三国第一季',
            coverUrl: '',
            episodes: [
              Chapter(itemId: 'film-nine-e1', title: '第1集', volumeName: ''),
              Chapter(itemId: 'film-nine-e2', title: '第2集', volumeName: ''),
            ],
            episodeIndex: 0,
            contentLoader: (itemId, tab) async => {
              'video_url': 'https://example.invalid/$itemId.mp4',
            },
            playerFactory: () {
              final player = ControlledNativePlayer();
              players.add(player);
              return player;
            },
            onBack: () {},
            onFullscreen: () {},
            onOpenEpisodes: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('片库内嵌九项：删投屏/返回缩小贴顶/旋转单个/徽标缩小无底板/整层同隐同显/画中画接通', (
    tester,
  ) async {
    final players = <ControlledNativePlayer>[];
    await tester.pumpWidget(_filmHost(players));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('film-inline-play')));
    for (var i = 0; i < 50 && players.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(players, hasLength(1));
    players.single.emitFirstFrame();
    await tester.pump();

    final player = find.byKey(const ValueKey('film-inline-player'));
    final back = find.byKey(const ValueKey('film-inline-back'));
    final seek = find.byType(Slider);

    // 第 4 项：投屏钮整个删除。
    expect(find.byKey(const ValueKey('film-inline-cast')), findsNothing);
    expect(
      find.descendant(of: player, matching: find.byIcon(Icons.cast_rounded)),
      findsNothing,
    );

    // 第 1 项：返回键视觉与触控一起缩小到 36（默认 IconButton 48）。
    expect(tester.getSize(back), const Size(36, 36));

    // 第 8 项：顶栏贴画面最上边——返回键顶边与播放器顶边齐平。
    final origin = tester.getTopLeft(player);
    expect(tester.getTopLeft(back).dy - origin.dy, lessThan(4));

    // 第 3 项核查：旋转类图标只有一个（方向控制），无重叠多余。
    expect(
      find.descendant(
        of: player,
        matching: find.byIcon(Icons.screen_rotation_alt_rounded),
      ),
      findsOneWidget,
    );

    // 第 5 项：核心徽标缩小（字号 10.5）；第 9 项：徽标与倍速钮
    // 去掉胶囊深色底板（子树里不再有带装饰的 Container）。
    final badgeText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('film-inline-core')),
        matching: find.text('MPV'),
      ),
    );
    expect(badgeText.style?.fontSize, 10.5);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('film-inline-core')),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('film-inline-speed')),
        matching: find.byType(Container),
      ),
      findsNothing,
    );

    // 第 2 项：控件层整层一起隐、一起显。播放中 3 秒自动隐藏时
    // 顶栏与进度条（底栏）一起消失，不是只隐进度条。
    expect(back, findsOneWidget);
    expect(seek, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(back, findsNothing);
    expect(seek, findsNothing);

    // 点画面整层一起回来（单击与双击并存，单击要等约 300ms
    // 消歧窗口才落，泵 400ms 再断言）。
    await tester.tapAt(origin + const Offset(400, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(back, findsOneWidget);
    expect(seek, findsOneWidget);

    // 双击暂停 → 中央播放钮出现；点画面隐层时中央钮跟着一起隐、
    // 再点一起显——中央不自成一层。
    await tester.tapAt(origin + const Offset(400, 100));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(origin + const Offset(400, 100));
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final centerPlay = find.byKey(const ValueKey('film-inline-play'));
    expect(centerPlay, findsOneWidget);
    await tester.tapAt(origin + const Offset(400, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(centerPlay, findsNothing);
    expect(back, findsNothing);
    expect(seek, findsNothing);
    await tester.tapAt(origin + const Offset(400, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(centerPlay, findsOneWidget);
    expect(back, findsOneWidget);
    expect(seek, findsOneWidget);

    // 第 7 项：画中画钮在位、触控 36；点它走悬浮窗路——测试假
    // 播放器没有原生 playerId，必须给实话而不是假装已进小窗，
    // 更不能再用旧的「切后台会自动小窗播放」搪塞话。
    final pip = find.byKey(const ValueKey('film-inline-pip'));
    expect(pip, findsOneWidget);
    expect(tester.getSize(pip), const Size(36, 36));
    await tester.tap(pip);
    await tester.pump();
    expect(find.text('播放器还没就绪，画中画用不了'), findsOneWidget);
    expect(find.text('切后台会自动小窗播放'), findsNothing);
  });

  testWidgets('演员内嵌：画中画钮在位、触控 36、无原生播放器时给实话', (tester) async {
    final players = <ControlledNativePlayer>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              child: ActressInlinePlayer(
                url: 'https://example.invalid/a.mp4',
                title: 'TEST-001',
                playerFactory: () {
                  final player = ControlledNativePlayer();
                  players.add(player);
                  return player;
                },
                onFullscreen: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    players.single.emitFirstFrame();
    await tester.pump();

    final pip = find.byKey(const ValueKey('inline-player-pip'));
    expect(pip, findsOneWidget);
    expect(tester.getSize(pip), const Size(36, 36));
    await tester.tap(pip);
    await tester.pump();
    expect(find.text('播放器还没就绪，画中画用不了'), findsOneWidget);
  });
}
