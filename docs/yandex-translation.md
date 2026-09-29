# Yandex translation

## Implementation

`YandexTranslationClient` uses NSURLSession and CommonCrypto to implement the
session, protobuf and request signing flow from FOSWLY/vot.js 3.1.4. No server,
JavaScript runtime or extra build dependency is required. Requests are cancelled
when the user disables translation or changes videos. A generation counter drops
late replies. HTTP transient errors are retried at most twice per request. Overall
translation waiting is limited to 15 minutes; partial tracks wait for completion.
Audio-requested replies download the video's source audio through the existing
SABR downloader and upload it to Yandex in 5,295,308-byte chunks. No empty-audio
fallback is sent. The download is capped at 256 MiB and 180 seconds; cancellation
stops it and scratch files are removed. A cached failure is retried once with
bypassCache before reporting the server's error. Only the selected video's audio
is uploaded; local library files are not used.

`TranslationControls` registers through the existing overlay host. It reads the
active YTPlayerViewController's currentVideoMediaTime and YTSingleVideoController's
volume and mediaPlayer.rate. These selectors and their method
signatures were checked in the decrypted YouTube 21.38.3 binary. Unsupported
players fail with a notice; no private playback-state integer values are assumed.
The existing playback-time hook emits notifications even with SponsorBlock off.

The audio clock is checked every 200ms and on playback-time notifications. A drift
above max(2 seconds, playback rate in seconds) triggers a seek, with an 800ms
settling period. Audio holds the selected video rate instead of changing pitch
processing speed every tick. TimeDomain restores the voice algorithm used before
yandex.10. Automatic buffer waiting is respected using setRate rather than
playImmediatelyAtRate, and drift seeks are deferred while buffering.
Lack of video clock progress pauses audio within
500ms as a buffering fallback; explicit play/pause commands are hooked for immediate
pause handling. Private playback-intent flags are not used. The
translation follows YouTube's current playback rate. The enabled notice appears
only after AVPlayer reports actual playback.
Source volume stays at the chosen level during pauses, seeks and buffering after
translation has started, and is restored on stop/error/end. No audio session
category or system volume is changed. Supported speeds are 0.25x–5x.

Holding the translation button opens two native volume sliders and the optional
automatic-translation toggle (off by default). Changes apply
immediately while the original is ducked. Muting the original track does not mute
the translation. Overlay refreshes reuse a single hold recognizer per button.

The last 200 video choices retain explicit on/off and both volume levels. Explicit
off overrides automatic translation. The selected audio format's track ID, tags
and track name are checked first, followed by the overlay's selected audio track.
Russian playback prevents auto start, hides the button and stops active Yandex
translation. YouTube retains control of audio track selection. When the selected
track has no language metadata, original audio xtags and automatic captions provide
a fallback. Unknown language leaves the button visible and only a remembered manual
enable can start automatically. Metadata is refreshed once per second of playback
and on audioTrackDidChange:source:, including after the initial startup window.

TranslationStore downloads a low-priority cache copy only after playback starts and
AVPlayer reports it is likely to keep up. It never swaps out the running player.
Completed audio is reused on later visits, expires after 14 days, and is bounded
to 256 MiB per file / 512 MiB total. Leaving translation cancels unfinished caching.
Redirects, non-audio responses and partial downloads are not saved. Failed cached
playback removes that file so the next request fetches a fresh translation.
Preparation notices distinguish source download, upload, service wait and audio load.

This build is experimental. Background playback relies on YouTube background audio
being enabled and iOS keeping the audio session active. PiP uses the active
AVPlayer's time, rate and original volume. Cast/AirPlay, an ad,
another video, or losing headphones stops translation.
Account-required translations are reported as unsupported. Source language uses
Yandex detection with an English hint and forceSourceLang=false.

## Automated checks

On macOS with Xcode command line tools:

```sh
bash Scripts/test-translation.sh
python3 -m unittest discover -s Tests -v
```

The native check exercises malformed protobuf, HMAC, URL restrictions, successful
translation, waiting/partial replies, single/multipart audio uploads, cached failure
retry, cancellation during source download, HTTP failures/retry, deadline,
cancellation followed by a new video, and clock behavior. It uses NSURLProtocol
fixtures and makes no live network requests. GitHub Actions runs it on macOS.

## Before treating a build as stable

On a physical iPhone with YouTube 21.38.3:

1. Open a regular English video and tap the speech-bubble button. Confirm Russian
   audio starts at the current position and the original track is quieter.
2. Pause/resume, seek in both directions, and try 0.5x, 1x, 2x, 3x and 5x. Enable SponsorBlock
   and verify translation follows a skipped segment.
3. Repeat with SponsorBlock and speed controls disabled.
4. Cancel while preparing, immediately open another video, and request its translation.
   No audio or error from the previous request should appear.
5. Enter PiP, pause/resume there, and return to YouTube. Check synchronization.
   Disconnect the network, remove headphones, and turn off the translation setting.
   Original volume must return when translation stops.
6. Check portrait/fullscreen layout, VoiceOver labels, and hiding the button.

Successful compilation and API requests do not establish on-device synchronization.
