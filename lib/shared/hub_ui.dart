import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'skeleton.dart';
import 'workspace_ui.dart';

/// Tile hues for hub rows, modelled on GitHub Mobile's "My Work" list. They
/// are the same in both modes: each tile carries a white (or, on yellow, a
/// near-black) glyph and always sits beside a text label, so the hue is a
/// recognition aid rather than the only signal.
abstract final class HubColors {
  static const green = Color(0xFF2DA44E);
  static const blue = Color(0xFF2F81F7);
  static const purple = Color(0xFF8250DF);
  static const grey = Color(0xFF8C919C);
  static const slate = Color(0xFF474A55);
  static const orange = Color(0xFFF0883E);
  static const yellow = Color(0xFFE9B10E);
  static const red = Color(0xFFE5534B);
  static const pink = Color(0xFFBF4B8A);
  static const teal = Color(0xFF1B998B);
}

/// A rounded-square colour tile holding one glyph.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color, this.size = 32});
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * .25)),
    child: Icon(icon, size: size * .58, color: readableInk(color)),
  );
}

/// A neutral tile for secondary rows (code, commits, "more").
class NeutralTile extends StatelessWidget {
  const NeutralTile(this.icon, {super.key, this.size = 32});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * .25),
      ),
      child: Icon(icon, size: size * .58, color: scheme.onSurface),
    );
  }
}

/// A full-bleed group on the raised surface: optional bold heading with a
/// trailing action, then its rows. Groups are separated by hairlines rather
/// than card edges, the way GitHub Mobile stacks Home sections.
class HubSection extends StatelessWidget {
  const HubSection({
    super.key,
    this.title,
    this.trailing,
    required this.children,
    this.divider = true,
    this.padding = const EdgeInsets.only(bottom: 8),
  });
  final String? title;
  final Widget? trailing;
  final List<Widget> children;
  final bool divider;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: divider
              ? Border(bottom: BorderSide(color: theme.dividerTheme.color ?? theme.colorScheme.outlineVariant))
              : const Border(),
        ),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 18, trailing == null ? 16 : 4, 6),
                  child: Row(children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(title!, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    ?trailing,
                  ]),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One hub row: leading tile, label, optional count or value, chevron. The
/// whole row is one button for screen readers.
class HubRow extends StatelessWidget {
  const HubRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.chevron = false,
    this.trailing,
    this.semanticLabel,
  });
  final Widget leading;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final bool chevron;
  final Widget? trailing;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = semanticLabel ??
        [title, if (subtitle != null && subtitle!.isNotEmpty) subtitle!, if (value != null && value!.isNotEmpty) value!]
            .join(' · ');
    return Semantics(
      container: true,
      button: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: HomeSectionSkeleton.rowPadding,
            child: Row(children: [
              leading,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.3)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              if (value != null && value!.isNotEmpty) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16, color: muted)),
                ),
              ],
              ?trailing,
              if (chevron) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 20, color: muted),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// The wide secondary button under hub empty states ("瀏覽專案").
class HubButton extends StatelessWidget {
  const HubButton({super.key, required this.label, required this.onPressed, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null ? null : Icon(icon, size: 18),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: scheme.primary,
          side: BorderSide(color: theme.dividerTheme.color ?? scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1),
        ),
        label: Text(label),
      ),
    );
  }
}

