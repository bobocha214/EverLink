import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 验证码式 PIN 输入：一行等宽矩形框，自动跳格、可粘贴、可退格。
///
/// 默认仅允许数字；[controller] 可选，由父组件持有以便程序化设值（如"随机生成"）。
/// [enabled] 为 false 时仅展示 [controller] 中的值（用于"查看密码"场景）。
class PinInputWidget extends StatefulWidget {
  final int length;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final double boxSize;
  final bool autoFocus;

  const PinInputWidget({
    super.key,
    this.length = 6,
    this.controller,
    this.onChanged,
    this.enabled = true,
    this.boxSize = 44,
    this.autoFocus = true,
  });

  @override
  State<PinInputWidget> createState() => _PinInputWidgetState();
}

class _PinInputWidgetState extends State<PinInputWidget> {
  late final TextEditingController _internal;
  late final FocusNode _focus;

  TextEditingController get _ctl => widget.controller ?? _internal;

  @override
  void initState() {
    super.initState();
    _internal = TextEditingController();
    _focus = FocusNode();
    _ctl.addListener(_onControllerChanged);
    if (widget.autoFocus && widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctl.removeListener(_onControllerChanged);
    // 仅释放内部控制器；外部传入的由父组件负责销毁。
    _internal.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onInput(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    final clamped = digits.length > widget.length
        ? digits.substring(0, widget.length)
        : digits;
    if (clamped != _ctl.text) {
      _ctl.value = TextEditingValue(
        text: clamped,
        selection: TextSelection.collapsed(offset: clamped.length),
      );
    }
    widget.onChanged?.call(clamped);
  }

  /// 单格之间的水平间距（左右各一份 margin）。
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = _ctl.text;
    final cursorIndex = text.length;
    final n = widget.length;
    final fontSize = (widget.boxSize * 0.45).clamp(14.0, 22.0);

    return GestureDetector(
      onTap: widget.enabled ? () => _focus.requestFocus() : null,
      child: SizedBox(
        height: widget.boxSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.enabled)
              Opacity(
                opacity: 0,
                child: SizedBox(
                  width: 1,
                  child: TextField(
                    controller: _ctl,
                    focusNode: _focus,
                    autofocus: widget.autoFocus,
                    enabled: widget.enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: widget.length,
                    onChanged: _onInput,
                    decoration: const InputDecoration(
                      counterText: '',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    style: const TextStyle(color: Colors.transparent),
                  ),
                ),
              ),
            // 自适应宽度：整行最多占 n*(boxSize+2*gap)，空间不足时由 Expanded
            // 自动均分收缩，格子用 AspectRatio 保持正方形，窄屏不会横向溢出。
            // 注意：这里刻意不用 LayoutBuilder——它在 layout 阶段重建子树，
            // 而子树中的 TextField 会注册/注销 Inherited 依赖，容易触发
            // "check that it really is our descendant" 断言。
            Center(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: n * (widget.boxSize + _gap * 2)),
                child: Row(
                  children: List.generate(n, (i) {
                    final filled = i < text.length;
                    final isCursor = widget.enabled && i == cursorIndex;
                    final borderColor = filled || isCursor
                        ? scheme.primary
                        : Colors.grey.withValues(alpha: 0.4);
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: _gap),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: borderColor, width: 1.6),
                              borderRadius: BorderRadius.circular(10),
                              color: filled
                                  ? scheme.primary.withValues(alpha: 0.10)
                                  : (isCursor
                                      ? scheme.primary.withValues(alpha: 0.06)
                                      : Colors.transparent),
                            ),
                            child: Center(
                              child: Text(
                                filled ? text[i] : '',
                                style: TextStyle(
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.bold,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
