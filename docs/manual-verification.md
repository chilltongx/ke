# Manual Verification

## Verification record

- Test date: `2026-07-15 20:43:57 CST` (`Asia/Shanghai`)
- Scope completed in this record: automated tests, an isolated synthetic Hook check,
  release packaging, metadata validation, and signature validation.
- Scope deliberately not performed: installing or opening `Codex 可.app`, changing
  the plugin marketplace, registering the login item, changing Accessibility
  permission, interacting with the real Codex UI, sending `可`, and uninstalling.
- Status meaning:
  - `PASS (automatic)` means the complete row is covered by a named automated or
    isolated synthetic check.
  - `PENDING (manual)` means a real installed app, current Codex Accessibility tree,
    permission transition, visual check, real send, restart, display change, or
    uninstall is still required. Passing unit tests are listed only as partial
    evidence for these rows and do not change their status.

## Versions observed on the test machine

| Component | Observed version | Read-only evidence |
| --- | --- | --- |
| Codex desktop | `26.707.72221` (build `5307`) | `/Applications/ChatGPT.app/Contents/Info.plist`; Bundle ID is exactly `com.openai.codex`. |
| Codex CLI on `PATH` | `codex-cli 0.143.0` | `/Users/x/.local/bin/codex --version`. |
| Codex desktop embedded CLI | `codex-cli 0.144.2` | `/Applications/ChatGPT.app/Contents/Resources/codex --version`. |
| macOS | `26.5.2` (build `25F84`) | `sw_vers`. |
| Candidate companion app | `0.1.0` (build `1`), minimum macOS `14.0` | `PlistBuddy` against the freshly built app. |

The desktop app and its embedded CLI are newer than the CLI currently found on
`PATH`. Manual installation must therefore record which CLI performs plugin setup
and must not silently replace either CLI.

## Automated and synthetic evidence

All commands below were run from the implementation worktree on the test date.

| Check | Result | Evidence |
| --- | --- | --- |
| Unit and integration tests | PASS | Fresh `swift test`: 75 tests executed, 0 failures. |
| Release rebuild | PASS | Fresh `zsh scripts/build-release.sh`: exit 0; `dist` was rebuilt. |
| App signature | PASS | `codesign --verify --deep --strict --verbose=2 'dist/Codex 可.app'`: valid on disk and satisfies its designated requirement. The candidate uses an ad-hoc signature. |
| Property lists | PASS | `plutil -lint` passed for both source plists and both plists copied into the app bundle. |
| Packaging static checks | PASS | `zsh Tests/PackagingTests.sh`: `Packaging static checks passed.` |
| Whitespace/error markers | PASS | `git diff --check`: no output. |
| Isolated Hook state transition | PASS | The built Hook ran with `HOME` and `CFFIXED_USER_HOME` set to a temporary directory. An approval-style Stop produced `waitingForApproval` with `waitingSince`; an ordinary completed Stop produced `idle` without `waitingSince`. The temporary directory was removed. |
| Candidate plugin archive | PASS | `ditto -c -k --keepParent` created `dist/CodexQuickOK-Codex插件.zip`; `unzip -t` reported no errors and inventory includes the marketplace descriptor, plugin descriptor, Hook configuration, and executable Hook. |

Candidate SHA-256 values from this build:

```text
c967638eb3846e01d2a815b4efcf3afef24cd9ce8f9023b69dbd009fac0ee01c  CodexQuickOKApp
93cf3b1e4383bb3fe4d75bf8c88773e0008f67574f60ed1bcc9148bf5b3c1269  CodexQuickOKHook
aeca854bcad9404e382ccebad6eabaf2870a902e08ef50dd05e03069536a3780  CodexQuickOK-Codex插件.zip
```

## Acceptance matrix

