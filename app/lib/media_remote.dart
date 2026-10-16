import 'package:flutter/material.dart';

/// Consumer video playback is a separate mode from presentation controls.
/// Commands are sent only to the already-authenticated desktop agent.
enum MediaService { youtube, netflix }

extension MediaServiceLabel on MediaService {
  String get label => switch (this) {
    MediaService.youtube => 'YouTube',
    MediaService.netflix => 'Netflix',
  };
}

/// Generates only two fixed, allowlisted browser search destinations.
/// The generated URL is typed into the foreground browser on the computer.
class MediaSearch {
  const MediaSearch._();

  static String url(MediaService service, String search) {
    final query = search.trim();
    if (query.isEmpty) {
      throw const FormatException('Enter a video title or search phrase.');
    }
    if (query.runes.length > 70 || query.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
      throw const FormatException('Keep your video search under 70 characters.');
    }
    final uri = switch (service) {
      MediaService.youtube => Uri.https(
          'www.youtube.com', '/results', {'search_query': query}),
      MediaService.netflix => Uri.https(
          'www.netflix.com', '/search', {'q': query}),
    };
    final destination = uri.toString();
    if (destination.length > 256) {
      throw const FormatException('Search too long for desktop typing.');
    }
    return destination;
  }
}

class MediaRemote extends StatefulWidget {
  const MediaRemote({
    super.key,
    required this.service,
    required this.enabled,
    required this.landscape,
    required this.onServiceChanged,
    required this.onKey,
    required this.onSearch,
    this.onOpenService,
  });

  final MediaService service;
  final bool enabled;
  final bool landscape;
  final ValueChanged<MediaService> onServiceChanged;
  final ValueChanged<String> onKey;
  final Future<void> Function(MediaService, String) onSearch;
  final Future<void> Function(MediaService)? onOpenService;

  @override
  State<MediaRemote> createState() => _MediaRemoteState();
}

class _MediaRemoteState extends State<MediaRemote> {
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _submitSearch() async {
    if (!widget.enabled || _searching) return;
    setState(() => _searching = true);
    try {
      await widget.onSearch(widget.service, _search.text);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Widget _button(String label, IconData icon, String key, {Key? buttonKey}) {
    return IconButton.filledTonal(
      key: buttonKey,
      tooltip: label,
      iconSize: 25,
      onPressed: widget.enabled ? () => widget.onKey(key) : null,
      icon: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: SegmentedButton<MediaService>(
          key: const ValueKey('media-provider-selector'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: MediaService.youtube,
                label: Text('YouTube', maxLines: 1)),
            ButtonSegment(value: MediaService.netflix,
                label: Text('Netflix', maxLines: 1)),
          ],
          selected: {widget.service},
          onSelectionChanged: (selection) =>
              widget.onServiceChanged(selection.first),
        )),
        if (widget.onOpenService != null) ...[
          const SizedBox(width: 4),
          IconButton.outlined(
            key: const ValueKey('media-open-provider'),
            tooltip: 'Open selected service on computer',
            onPressed: widget.enabled ? () =>
                widget.onOpenService!(widget.service) : null,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
      ]),
      const SizedBox(height: 10),
      TextField(
        key: const ValueKey('media-search-text'),
        controller: _search,
        enabled: widget.enabled && !_searching,
        autocorrect: false,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search ${widget.service.label} on your computer',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: IconButton(
            key: const ValueKey('media-search-submit'),
            tooltip: 'Search on computer',
            onPressed: widget.enabled && !_searching ? _submitSearch : null,
            icon: const Icon(Icons.arrow_forward),
          ),
        ),
        onSubmitted: (_) => _submitSearch(),
      ),
      const SizedBox(height: 15),
      Text('Playback', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 10, runSpacing: 8,
        children: [
          _button('Seek backward', Icons.replay_10, 'Left'),
          _button('Play / Pause', Icons.play_arrow, 'space',
              buttonKey: const ValueKey('media-play-pause')),
          _button('Seek forward', Icons.forward_10, 'Right'),
          _button('Full screen', Icons.fullscreen, 'f'),
        ],
      ),
      const SizedBox(height: 16),
      Text('Volume', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 10, runSpacing: 8,
        children: [
          _button('Lower volume', Icons.volume_down, 'XF86AudioLowerVolume',
              buttonKey: const ValueKey('media-volume-down')),
          _button('Mute', Icons.volume_off, 'XF86AudioMute'),
          _button('Raise volume', Icons.volume_up, 'XF86AudioRaiseVolume',
              buttonKey: const ValueKey('media-volume-up')),
        ],
      ),
    ]);
  }

}
