import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:http/http.dart' as http;

import '../../data/api_exception.dart';

/// Which part of email sign-in failed. The same server or network error
/// needs different advice depending on whether the code was already used.
enum AuthStage {
  /// Asking the server to email a code.
  sendCode,

  /// Checking the code the user typed. The server uses the code up the
  /// moment it accepts it, so a lost reply here can burn the code.
  verifyCode,

  /// The code was accepted; the app is saving the session and profile.
  finishSignIn,
}

enum AuthNoticeTone { error, warning, info }

enum AuthFailureKind {
  invalidInput,
  network,
  timeout,
  wrongCode,
  expiredCode,
  codeLocked,
  codeAlreadySent,
  tooManyRequests,
  tooManyAttempts,
  accountNotFound,
  accountExists,
  accountMismatch,
  blocked,
  emailNotSent,
  serviceUnavailable,
  sessionRejected,
  unexpected,
}

/// What the sign-in screens show when something goes wrong (or needs the
/// user's attention): a short title, one or two sentences on what happened
/// and what to do next, and an optional support reference.
class AuthNotice {
  final String? title;
  final String message;
  final AuthNoticeTone tone;
  final AuthFailureKind kind;

  /// Shown in small print so support can match the failure to server logs.
  final String? reference;

  const AuthNotice({
    this.title,
    required this.message,
    required this.kind,
    this.tone = AuthNoticeTone.error,
    this.reference,
  });

  /// Local checks before any request, such as an empty field.
  const AuthNotice.input(this.message)
    : title = null,
      tone = AuthNoticeTone.warning,
      kind = AuthFailureKind.invalidInput,
      reference = null;

  const AuthNotice.codeExpired()
    : title = 'Code expired',
      message =
          'Codes only work for 1 minute. Request a new code to continue.',
      tone = AuthNoticeTone.warning,
      kind = AuthFailureKind.expiredCode,
      reference = null;

  const AuthNotice.codeLocked()
    : title = 'Too many incorrect tries',
      message =
          'This code is locked for your security. Request a new code when '
          'the timer runs out.',
      tone = AuthNoticeTone.error,
      kind = AuthFailureKind.codeLocked,
      reference = null;

  @override
  String toString() => [?title, message, ?reference].join(' · ');
}

