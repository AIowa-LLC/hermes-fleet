# Fleet Dev isolation and local validation

The `HermesFleetDev` target is a separate app with bundle identifier
`com.aiowa.hermesfleet.dev` and display name **Hermes Fleet Dev**. Its Keychain
services, pending enrollment identities, cache directory and conversation URL
scheme are separate from production. Production keeps its existing identifiers
and data. `project.yml` is authoritative; regenerate with `xcodegen generate`.

Run the repository gates before delivery. The local Dev wrapper requires a clean
checkout, an explicit full source SHA and an unused Dev build number:

```sh
bash scripts/fleet_dev_build.sh simulator --sha "$SOURCE_SHA" --build "$DEV_BUILD"
bash scripts/fleet_dev_build.sh test --sha "$SOURCE_SHA" --build "$DEV_BUILD"
```

The test mode runs eight hosted isolation checks. The Python contract tests use
synthetic build settings, signatures and test results; they do not prove that a
real app was built, signed or installed.

`structure-only` creates an unsigned device archive. `export` creates a local
internal TestFlight export using existing signing setup, without uploading.
Neither mode installs a phone build. Direct WiFi delivery requires a separate
development-signed build, verified Dev identity and an available, already paired
physical device with a local-network transport. Missing signing or device setup
is a blocker; these scripts do not register devices or change account settings.

Phone enrollment also requires the server-side owner-enrollment API. App build
delivery does not deploy that backend or change the server's authentication,
tunnel or firewall configuration.
