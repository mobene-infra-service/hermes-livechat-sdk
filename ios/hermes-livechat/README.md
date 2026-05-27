# Hermes LiveChat iOS Sample App

This sample app is a minimal UIKit host for manually testing the iOS SDK. The installed app name is `hermes-livechat`.

## Run

Open `hermes-livechat.xcodeproj` in Xcode, select the `hermes-livechat` target, and run on an iOS Simulator or a signed device.

The form mirrors the Android sample app:

- `baseUrl`
- `realtimeUrl`
- `appKey`
- `secretKey`
- `customerId`

Default values are defined in `hermes-livechat/SampleConfig.swift`.

| Field | Default |
|---|---|
| `baseUrl` | `https://hermes-test.financifyx.com/api` |
| `realtimeUrl` | `wss://hermes-test.financifyx.com/api/connection/websocket` |
| `appKey` | `app_019e6335c04478838ef4f9418263d279` |
| `secretKey` | `sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg` |
| `customerId` | `ios-test-user` |

The app configures `HermesLiveChat` and opens the default chat page with `startSessionOnOpen` enabled.

`secretKey` is included only to test `is_auth=1` against the test environment. Do not embed the Secret Key in a production app; production integrations should ask the customer App Backend for a short-lived `identity_token`.

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