| ID | Acceptance check | Status | Automatic evidence | Manual evidence / action still required |
| --- | --- | --- | --- | --- |
| 1 | Idle Codex: button hidden. | PENDING (manual) | The snapshot evaluator has a hidden mode, but the suite does not exercise a real idle Codex window. | With the installed companion and Hook trusted, leave Codex open with no running or waiting task and confirm no panel is visible. |
| 2 | Running task: button visible with breathing halo. | PENDING (manual) | `SessionSnapshotTests.testShowsRunningButHasNoSendTarget` proves the running mode; animation tests cover the reduced-motion branch, not real rendering. | Start a real Codex task and visually confirm the 64 pt panel and breathing halo. Repeat with Reduce Motion enabled and confirm the non-continuous fallback. |
| 3 | Approval-style Stop message: button remains visible. | PASS (automatic) | Isolated built-Hook check produced `waitingForApproval`; `SessionSnapshotTests.testHidesWithoutCodexAndSelectsNewestWaitingSession` maps a fresh waiting state to visible waiting mode. | Optional real UI confirmation remains useful but is not claimed here. |
| 4 | Ordinary completed answer: button hides. | PENDING (manual) | Isolated built-Hook check produced `idle`; classifier tests reject an ordinary completion as an approval request. There is no full real-panel check in this record. | Complete a real ordinary task and confirm the panel hides after its Stop event. |
| 5 | Two waiting tasks: newest waiting task is selected. | PASS (automatic) | `SessionSnapshotTests.testHidesWithoutCodexAndSelectsNewestWaitingSession` selects session `newer`. | Optional real two-task confirmation remains useful but is not claimed here. |
| 6 | Other app frontmost: click activates Codex and sends exactly one `可`. | PENDING (manual) | `ApprovalSenderTests.testSendsOneChineseApprovalAfterEveryCheckPasses` proves one synthetic write and one send after safety checks. It does not validate the current real Accessibility tree or app activation. | Put another app frontmost, click once, then confirm Codex becomes active and exactly one real `可` appears in the intended task. |
| 7 | Running-only state: click shows `暂无待批准会话` and sends nothing. | PASS (automatic) | `AppControllerTests.testNoTargetActivationDoesNotCallSender` proves the exact failure text and zero sender calls. | Optional real UI confirmation remains useful but is not claimed here. |
| 8 | Non-empty Codex draft: click refuses and preserves the draft. | PASS (automatic) | `ApprovalSenderTests.testRejectsExistingDraftWithoutWriting` proves zero writes and zero send actions for a non-empty synthetic composer. | Optional real Accessibility confirmation remains useful but is not claimed here. |
| 9 | Native approval card: click reports unsupported and sends nothing. | PENDING (manual) | `AccessibilityClientSafetyTests.testRejectsNativeApprovalCardBeforeSelectingComposer` proves the synthetic AX tree fails closed before composer selection. The exact current Codex AX representation and user-facing report were not exercised. | Open a real native approval card, click the companion, verify the unsupported message, and confirm no text or action is submitted. |
| 10 | Accessibility revoked: click opens guidance and sends nothing. | PENDING (manual) | Activation-failure and missing-composer tests prove fail-closed sender behavior, but permission revocation and System Settings guidance were not triggered. | Revoke only this app's Accessibility permission, click once, verify guidance opens and no send occurs, then restore the permission. |
| 11 | Weekly quota present: ring equals `100 - usedPercent` and tooltip reset time is local. | PENDING (manual) | `QuotaSelectorTests.testSelectsOnlySevenDayCodexWindow` proves `usedPercent: 25` becomes 75% remaining; tooltip restoration is unit-tested. Pixel arc length and local-time presentation were not manually inspected. | With a real weekly limit present, compare the ring and tooltip with App Server data and confirm reset time uses the machine's local time. |
| 12 | Weekly quota absent: ring is gray; no short-window fallback appears. | PASS (automatic) | `QuotaSelectorTests.testReturnsNilInsteadOfFallingBackToShortWindow` returns nil; `HaloButtonViewTests.testFailureReplacingSuccessInvalidatesInvertedSeal` proves the unavailable halo token is used. | Optional visual confirmation remains useful but is not claimed here. |
| 13 | Drag over 5 pt: position changes without a send. | PENDING (manual) | `GestureDecisionTests.testMovementOverFivePointsIsDrag` and `testDragRemainsLatchedAfterPointerReturnsNearStart` prove movement over 5 pt cannot become a click. Actual panel movement was not manually observed. | Drag the installed panel more than 5 pt, confirm its origin changes, and confirm no `可` is sent. |
| 14 | Repeated click during send: at most one `可` is submitted. | PASS (automatic) | `ApprovalSenderTests.testDuplicateInFlightSendThrowsExplicitErrorAndPressesOnlyOnce` and `AppControllerTests.testActivationIsLockedWhileSendIsInProgress` prove the in-flight lock and one synthetic send. | Optional real timing confirmation remains useful but is not claimed here. |
| 15 | Codex exits: panel hides immediately. | PASS (automatic) | `AppControllerTests.testCodexTerminationHidesPanelAndClearsTarget` synchronously changes the panel to hidden and clears the target when Codex stops. | Optional real process-exit observation remains useful but is not claimed here. |
| 16 | App restart and display change: normalized panel position is restored on-screen. | PENDING (manual) | Screen selection geometry is unit-tested, but restart persistence and a real display topology change were not performed. | Drag to a non-default position, restart the companion, change display arrangement or disconnect a display, and confirm restoration remains on-screen. |
| 17 | Uninstall: app, login item, plugin, marketplace, and owned state are removed only. | PENDING (manual) | `PackagingTests.sh` statically proves the uninstall script's only filesystem deletion is the owned app and support paths. The script was deliberately not executed. | After all preceding checks, run uninstall and inspect the app, login item, plugin, marketplace, owned support state, unrelated Codex configuration, and Accessibility permission. |

