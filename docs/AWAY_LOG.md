# Away log

Open questions and blocked checks while the user is away. Root keeps working on everything that does not depend on them.

- 2026-10-23: none open.
- 2026-10-23: The Reddit pull for the speed research failed twice with "Authentication required" from Antigravity (`agy`). The user must log in to Antigravity again. Stage 0 went on with Astra's report, X posts and YouTube search; Reddit is a gap in `docs/research.md`.
- 2026-10-23: The login keychain is locked in the session shell (`security show-keychain-info`: "User interaction is not allowed"). Developer ID signing fails with `errSecInternalComponent` and `notarytool` fails with `keychainLocked`. Until the user runs `security unlock-keychain ~/Library/Keychains/login.keychain-db`, milestone builds are ad-hoc signed (they run on this Mac only) and are NOT notarized. Each build is notarized once the keychain is open.
- 2026-10-23: The terminal has no Screen Recording permission: `screencapture` fails with "could not create image from display" and window titles read as empty. Screenshots come from XCUITest attachments instead. If the user grants Screen Recording to the terminal app (System Settings > Privacy & Security > Screen & System Audio Recording), root can also shoot TextEdit for side-by-side checks.
- 2026-10-23: UI tests need Automation Mode. Turning it on needs the user's admin password: `sudo automationmodetool enable-automationmode-without-authentication`. This is an access change, so root did not do it. Until then every UI test is written and compiled but NOT RUN, and milestones close on unit tests only, marked as such.
- 2026-10-23 (later): RESOLVED by the user: Automation Mode no longer needs a password, the keychain is unlocked (Developer ID signing and notarytool work), Antigravity is logged in. Still open: the screen reports locked (CGSSessionScreenIsLocked true), so UI tests and launch timing wait for it.
