/// One contract violation: a stable [code] from
/// `contracts/sms/v2/error_codes.json` and the JSON-pointer [path] it was
/// found at. The Node validator reports the same codes.
final class ContractError {
  const ContractError(this.code, this.path);

  final String code;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is ContractError && other.code == code && other.path == path;

  @override
  int get hashCode => Object.hash(code, path);

  @override
  String toString() => '$code at ${path.isEmpty ? '/' : path}';
}

/// The outcome of validating a document.
final class ValidationResult {
  const ValidationResult(this.errors);

  final List<ContractError> errors;

  bool get ok => errors.isEmpty;

  /// The distinct error codes, in first-seen order.
  List<String> get codes => <String>{for (final e in errors) e.code}.toList();

  @override
  String toString() => ok ? 'ok' : errors.join('; ');
}

/// Thrown by `fromJson` constructors when the JSON breaks the contract.
final class ContractException implements Exception {
  ContractException(List<ContractError> errors)
      : errors = List.unmodifiable(errors);

  final List<ContractError> errors;

  @override
  String toString() => 'ContractException(${errors.join('; ')})';
}
