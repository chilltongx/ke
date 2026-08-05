# Task W5 implementation report

## Status

Implementation complete at the local cross-build gate. The WindowsDesktop test
assembly compiles on macOS; executable Automation test GREEN is pending GitHub
Windows CI because the macOS SDK has no `Microsoft.WindowsDesktop.App` runtime.

## RED evidence

Command:

```text
DOTNET_ROOT=/tmp/ke-windows-dotnet-x64.aBV6wd/sdk \
  /usr/bin/arch -x86_64 \
  /tmp/ke-windows-dotnet-x64.aBV6wd/sdk/dotnet test \
  windows/tests/Ke.Windows.Automation.Tests/Ke.Windows.Automation.Tests.csproj \
  -c Release -p:EnableWindowsTargeting=true \
  --filter "FocusedChatSenderTests|WindowsInputWriterTests"
```

Expected feature-missing failure, exit 1:

```text
CS0246: FocusedChatSender could not be found
CS0246: WindowsInputWriter could not be found
CS0246: IWindowsInputWriter/TextWriteResult could not be found
CS0246: IWindowsInputNative/IWriterAutomationBackend could not be found
CS0117: NativeMethods did not contain the Task W5 input constants
```

No production implementation existed when this RED was captured.

## GREEN evidence

- Full solution Release cross-build with `EnableWindowsTargeting=true`: pass,
  0 warnings, 0 errors.
- Core Release tests: 61 passed, 0 failed, 0 skipped.
- `git diff --check`: pass.
- Case-insensitive scan for `clipboard`, `OpenClipboard`, `SetClipboardData`,
  and `GetClipboardData` under `windows/`: clean.
- Focused Automation test assembly: compiles. Local execution stops before test
  discovery because macOS cannot install the WindowsDesktop runtime; GitHub
  Windows CI is the required executable GREEN gate.

## Exact behavior asserted

- Success event order is exactly: capture, capture, modifier check, one write,
  capture, modifier check, one Enter.
- Second-capture mutations of HWND, PID, runtime ID, application, or draft are
  `TargetChanged` with zero write/Enter attempts.
- Third-capture mutations of the same four identity fields or non-exact approval
  text are `WriteUnconfirmed` with zero Enter attempts.
- Cancellation is checked after capture one, immediately before write,
  immediately after write, and immediately before Enter; capture timeout at any
  of the three captures maps to `AutomationTimeout`.
- Both modifier gates prevent the next side effect.
- Failed writes and partial/failed `SendInput` calls are never retried.
- Failed Enter is attempted exactly once and maps to `ReturnDeliveryFailed`.
- Writable `ValuePattern` wins; unsupported/read-only ValuePattern falls back to
  exactly two Unicode keyboard records for `可`.
- Enter is exactly one VK_RETURN down/up pair.
- Foreground HWND/PID and focused runtime-ID mismatches prevent all writes.
- Only the high bit of Control, Alt/Menu, Shift, left Windows, and right Windows
  key state is treated as pressed.

## Native/UIA safety review

- Every input side effect is preceded by cancellation and foreground HWND/PID
  validation against `TargetIdentity`.
- Approval writing fetches the focused UIA element once and compares its
  dot-joined runtime ID before writing.
- Unicode fallback revalidates foreground HWND/PID after the UIA attempt and
  before `SendInput`.
- Enter revalidates foreground HWND/PID and all modifiers before `SendInput`.
- `SendInput` succeeds only when the native return count equals two.
- No clipboard, activation, window switch, or retry API is present.
- `NativeMethods` contains only Task W5 keyboard constants, `GetAsyncKeyState`,
  `SendInput`, and the exact keyboard input structs required by this task.

## Changed files

- `windows/src/Ke.Windows.Automation/FocusedChatSender.cs`
- `windows/src/Ke.Windows.Automation/WindowsInputWriter.cs`
- `windows/src/Ke.Windows.Automation/NativeMethods.cs`
- `windows/tests/Ke.Windows.Automation.Tests/FocusedChatSenderTests.cs`
- `windows/tests/Ke.Windows.Automation.Tests/WindowsInputWriterTests.cs`
- `.superpowers/sdd/task-5-report.md`

## Concerns

- WindowsDesktop tests must pass on GitHub Windows CI before W5 is accepted.

## Critical ABI review fix

Review found that the initial `INPUT` union contained only `KEYBDINPUT`. On x64,
that made `Marshal.SizeOf<NativeInput>()` return 32 even though Win32 requires
`INPUT` and `SendInput.cbSize` to be 40 bytes.

The regression test was written first. A pure `net10.0` runner linked the actual
pre-fix `NativeMethods.cs` and produced the valid RED:

```text
NativeInput size: expected 40, actual 32
exit=1
```

The union now overlays the complete Win32 `KEYBDINPUT`, `MOUSEINPUT`, and
`HARDWAREINPUT` members at offset zero. The same runner then produced GREEN:

```text
NativeInput=40, Type@0, Data@8, Mouse=32, Keyboard=24, Hardware=8
exit=0
```

`WindowsInputWriterTests` now asserts those sizes and offsets. It also exercises
the production `WindowsInputNative` adapter through an `IUser32InputApi` fake and
proves that the adapter forwards two keyboard inputs with
`cbSize == Marshal.SizeOf<NativeInput>() == 40`; no input size is hard-coded.
