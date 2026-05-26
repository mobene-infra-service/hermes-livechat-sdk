# Hermes LiveChat iOS Sample App

This sample app is a minimal UIKit host for manually testing the iOS SDK. The installed app name is `hermes-livechat`.

## Run

Open `hermes-livechat.xcodeproj` in Xcode, select the `hermes-livechat` target, and run on an iOS Simulator or a signed device.

The form mirrors the Android sample app:

- `baseUrl`
- `realtimeUrl`
- `appKey`
- `customerId`

Default values are defined in `hermes-livechat/SampleConfig.swift`.

The app configures `HermesLiveChat` and opens the default chat page with `startSessionOnOpen` enabled.

## Command Line Build

```bash
xcodebuild \
  -project hermes-livechat.xcodeproj \
  -target hermes-livechat \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Device IPA packaging requires an Apple development team and signing profile.
