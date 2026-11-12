/// Position is the fraction of overflow hidden before the viewport on each axis.
/// These values remain usable across screen sizes and contain no file paths.
class BackgroundFrame {
  const BackgroundFrame({
    this.x = .5,
    this.y = .5,
    this.zoom = 1,
    this.turns = 0,
  });
  final double x, y, zoom;
  final int turns;

  factory BackgroundFrame.fromJson(Object? value) {
    final data = value is Map ? value : const {};
    double number(String key, double fallback, double min, double max) {
      final raw = data[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    return BackgroundFrame(
      x: number('x', .5, 0, 1),
      y: number('y', .5, 0, 1),
      zoom: number('zoom', 1, 1, 4),
      turns: number('turns', 0, 0, 3).toInt(),
    );
  }
  BackgroundFrame copyWith({double? x, double? y, double? zoom, int? turns}) =>
      BackgroundFrame.fromJson({
        'x': x ?? this.x,
        'y': y ?? this.y,
        'zoom': zoom ?? this.zoom,
        'turns': turns ?? this.turns,
      });
  Map<String, Object> toJson() => {
    'x': x,
    'y': y,
    'zoom': zoom,
    'turns': turns,
  };
  @override
  bool operator ==(Object other) =>
      other is BackgroundFrame &&
      x == other.x &&
      y == other.y &&
      zoom == other.zoom &&
      turns == other.turns;
  @override
  int get hashCode => Object.hash(x, y, zoom, turns);
}
