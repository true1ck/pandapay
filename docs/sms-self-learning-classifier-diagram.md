# SMS classification and learning loop

```mermaid
flowchart TD
    A[New SMS arrives] --> B[On-device safety and relevance filter]
    B -->|OTP, offer, or unrelated| X[Ignore as transaction]
    B -->|Possible financial message| C[Apply downloaded shared rules and user-specific rules]
    C --> D{Strong rule match and required fields valid?}
    D -->|Yes| E[Auto-classify and save transaction]
    D -->|No| F[Server checks and Gemini suggestion]
    F --> G{Validated final confidence}
    G -->|High enough for auto action| E
    G -->|Uncertain, conflicting, or AI unavailable| H[Needs Review: prefill safe fields and explain uncertainty]
    H --> I{User decision}
    I -->|Confirm or edit| J[Save transaction and user correction]
    I -->|Not a transaction| K[Dismiss and record label]
    J --> L[Feedback example]
    K --> L
    E --> M[Monitor rule accuracy and corrections]
    L --> N[Cluster similar reviewed messages by issuer and wording]
    N --> O[Generate candidate reusable template]
    O --> P[Test against positive, negative, and historical examples]
    P --> Q{Meets promotion gate?}
    Q -->|No| R[Keep candidate for more evidence]
    Q -->|Yes| S[Publish versioned shared rule]
    S --> T[Devices download updated rule bundle]
    T --> C
    M --> N
```

## How to explain it

1. **Known SMS formats resolve immediately.** Each device has the latest approved shared rules plus that user's own account mappings and corrections. New users receive the existing approved rules.
2. **Unfamiliar messages get a second pass.** The server and Gemini propose fields and a classification. Validation checks transaction status, amount labels, direction, and contradictions before assigning a final score.
3. **Low confidence goes to Needs Review.** The user can confirm, edit, or dismiss a prefilled suggestion. If Gemini fails, the message still reaches review.
4. **Reviews improve future detection.** Confirmed decisions become examples. Similar examples produce candidate templates, which are tested before release to everyone.

**Score policy:** Measure confidence separately for transaction detection, field extraction, lifecycle, and economic kind. Use a moderate score to prefill review; require a much higher, empirically calibrated threshold for automatic financial classification. A user correction always takes priority over a shared rule.

**Data boundary:** Share approved template definitions across users, not their raw SMS or personal account mappings. Keep candidate versions, evaluation results, and rollout history on the server; cache published rules and user-specific decisions on the device.
