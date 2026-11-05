// GENERATED TEXT: the privacy policy and terms shown in the app. The hosted
// pages in deploy/legal/*.html carry exactly the same wording, and a test
// (legal_text_test.dart) fails if the two drift apart. Edit both together.

/// The day this wording was published. It is also the policy version recorded
/// with every consent (see `consentPolicyVersion`).
const legalLastUpdated = '15 November 2026';

/// Placeholders the owner must replace before the pages are published. They
/// are spelled `[OWNER TO FILL: ...]` so they cannot be missed.
const legalOwnerPlaceholder = '[OWNER TO FILL';

class LegalSection {
  const LegalSection(this.title, this.blocks);
  final String title;
  final List<LegalBlock> blocks;
}

class LegalBlock {
  const LegalBlock.paragraph(this.text) : items = const [];
  const LegalBlock.bullets(this.items) : text = null;

  /// A paragraph, or null for a bulleted list.
  final String? text;
  final List<String> items;
}

const termsOfServiceSections = <LegalSection>[
  LegalSection(
    '1. What PandaPay is',
    [
      LegalBlock.paragraph('PandaPay helps you decide which of your existing payment cards to use for a purchase, and tracks your own spend against each card\'s reward caps and milestones. We do not issue cards, extend credit, move money, or act as a payment processor. We are not a party to any transaction between you and your card issuer, merchant, or bank.'),
    ],
  ),
  LegalSection(
    '2. Who can use PandaPay',
    [
      LegalBlock.paragraph('PandaPay is only for people aged 18 or over. By creating an account you confirm that you are 18 or older. If you are under 18, please do not use PandaPay.'),
    ],
  ),
  LegalSection(
    '3. Your account',
    [
      LegalBlock.paragraph('A PandaPay account is required to use the app, so your cards, transactions and insights stay tied to you. You are responsible for keeping your sign-in access secure.'),
    ],
  ),
  LegalSection(
    '4. Optional features and your consent',
    [
      LegalBlock.paragraph('Reading your bank SMS, sharing message layouts and shop names, and email import are optional. Each asks for your agreement on its own screen, is described in the Privacy Policy, and can be turned off at any time. PandaPay works for manual entry without them.'),
    ],
  ),
  LegalSection(
    '5. Accuracy of reward and card data',
    [
      LegalBlock.paragraph('Reward rates, caps, fees, and benefit terms shown in the app are sourced from card issuers\' public terms and community contributions, and may be inaccurate, incomplete, or out of date at any time. Always confirm reward terms directly with your card issuer before relying on them for a real financial decision.'),
    ],
  ),
  LegalSection(
    '6. No liability for financial decisions',
    [
      LegalBlock.paragraph('PandaPay provides informational estimates only. We accept no liability for financial outcomes, missed rewards, fees, or other consequences arising from decisions made using the app.'),
    ],
  ),
  LegalSection(
    '7. Crowdsourced contributions',
    [
      LegalBlock.paragraph('Contributions you submit (for example confirming a merchant\'s card acceptance or category) may be used, in anonymized form as described in the Privacy Policy, to improve recommendations for all users. By submitting a contribution you grant us a perpetual, royalty-free licence to use the anonymized version of it for that purpose.'),
    ],
  ),
  LegalSection(
    '8. Account deletion',
    [
      LegalBlock.paragraph('You may request account deletion at any time from Settings. See the Privacy Policy for what is deleted and the timeline.'),
    ],
  ),
  LegalSection(
    '9. Not financial advice',
    [
      LegalBlock.paragraph('PandaPay estimates rewards and surfaces informational suggestions based on publicly available card and reward terms. It is not a regulated financial advisor and never provides personalized financial or investment advice. Always verify reward terms with your card issuer, and consult a licensed financial advisor before making real financial decisions.'),
    ],
  ),
  LegalSection(
    '10. Changes to these terms',
    [
      LegalBlock.paragraph('We may update these terms as the app changes. Material changes will be reflected here with an updated "Last updated" date; continued use of the app after a change constitutes acceptance.'),
    ],
  ),
  LegalSection(
    '11. Governing law',
    [
      LegalBlock.paragraph('These terms are governed by [OWNER TO FILL: governing law and courts, for example the laws of India and the courts of a named city].'),
    ],
  ),
  LegalSection(
    '12. Contact',
    [
      LegalBlock.paragraph('Questions about these terms: panda.paths123@gmail.com.'),
    ],
  ),
];