/// "1:05" style countdown text.
String formatCountdown(Duration remaining) {
  final total = remaining.isNegative ? 0 : remaining.inSeconds;
  final minutes = total ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// True when the server rejected the code itself ("Invalid or expired
/// code"). The server deliberately does not say which, so the screen uses
/// its own timer and attempt count to explain it.
bool isRejectedCode(Object error) =>
    error is ApiException &&
    error.statusCode == 400 &&
    error.userMessage.toLowerCase().contains('invalid or expired code');

/// True when the server refused a new code because the last one is still
/// valid.
bool isCodeStillActive(Object error) {
  if (error is! ApiException || error.statusCode != 429) return false;
  final message = error.userMessage.toLowerCase();
  return message.contains('otp') && message.contains('active');
}

/// Turns any sign-in failure into copy that says what happened, whether it
/// was the user's input, their connection, or our side, and what to do next.
///
/// [codeTimeLeft] is the screen's countdown (null when unknown) and
/// [attemptsLeft] the wrong tries left on this code (null when unknown).
AuthNotice describeAuthFailure(
  Object error, {
  required AuthStage stage,
  required String email,
  Duration? codeTimeLeft,
  int? attemptsLeft,
}) {
  final codeStillValid =
      stage == AuthStage.verifyCode &&
      codeTimeLeft != null &&
      codeTimeLeft > Duration.zero;
  final validFor = codeStillValid
      ? ' Your code is still valid for ${formatCountdown(codeTimeLeft)}.'
      : '';

  if (error is TimeoutException) {
    return AuthNotice(
      title: 'This is taking too long',
      message: switch (stage) {
        AuthStage.sendCode =>
          'PandaPay didn’t respond in time. If a code arrives in your email, '
              'you can still use it. Otherwise, try again.',
        AuthStage.verifyCode =>
          'We couldn’t confirm your code in time. If it was accepted, it '
              'can’t be used again. Tap Resend code to get a new one.',
        AuthStage.finishSignIn =>
          'Your code was accepted, but setting up your account timed out. '
              'Tap Continue to try again.',
      },
      kind: AuthFailureKind.timeout,
      tone: AuthNoticeTone.warning,
    );
  }

  if (error is http.ClientException ||
      error is SocketException ||
      error is HandshakeException) {
    return AuthNotice(
      title: 'No connection',
      message: stage == AuthStage.finishSignIn
          ? 'Your code was accepted. Reconnect to the internet and tap '
                'Continue.'
          : 'We couldn’t reach PandaPay. Check that you’re online and try '
                'again.$validFor',
      kind: AuthFailureKind.network,
      tone: AuthNoticeTone.warning,
    );
  }

  if (error is ApiException) {
    final status = error.statusCode;
    final message = error.userMessage;
    final lower = message.toLowerCase();
    final reference = error.requestId != null
        ? 'Ref ${error.requestId}'
        : status != null && status >= 500
        ? 'HTTP $status'
        : null;

    if (isCodeStillActive(error)) {
      return AuthNotice(
        title: 'Code already sent',
        message:
            'We sent a code to $email less than a minute ago. Enter that '
            'code, or request a new one once it expires.',
        kind: AuthFailureKind.codeAlreadySent,
        tone: AuthNoticeTone.info,
      );
    }
    if (status == 429 && lower.contains('attempts')) {
      return const AuthNotice(
        title: 'Too many attempts',
        message:
            'For your security, sign-in for this email is paused. Please try '
            'again in about an hour.',
        kind: AuthFailureKind.tooManyAttempts,
      );
    }
    if (status == 429) {
      return const AuthNotice(
        title: 'Too many code requests',
        message:
            'For your security, we limit how many codes we send. Please wait '
            'a few minutes, then try again.',
        kind: AuthFailureKind.tooManyRequests,
      );
    }
    if (isRejectedCode(error)) {
      if (codeTimeLeft == Duration.zero) return const AuthNotice.codeExpired();
      if (attemptsLeft != null && attemptsLeft <= 0) {
        return const AuthNotice.codeLocked();
      }
      final tries = attemptsLeft == null
          ? ''
          : ' $attemptsLeft ${attemptsLeft == 1 ? 'try' : 'tries'} left.';
      return AuthNotice(
        title: 'Incorrect code',
        message:
            'That code doesn’t match the latest one sent to $email. Use the '
            'code from the newest email.$tries',
        kind: AuthFailureKind.wrongCode,
      );
    }
    if (status == 404 && lower.contains('account not found')) {
      return AuthNotice(
        title: 'No account found',
        message:
            'There’s no PandaPay account for $email. Check the spelling, or '
            'create a new account.',
        kind: AuthFailureKind.accountNotFound,
        tone: AuthNoticeTone.warning,
      );
    }
    if (status == 409 && lower.contains('already exists')) {
      return AuthNotice(
        title: 'Account already exists',
        message: '$message If this is you, sign in instead.',
        kind: AuthFailureKind.accountExists,
        tone: AuthNoticeTone.warning,
      );
    }
    if (status == 409) {
      return AuthNotice(
        title: 'Details don’t match',
        message:
            '$message Use the details on your account, or tap Need help '
            'signing in?',
        kind: AuthFailureKind.accountMismatch,
      );
    }
    if (status == 403) {
      return AuthNotice(
        title: 'Sign-in blocked',
        message: message,
        kind: AuthFailureKind.blocked,
      );
    }
    if (status == 401 && stage == AuthStage.finishSignIn) {
      return const AuthNotice(
        title: 'Session couldn’t start',
        message:
            'Your sign-in expired before setup finished. Request a new code '
            'to continue.',
        kind: AuthFailureKind.sessionRejected,
      );
    }
    if (status == 503 && lower.contains('unable to send')) {
      return AuthNotice(
        title: 'Couldn’t send the email',
        message:
            'Our email service didn’t respond. Please try again in a minute.',
        kind: AuthFailureKind.emailNotSent,
        tone: AuthNoticeTone.warning,
        reference: reference,
      );
    }
    if (status != null && status >= 500) {
      return AuthNotice(
        title: 'PandaPay is having trouble',
        message:
            'This is a problem on our side, not with your details. Please try '
            'again in a minute.${stage == AuthStage.finishSignIn ? ' Your code was accepted, so tap Continue.' : ''}',
        kind: AuthFailureKind.serviceUnavailable,
        reference: reference,
      );
    }
    return AuthNotice(
      title: 'Couldn’t continue',
      message: message,
      kind: AuthFailureKind.unexpected,
      reference: reference,
    );
  }

  if (error is StateError) {
    return AuthNotice(
      message: error.message,
      kind: AuthFailureKind.unexpected,
      tone: AuthNoticeTone.warning,
    );
  }

  return AuthNotice(
    title: 'Something went wrong',
    message: stage == AuthStage.finishSignIn
        ? 'Your code was accepted, but the app couldn’t finish signing you '
              'in. Tap Continue to try again. If it keeps happening, contact '
              'support with the reference below.'
        : 'Sign-in couldn’t finish. Please try again. If it keeps happening, '
              'contact support with the reference below.',
    kind: AuthFailureKind.unexpected,
    reference: 'Ref ${stage.name}/${error.runtimeType}',
  );
}
