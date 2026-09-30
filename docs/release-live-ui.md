# Release live UI verification

Release ignores all App Lock launch-environment overrides. Keep these environmental
suites in Release so they exercise the real service graph: `L1LiveGatewayUITests`,
`L1FixLiveGatewayUITests`, `P0_7LiveTailnetUITests`, `T2FixTailnetGatewayUITests`,
`P3FixLANGatewayUITests` and `B1LiveBoardPickerUITests`.

On a physical device, authenticate normally and turn App Lock off in Settings >
Security on the dedicated QA install before running an unattended suite. Restore
it afterward. These suites still require their operator-supplied gateway and
credential fixtures; they are environmental and do not run on public CI.

For simulator QA, install the Release app on a **dedicated, booted simulator**,
then prepare the same normal persisted preference externally before the test run:

```sh
python3 scripts/prepare_release_live_ui.py --simulator "$FLEET_QA_SIMULATOR" --disable-app-lock
```

The helper stops that simulator's app and preferences daemon, preserves unrelated
preferences, and writes only `fleet.appLock.enabled=false`. It does not add an
app-side bypass, modify Keychain items, set an install marker, or skip install
hygiene. Use the app's Security settings to re-enable App Lock after verification.
Do not run the preparation helper on a shared or personal simulator.

`LaunchOverrideHygieneTests` verifies that Release mode selection ignores disable
and reset overrides. Run that suite with both Debug and Release configurations;
Debug scripted lock suites continue to verify the authentication UI separately.
A successful Release build or preference preparation is not live-gateway evidence.
