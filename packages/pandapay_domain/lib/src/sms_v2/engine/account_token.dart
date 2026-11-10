// How an account number is printed, before any rule or the evidence reader
// looks at the message.

/// A branch (or branch and scheme) code some banks print in front of the masked
/// account number: `A/c No.40000/XXXXX913`, `A/c 021/XXXX2468`,
/// `A/c No.00123/CA/XXXX4410`. Group 1 is the account word, group 2 the prefix.
/// It only counts as a prefix when a masked number follows, so a date or a
/// plain `12/34` is never touched.
final RegExp _branchPrefix = RegExp(
  r'(\b(?:a/?c|acct?|account)\b\.?(?:\s*(?:no|number|num)\b\.?)?\s*[:\-]?\s*)'
  r'(\d{1,8}\s*/\s*(?:[a-z]{1,4}\s*/\s*)?)'
  r'(?=[x*•●]{2,}[\s\-]?\d{2,})',
  caseSensitive: false,
);

/// Returns [body] with every branch prefix in front of a masked account number
/// replaced by spaces of the same length.
///
/// Every account pattern, in every rule and in the evidence reader, expects the
/// masked digits right after the account word. With a branch code in the way
/// they either took the branch code for the account (`40000` instead of `913`)
/// or did not match at all. Blanking it in one place fixes all of them, for
/// every bank that prints accounts this way. The length is kept, so offsets into
/// the text (evidence spans) do not move.
String blankBranchPrefixes(String body) {
  if (!body.contains('/')) return body;
  return body.replaceAllMapped(
    _branchPrefix,
    (m) => '${m[1]}${' ' * m[2]!.length}',
  );
}