Current matrix total: **7 PASS (automatic), 10 PENDING (manual), 0 FAIL**.

## Manual run procedure

The following steps are instructions for the remaining controlled manual run; they
have not been executed as part of this record.

1. Save or close any important Codex drafts and choose a disposable Codex task for
   the real-send checks.
2. Run `zsh scripts/install-local.sh`. Record whether plugin setup used the observed
   `PATH` CLI (`0.143.0`) or another explicitly selected CLI.
3. Review and trust the local Hook in Codex. Grant only Accessibility to `Codex 可`
   when macOS requests it; do not grant Full Disk Access, Screen Recording, or
   administrator privileges.
4. Execute all rows still marked `PENDING (manual)` in numeric order. Put the date,
   operator, observed result, and PASS or FAIL directly into this document. A failure
   must return to the owning task and gain a focused regression test before rerun.
5. Perform row 17 last with `zsh scripts/uninstall-local.sh`. Confirm unrelated Codex
   configuration and other applications are unchanged.
6. Rebuild and repeat signature, plist, packaging, test, and `git diff --check`
   verification after any fix.
7. Only after every row is PASS, copy the rebuilt app and plugin ZIP to the final
   user-facing output directory. Do not treat the current `dist` candidates as
   manually verified deliverables.

## Dock icon regression

- Verification date: `2026-07-17` (`Asia/Shanghai`).
- [x] Installed bundle declares `CFBundleIconFile = AppIcon`.
- [x] Installed bundle contains a non-empty `Contents/Resources/AppIcon.icns`.
- [ ] Dock shows the coal-gray “可” icon instead of a question mark. The existing
  Dock item still resolves to `~/Applications/Codex 可.app`; visual confirmation is
  pending because the Dock remained auto-hidden during the automated screenshot.
- [ ] Clicking the Dock tile launches `Codex 可`. The installer reopened the new
  build successfully, but the Dock tile was deliberately not clicked automatically.
