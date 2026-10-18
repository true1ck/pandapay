# PandaPay Android releases with Fastlane

Fastlane is pinned in `app/android/Gemfile`, with the release lanes in
`app/android/fastlane/Fastfile`. The repository wrapper runs from
`app/android` and picks Homebrew Ruby on Apple Silicon, avoiding macOS's
incompatible system Ruby 2.6.

## One-time setup

1. Install Ruby 3.3 or newer and Bundler.
2. From the repository root, install the pinned Fastlane dependency:

   ```sh
   ./scripts/fastlane.sh install
   ```

3. Create a Google Play service account with release access to PandaPay. The
   local JSON key is stored in the ignored `app/android/keys/` directory at:

   ```text
   app/android/keys/google-play-service-account.json
   ```

   Keep this file private and never force-add it to Git. Or set
   `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` to another local path. PandaPay's Play
   Console access is limited to this app. The first app upload and Play Console
   app setup must be completed in the Console itself.

The production upload keystore is read from the existing ignored
`app/android/key.properties`; the build lane refuses to produce a production
bundle without that file.

## Release commands

Build and publish a new version to internal testing:

```sh
./scripts/fastlane.sh exec fastlane android internal build_number:12028
```

`build_number` must be a new, higher Play `versionCode`; choose it by checking
the current Play Console release. This is the only lane that publishes a
release immediately, and it targets the internal testing track.

Prepare a production-track draft for review in Play Console:

```sh
./scripts/fastlane.sh exec fastlane android production_draft build_number:12029
```

Both lanes use `scripts/build_app.sh` with PandaPay's fixed production URLs,
build a signed `prod` AAB, and skip store listing, screenshots, and release
notes so those existing Play Console values are left alone.