/// A square action button for the project header (fork, share, web).
class HeaderSquareButton extends StatelessWidget {
  const HeaderSquareButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.child,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Widget? child;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: scheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Theme.of(context).dividerTheme.color ?? scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: 56,
              height: 48,
              child: Center(
                child: child ??
                    Icon(icon, size: 22,
                      color: onPressed == null
                          ? scheme.onSurface.withValues(alpha: .38)
                          : selected ? const Color(0xFFE3B341) : scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round coloured shortcut with its label underneath.
class CircleShortcut extends StatelessWidget {
  const CircleShortcut({super.key, required this.icon, required this.color, required this.label, required this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final fill = Color.alphaBlend(color.withValues(alpha: dark ? .22 : .14), theme.colorScheme.surface);
    final ink = dark ? Color.lerp(color, Colors.white, .35)! : Color.lerp(color, Colors.black, .25)!;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                child: Icon(icon, size: 22, color: ink),
              ),
              const SizedBox(height: 6),
              Text(label, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The "all caught up" scene for an empty inbox: a night ridge of pines, a
/// moon and a check badge. Drawn in code, so it follows the theme.
class CaughtUpArt extends StatelessWidget {
  const CaughtUpArt({super.key, this.height = 150});
  final double height;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _CaughtUpPainter(
            dark: theme.brightness == Brightness.dark,
            accent: theme.colorScheme.primary,
            ground: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _CaughtUpPainter extends CustomPainter {
  const _CaughtUpPainter({required this.dark, required this.accent, required this.ground});
  final bool dark;
  final Color accent;
  final Color ground;

  @override
  void paint(Canvas canvas, Size size) {
    final w = math.min(size.width, 340.0);
    final left = (size.width - w) / 2;
    final h = size.height;
    final base = h * .82;
    final ridge = dark ? const Color(0xFF26272D) : const Color(0xFFE3E7EC);
    final pine = dark ? const Color(0xFF30313A) : const Color(0xFFD3D9E0);

    // Moon.
    canvas.drawCircle(Offset(left + w * .80, h * .20), h * .075,
      Paint()..color = (dark ? const Color(0xFFE9E3C8) : const Color(0xFFF2C14E)).withValues(alpha: .9));
    // Stars.
    final star = Paint()..color = ground.withValues(alpha: .55);
    for (final (x, y, r) in const [(.12, .16, 1.6), (.30, .08, 1.2), (.58, .14, 1.4), (.92, .40, 1.2), (.05, .45, 1.0)]) {
      canvas.drawCircle(Offset(left + w * x, h * y), r, star);
    }
    // Ridge.
    final hill = Path()
      ..moveTo(left, base)
      ..lineTo(left + w * .10, base - h * .22)
      ..lineTo(left + w * .26, base - h * .40)
      ..lineTo(left + w * .40, base - h * .18)
      ..lineTo(left + w * .52, base - h * .30)
      ..lineTo(left + w * .66, base - h * .08)
      ..lineTo(left + w * .72, base)
      ..close();
    canvas.drawPath(hill, Paint()..color = ridge);
    // Pines.
    void tree(double x, double height, double width) {
      final top = base - height;
      final path = Path()
        ..moveTo(x, top)
        ..lineTo(x + width / 2, base - height * .45)
        ..lineTo(x + width * .3, base - height * .45)
        ..lineTo(x + width * .62, base)
        ..lineTo(x - width * .62, base)
        ..lineTo(x - width * .3, base - height * .45)
        ..lineTo(x - width / 2, base - height * .45)
        ..close();
      canvas.drawPath(path, Paint()..color = pine);
    }
    tree(left + w * .18, h * .46, w * .10);
    tree(left + w * .30, h * .62, w * .13);
    tree(left + w * .43, h * .40, w * .09);
    // Ground line and shadow.
    canvas.drawLine(Offset(left, base), Offset(left + w, base),
      Paint()..color = ground.withValues(alpha: .35)..strokeWidth = 1);
    canvas.drawOval(Rect.fromCenter(center: Offset(left + w * .74, base + 4), width: w * .26, height: 9),
      Paint()..color = ground.withValues(alpha: .18));
    // Check badge.
    final center = Offset(left + w * .74, base - h * .26);
    final radius = h * .22;
    canvas.drawCircle(center, radius + 7, Paint()..color = accent.withValues(alpha: .16));
    canvas.drawCircle(center, radius, Paint()..color = accent);
    final check = Path()
      ..moveTo(center.dx - radius * .42, center.dy + radius * .02)
      ..lineTo(center.dx - radius * .10, center.dy + radius * .34)
      ..lineTo(center.dx + radius * .46, center.dy - radius * .30);
    canvas.drawPath(check, Paint()
      ..color = dark ? const Color(0xFF0B1A2C) : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * .2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
    // A leaf drifting down.
    final leaf = Path()
      ..moveTo(left + w * .56, base - h * .52)
      ..quadraticBezierTo(left + w * .60, base - h * .62, left + w * .64, base - h * .55)
      ..quadraticBezierTo(left + w * .60, base - h * .47, left + w * .56, base - h * .52)
      ..close();
    canvas.drawPath(leaf, Paint()..color = const Color(0xFFF0883E));
  }

  @override
  bool shouldRepaint(covariant _CaughtUpPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.accent != accent || oldDelegate.ground != ground;
}

/// The large page title GitHub Mobile uses on root destinations ("首頁").
class LargeTitle extends StatelessWidget {
  const LargeTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).appBarTheme.titleTextStyle?.copyWith(fontSize: 26, letterSpacing: -.6),
  );
}

/// A GitHub-style filter pill. [selected] fills it with the accent
/// container; [dropdown] adds a caret for pills that open a menu.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    this.selected = false,
    this.dropdown = false,
    this.icon,
    this.onTap,
  });
  final String label;
  final bool selected;
  final bool dropdown;
  final IconData? icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fill = selected ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final ink = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    final pill = Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: EdgeInsets.fromLTRB(icon == null ? 14 : 10, 6, dropdown ? 8 : 14, 6),
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 16, color: ink), const SizedBox(width: 6)],
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: ink, height: 1.2, fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
        ),
        if (dropdown) ...[const SizedBox(width: 2), Icon(Icons.keyboard_arrow_down, size: 18, color: ink)],
      ]),
    );
    // A 48 dp target around the 36 dp pill.
    final target = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Center(widthFactor: 1, child: pill),
    );
    if (onTap == null) return target;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(customBorder: const StadiumBorder(), onTap: onTap, child: target),
    );
  }
}