const privacyPolicySections = <LegalSection>[
  LegalSection(
    '1. Who we are',
    [
      LegalBlock.paragraph('PandaPay helps you track spending and choose the right card. This policy explains what we collect, why, and the choices you have. It is written to be read, not skimmed past.'),
      LegalBlock.paragraph('PandaPay is run by [OWNER TO FILL: legal entity name and registered address]. Our grievance officer under the Digital Personal Data Protection Act, 2023 is [OWNER TO FILL: grievance officer name], at [OWNER TO FILL: grievance officer email]. We reply to every request and complaint within 30 days. For general questions you can also write to panda.paths123@gmail.com.'),
    ],
  ),
  LegalSection(
    '2. Data we collect',
    [
      LegalBlock.bullets([
        'Your account: the email address and phone number you sign up with, and your Google account details if you use Google sign-in.',
        'Transaction details from your bank SMS: the amount, merchant, date, card or account ending, and type of transaction (for example a purchase, refund or bill). We do not collect the message itself.',
        'Details you enter: cards, transactions, notes, budgets, and the name and phone number of anyone you add to a shared expense.',
        'Statements and files you choose to import.',
        'Bank emails, only if you turn on email import (see 5a).',
        'Device and push identifiers: a notification token, an install ID, the app version and your phone type, so we can deliver the notifications you turn on.',
        'Your location, only if you allow it, to find nearby merchants and send location alerts you turn on.',
        'Privacy-safe error reports: the type of error, where in our code it happened, the app version and your phone type. Never message text, amounts, names or account numbers.',
        'Basic in-app usage events (for example which screens are opened) from a short fixed list. Never free-text input, amounts or card details.',
      ]),
      LegalBlock.paragraph('We do not read your contacts or call log. If you pick a contact to add to a shared expense, only that person\'s name and number are used.'),
    ],
  ),
  LegalSection(
    '3. What stays on your phone',
    [
      LegalBlock.bullets([
        'The text of your bank SMS. It is read on your phone and is never sent to us. Personal messages and one-time passwords are skipped.',
        'Messages waiting for your review.',
        'Receipts and files you attach.',
      ]),
      LegalBlock.paragraph('We protect this data on your phone. The app\'s database is encrypted, with a key kept in the iPhone Keychain or Android Keystore. Receipt files are encrypted. On iPhone, messages you share through the Shortcut are encrypted while they wait. All of it is kept in storage that is left out of phone backups. Signing out removes this data and its keys from the phone.'),
    ],
  ),
  LegalSection(
    '4. Why we use your data',
    [
      LegalBlock.bullets([
        'Email address and phone number: to sign you in and keep your account secure.',
        'Transaction details: to show your spending, bills, card rewards and caps on any phone you sign in to.',
        'Cards and details you enter: to estimate rewards and suggest the best card.',
        'Statements and files: only to import them the way you asked.',
        'Notification token and device identifiers: to deliver the notifications you turn on.',
        'Location: to find nearby merchants and send the location alerts you turn on. Nearby searches send coordinates to the PandaPay API, which can pass them to Google Places or OpenStreetMap-based providers. Stored merchant coordinates are rounded to about 11 metres.',
        'Error reports: to find and fix crashes.',
        'Usage events: to see which features work.',
        'Card "Apply" links: tapping Apply sends you to the issuer\'s own site with a random reference code, not your personal details. We record that the click happened so we can see which recommendations are useful.',
      ]),
      LegalBlock.paragraph('We do not sell your account data. Three things are optional and off unless you turn them on in Settings, Privacy & Permissions: sharing anonymous merchant information ("Help improve PandaPay"), allowing combined, non-identifying statistics, and sharing with a named partner. Merchant information is stored without your name, email or account ID, with amounts left out and times kept to the day.'),
    ],
  ),
  LegalSection(
    '5. Optional: sharing message layouts, shop categories and shop names',
    [
      LegalBlock.paragraph('This is off unless you turn it on ("Help PandaPay get better for everyone"). If you turn it on, PandaPay shares:'),
      LegalBlock.bullets([
        'The layout of bank messages it can\'t read, with every amount, name, number and date removed.',
        'The shop names it couldn\'t put in a category, and the categories and shop names you pick for shops.',
      ]),
      LegalBlock.paragraph('It never shares your messages, amounts, account numbers or the people you pay. A shop name is looked at only once several different people have shared it, and only if it has no long numbers or personal details. Google Gemini, a service of Google, may process message layouts and shop names to suggest new rules, and a person at PandaPay approves every rule before it is added for everyone. Nothing is shared unless you turn this on. You can turn it off at any time in Settings, Privacy & Permissions. If you turn it off, what you shared is deleted. Rules already added for everyone stay, and they contain nothing about you.'),
    ],
  ),
  LegalSection(
    '5a. Optional: email import',
    [
      LegalBlock.paragraph('This is off unless you connect a mailbox or forward bank emails, and it has its own consent screen.'),
      LegalBlock.bullets([
        'Only emails from bank and card senders are read. Other emails are not opened.',
        'The email text is sent to PandaPay to read the transaction and is deleted once it has been read. Emails we could not read are kept for up to 30 days so you can review them, then deleted.',
        'Your mailbox app password is stored encrypted and used only to read these emails. Disconnecting deletes it.',
        'To stop, disconnect the mailbox or stop forwarding in Import & Sync. You can also contact the grievance officer.',
      ]),
    ],
  ),
  LegalSection(
    '6. Service providers',
    [
      LegalBlock.paragraph('We use a few providers to run PandaPay. Each gets only what it needs for its job.'),
      LegalBlock.bullets([
        'Hosting and storage of your account data: [OWNER TO FILL: hosting provider and region].',
        'Push notifications: Novu and Google Firebase Cloud Messaging.',
        'Error reports: GlitchTip ([OWNER TO FILL: where error reports are hosted]).',
        'Google Gemini: only if you turn on sharing message layouts and shop names (section 5).',
        'Google Places or OpenStreetMap-based providers: for nearby merchant searches (section 4).',
        'Google: only if you use Google sign-in.',
      ]),
    ],
  ),
  LegalSection(
    '7. Security',
    [
      LegalBlock.bullets([
        'Everything between the app and our servers uses encrypted connections (HTTPS/TLS).',
        'Our database backups are encrypted.',
        'Access to account data on our servers is restricted.',
        'Mailbox app passwords are encrypted with AES-256-GCM before they are stored.',
        'On your phone, the database, receipts and shared-message queue are encrypted and left out of phone backups (section 3).',
      ]),
    ],
  ),
  LegalSection(
    '8. How long we keep data',
    [
      LegalBlock.paragraph('We keep your data while your account exists. If you ask us to delete your account, you have 30 days to change your mind. After that your data is deleted from our live systems, and encrypted backups that still hold it expire within 30 days. Parsed emails are deleted as described in section 5a.'),
    ],
  ),
  LegalSection(
    '9. Your rights and how to use them',
    [
      LegalBlock.bullets([
        'Access: export your transactions and cards as JSON or CSV from Settings.',
        'Correction: edit your details and transactions in the app, or ask the grievance officer.',
        'Deletion: delete your account from Settings.',
        'Withdrawing consent: turn off SMS reading, shared learning or other optional settings in Settings, Privacy & Permissions, or disconnect email import. Withdrawing does not affect what we did before you withdrew.',
        'Complaints: write to the grievance officer (section 1). If we have not resolved it, you can complain to the Data Protection Board of India.',
      ]),
      LegalBlock.paragraph('If you are in India, we provide these rights consistent with the Digital Personal Data Protection Act, 2023.'),
    ],
  ),
  LegalSection(
    '10. If something goes wrong',
    [
      LegalBlock.paragraph('If a personal data breach affects you, we will tell you and the authorities as the law requires, without undue delay, and say what happened and what you can do.'),
    ],
  ),
  LegalSection(
    '11. Age',
    [
      LegalBlock.paragraph('PandaPay is only for people aged 18 or over. You confirm this when you sign up. We do not knowingly collect data from anyone under 18, and we will delete it if we learn we have.'),
    ],
  ),
  LegalSection(
    '12. Changes to this policy',
    [
      LegalBlock.paragraph('We may update this policy as PandaPay changes. We will change the date at the top, and where the change affects a consent you gave, we will ask you again.'),
    ],
  ),
];
