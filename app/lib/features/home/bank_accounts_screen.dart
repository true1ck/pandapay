import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../../data/user_cards_repository.dart' show BankAccountSummary;

class BankAccountsScreen extends ConsumerStatefulWidget {
  const BankAccountsScreen({super.key});

  @override
  ConsumerState<BankAccountsScreen> createState() => _BankAccountsScreenState();
}

class _BankAccountsScreenState extends ConsumerState<BankAccountsScreen> {
  final _localAuth = LocalAuthentication();
  bool _unlocked = false;
  bool _authenticating = false;

  Future<bool> _unlock() async {
    if (_unlocked) return true;
    if (_authenticating) return false;
    setState(() => _authenticating = true);
    try {
      if (!await _localAuth.isDeviceSupported()) {
        if (mounted) {
          _showMessage(
            'Set up a device PIN or biometric unlock to view and edit balances.',
          );
        }
        return false;
      }
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'View and edit bank balances in PandaPay',
        biometricOnly: false,
      );
      if (!mounted) return false;
      if (authenticated) setState(() => _unlocked = true);
      return authenticated;
    } catch (_) {
      if (mounted) _showMessage('Could not verify. Balances remain hidden.');
      return false;
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isBank(BankAccountSummary account) {
    final label = [
      account.issuerSlug,
      account.issuerShortName,
      account.issuerName,
    ].whereType<String>().join(' ').toLowerCase();
    return !RegExp(
      r'\b(?:lic|licind|dhan|dhanhq|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel|paytm\s+money)\b',
    ).hasMatch(label);
  }

  Future<void> _editBalance(BankAccountSummary account) async {
    if (!await _unlock() || !mounted) return;
    final namespace = ref.read(cacheNamespaceProvider);
    final current = account.availableBalance?.rupees;
    final controller = TextEditingController(
      text: current == null
          ? ''
          : current.toStringAsFixed(current % 1 == 0 ? 0 : 2),
    );
    String? inputError;
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Edit account balance'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${account.issuerShortName ?? account.issuerName ?? 'Bank account'} ••••${account.accountLast4}',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                    RegExp(r'^\d{0,10}(?:\.\d{0,2})?'),
                  ),
                ],
                decoration: InputDecoration(
                  labelText: 'Current balance',
                  prefixText: '₹ ',
                  helperText: 'Enter the balance shown in your bank app.',
                  errorText: inputError,
                ),
                onSubmitted: (text) {
                  final parsed = double.tryParse(text);
                  if (parsed != null && parsed >= 0) {
                    Navigator.pop(dialogContext, parsed);
                  } else {
                    setDialogState(() => inputError = 'Enter a valid balance.');
                  }
                },
              ),
            ],
          ),
          actions: [
            if (account.isBalanceManuallySet)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, -1),
                child: const Text('Use SMS balance'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = double.tryParse(controller.text);
                if (parsed != null && parsed >= 0) {
                  Navigator.pop(dialogContext, parsed);
                } else {
                  setDialogState(() => inputError = 'Enter a valid balance.');
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null ||
        !mounted ||
        ref.read(cacheNamespaceProvider) != namespace) {
      return;
    }

    final cache = await ref.read(responseCacheProvider.future);
    if (!mounted || ref.read(cacheNamespaceProvider) != namespace) return;
    final issuer =
        account.issuerSlug ??
        account.issuerShortName ??
        account.issuerName ??
        'unknown';
    if (value < 0) {
      cache.financialStore.clearManualBankBalance(
        namespace,
        issuer: issuer,
        accountLast4: account.accountLast4,
      );
    } else {
      cache.financialStore.setManualBankBalance(
        namespace,
        issuer: issuer,
        accountLast4: account.accountLast4,
        balance: Money.fromRupees(value),
      );
    }
    ref.invalidate(bankAccountSummariesProvider);
    if (mounted) {
      _showMessage(
        value < 0 ? 'Using the latest SMS balance' : 'Balance updated',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(bankAccountSummariesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bank accounts'),
        actions: [
          IconButton(
            tooltip: _unlocked ? 'Hide balances' : 'Reveal balances',
            onPressed: _authenticating
                ? null
                : () {
                    if (_unlocked) {
                      setState(() => _unlocked = false);
                    } else {
                      _unlock();
                    }
                  },
            icon: Icon(
              _unlocked
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
        ],
      ),
      body: result.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load bank accounts.\n$error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (allAccounts) {
          final accounts = allAccounts.where(_isBank).toList()
            ..sort(
              (a, b) => (a.issuerShortName ?? a.issuerName ?? '').compareTo(
                b.issuerShortName ?? b.issuerName ?? '',
              ),
            );
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: BambooInk.slate,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.sms_outlined, color: BambooInk.lime),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Balances are currently detected from bank SMS and may be out of date.',
                            style: BambooFonts.ui(13, color: BambooInk.onSlate),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'You can update any balance manually. Live bank balances are coming soon as an app feature.',
                      style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('No bank accounts detected yet.')),
                )
              else
                for (final account in accounts)
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        backgroundColor: BambooInk.slate,
                        foregroundColor: BambooInk.lime,
                        child: Text(
                          (account.issuerShortName ?? account.issuerName ?? 'B')
                              .trim()
                              .characters
                              .first
                              .toUpperCase(),
                        ),
                      ),
                      title: Text(
                        account.issuerShortName ??
                            account.issuerName ??
                            'Bank account',
                      ),
                      subtitle: Text(
                        'Account ending ${account.accountLast4}\n${account.isBalanceManuallySet
                            ? 'Manually updated ${DateFormat('dd MMM, h:mm a').format(account.manualBalanceUpdatedAt!.toLocal())}'
                            : account.latestBalanceSmsAt == null
                            ? 'No balance reported by SMS'
                            : 'SMS snapshot ${DateFormat('dd MMM, h:mm a').format(account.latestBalanceSmsAt!.toLocal())}'}',
                      ),
                      isThreeLine: true,
                      trailing: SizedBox(
                        width: 152,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Flexible(
                              child: Text(
                                account.availableBalance == null
                                    ? 'Not set'
                                    : _unlocked
                                    ? account.availableBalance!.format(
                                        hidePaise: true,
                                      )
                                    : '₹••••',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: BambooFonts.ui(
                                  13,
                                  weight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit balance',
                              onPressed: _authenticating
                                  ? null
                                  : () => _editBalance(account),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
