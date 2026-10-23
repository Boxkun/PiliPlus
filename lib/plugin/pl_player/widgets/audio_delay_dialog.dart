import 'package:PiliPlus/plugin/pl_player/widgets/audio_delay_wizard.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

/// 音频延迟可调范围（秒）
const double kAudioDelayMin = -2.0;
const double kAudioDelayMax = 2.0;

/// 离 0 多近时吸附到 0
const double _kSnapZone = 0.05;

String formatAudioDelay(double value) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}s';

/// 把 mpv 返回的字符串（或非法值）规整成 [-2, 2] 内的秒数
double parseAudioDelay(String? value) {
  final parsed = double.tryParse(value?.trim() ?? '');
  if (parsed == null || parsed.isNaN) return 0.0;
  return parsed.clamp(kAudioDelayMin, kAudioDelayMax).toDouble();
}

/// 当前播放器实际的音频延迟，用于菜单副标题
String audioDelayLabel(NativePlayer player) =>
    formatAudioDelay(parseAudioDelay(player.getProperty('audio-delay')));

Future<void> showAudioDelayDialog(
  BuildContext context, {
  required NativePlayer player,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AudioDelayDialog(player: player),
  );
}

class _AudioDelayDialog extends StatefulWidget {
  const _AudioDelayDialog({required this.player});

  final NativePlayer player;

  @override
  State<_AudioDelayDialog> createState() => _AudioDelayDialogState();
}

class _AudioDelayDialogState extends State<_AudioDelayDialog> {
  late final double _initialValue = parseAudioDelay(
    widget.player.getProperty('audio-delay'),
  );
  late double _value = _initialValue;
  late final TextEditingController _textController = TextEditingController(
    text: _initialValue.toStringAsFixed(2),
  );
  final FocusNode _focusNode = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _editing) _commitEditing();
    });
  }

  @override
  void dispose() {
    // 无论以何种方式关闭，都把当前值写回，下次创建播放器时作为默认值
    GStorage.setting.put(SettingBoxKey.audioDelay, _value);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _apply(double value) => widget.player.setProperty(
    'audio-delay',
    value.clamp(kAudioDelayMin, kAudioDelayMax).toStringAsFixed(3),
  );

  /// 限制范围、按 0.01 对齐，并在 0 附近吸附
  double _snap(double value) {
    final clamped = value.clamp(kAudioDelayMin, kAudioDelayMax).toDouble();
    if (clamped.abs() <= _kSnapZone) return 0;
    return double.parse(clamped.toStringAsFixed(2));
  }

  void _onSliderChanged(double raw) {
    final value = _snap(raw);
    if (value == _value) {
      EasyThrottle.throttle(
        'audioDelay',
        const Duration(milliseconds: 80),
        () => _apply(_value),
      );
      return;
    }
    if (value == 0) feedBack();
    setState(() {
      _value = value;
      if (!_editing) _textController.text = value.toStringAsFixed(2);
    });
    EasyThrottle.throttle(
      'audioDelay',
      const Duration(milliseconds: 80),
      () => _apply(value),
    );
  }

  void _startEditing() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    });
  }

  void _commitEditing() {
    final parsed = double.tryParse(_textController.text.trim());
    if (parsed == null) {
      _textController.text = _value.toStringAsFixed(2);
    } else {
      final value = _snap(parsed);
      _value = value;
      _textController.text = value.toStringAsFixed(2);
      _apply(value);
    }
    if (mounted) setState(() => _editing = false);
  }

  void _onCancel() {
    _value = _initialValue;
    _apply(_initialValue);
    Navigator.of(context).pop();
  }

  void _onConfirm() {
    if (_editing) {
      final parsed = double.tryParse(_textController.text.trim());
      if (parsed != null) _value = _snap(parsed);
      _editing = false;
    }
    _apply(_value);
    Navigator.of(context).pop();
  }

  Future<void> _openWizard() async {
    final result = await showAudioDelayWizard(context, player: widget.player);
    if (!mounted || result == null) return;
    final value = _snap(result);
    setState(() {
      _value = value;
      _editing = false;
      _textController.text = value.toStringAsFixed(2);
    });
    _apply(value);
  }

  Widget _buildValue(ThemeData theme) {
    if (_editing) {
      return SizedBox(
        width: 160,
        child: TextField(
          controller: _textController,
          focusNode: _focusNode,
          autofocus: true,
          textAlign: TextAlign.center,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          style: theme.textTheme.headlineSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: '0.00',
          ),
          onSubmitted: (_) => _commitEditing(),
        ),
      );
    }
    return InkWell(
      onTap: _startEditing,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatAudioDelay(_value),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.edit_outlined,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentWidth = (MediaQuery.sizeOf(context).width * 0.72)
        .clamp(320.0, 760.0)
        .toDouble();
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: const Text('音频延迟'),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        width: contentWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 横屏下尽量拉长；不设置 divisions 即无极调节
            Row(
              children: [
                Text('-2s', style: labelStyle),
                Expanded(
                  child: Slider(
                    value: _value,
                    min: kAudioDelayMin,
                    max: kAudioDelayMax,
                    onChanged: _onSliderChanged,
                    onChangeEnd: (value) => _apply(_snap(value)),
                  ),
                ),
                Text('+2s', style: labelStyle),
              ],
            ),
            Row(
              children: [
                Text('提前', style: labelStyle),
                Expanded(child: Center(child: _buildValue(theme))),
                Text('延后', style: labelStyle),
              ],
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _openWizard,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('延迟向导'),
                ),
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _onCancel, child: const Text('取消')),
        TextButton(onPressed: _onConfirm, child: const Text('确定')),
      ],
    );
  }
}
