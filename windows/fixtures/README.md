# Windows UI Automation fixtures

The four JSON files in this directory are deterministic, sanitized bootstrap
fixtures. They are not captured from a live, logged-in Codex or Visual Studio
Code session and must not be treated as real UIA provenance.

Before a stable release, W10 acceptance must:

1. capture replacement fixtures on Windows 11 with the read-only capture harness;
2. review every sanitized field and explicitly approve any new technical
   identifier before extending the exact allow-list;
3. replace both positive bootstrap profiles;
4. capture and verify every documented negative scenario; and
5. confirm differing or unknown UIA shapes still fail closed.

Until those gates pass, Windows artifacts using these profiles are pre-release
test builds only.
