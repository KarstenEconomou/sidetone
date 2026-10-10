# Sidetone engineering design

## Build and package

Use an Apple Silicon Mac with macOS 13 or later and Swift 6 command line tools.
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
local use. Public distribution requires a Developer ID Application certificate
and a notarytool keychain profile.

```sh
SIGNING_IDENTITY='Developer ID Application: NAME (TEAM)' \
NOTARY_PROFILE='PROFILE' Scripts/distribute.sh
```

The distribution script signs the app, submits the ZIP file to Apple, attaches
the notary ticket, checks Gatekeeper, and creates `dist/Sidetone.zip`.
Credentials stay in the keychain. The script does not create credentials.

## Control and audio ownership

`Sidetone` contains the AppKit status item and the SwiftUI popover.
`SidetoneKit` contains settings, route selection, permissions, and lifecycle
control. The main actor owns the interface. An audio worker actor serializes
all C engine calls. A request number prevents a stale start request from
replacing a later stop request.

`AudioCore` owns the AUHAL units, sample buffers, DSP state, and telemetry.
The control thread creates and initializes each audio unit before it starts.
It stops and disposes the units before it releases the sample buffers.
Device listeners hold no engine pointer. They change process-wide atomic
counters. Thus, a delayed property notification cannot access a released engine.

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

## Signal processing

Direct mode applies gain and a 0.95 full-scale output ceiling. Gain has a 5 ms
smoothing time constant. Non-finite input becomes silence. Output is always
finite and bounded. The interface limits gain to -60 through 0 dB.

Natural mode adds a second-order high-pass filter and one parametric EQ band.
Voice mode uses a high-pass cutoff of at least 110 Hz, adds 3 dB to the EQ band,
and reduces 350 Hz by 2 dB. The EQ controls set frequency, gain, and Q. Filter
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

## Device and route policy

Settings use stable device UIDs. A saved device that is unavailable does not
fall back to another device. System-default selections resolve to the current
Core Audio defaults. Startup checks the expected device UIDs, output source, and jack state before
configuration and again before I/O starts. A change to the active destination
stops monitoring.
An output data-source, jack, or stereo-channel change also stops output.
The user must enable the new route.

Sleep stops the units. Recovery can resume only the same device route,
including its output source and jack state. Recovery limits gain to -18 dB.
The app starts with monitoring off. Microphone permission is requested only
when the user enables monitoring. The app has no recording or network path.

A requested hardware buffer size is bounded by the device's supported range.
The device can use another size. Diagnostics show the actual size. When the
engine stops, it restores a previous buffer size only if the current value
still equals the value it applied and the device UID is unchanged.

The optional Shift-Command-M shortcut uses a Carbon hot-key registration.
It does not require Accessibility permission. Launch at login uses
`SMAppService.mainApp`. Both options are off by default.

## Latency terms

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

## Validation results

Validation uses an Apple Silicon MacBook Pro with macOS 26.6.1 and Swift 6.3.3.
The release app builds with compiler warnings treated as errors. Its local
signature and hardened runtime pass `codesign --verify --deep --strict`.

The C++ tests pass for finite output, gain, filters, compression, profile
transitions, ring wrap, outage recovery, supported capacity, and rate conversion.
Four 90-second synthetic runs at plus and minus 100 and 1000 ppm have no buffer
underruns or overruns. The maximum queue latency is 3.92 ms. Lifecycle tests
include 1000 failed starts, repeated stops, and route-identity checks. The 24
Swift tests pass for settings, device selection, permission requests, sleep,
recovery, and stale control requests. Address, undefined-behavior, and thread
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
of 0.80 / 0.92 microseconds for Direct, 5.09 / 5.79 for Natural, and
5.13 / 6.33 for Voice. The 96-to-48 kHz transport reports 4.40 / 5.21
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

## Physical latency measurement

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
