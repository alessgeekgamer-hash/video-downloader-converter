import 'package:flutter/material.dart';

/// Botón principal con degradado llamativo (violeta → rosa).
/// `semanticsLabel` lo expone con nombre propio para lectores de pantalla
/// y UI Automation (botón accesible e invocable).
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.semanticsLabel,
    this.expanded = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final String? semanticsLabel;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final button = Semantics(
      button: semanticsLabel != null,
      label: semanticsLabel,
      excludeSemantics: semanticsLabel != null,
      // La acción va en ESTE nodo (el excluido no hereda onTap del InkWell):
      // así los lectores de pantalla y UI Automation pueden activarlo.
      onTap: enabled && semanticsLabel != null ? onPressed : null,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: enabled
                ? LinearGradient(
                    colors: [scheme.primary, scheme.secondary],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            color: enabled ? null : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
    if (!expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

/// Título con texto en degradado (violeta → rosa).
class GradientTitle extends StatelessWidget {
  const GradientTitle(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = style ?? Theme.of(context).textTheme.titleLarge;
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: [scheme.primary, scheme.secondary],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(bounds),
      blendMode: BlendMode.srcIn,
      child: Text(
        text,
        style: base?.copyWith(fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}

/// Cuadro con degradado para el ícono del encabezado.
class GradientIconBadge extends StatelessWidget {
  const GradientIconBadge(this.icon, {super.key, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: [
          BoxShadow(
            color: scheme.secondary.withValues(alpha: .35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.55),
    );
  }
}
