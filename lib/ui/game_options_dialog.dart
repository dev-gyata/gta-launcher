import 'package:flutter/material.dart';

import '../services/game_options.dart';

/// Edits the game options (passed to the game page as URL options).
/// Pops with the new options, or null when cancelled.
class GameOptionsDialog extends StatefulWidget {
  const GameOptionsDialog({super.key, required this.initial});

  final GameOptions initial;

  @override
  State<GameOptionsDialog> createState() => _GameOptionsDialogState();
}

class _GameOptionsDialogState extends State<GameOptionsDialog> {
  late GameOptions _o = widget.initial;

  void _set(GameOptions o) => setState(() => _o = o);

  Widget _choice<T>(String label, T value, Map<T, String> options, ValueChanged<T> onChanged, {String? help}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          helperMaxLines: 3,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    int divisions,
    String Function(double) text,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ${text(value)}', style: Theme.of(context).textTheme.bodyMedium),
          Slider(value: value, min: min, max: max, divisions: divisions, label: text(value), onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged, {String? help, bool enabled = true}) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: help == null ? null : Text(help),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final storyStart = o.startMode == StartMode.story || o.startMode == StartMode.ask;
    return AlertDialog(
      title: const Text('Game options'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading('Start'),
            _choice('Start mode', o.startMode, const {
              StartMode.ask: 'Ask on the start screen',
              StartMode.story: 'Story Mode',
              StartMode.sandbox: 'Sandbox Mode (GTA V map)',
              StartMode.sandboxTestMap: 'Sandbox Mode (GTA VI map)',
            }, (v) => _set(o.copyWith(startMode: v))),
            _switch(
              'New game',
              o.newGame && storyStart,
              (v) => _set(o.copyWith(newGame: v)),
              help: 'Story Mode starts a new game instead of loading the last save',
              enabled: storyStart,
            ),
            _heading('Graphics'),
            _choice(
              'Quality profile',
              o.graphics,
              const {
                GraphicsProfile.auto: 'Automatic',
                GraphicsProfile.low: 'Low memory',
                GraphicsProfile.full: 'Full',
              },
              (v) => _set(o.copyWith(graphics: v)),
              help: 'Low memory: smaller textures, no shadows, fewer threads (automatic on devices with 4 GB or less)',
            ),
            _switch(
              'Shadows in low memory',
              o.lowMemoryShadows && o.graphics != GraphicsProfile.full,
              (v) => _set(o.copyWith(lowMemoryShadows: v)),
              help: 'Keep shadows at the lowest level',
              enabled: o.graphics != GraphicsProfile.full,
            ),
            _slider(
              'Render scale',
              o.renderScale,
              0.5,
              1.0,
              10,
              (v) => '${(v * 100).round()} %',
              (v) => _set(o.copyWith(renderScale: v)),
            ),
            _choice('Frame rate cap', o.frameCap, const {
              FrameCap.fps60: '60 FPS',
              FrameCap.fps30: '30 FPS',
              FrameCap.uncapped: 'Uncapped',
            }, (v) => _set(o.copyWith(frameCap: v))),
            _switch(
              'Show FPS counter',
              o.showFps,
              (v) => _set(o.copyWith(showFps: v)),
              help: 'The = key also toggles it',
            ),
            _heading('Controls'),
            _choice(
              'Controller',
              o.controller,
              const {
                ControllerMode.native: 'Gamepad',
                ControllerMode.keyboard: 'Keyboard and mouse mapping',
                ControllerMode.off: 'Off',
              },
              (v) => _set(o.copyWith(controller: v)),
              help: 'Gamepad: analog sticks, controller prompts and vibration',
            ),
            _choice('Touch controls', o.touch, const {
              TouchControls.auto: 'Phones and tablets',
              TouchControls.on: 'Always on',
              TouchControls.off: 'Off',
            }, (v) => _set(o.copyWith(touch: v))),
            _slider(
              'Camera sensitivity',
              o.lookSensitivity,
              0.25,
              3.0,
              11,
              (v) => '${v.toStringAsFixed(2)}×',
              (v) => _set(o.copyWith(lookSensitivity: v)),
            ),
            _heading('Advanced'),
            _switch(
              'Skip the device check',
              o.skipDeviceCheck,
              (v) => _set(o.copyWith(skipDeviceCheck: v)),
              help: 'Start even if the device seems to lack something the game needs',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => _set(GameOptions.defaults), child: const Text('Reset')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_o), child: const Text('Save')),
      ],
    );
  }
}
