# Yandex translation

## Implementation

`YandexTranslationClient` uses NSURLSession and CommonCrypto to implement the
session, protobuf and request signing flow from FOSWLY/vot.js 3.1.4. No server,
JavaScript runtime or extra build dependency is required. Requests are cancelled
when the user disables translation or changes videos. A generation counter drops
late replies. HTTP transient errors are retried at most twice per request. Overall
translation waiting is limited to 15 minutes; partial tracks wait for completion.
Audio-requested replies use the same empty-audio fallback as vot.js; videos where
Yandex cannot obtain the source audio can still fail. No user media is uploaded.

`TranslationControls` registers through the existing overlay host. It reads the
active YTPlayerViewController's currentVideoMediaTime and YTSingleVideoController's
volume and mediaPlayer.rate. These selectors and their method
signatures were checked in the decrypted YouTube 21.38.3 binary. Unsupported
players fail with a notice; no private playback-state integer values are assumed.
The existing playback-time hook emits notifications even with SponsorBlock off.

The audio clock is checked every 200ms and on playback-time notifications. A drift
above 350ms triggers a seek. Lack of video clock progress pauses audio within
500ms, including when the user pauses. Playback does not depend on YouTube's
private attemptingToPlay flag. The enabled notice appears only after AVPlayer
reports actual playback. Source volume is restored while
waiting, when cancelled, and on every exit path. No audio session category or
system volume is changed. Speeds outside 0.5x–2x stop translation.

This first build is experimental. Foreground playback only; entering background,
PiP, Cast/AirPlay, an ad, another video, or losing headphones stops translation.
Account-required translations are reported as unsupported. Source language uses
Yandex detection with an English hint and forceSourceLang=false.

## Automated checks

On macOS with Xcode command line tools:

```sh
bash Scripts/test-translation.sh
python3 -m unittest discover -s Tests -v
```

The native check exercises malformed protobuf, HMAC, URL restrictions, successful
translation, waiting/partial replies, audio fallback, HTTP failures/retry, deadline,
cancellation followed by a new video, and clock behavior. It uses NSURLProtocol
fixtures and makes no live network requests. GitHub Actions runs it on macOS.

## Before treating a build as stable

On a physical iPhone with YouTube 21.38.3:

1. Open a regular English video and tap the speech-bubble button. Confirm Russian
   audio starts at the current position and the original track is quieter.
2. Pause/resume, seek in both directions, and try 0.5x, 1x and 2x. Enable SponsorBlock
   and verify translation follows a skipped segment.
3. Repeat with SponsorBlock and speed controls disabled.
4. Cancel while preparing, immediately open another video, and request its translation.
   No audio or error from the previous request should appear.
5. Disconnect the network, enter PiP/background, remove headphones, and turn off
   the translation setting. Original volume must always return.
6. Check portrait/fullscreen layout, VoiceOver labels, and hiding the button.

Successful compilation and API requests do not establish on-device synchronization.
