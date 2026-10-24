# Away log

Open questions and blocked checks while the user is away. Root keeps working on everything that does not depend on them.

- 2026-10-23: none open.
- 2026-10-23: The Reddit pull for the speed research failed twice with "Authentication required" from Antigravity (`agy`). The user must log in to Antigravity again. Stage 0 went on with Astra's report, X posts and YouTube search; Reddit is a gap in `docs/research.md`.
- 2026-10-23: The login keychain is locked in the session shell (`security show-keychain-info`: "User interaction is not allowed"). Developer ID signing fails with `errSecInternalComponent` and `notarytool` fails with `keychainLocked`. Until the user runs `security unlock-keychain ~/Library/Keychains/login.keychain-db`, milestone builds are ad-hoc signed (they run on this Mac only) and are NOT notarized. Each build is notarized once the keychain is open.
