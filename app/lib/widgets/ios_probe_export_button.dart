import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IosProbeExportButton extends StatefulWidget {
  final String Function() report;
  const IosProbeExportButton({super.key, required this.report});
  @override
  State<IosProbeExportButton> createState() => _IosProbeExportButtonState();
}

class _IosProbeExportButtonState extends State<IosProbeExportButton> {
  static const _channel = MethodChannel('pandapay/ios_history_device_probe');
  bool _busy = false;
  String? _message;
  Future<void> _export() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await _channel.invokeMethod<String>(
        'shareDiagnostics',
        widget.report(),
      );
      if (mounted && result == 'shared') {
        setState(() => _message = 'Diagnostic file shared.');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message =
              error is PlatformException && error.code == 'export_too_large'
              ? 'This session is too large to export. Use a smaller test range.'
              : 'Couldn’t export diagnostics. Tap to try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        onPressed: _busy ? null : _export,
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.ios_share),
        label: Text(_busy ? 'Preparing export…' : 'Export diagnostics'),
      ),
      const Text(
        'One JSON file with SMS text, sender values and processing results. Security-code content is excluded.',
      ),
      if (_message != null) Text(_message!),
      const SizedBox(height: 12),
    ],
  );
}
