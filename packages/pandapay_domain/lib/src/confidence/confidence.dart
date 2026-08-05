/// product-plan §5.10 (R3): every financial figure carries an
/// estimated/confirmed state. There is no third option — UI must always
/// know which one it's showing.
enum Confidence {
  estimated,
  confirmed;

  bool get isConfirmed => this == Confidence.confirmed;
}
