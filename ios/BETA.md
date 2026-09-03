# Shipping CatchMeUp to TestFlight

Everything needed to get a build in front of testers, and what to tell them
once it's there.

---

## 1. Before the first upload

Three things are set in the repo already: the privacy manifest
(`CatchMeUp/PrivacyInfo.xcprivacy`), `ITSAppUsesNonExemptEncryption` (so the
export-compliance question doesn't appear on every upload), and version
`1.0 (1)` in `project.yml`.

Two things are **not**, because they're yours and not the repo's:

| What | Where | Note |
|---|---|---|
| Team ID | `DEVELOPMENT_TEAM` in `project.yml`, or the command line | Left blank on purpose — see below |
| Bundle IDs | `com.catchmeup.app`, `.widgets`, and the iCloud container | Must exist in your developer account, with iCloud and Push capabilities on the app ID |

The iCloud container `iCloud.com.catchmeup.app` has to be created in the
developer portal before a signed build will install, or sync silently does
nothing.

## 2. Build and upload

```bash
cd ios && xcodegen generate --spec project.yml
```

```bash
xcodebuild -project ios/CatchMeUp.xcodeproj -scheme CatchMeUp -configuration Release -archivePath build/CatchMeUp.xcarchive DEVELOPMENT_TEAM=YOURTEAMID -allowProvisioningUpdates archive
```

Then export and upload from Xcode's Organizer (Window ▸ Organizer ▸ Archives),
which handles the signing and the App Store Connect handshake.

**Bump `CURRENT_PROJECT_VERSION` for every upload.** App Store Connect rejects a
build number it has already seen, and it's the single most common wasted
twenty minutes in TestFlight.

## 3. What App Store Connect will ask for

- **Privacy policy URL** — required for external testing. The text is in the
  app under Settings ▸ Privacy; publish the same wording at a URL you control.
- **Data collection** — answer *no data collected*. There's no analytics SDK,
  no crash reporter, no account, and no identifier. Transcripts sent to a
  provider are sent by the user, with the user's own key, to a service the user
  chose — that isn't collection by this app.
- **Encryption** — already answered in `Info.plist` (standard HTTPS only).
- **Sign-in** — there is none; say so, and don't attach a demo account.

## 4. What to put in the tester notes

> CatchMeUp turns a recorded lecture or meeting into notes, then turns the notes
> into questions and brings them back on a schedule.
>
> **Start here:** Settings ▸ Load two sample recaps, if you don't want to record
> anything yet. Otherwise hit Record, talk for two minutes, and watch it work.
>
> **What I most want to know:**
> 1. Did the notes match what was actually said?
> 2. Were the questions worth answering, or obvious/nonsense?
> 3. Did the "Before you read" warm-up feel useful or feel like a gate?
> 4. Did the daily reminder arrive when it should, and stay quiet when nothing
>    was due?
> 5. Anything that felt slow, stuck, or made you close the app.
>
> **Sending a report:** Settings ▸ Send feedback pre-fills your version, device
> and library size — never your notes or transcripts. Paste it into TestFlight
> feedback along with what happened.

## 5. Known limits, worth saying out loud

- **Demo mode writes sample notes, not real ones.** A first-run user who
  records something and gets a recap about a billing migration hasn't found a
  bug — they're in Demo mode. Switch to Apple's on-device model or an API key.
- **Transcription is Apple Speech, on device.** Accented speech, crosstalk and
  bad room audio degrade it, and everything downstream inherits that. iOS 26
  uses `SpeechAnalyzer`, which is built for long files; older versions fall back
  to `SFSpeechRecognizer`. Neither runs in the Simulator — that is Apple's
  limitation, not a build problem, so test transcription on a real device.
- **Offline grading is keyword matching.** A right answer in unusual words can
  be marked "not quite". Model grading (Settings ▸ Study) fixes most of it and
  needs an API key.
- **iCloud sync is file-based.** Two devices editing the same recap while both
  are offline resolve last-writer-wins per file.
- **iPad runs the iPhone layout.** It works; it isn't designed for the space.

## 6. Before each new build

```bash
cd ios && xcodegen generate --spec project.yml && xcodebuild -project CatchMeUp.xcodeproj -scheme CatchMeUp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Run the tests, bump the build number, archive. New Swift files need
`xcodegen generate` before they exist as far as the build is concerned —
including test files.
