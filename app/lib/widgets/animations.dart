import 'package:flutter/material.dart';

/// 弹性按压包装器 — 按下时缩小，松开后回弹
class BounceTap extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double scale;

  const BounceTap({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.scale = 0.94,
  });

  @override
  State<BounceTap> createState() => _BounceTapState();
}

class _BounceTapState extends State<BounceTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, child) {
          return Transform.scale(
            scale: 1 - (_controller.value * (1 - widget.scale)),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// 淡入滑入动画 — 用于列表项
class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final int index;
  final Duration delay;

  const FadeSlideIn({
    super.key,
    required this.child,
    required this.index,
    this.delay = const Duration(milliseconds: 30),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// 照片卡片淡入动画
class PhotoFadeIn extends StatelessWidget {
  final Widget child;

  const PhotoFadeIn({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: child,
        );
      },
      child: child,
    );
  }
}

/// 页面切换动画 — 淡入 + 轻微上滑。
///
/// 适用于前后底色反差明显的跳转（例如白底缩略图 → 黑色大图查看页），
/// 此时淡入清晰可见。若前后都是白底页面请改用 [PageSlideTransition]。
class PageFadeTransition extends PageRouteBuilder {
  final Widget child;

  PageFadeTransition({required this.child})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(0.0, 0.05);
            const end = Offset.zero;
            const curve = Curves.easeOutCubic;

            var tween = Tween(begin: begin, end: end).chain(
              CurveTween(curve: curve),
            );

            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: animation.drive(tween),
                child: child,
              ),
            );
          },
          transitionDuration: const Duration(milliseconds: 250),
        );
}

/// 页面下钻切换动画 — 新页面自右侧滑入，被覆盖的旧页面同步左移让出（视差）。
///
/// 为什么不复用 [PageFadeTransition]：本应用主界面各页背景都是纯白，
/// 白底页面之间做淡入淡出几乎察觉不到，观感等同于「没有过渡动画」。
/// 横向滑动即便前后同为白底也清晰可见，与 MIUI 相册逐级下钻的转场一致。
class PageSlideTransition extends PageRouteBuilder {
  final Widget child;

  PageSlideTransition({required this.child})
      : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const curve = Curves.easeOutCubic;
            // 本页面入场：自屏幕右侧整屏滑入。
            final enter =
                Tween(begin: const Offset(1.0, 0.0), end: Offset.zero)
                    .chain(CurveTween(curve: curve))
                    .animate(animation);
            // 本页面被新页面覆盖时：向左让出 25% 宽度，形成层次感。
            final exit =
                Tween(begin: Offset.zero, end: const Offset(-0.25, 0.0))
                    .chain(CurveTween(curve: curve))
                    .animate(secondaryAnimation);
            return SlideTransition(
              position: exit,
              child: SlideTransition(position: enter, child: child),
            );
          },
        );
}

/// 弹窗弹出缩放动画
class ScaleDialogTransition extends StatelessWidget {
  final Widget child;

  const ScaleDialogTransition({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        return Opacity(
          opacity: (value - 0.9) * 10,
          child: Transform.scale(
            scale: value,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// 底部 Sheet 上滑动画
class SlideUpSheet extends StatelessWidget {
  final Widget child;

  const SlideUpSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Offset>(
      tween: Tween(begin: const Offset(0, 1), end: Offset.zero),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, offset, child) {
        return FractionalTranslation(
          translation: offset,
          child: child,
        );
      },
      child: child,
    );
  }
}
