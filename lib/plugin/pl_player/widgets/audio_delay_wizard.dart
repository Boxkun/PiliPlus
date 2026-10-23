import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show Media, NativePlayer, Player;

/// 与音频延迟对话框保持一致的范围（这里不反向 import，避免循环依赖）
const double _kMinDelay = -2.0;
const double _kMaxDelay = 2.0;

const double _kLeadIn = 0.8; // 开始前的留白
const double _kBpm = 140;
const int _kRounds = 3;
const int _kBeatsPerRound = 12;
const int _kSampleRate = 44100;
const double _kToneSeconds = 0.13;

/// 点击与最近一个 C6 的最大允许偏差，超出视为误触
const double _kTapWindow = 0.32;

/// 0 = C4（低音），1 = C6（高音）
const List<int> _kPattern = [0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0];

const double _kC4 = 261.63;
const double _kC6 = 1046.50;

Future<double?> showAudioDelayWizard(
  BuildContext context, {
  required NativePlayer player,
}) {
  return showDialog<double>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AudioDelayWizard(mainPlayer: player),
  );
}

enum _Phase { intro, running, result }

class _AudioDelayWizard extends StatefulWidget {
  const _AudioDelayWizard({required this.mainPlayer});

  final NativePlayer mainPlayer;

  @override
  State<_AudioDelayWizard> createState() => _AudioDelayWizardState();
}

class _AudioDelayWizardState extends State<_AudioDelayWizard> {
  static const double _beat = 60 / _kBpm;

  late final List<double> _onsets;
  late final List<double> _freqs;
  late final List<int> _c6Indices;
  late final double _totalSeconds;
  late final Uint8List _wav;

