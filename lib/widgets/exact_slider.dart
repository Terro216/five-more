import 'package:flutter/material.dart';

/// An invalid edit remains visible and blocks the owning form; it is never
/// silently rounded or clamped into a different saved value.
class ExactSlider extends StatefulWidget {
  const ExactSlider({
    super.key,
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.sliderMax,
    this.enabled = true,
    this.onValidityChanged,
  });
  final String label, unit;
  final int value, min, max;
  final int? sliderMax;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<bool>? onValidityChanged;
  @override
  State<ExactSlider> createState() => _ExactSliderState();
}

class _ExactSliderState extends State<ExactSlider> {
  late final _text = TextEditingController(text: '${widget.value}');
  bool _valid = true;
  @override
  void didUpdateWidget(ExactSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && _text.text != '${widget.value}') {
      _text.text = '${widget.value}';
      _valid = true;
    }
  }

  void _validate(String raw) {
    final value = RegExp(r'^\d+$').hasMatch(raw) ? int.tryParse(raw) : null;
    final valid = value != null && value >= widget.min && value <= widget.max;
    setState(() => _valid = valid);
    widget.onValidityChanged?.call(valid);
    if (valid) widget.onChanged(value);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sliderMax = widget.sliderMax ?? widget.max;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            enabled: widget.enabled,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: widget.label,
              suffixText: widget.unit,
              errorText: _valid
                  ? null
                  : 'Целое число от ${widget.min} до ${widget.max}',
            ),
            style: const TextStyle(fontSize: 24),
            onChanged: _validate,
          ),
          Slider(
            value: widget.value.clamp(widget.min, sliderMax).toDouble(),
            min: widget.min.toDouble(),
            max: sliderMax.toDouble(),
            divisions: sliderMax - widget.min,
            label: '${widget.value} ${widget.unit}',
            onChanged: widget.enabled
                ? (v) {
                    final value = v.round();
                    _text.text = '$value';
                    setState(() => _valid = true);
                    widget.onValidityChanged?.call(true);
                    widget.onChanged(value);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
