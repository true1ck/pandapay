/// The code locations in a stack trace from an obfuscated release build
/// (`--obfuscate --split-debug-info`). Such a build prints no file names or
/// line numbers, only a header and one address line per frame:
///
/// ```text
/// *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
/// pid: 4242, tid: 4243, name 1.ui
/// os: android arch: arm64 comp: yes sim: no
/// build_id: '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
/// isolate_dso_base: 7b3c400000, vm_dso_base: 7b3c400000
/// isolate_instructions: 7b3c410000, vm_instructions: 7b3c404000
///     #00 abs 0000007b3c5a1234 virt 00000000001a1234 _kDartIsolateSnapshotInstructions+0x191234
/// ```
///
/// Only what `flutter symbolize` needs with the build's saved `.symbols` file
/// is kept: the build id, the os/arch line, and per frame the binary-relative
/// `virt` address and the `_kDart...SnapshotInstructions+0x...` offset. The
/// process and thread ids, the thread name, absolute addresses, load bases
/// and library paths are dropped. Every kept value is hex digits or a fixed
/// word, so no free text from the trace can pass through.
///
/// Pure Dart (no Flutter imports) so it can be checked against a real
/// `dart compile exe` trace and `flutter symbolize`.
class ObfuscatedTrace {
  const ObfuscatedTrace({
    required this.frames,
    this.buildId,
    this.os,
    this.arch,
    this.compressedPointers,
    this.simulator,
  });

  /// Newest frame first, as printed.
  final List<ObfuscatedFrame> frames;
  final String? buildId;
  final String? os;
  final String? arch;
  final bool? compressedPointers;
  final bool? simulator;

  static const maxFrames = 50;
  static const headerStart =
      '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***';
  static const isolateSymbol = '_kDartIsolateSnapshotInstructions';
  static const vmSymbol = '_kDartVmSnapshotInstructions';

  static final _osArch = RegExp(
    r'^os: ([a-z0-9_]{1,16}) arch: ([a-z0-9_]{1,16}) '
    r'comp: (yes|no) sim: (yes|no)$',
  );
  static final _buildId = RegExp(r"^build_id: '([0-9a-f]{8,128})'$");
  static final _frame = RegExp(
    r'^#\d{1,5} abs [0-9a-f]{1,16}(?: virt ([0-9a-f]{1,16}))?(?: (.*))?$',
  );
  static final _symbolOffset = RegExp(
    '^($isolateSymbol|$vmSymbol)\\+0x([0-9a-f]{1,16})\$',
  );

  /// Reads the first non-symbolic trace in [text]. Returns null when there is
  /// no header, or the header is followed by neither a build id nor a frame.
  static ObfuscatedTrace? parse(String text) {
    var inTrace = false;
    String? buildId, os, arch;
    bool? compressed, simulator;
    final frames = <ObfuscatedFrame>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line == headerStart) {
        if (inTrace) break; // Only the first trace.
        inTrace = true;
        continue;
      }
      if (!inTrace) continue;
      final osArch = _osArch.firstMatch(line);
      if (osArch != null) {
        os = osArch.group(1);
        arch = osArch.group(2);
        compressed = osArch.group(3) == 'yes';
        simulator = osArch.group(4) == 'yes';
        continue;
      }
      final id = _buildId.firstMatch(line);
      if (id != null) {
        buildId = id.group(1);
        continue;
      }
      final frame = _frame.firstMatch(line);
      if (frame == null) continue; // pid, load bases, async gaps, other text.
      final virt = frame.group(1);
      final symbol = _symbolOffset.firstMatch(frame.group(2) ?? '');
      if (virt == null && symbol == null) continue;
      frames.add(
        ObfuscatedFrame(
          virtualAddress: virt == null ? null : int.parse(virt, radix: 16),
          symbol: symbol?.group(1),
          offset: symbol == null
              ? null
              : int.parse(symbol.group(2)!, radix: 16),
        ),
      );
      if (frames.length >= maxFrames) break;
    }
    if (!inTrace || (buildId == null && frames.isEmpty)) return null;
    return ObfuscatedTrace(
      frames: frames,
      buildId: buildId,
      os: os,
      arch: arch,
      compressedPointers: compressed,
      simulator: simulator,
    );
  }

  /// The trace as `flutter symbolize -i` reads it. Absolute addresses are
  /// written as zeros: symbolize uses the symbol offset, or the `virt`
  /// address when there is no symbol.
  String toSymbolizeInput() {
    final out = StringBuffer()..writeln(headerStart);
    if (os != null && arch != null) {
      out.writeln(
        'os: $os arch: $arch '
        'comp: ${compressedPointers == true ? 'yes' : 'no'} '
        'sim: ${simulator == true ? 'yes' : 'no'}',
      );
    }
    if (buildId != null) out.writeln("build_id: '$buildId'");
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      out.write('    #${i.toString().padLeft(2, '0')} abs ${_hex16(0)}');
      if (frame.virtualAddress != null) {
        out.write(' virt ${_hex16(frame.virtualAddress!)}');
      }
      out.writeln(' ${frame.location ?? '<unknown>'}');
    }
    return out.toString();
  }

  static String _hex16(int value) => value.toRadixString(16).padLeft(16, '0');
}

/// One frame of an obfuscated trace: offsets only.
class ObfuscatedFrame {
  const ObfuscatedFrame({this.virtualAddress, this.symbol, this.offset});

  /// The program counter relative to the start of the binary.
  final int? virtualAddress;

  /// `_kDartIsolateSnapshotInstructions` or `_kDartVmSnapshotInstructions`.
  final String? symbol;

  /// The program counter relative to [symbol].
  final int? offset;

  /// For example `_kDartIsolateSnapshotInstructions+0x191234`.
  String? get location =>
      symbol == null ? null : '$symbol+0x${offset!.toRadixString(16)}';

  /// For example `0x1a1234`.
  String? get instructionAddress =>
      virtualAddress == null ? null : '0x${virtualAddress!.toRadixString(16)}';
}
