# Sidetone engineering design

## Audio features

Microphone monitoring plays live microphone audio. Keyboard sounds play
recorded key presses and releases. Each feature has its own engine, state model,
settings, on/off switch, and volume. Both features are off at launch and can run
separately or together. Audio stays on the Mac. Typed text is not read or stored.

One stored output selection supplies both engines. Settings use stable device
UIDs. An unavailable saved device does not fall back to another device.
System-default selections resolve to the current Core Audio defaults.
The menu shows output selection above the microphone and keyboard controls.

## Keyboard sounds

Keyboard sounds use a separate output unit and do not open an input device.

The app bundles recorded Alps SKCM Blue, Topre, Gateron Ink Black,
IBM Buckling Spring, and Drop Holy Panda sounds by Thomas Lai from
[Thock sound packs](https://github.com/kamillobinski/thock-soundpacks).
Each pack has its source revision, archive SHA-256, configuration, and MIT
license notice in `Sources/SidetoneKit/Resources/KeyboardSounds`. All packs
contain key-press and key-release recordings. Settings control release sounds,
modifier keys, key repeat, and recording variation.

A worker actor decodes and filters the recordings before it starts output.
Swift and Accelerate apply spectral noise reduction at the recording's sample
rate. The filter uses a Hann window of approximately 12 ms with 75% overlap.
Quiet full windows supply the noise estimate. Smoothed frequency gains reduce
noise by up to 18 dB. High-energy windows keep the key impact. Recordings that
are too short or have no clear quiet section bypass the filter. A
[spectral flatness](https://www.mathworks.com/help/signal/ref/spectralflatness.html)
check excludes DC and Nyquist and is limited to 12 kHz. It rejects tonal noise
estimates below a threshold of 0.01. The band must contain at least 0.01% of the
total energy. This keeps clean resonant decays, including those above the band.
Both analysis and reconstruction use the full spectrum energy, with separate
weights for DC and Nyquist. Stereo channels use the same gains. Invalid sample
values are rejected before filtering. The bundled files are not changed.

AVAudioConverter uses maximum quality and the mastering
algorithm to prepare each recording at the output rate. Conversion drains
through the end of the file. The prepared buffers stay in memory until the
output rate changes. No file access, filtering, or sample conversion occurs on
a key event.
The loader removes leading silence and keeps 0.5 ms before the first sample
above 1% of peak or −66 dBFS, whichever is higher. A linear fade brings the
last 2 ms to zero. The fade is limited to one quarter of the recording length.

Key codes index prepared tables for press and release recordings. Unmapped
keys use the default recordings. The event listener does not read event text.
The sample variation option avoids the previous recording within each group,
including when press and release events alternate. Held keys use two 64-bit
masks. Volume changes keep the held-key state.
Modifier transitions use flags captured in each event, with separate masks for
left and right keys. Caps Lock uses its physical key state, not its lock state.

A passive session event tap runs on a dedicated thread with an interactive
quality of service. It submits sounds directly to the C++ queue, without a
main-actor task or audio-worker task for each event. Short control locks protect
event order, settings, and the lifetime of the playback handle. These locks do
not protect device calls, file access, or conversion. The worker closes playback
before it stops output or loads samples. The render callback takes no locks.

Input Monitoring access is requested when the user turns on keyboard sounds.
Secure input blocks key sounds and clears held-key state. Sleep stops the event
tap and output unit. Device polling detects permission and output changes.
Failed output starts use bounded retry delays. Device notifications invalidate
output after rate, buffer size, channel, connection, or audio-service changes.
A callback watchdog also detects an output that stops calling back.
While enabled, keyboard sounds follow the selected output, including changes
to the system default. An unavailable saved output pauses playback.

The C++ render callback reads a fixed queue of 256 sample indices. It mixes up
to 64 overlapping recordings. Only active voices are processed. Prepared
recordings use contiguous sample reads at the output rate; linear interpolation
supports a rate change during device setup. Volume has a 5 ms time constant.
A peak limit bounds each output channel to 0.98. The callback has no allocation,
file access, or Swift calls. Extra events are dropped when the queue or voice
pool is full. Queued sounds older than 100 ms are dropped before playback.

Output uses the selected device's sample rate, buffer size, and preferred
stereo channels. It does not change the device buffer size. Queue wait measures
submission to the render callback. It excludes the event tap, hardware buffer,
output device, and Bluetooth delay. It is not a key-to-ear latency measurement.
Diagnostics show callback time, queue wait, callback overruns, peak voice count,
dropped sounds, and protected frames. Counts reset when output starts.

`Scripts/benchmark.sh` measures 0, 1, 8, and 64 voices with 32-, 128-, and
512-frame blocks at 44.1, 48, 96, and 192 kHz. The benchmark uses prepared buffers
and excludes device I/O. `Scripts/test.sh` checks all 61 bundled files at six
rates from 8 to 192 kHz, press and release coverage, sample variation, key order
while the main thread waits, queued modifier transitions, queue saturation,
concurrent queue use, stale sounds, tail fades, and lifecycle rules.
Noise-reduction tests check hiss removal, impact timing and level, clean resonant
decays, short sounds, silence, stereo balance, invalid samples, and the bundled
Topre and Holy Panda recordings.

An Apple Silicon run with `-O3`, 48 kHz, and 128-frame blocks gives these
render times. Each row uses 12,000 measured calls after warm-up. The callback
budget at this rate and block size is 2,666.7 µs. These are mixer CPU times.

| Active voices | Mean | 99th percentile |
| --- | ---: | ---: |
| 0 | 0.020 µs | 0.042 µs |
| 1 | 0.565 µs | 0.625 µs |
| 8 | 0.713 µs | 0.750 µs |
| 64 | 1.827 µs | 1.959 µs |

```sh
SIDETONE_KEYBOARD_LIVE_TEST=1 build/tests/keyboard-engine-tests
```

The optional live check sends silence to the default output. It opens no
microphone and changes no device settings.
Hardware playback and key-to-ear latency remain unverified.

## Build and package

Use a Mac with macOS 13 or later and Xcode 26 or its command line tools.
The build requires Swift 6 and the macOS 26 SDK.
The Swift Testing suite requires macOS 14 or later. The test script locates the
Testing framework in the command line tools when full Xcode is not selected.
The project has no external packages.

```sh
Scripts/build.sh
open dist/Sidetone.app
Scripts/test.sh
Scripts/benchmark.sh
```

The build script creates a standalone app with a local code signature and the
hardened runtime. The only entitlement is audio input. This signature supports
local use. GitHub release downloads use ad hoc signing and are not notarized.
A notarized build requires a Developer ID Application certificate and a
notarytool keychain profile.
The app and probe scripts use one bundle function. It signs and checks a staged
bundle before it replaces the destination. `CONFIGURATION` selects the build
configuration. Its default is `release`. `BUILD_ARCHITECTURES` selects `arm64`,
`x86_64`, or both. Its default is the host architecture. `VERSION` sets the app
version. `BUILD_NUMBER` sets the bundle build number; its default is 1.
The bundle contains the GPL-3.0 license text and the sound pack MIT notices.

```sh
SIGNING_IDENTITY='Developer ID Application: NAME (TEAM)' \
NOTARY_PROFILE='PROFILE' Scripts/distribute.sh
```

The distribution script signs the app, submits the ZIP file to Apple, attaches
the notary ticket, checks Gatekeeper, and creates
`dist/Sidetone-VERSION-macos-universal.zip` with a SHA-256 checksum file.
Credentials stay in the keychain. The script does not create credentials.

## Control and audio ownership

`Sidetone` contains the AppKit status item and the SwiftUI popover.
`SidetoneKit` contains settings, route selection, permissions, and lifecycle
control. The main actor owns the interface. Each engine has a worker actor
that serializes device control. Keyboard events submit sounds directly to the
playback queue. Each start or stop request contains an immutable route and
settings snapshot. A request number prevents a stale start request from
replacing a later stop request. A separate parameter number prevents stale
gain or filter settings from replacing later settings.

`AudioCore` owns the AUHAL units, sample buffers, DSP state, and telemetry.
The control thread creates and initializes each audio unit before it starts.
It stops and disposes the units before it releases the sample buffers.
The engine destructor performs the same cleanup. DSP and transport functions
use `std::span` to read or write caller-owned buffers.
Device listeners hold no engine pointer. They change process-wide atomic
counters. Thus, a delayed property notification cannot access a released engine.

### Microphone audio path

A device that has both input and output uses one full-duplex AUHAL unit. Its
output callback reads the input for that cycle and processes it directly.
There is no software ring delay on this path.

Separate input and output devices use two AUHAL units at their native sample
rates. The input callback is the single producer of a mono ring buffer. The
output callback is the single consumer. It resamples to the output clock.
Acquire/release operations protect sample ownership. Only the consumer can
remove samples. Only the producer can add samples. Reset requires stopped I/O.

AUHAL converts each device format to noninterleaved 32-bit float at the native
rate. The selected microphone channel feeds the output device's preferred
stereo pair. All other output channels are silent. Mono output is supported.
The engine bounds its channel count and callback capacity before allocation.
An oversized callback produces silence and requests a restart.

The callbacks use preallocated buffers and lock-free scalar atomics. They do
not allocate, log, access files, call Swift, or wait for another thread.
Core Audio owns their scheduling. There is no additional audio worker thread
that needs to join an Audio Workgroup.

## Microphone signal processing

Direct mode applies gain and a 0.95 full-scale output ceiling. Gain has a 5 ms
smoothing time constant. Non-finite input becomes silence. Output is always
finite and bounded. The interface limits gain to -60 through 0 dB.

Natural mode adds a second-order high-pass filter and one parametric EQ band.
Voice mode uses a high-pass cutoff of at least 110 Hz, adds 3 dB to the EQ band,
and reduces 350 Hz by 2 dB. The EQ controls set frequency, gain, and Q.
The supported Q range is 0.2 through 5.0. Filter
coefficients follow the [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/).
The coefficient calculation limits frequency to 45 percent of the current
sample rate. The stored frequency remains intact across rate changes.

Optional compression has an 8 ms attack and a 120 ms release. Natural mode
uses a -18 dB threshold and a 1.5:1 ratio. Voice mode uses -20 dB and 2.5:1.
There is no makeup gain or lookahead. Profile weights, EQ coefficients, and
compression enable state use 10 ms smoothing. Direct mode stops filter work
when the transition is complete.

The control writer calculates filter coefficients and publishes atomic scalar
values with a revision counter. The callback reads a complete parameter set
or keeps its last set. It never spins to wait for the writer. Prepare and
parameter writes use the same serialized control owner.

The separate-device transport uses a Blackman-windowed sinc filter with 256
fractional phases. Coefficients interpolate between adjacent phases. Tap count
is 32 times the input/output rate ratio rounded up, with a minimum of 32.
Filter storage is allocated before audio starts. The group delay is
`(tapCount / 2 - 1) / inputRate` seconds.

The clock controller changes the consumption ratio from mean queue occupancy.
It bounds correction to 3000 ppm and limits the correction slew. The queue
keeps a 2 ms reserve while the controller acquires clock drift. Startup removes
stale excess audio. A severe timing disturbance bounds the queue again and
fades through silence. Queue discard has constant time. The ring holds at most
131072 mono samples. Unsupported combinations of rate and buffer size fail
before audio starts.

## Microphone route policy

Startup checks the expected device UIDs, output source,
jack state, and effective output channel pair before configuration and again
before I/O starts. The effective pair uses the device's valid preferred stereo
channels. Otherwise, it uses the first two channels, or one channel for mono.
A change to the active destination stops monitoring.
An output data-source, jack, or stereo-channel change also stops output.
The user must enable the new route.

Sleep stops the units. Each automatic restart requires the same saved device
route, including its output source, jack state, and output channel pair.
This check also applies to buffer and input-channel changes while monitoring.
Recovery limits gain to -18 dB.
The app starts with monitoring off. Microphone permission is requested only
when the user enables monitoring. The app has no recording or network path.

A requested hardware buffer size is bounded by the device's supported range.
The device can use another size. Diagnostics show the actual size. When the
engine stops, it restores a previous buffer size only if the current value
still equals the value it applied and the device UID is unchanged.

The optional Shift-Command-M shortcut controls microphone monitoring through
a Carbon hot-key registration.
It does not require Accessibility permission. Launch at login uses
`SMAppService.mainApp`. Both options are off by default.

## Microphone latency terms

- Buffer duration is frames divided by sample rate. It is not end-to-end latency.
- The device path includes the reported device latency, stream latency, and
  safety offset. It excludes the callback buffer duration.
- Queue latency describes audio held in the transport queue.
- Resampler latency is the filter's group delay.
- The displayed estimate adds the two device paths, both buffer durations,
  queue latency, and resampler latency. It is not a physical measurement.
- Callback and DSP times measure execution time with the monotonic host clock.
  They are not audio propagation time. Callback overruns count execution that
  exceeds one buffer period. Hardware overloads count Core Audio overload
  notifications. These counters do not prove that every device met its deadline.
- Clock correction is the applied resampling ratio adjustment. It is not an
  independent measurement of hardware clock drift.

Some device drivers report incomplete latency data. A physical loopback
measurement is required to verify microphone-to-headphone latency.

## Microphone validation results

Validation uses an Apple Silicon MacBook Pro with macOS 26.6.1 and Swift 6.3.3.
The release app builds with compiler warnings treated as errors. Its local
signature and hardened runtime pass `codesign --verify --deep --strict`.

The C++ tests pass for finite output, gain, filters, compression, profile
transitions, ring wrap, outage recovery, supported capacity, and rate conversion.
Four 90-second synthetic runs at plus and minus 100 and 1000 ppm have no buffer
underruns or overruns. The maximum queue latency is 3.92 ms. Lifecycle tests
include 1000 failed starts, repeated stops, and route-identity checks.
Swift tests pass for settings, device selection, permission requests, sleep,
recovery, and stale control requests. Route tests cover a configuration change
during a pending poll and an output-pair change during sleep or disconnection.
Address, undefined-behavior, and thread
sanitizer runs report no defects.

The hardware route is MacBook Pro Microphone to External Headphones at 48 kHz.
The probe uses -60 dB gain and changes profiles during each run. It saves only
numeric diagnostics.

| Test | Result |
|---|---|
| Two 300-second runs, 64-frame buffers | No underruns, overruns, clipping, callback overruns, or restart requests |
| Maximum callback execution time in that run | 0.0162 ms |
| Maximum DSP execution time in that run | 0.0076 ms |
| Estimated latency in that run | 58.92 to 60.58 ms; about 60.2 ms after startup |
| Five 3-second runs, 32-frame buffers | No buffer errors, callback overruns, or hardware overload notifications |
| Estimated latency with 32-frame buffers | 58.52 to 58.73 ms |
| Five-second private aggregate test | 3761 paired callbacks, no overloads, no software queue or resampler delay |

The input device path reports 51.02 ms. The output device path reports 3.54 ms.
Thus, this device pair cannot meet a 10 ms estimate. These values are device
reports, not physical loopback measurements. The 10-minute log does not include
the hardware-overload counter.

At 128 frames and 48 kHz, the DSP benchmark reports mean / 99th-percentile times
of 1.61 / 2.29 microseconds for Direct, 5.08 / 7.71 for Natural, and
4.60 / 4.83 for Voice. The 96-to-48 kHz transport reports 3.94 / 4.67
microseconds. These isolated timings do not measure end-to-end latency.

Live interface checks cover microphone permission, meters, profiles, gain,
EQ values, default-route stop, settings after relaunch, shutdown, and login-item
registration. An idle process sample reports 0.0 percent CPU and about 76 MiB
resident memory. This sample does not establish sustained CPU use or leak rate.
Global shortcut registration succeeds. The computer-use key command does not
toggle monitoring. A physical Shift-Command-M key press remains unverified.

Physical loopback, listening tests, USB clock pairs, physical sleep and wake,
an hour under load, and login after a system restart require the hardware
procedure below. Instruments is not available with the selected command line
tools. Public distribution is not verified because this environment has no
Developer ID certificate or notary profile.

## Hardware integration procedure

### Microphone monitoring

List current device IDs. IDs can change when a device reconnects.

```sh
Scripts/probe.sh
```

Use the microphone ID and the wired headphone ID from that output. The probe
requires explicit IDs. It starts at -60 dB and never saves audio. Its optional
log contains device details and numeric diagnostics.

```sh
Scripts/probe.sh --run --input INPUT_ID --output OUTPUT_ID \
  --seconds 60 --cycles 5 --frames 64 --gain -60 --profiles \
  --log build/hardware-test.log
```

To test the single-unit path with this Mac's separate built-in devices, use a
private aggregate. The test removes it on exit and does not change defaults.
This test requires an input-only device and an output-only device.

```sh
Scripts/aggregate-probe.sh INPUT_ID OUTPUT_ID 10 64
```

To check memory and thread access, run the C++ tests with a sanitizer:

```sh
SANITIZER=address,undefined Scripts/audio-tests.sh
SANITIZER=thread Scripts/audio-tests.sh
```

For a prolonged run, use `--seconds 3600 --cycles 1`. Repeat with 32, 128, and
256 frames. Test a same-device duplex interface and a route with separate
USB input and output clocks. Use Audio MIDI Setup to test different native
sample rates. The engine must remain finite, keep queue latency bounded, and
recover from timing disturbances. Inspect all counters; a successful startup
alone does not prove stable operation.

Test the app with headphones at a low hardware volume:

1. Open the menu. Select the input and output. Enable monitoring. Verify that
   speech is audible in both ears. Check gain throughout its range.
2. Switch profiles while speaking. Adjust the filter, EQ, and compression.
   Listen for clicks, unstable tones, or a sudden gain increase.
3. Unplug the selected device. Verify that output stops. Reconnect it. The same
   saved route can resume at reduced gain. A changed output must remain off.
4. Change the system default output. Check that no new destination plays audio
   until it is enabled. Remove a headphone plug from a shared output device.
5. Sleep and wake the Mac. Verify the route before and after sleep. A changed
   destination must remain off. Check recovery after a sample-rate change.
6. Quit and reopen the app. Check the stored device, gain, profile, and advanced
   controls. Monitoring must be off. Test denied microphone permission in a
   separate macOS test account, then grant it and retry.
7. Enable the optional shortcut. Use Shift-Command-M in another app. Disable
   the shortcut and check that it no longer controls monitoring.
8. Test launch at login from a stable app location, such as `/Applications`.
   Check both enabled and disabled states in Login Items.
9. Run a CPU load while monitoring for at least one hour. Check memory growth,
   queue growth, underruns, overruns, and callback timing. Keep external devices
   connected during this test.

### Keyboard sounds

1. Enable keyboard sounds with microphone monitoring off. Check Input
   Monitoring access. Test press and release sounds for each sound pack.
2. Test left and right modifiers together, Caps Lock, held keys, and rapid
   typing. Check release sounds, modifier keys, key repeat, and recording
   variation with each option on and off.
3. Enable both features. Check separate volumes and the shared output.
   Test output changes, disconnection, sleep, and wake. Check that secure input
   pauses keyboard sounds and that both features are off after relaunch.
4. Type under CPU load. Listen for missed or delayed sounds. Check callback
   overruns, queue wait, and dropped sounds in Diagnostics.

## Microphone latency measurement

Use an audio interface with two measurement inputs and a safe line-level
splitter. Do not connect a headphone output directly to an unprotected
microphone input.

1. Set Direct mode and a low monitor gain. Disable interface direct monitoring.
2. Feed a short electrical pulse to the selected input and measurement channel
   A at the same time. Feed Sidetone's selected output to measurement channel B.
3. Use an external recorder or oscilloscope to acquire both channels on the
   same clock. The app does not record these signals.
4. Find the pulse onset or correlation peak in each channel. Subtract the two
   sample positions. Divide by the measurement sample rate and multiply by
   1000 for milliseconds.
5. Repeat at least 100 times. Report the median, maximum, device names, native
   rates, actual buffers, profile, and measurement interface delay.
6. Swap the two measurement cables and repeat to check channel delay bias.

For the built-in microphone, use an acoustic pulse near the microphone and a
reference microphone on measurement channel A. Include the acoustic path in
the reported result. Do not label this result as pure software latency.

## Platform references

The implementation uses these public Apple interfaces:

- [AUHAL device input and format setup](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- [Current device selection](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice)
- [Core Audio device functions](https://developer.apple.com/documentation/coreaudio/core-audio-functions)
- [Audio Workgroups](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_osworkgroup)
- [Aggregate-device drift compensation](https://developer.apple.com/documentation/coreaudio/kaudiosubdevicedriftcompensationkey)
- [Launch at login](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
- [Hardened runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Notary workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

A private aggregate device can let Core Audio correct clock drift. The current
engine uses explicit streams and a bounded queue. It does not create or change
aggregate-device membership. AUHAL supplies format conversion and native device
routing without a virtual driver. Direct HAL I/O would require format handling
for each device. Both APIs use Core Audio's device callbacks.