  _Phase _phase = _Phase.intro;
  Player? _player;
  Stopwatch? _stopwatch;
  Timer? _ticker;
  final List<double> _offsets = <double>[];
  final Set<int> _usedOnsets = <int>{};
  bool _mainWasPlaying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _onsets = [
      for (var round = 0; round < _kRounds; round++)
        for (var i = 0; i < _kBeatsPerRound; i++)
          _kLeadIn + (round * _kBeatsPerRound + i) * _beat,
    ];
    _freqs = [
      for (var round = 0; round < _kRounds; round++)
        for (final value in _kPattern) value == 0 ? _kC4 : _kC6,
    ];
    _c6Indices = [
      for (var i = 0; i < _freqs.length; i++)
        if (_freqs[i] == _kC6) i,
    ];
    _totalSeconds = _onsets.last + _kToneSeconds + 0.5;
    _wav = _buildWav(_onsets, _freqs, _totalSeconds);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
    _stopwatch?.stop();
    _resumeMain();
    super.dispose();
  }

  void _resumeMain() {
    if (_mainWasPlaying) {
      _mainWasPlaying = false;
      unawaited(widget.mainPlayer.play());
    }
  }

  double? get _position {
    final player = _player;
    if (player != null) {
      final parsed = double.tryParse(player.getProperty('time-pos'));
      if (parsed != null && parsed >= 0) return parsed;
    }
    final watch = _stopwatch;
    return watch == null ? null : watch.elapsedMicroseconds / 1e6;
  }

  Future<void> _releasePlayer() async {
    final player = _player;
    _player = null;
    _stopwatch = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  Future<void> _start() async {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    await _releasePlayer();
    if (!mounted) return;

    setState(() {
      _phase = _Phase.running;
      _offsets.clear();
      _usedOnsets.clear();
      _error = null;
    });

    _mainWasPlaying = widget.mainPlayer.state.playing;
    try {
      await widget.mainPlayer.pause();
    } catch (_) {}

    try {
      final file = File('$tmpDirPath/audio_delay_calib.wav');
      await file.writeAsBytes(_wav, flush: true);
      final player = await Player.create();
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      player.stream.completed.listen((completed) {
        if (completed && mounted && _phase == _Phase.running) _finish();
      });
      _stopwatch = Stopwatch()..start();
      await player.open(Media(Uri.file(file.path).toString()), play: true);
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted && _phase == _Phase.running) setState(() {});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.intro;
        _error = '音频播放失败：$e';
      });
    }
  }

  void _finish() {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch?.stop();
    final player = _player;
    if (player != null) unawaited(player.pause());
    if (mounted) setState(() => _phase = _Phase.result);
  }

  void _onTap() {
    if (_phase != _Phase.running) return;
    final position = _position;
    if (position == null) return;

    int? best;
    var bestDistance = _kTapWindow;
    for (var i = 0; i < _c6Indices.length; i++) {
      if (_usedOnsets.contains(i)) continue;
      final onset = _onsets[_c6Indices[i]];
      final distance = (position - onset).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (best == null) return;

    _usedOnsets.add(best);
    _offsets.add(position - _onsets[_c6Indices[best]]);
    feedBack();
    setState(() {});
  }

  double get _mean => _offsets.isEmpty
      ? 0
      : _offsets.reduce((a, b) => a + b) / _offsets.length;

  double get _std {
    if (_offsets.length < 2) return 0;
    final mean = _mean;
    final variance =
        _offsets
            .map((e) => (e - mean) * (e - mean))
            .reduce((a, b) => a + b) /
        (_offsets.length - 1);
    return math.sqrt(variance);
  }

  /// 正偏差表示点得偏晚，按反方向补偿
  double get _suggested =>
      (-_mean).clamp(_kMinDelay, _kMaxDelay).toDouble();

  int get _currentRound {
    if (_phase != _Phase.running) return _kRounds;
    final position = _position ?? 0;
    final index = ((position - _kLeadIn) / (_beat * _kBeatsPerRound)).floor();
    return index.clamp(0, _kRounds - 1) + 1;
  }

  double get _progress {
    if (_phase != _Phase.running) return 0;
    return ((_position ?? 0) / _totalSeconds).clamp(0.0, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: theme.colorScheme.surface,
      clipBehavior: Clip.hardEdge,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.graphic_eq,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('音频延迟向导', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: switch (_phase) {
                  _Phase.intro => _buildIntro(theme),
                  _Phase.running => _buildRunning(theme),
                  _Phase.result => _buildResult(theme),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIntro(ThemeData theme) {
    final outline = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.hearing, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          '${_kRounds * _kBeatsPerRound} 拍节拍器',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          '140 BPM，4/4 拍。低音 C4 为普通拍，高音 C6 出现时请立刻点击屏幕。\n'
          '共 ${_c6Indices.length} 次 C6，结束后会显示每次偏差与平均值。',
          style: outline,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '建议佩戴耳机、保持安静；开始后当前视频会自动暂停。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
          textAlign: TextAlign.center,
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.play_arrow),
          label: const Text('开始'),
        ),
      ],
    );
  }

  Widget _buildRunning(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Column(
      children: [
        LinearProgressIndicator(value: _progress, minHeight: 4),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('第 $_currentRound / $_kRounds 轮', style: small),
            const Spacer(),
            Text('已记录 ${_offsets.length} / ${_c6Indices.length}', style: small),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _onTap(),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.touch_app,
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 10),
                    Text('听到 C6 就点这里', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      '点偏了会自动忽略，不用紧张',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_offsets.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _offsets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Center(
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_formatMs(_offsets[index])),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _finish,
          child: const Text('提前结束'),
        ),
      ],
    );
  }

  Widget _buildResult(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    final count = _offsets.length;
    return SingleChildScrollView(
      child: Column(
        children: [
          Text('测量完成', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('有效点击 $count / ${_c6Indices.length}', style: small),
          const SizedBox(height: 14),
          if (count > 0) ...[
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final offset in _offsets)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(_formatMs(offset)),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '平均偏差 ${_formatMs(_mean)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('标准差 ${_formatMs(_std, withSign: false)}', style: small),
            const SizedBox(height: 14),
            Text(
              '建议音频延迟 ${_formatSeconds(_suggested)}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text('按平均偏差反方向补偿，应用后仍可手动微调', style: small),
          ] else
            Text(
              '没有记录到有效点击，请再试一次',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(onPressed: _start, child: const Text('重测')),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              if (count >= 3) ...[
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_suggested),
                  child: const Text('应用'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _formatMs(double seconds, {bool withSign = true}) {
    final ms = (seconds * 1000).round();
    final sign = withSign && ms > 0 ? '+' : '';
    return '$sign${ms}ms';
  }

  static String _formatSeconds(double value) =>
      '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}s';
}

/// 生成 16bit 单声道 WAV：每个 onset 处叠加一个带淡入淡出包络的正弦音
Uint8List _buildWav(
  List<double> onsets,
  List<double> freqs,
  double totalSeconds,
) {
  final totalSamples = (totalSeconds * _kSampleRate).ceil();
  final mix = Float32List(totalSamples);
  final toneSamples = (_kToneSeconds * _kSampleRate).round();
  const attack = 0.004;
  const release = 0.03;
  const amplitude = 0.55;

  for (var i = 0; i < onsets.length && i < freqs.length; i++) {
    final start = (onsets[i] * _kSampleRate).round();
    final freq = freqs[i];
    for (var k = 0; k < toneSamples; k++) {
      final index = start + k;
      if (index >= totalSamples) break;
      final t = k / _kSampleRate;
      var envelope = 1.0;
      if (t < attack) envelope = t / attack;
      final remaining = _kToneSeconds - t;
      if (remaining < release) {
        envelope = math.min(envelope, remaining / release);
      }
      mix[index] +=
          amplitude * envelope * math.sin(2 * math.pi * freq * t);
    }
  }

  final data = ByteData(44 + totalSamples * 2);
  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + totalSamples * 2, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, _kSampleRate, Endian.little);
  data.setUint32(28, _kSampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, totalSamples * 2, Endian.little);
  for (var i = 0; i < totalSamples; i++) {
    final sample = (mix[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, sample, Endian.little);
  }
  return data.buffer.asUint8List();
}
