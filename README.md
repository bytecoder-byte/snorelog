# SnoreLog

An iPhone app that records your night, finds the snoring on the device, and shows a morning report: a snore score, a timeline, and short clips you can play back. History shows your trend and which tags (alcohol, nasal strip, side sleeping and so on) seem to make a difference.

Version 0.1, written without being compiled. See "Not yet verified" below.

## Open and run

1. You need a Mac with **Xcode 16 or newer**. The app targets **iOS 17+**.
2. Open `SnoreLog.xcodeproj`.
3. Select the **SnoreLog** target > Signing & Capabilities. Pick your Team and change the bundle ID from `com.example.snorelog` to your own (for example `com.yourname.snorelog`). Do the same for **SnoreLogTests**.
4. Run on a **real iPhone**. The simulator can't test overnight recording with the screen locked.
5. Run the unit tests with Cmd-U. They cover episode detection, scoring, the factor comparison and formatting.

A quick way to test detection: start a night, play a snoring video from another device near the phone for a couple of minutes, then tap "I'm awake".

## Running without a Mac

iOS apps can only be built on macOS. If you don't have a Mac, push this folder to GitHub: the workflow in `.github/workflows/ios.yml` runs on GitHub's Mac machines on every push. It runs the unit tests, builds the app for the iPhone Simulator, launches it with sample data (`-demoData`) and saves screenshots. Download them from the run's **Artifacts** section, or open the `screenshots` branch (`screenshots-<branch>` for other branches). The artifact also holds `SnoreLog-simulator.zip`, which you can upload to a browser-based simulator such as Appetize.io to tap around the app.

The simulator has no real night to record, so recording and snore detection still need a real iPhone.

## SnoreLog Pro

Everything above stays free. **SnoreLog Pro** is an optional upgrade, sold with StoreKit 2:

| Plan | Product ID | Price |
|---|---|---|
| Yearly, with a 7-day free trial | `com.example.snorelog.pro.yearly` | $24.99 |
| Monthly | `com.example.snorelog.pro.monthly` | $3.99 |
| Lifetime (one-time purchase) | `com.example.snorelog.pro.lifetime` | $49.99 |

The first Pro feature is a **PDF report for your doctor** (History > PDF report, or Settings): an overview of the period (average snore score, snoring time, quiet nights, trend), a chart of nightly scores, how tags line up with scores, and a night-by-night log. It describes recorded nights only and carries a "not a medical device" footer on every page.

