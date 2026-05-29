# Hermes LiveChat iOS Sample App

This sample app is a minimal UIKit host for manually testing the iOS SDK. The installed app name is `hermes-livechat`.

## Run

Open `hermes-livechat.xcodeproj` in Xcode, select the `hermes-livechat` target, and run on an iOS Simulator or a signed device.

The launch screen provides preset environment buttons for test and production.
The app info is prefilled from `hermes-livechat/SampleConfig.swift`, and the
customer ID defaults to a random `ios-demo-*` value. Use the custom config page
to manually enter:

- `baseUrl`
- `realtimeUrl`
- `appKey`
- `secretKey`

| Field | Default |
|---|---|
| `baseUrl` | `https://hermes-test.financifyx.com/api` |
| `realtimeUrl` | `wss://hermes-test.financifyx.com/api/connection/websocket` |
| `appKey` | `app_019e6335c04478838ef4f9418263d279` |
| `secretKey` | `sk_bB3QVOT8KZWex6qSU58Y196MUPHFb1WA8rBGdppA1hg` |
| `customerId` | Random `ios-demo-*` value |

The app configures `HermesLiveChat` and opens the default chat page with
`startSessionOnOpen` enabled. The SDK default chat page shows loading state while
the initial session or welcome message is fetched.

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
