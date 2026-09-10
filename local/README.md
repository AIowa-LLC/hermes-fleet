# i16 local evidence (QA run)

- baseline/    — 5x standalone H1AppLockUITests (15/15 PASS). Logs + xcresults.
- repro/       — hosted-condition repro (HappyPath -> H1 same sim, 2 iters,
                 FAIL 2/3 each, exact hosted signature).
- causal/      — single-variable experiment: seeded HappyPath state,
                 navkey_wiped run PASSES 2/2.
- shots/       — post-unlock-persisted-nav.png (landing on Render Box bot
                 detail after biometric unlock; OCR text in evidence.md).
- decode_nav2.py — decodes fleet.navigation.v1 from the app container plist.
- ocr.swift    — macOS Vision OCR used for the screenshot.
- *.sh         — exact scripts used (baseline_5x.sh, repro_hosted.sh,
                 causal_navkey3.sh, shot_landing.sh, inspect_state.sh).