- Code: `SnoreLog/Pro/` (`ProStore` for purchases, `PaywallView`, `DoctorReport` for the numbers, `DoctorReportPDF` for drawing).
- Local testing: `SnoreLogTests/SnoreLog.storekit` holds the three products. The shared scheme points Xcode at it, so purchases work in the simulator without App Store Connect (if Xcode doesn't pick it up, choose it under Product > Scheme > Edit Scheme > Run > Options > StoreKit Configuration). The unit tests buy against the same file with `SKTestSession`.
- `-proUnlocked` as a launch argument turns Pro on for screenshots.

**Before selling:** create the same three products in App Store Connect (subscription group "SnoreLog Pro", the yearly plan with a 1-week free-trial introductory offer), sign the Paid Apps Agreement, enroll in the App Store Small Business Program (15% commission), change the `com.example.snorelog` prefix in `ProProducts` and the `.storekit` file to match your bundle ID, and set `AppLinks.privacyPolicy` to a hosted privacy policy. Keep marketing free of medical words such as "apnea" or "diagnose".

## How it works

| Step | What happens | Where |
|---|---|---|
| Record | `AVAudioEngine` records the mic at 16 kHz mono into 10-minute AAC files. The app's background audio mode keeps it going while the screen is locked. A per-second loudness track is saved too. | `Audio/NightRecorder.swift` |
| Survive crashes | A `manifest.json` in each night's folder lists the files and loudness so far. It's saved every 5 minutes. If the app is closed mid-night, the next launch offers to analyze what was recorded. | `Audio/RecordingManifest.swift`, `AnalysisService.recoverUnfinishedNights` |
| Detect | In the morning, Apple's built-in sound classifier (SoundAnalysis, `.version1`, label `snoring`) scores roughly 1-second windows. Windows above the sensitivity threshold that are less than 8 s apart are merged into episodes. | `Analysis/NightAnalyzer.swift`, `Analysis/NightScoring.swift` |
| Score | Each episode's loudness compared with the room's noise floor gives Quiet, Loud or Very loud. The score is the share of the night spent snoring, weighted by loudness (0 to 100). | `NightScoring.score` |
| Clips | The 30 most notable episodes keep a clip of up to 20 s. Full recordings are deleted afterwards unless "Keep full recordings" is on. | `ClipExporter` |
| Compare | Each report compares the night with the analyzed night before it (score, snoring time, share of the night, loud episodes) and lists what changed: tags added or dropped, and bedtime or night length. Each tag is marked as pointing louder or quieter, from the person's own history once a tag has 2+ nights, otherwise from common knowledge. Tags can be edited after the fact. | `Analysis/NightComparison.swift`, `Views/NightComparisonView.swift` |
| Your day | Optional, off by default (Settings > Your day). Reads workouts (strength training separately), steps, water, caffeine and alcohol from Apple Health for the day before each night, from midnight to bedtime (bedtimes before 6 AM count toward the day before). Readings become tags with the same names as the manual "How was your day?" tags (Exercise, Strength training, Active day, Low water, Late caffeine, Alcohol), so they feed the comparison and History alongside manual tags. Read-only, nothing is written to Health, and nothing leaves the phone. Turning it off deletes the imported readings. | `Health/HealthImporter.swift`, `Analysis/DaytimeActivity.swift` |
| Store | SwiftData for nights and episodes, Swift Charts for the graphs. | `Models/SleepSession.swift`, `Views/` |

**Why analysis happens in the morning, not live:** Apple's built-in classifier is reported to fail with `SNErrorCode.operationFailed` once the app is in the background, even when audio recording keeps working ([Apple forum thread](https://developer.apple.com/forums/thread/811582)). Recording all night and analyzing in the foreground avoids that and saves battery.

## Guesses to tune with real nights

These are marked in the code and are starting points, not tested values:

- Sensitivity thresholds: 0.7 / 0.5 / 0.3 confidence for Low / Medium / High.
- Episode merge gap 8 s, minimum episode 2 s.
- Intensity: Loud is 12 dB above the noise floor, Very loud is 25 dB above it.
- The score formula.
- That the built-in classifier's label is exactly `snoring`. Check this on a device if detection finds nothing: `SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications`.

## Not yet verified

I wrote this in a Linux environment with no Swift compiler, so **it has never been built**. The project file uses Xcode 16's folder-synced format. Expect a few small compile fixes on the first build. Things most likely to need attention:

- Swift 5 language mode is set on purpose to avoid strict concurrency errors.
- Resuming recording after a phone call while the screen is locked. iOS may refuse to restart the mic in the background. In that case the night's recording stops at the call.
- The "Dim screen" mode is only a black overlay. Locking the phone is better for battery.

## Before submitting to the App Store

- [ ] Replace the placeholder icon in `Assets.xcassets/AppIcon.appiconset`.
- [ ] Set your own bundle ID and team.
- [ ] App Privacy in App Store Connect: "Data Not Collected" is accurate for this version. Audio stays on the device, and recordings are excluded from backups.
- [ ] Keep the "not a medical device" wording in the description and screenshots, and make no claims about diagnosing or treating sleep apnea. That keeps it out of medical-device review (guideline 1.4.1).
- [ ] Explain the background audio use in the review notes. Reviewers check that `UIBackgroundModes: audio` is used for real recording.
- [ ] A privacy policy URL (required even when nothing is collected, and required by Apple for any app that uses HealthKit). It must say what Health data is read and that it stays on the device. A draft is in [`docs/privacy.md`](docs/privacy.md): fill in the `[DEVELOPER NAME]` and `[CONTACT EMAIL]` placeholders, host it, then put the URL in `AppLinks.privacyPolicy` (`SnoreLog/Pro/PaywallView.swift`) and in App Store Connect (App Information > Privacy Policy URL). To host it with GitHub Pages: Settings > Pages > Deploy from a branch > `main`, folder `/docs`, and the page appears at `https://<user>.github.io/snorelog/privacy`. GitHub Pages needs a public repository on a free account. If this repository stays private, copy `privacy.md` into a small public repository and turn Pages on there instead. Update the policy whenever the app starts handling data differently.
- [ ] Turn on the **HealthKit** capability for the App ID in the Apple Developer portal (the entitlement is already in `SnoreLog.entitlements`). In the review notes, say Health is optional and read-only, and where to turn it on.
- [ ] App Privacy: Health data that never leaves the device still counts as "Data Not Collected".

## Ideas for later

- A custom Core ML snore model (Create ML sound classifier) if the built-in one misses soft snoring or picks up a partner or fan.
- Apple Health: write a "sleep" sample, read sleep stages from the Watch.
- Apple Health: read heart rate and sleep stages for the night itself.
- Gentle nudges: a Watch haptic tap when loud snoring starts.
- Export or share clips, for example to show a doctor.
- A paid tier later (longer history, trends, export).
