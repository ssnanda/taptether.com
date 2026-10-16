import 'package:flutter/material.dart';
import 'speaker_notes_panel.dart';

/// Keystroke-only presentation remote. No slide inspection, screenshots,
/// speaker notes, internet access, or integration with presentation files.
enum PresentationApp { powerPoint, googleSlides, keynote }

extension PresentationAppLabel on PresentationApp {
  String get label => switch (this) {
    PresentationApp.powerPoint => 'PowerPoint',
    PresentationApp.googleSlides => 'Google Slides',
    PresentationApp.keynote => 'Keynote',
  };
}

class PresentationShortcuts {
  const PresentationShortcuts._();

  static const next = 'Right';
  static const previous = 'Left';
  static const stop = 'Escape';
  static const blankToggle = 'b';

  /// Shortcuts start a presentation in the foreground editor.
  /// Null means the selected app isn't supported on this platform.
  static String? start(PresentationApp app, {required bool isMac}) {
    switch (app) {
      case PresentationApp.keynote:
        return isMac ? 'alt+cmd+p' : null;
      case PresentationApp.powerPoint:
        // Windows PowerPoint desktop uses F5; Mac uses the native
        // full-screen slideshow shortcut.
        return isMac ? 'cmd+shift+return' : 'f5';
      case PresentationApp.googleSlides:
        // Google Slides in a foreground browser, from the beginning.
        return isMac ? 'cmd+shift+return' : 'ctrl+f5';
    }
  }
}

/// Presentation buttons also track the speaker notes' approximate slide.
/// Slides changed on the computer can be aligned using the notes +/- buttons.
class PresentationControls extends StatefulWidget {
  const PresentationControls({
    super.key,
    required this.app,
    required this.isMac,
    required this.enabled,
    required this.landscape,
    required this.onAppChanged,
    required this.onKey,
  });

  final PresentationApp app;
  final bool isMac;
  final bool enabled;
  final bool landscape;
  final ValueChanged<PresentationApp> onAppChanged;
  final ValueChanged<String> onKey;

  @override
  State<PresentationControls> createState() => _PresentationControlsState();
}

class _PresentationControlsState extends State<PresentationControls> {
  int _slide = 1;

  PresentationApp get app => widget.app;
  bool get isMac => widget.isMac;
  bool get enabled => widget.enabled;
  bool get landscape => widget.landscape;
  ValueChanged<PresentationApp> get onAppChanged => widget.onAppChanged;
  ValueChanged<String> get onKey => widget.onKey;

  void _sendPresentationKey(String key) {
    if (key == PresentationShortcuts.next) {
      setState(() => _slide++);
    } else if (key == PresentationShortcuts.previous) {
      setState(() => _slide = (_slide - 1).clamp(1, 9999).toInt());
    } else if (key == PresentationShortcuts.start(app, isMac: isMac)) {
      setState(() => _slide = 1);
    }
    onKey(key);
  }

  Widget _sendButton({
    required String label,
    required IconData icon,
    required String? key,
    bool prominent = false,
    Key? widgetKey,
  }) {
    final action = enabled && key != null
        ? () => _sendPresentationKey(key) : null;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: landscape ? 20 : 23),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 2,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: landscape ? 11 : 13),
        ),
      ],
    );
    return SizedBox(
      height: landscape ? 55 : 68,
      child: prominent
          ? FilledButton(key: widgetKey, onPressed: action, child: content)
          : OutlinedButton(key: widgetKey, onPressed: action, child: content),
    );
  }

  @override
  Widget build(BuildContext context) {
    final startKey = PresentationShortcuts.start(app, isMac: isMac);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<PresentationApp>(
          key: const ValueKey('presentation-app'),
          initialValue: app,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.slideshow_outlined),
            labelText: 'Presenting with',
          ),
          items: [
            for (final choice in PresentationApp.values)
              if (isMac || choice != PresentationApp.keynote)
                DropdownMenuItem(value: choice, child: Text(choice.label)),
          ],
          onChanged: (choice) {
            if (choice != null) onAppChanged(choice);
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-previous'),
            label: 'Previous',
            icon: Icons.arrow_back,
            key: PresentationShortcuts.previous,
            prominent: true,
          )),
          const SizedBox(width: 12),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-next'),
            label: 'Next',
            icon: Icons.arrow_forward,
            key: PresentationShortcuts.next,
            prominent: true,
          )),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-start'),
            label: 'Start',
            icon: Icons.play_arrow,
            key: startKey,
          )),
          const SizedBox(width: 8),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-blank'),
            label: 'Blank / Restore',
            icon: Icons.tv_off_outlined,
            key: PresentationShortcuts.blankToggle,
          )),
          const SizedBox(width: 8),
          Expanded(child: _sendButton(
            widgetKey: const ValueKey('slide-stop'),
            label: 'End (Esc)',
            icon: Icons.stop_circle_outlined,
            key: PresentationShortcuts.stop,
          )),
        ]),
        const SizedBox(height: 10),
        SpeakerNotesPanel(
          slide: _slide,
          onSlideChanged: (value) => setState(() => _slide = value),
          landscape: landscape,
        ),
      ],
    );
  }
}
