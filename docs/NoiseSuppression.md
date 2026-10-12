# Microphone noise suppression

Sidetone uses the default quantized RNNoise model from Xiph. The menu has one
Noise suppression switch. Settings has a strength control. Suppression is off
by default. It applies to all sound profiles, before tone shaping and gain.
Processing stays on the Mac. The app does not send or save microphone audio.

## Operating limits

Own-voice monitoring combines the processed signal with sound that reaches the
ears through air and bone. Delay can cause a change in tone or an audible echo.
Execution time and signal delay are different quantities. A neural network can
finish in 0.1 ms while its analysis window and lookahead add 30 ms to the signal.

The 2025 [low latency comparison](https://arxiv.org/abs/2409.10358) evaluates
short windows, asymmetric windows, learned transforms, filter banks, and future
frame prediction under common training conditions. It finds no general benefit
from future frame prediction at equal delay. Shorter windows need more compute
to retain quality. Its hearing-device target is below 5 ms. Sidetone's RNNoise
path does not meet that target.

Noise suppression reduces sounds such as fans and keyboard clicks. It does not
identify the user. Another person's voice can pass through. Strong suppression
can remove quiet speech, breath sounds, and unvoiced consonants. A dry-signal
mix limits that loss. Suppression does not remove the latency of Bluetooth or
the input device. Use Off when minimum delay is the main requirement.

## Method constraints

The table compares deployable methods and current research. Published quality
scores from different datasets are not a direct ranking for Sidetone.

| Method | Signal delay and deployment properties | Constraint for monitoring |
|---|---|---|
| [RNNoise](https://github.com/xiph/rnnoise/tree/70f1d256acd4b34a572f999a05c87bf00b67730d) | Native C, 48 kHz, 480-sample frames, quantized recurrent network, BSD license. The model and pitch filter estimate speech gains. | Sidetone's streaming path adds 30 ms at 48 kHz. It has a small fixed memory cost and no inference service. |
| [DeepFilterNet3](https://arxiv.org/pdf/2305.08227) | 48 kHz, spectral gains plus complex deep filtering. The paper gives 20 ms windows and two lookahead frames, for 40 ms total. | Complex filtering can improve noise removal between harmonics. Its delay exceeds the RNNoise path. |
| [DPDFNet](https://github.com/ceva-ip/DPDFNet) | Published weights and ONNX/TFLite runtimes. Streaming starts after a 20 ms window. The 48 kHz models require 2.42 to 7.17 billion MACs per second. | This is a useful quality candidate, but a general inference runtime needs callback isolation and a measured scheduling budget. First-output time alone is not a full path measurement. |
| [GTCRN](https://github.com/Xiaobin-Rong/gtcrn) and [UL-UNAS](https://arxiv.org/abs/2503.00340) | Small networks target low compute. UL-UNAS uses 16 kHz audio, 32 ms windows, and 16 ms hops in its reported tests. | Low compute does not imply a short signal delay. The tested speech bandwidth is narrower than Sidetone's 48 kHz path. |
| [Deep FIR](https://arxiv.org/abs/2409.18239) | Minimum-phase filter prediction reports 0.32–1.25 ms mean algorithmic delay and 3.35 ms mean device delay for one DSP configuration. | The paper reports noise leakage during speech. The paper and demo do not supply a ready native model package for this app. |
| [µNet](https://arxiv.org/abs/2608.21155) | The 2026 paper reports 4 ms algorithmic delay and an integer model with a small memory cost. It identifies patent applications. | Research results do not establish available redistribution rights or a tested Mac runtime. Sidetone includes no µNet implementation or weights. |
| [Apple voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/) | AUVoiceIO and AVAudioEngine provide noise suppression, echo cancellation, gain control, and system microphone modes. | These APIs target voice communication. They do not specify a fixed suppression-only delay for Sidetone's independent device routes. |
| [SpeexDSP](https://www.speex.org/docs/manual/speex-manual/node4.html) and statistical spectral estimators | Small CPU cost; no trained model is required. | Noise estimation works best for steady noise. Transient noise and speech preservation need separate evaluation. A noise gate alone cannot remove noise during speech. |

The included RNNoise model provides a practical full-band neural path with
bounded callback work. It is not a claim of the best score across all methods.
The original [RNNoise paper](https://arxiv.org/abs/1709.08243) describes the
hybrid method. Exact frame delay and network dimensions come from the pinned
source and model, rather than the original paper's model.

## Signal path

```text
selected input channel -> device clock transport -> noise suppression
    -> sound profile -> monitor gain -> output ceiling -> selected output pair
```

The output callback owns the suppressor. Preparation allocates the recurrent
state and sample rate filter tables. It runs three non-silent frames to touch
the model weights before I/O starts. Model weights are constant and embedded
in the binary. There is no download during build or use.

The callback collects 480 samples at 48 kHz. RNNoise receives float samples in
16-bit PCM units. Its output is converted to normalized float. A 480-sample
adapter delay, a 480-sample overlap delay, and a 480-sample lookahead delay add
to 1440 samples, or 30 ms. Device and transport delays are separate terms.

At other output rates, two fixed-ratio Blackman-windowed sinc filters convert
to and from 48 kHz. Each filter uses 256 fractional phases with coefficient
interpolation. Tap count scales with the downsampling ratio. A bounded output
reserve covers fractional sample delivery. The latency report includes both
filter delays and this reserve. At 44.1 kHz the suppression path adds 31.03 ms;
at 96 kHz it adds 30.67 ms. The supported rate range is 8–768 kHz.

Strength blends processed audio with a dry signal delayed by the same 1440
model samples. Both signals use the same sample rate converters. Strength has
a 10 ms smoothing time constant. The default is 85 percent. For a fully removed
noise component, the remaining 15 percent dry signal is about -16.5 dB.
Zero strength retains the delayed dry path. Off restores immediate bypass.

On/off changes fade down over 2 ms, reset the model and buffers, then fade up
over 2 ms. Enabling holds silence until the delayed path has data. The callback
does not allocate, lock, access files, log, or wait for a worker. Controls and
the active latency use lock-free atomics. The existing output ceiling remains
after suppression. Invalid input cannot enter the recurrent model.

`ThirdParty/RNNoise/ORIGIN.json` contains the source revision, model archive
checksum, generated source checksum, and model transformation. The seven
optional float debug weight blocks are absent. The quantized weights are unchanged. Runtime source changes only remove
trailing whitespace. The app bundle includes the RNNoise license.

## Validation

Functional tests cover exact bypass, noise reduction, strength, finite output,
sample rate conversion, alias rejection, impulse delay, callback sizes,
transitions, reset, and concurrent controls. Settings tests cover persistence,
numeric bounds, and files without suppression keys. The C++ suite passes with
AddressSanitizer, UndefinedBehaviorSanitizer, and ThreadSanitizer. The Swift
suite has 60 passing tests. The local universal app build and signature check
pass.

On the development Apple Silicon Mac, a 10-second synthetic benchmark at
48 kHz with 64-frame blocks gives about 13 microseconds mean and 97 microseconds
at the 99th percentile. The buffer period is 1333 microseconds. These figures
measure CPU execution, not audio delay. Thread scheduling and other workloads
can cause larger maximum times. Intel hardware timing is not measured.

A local check uses the first 20 seconds of the RNNoise author's public
[clean speech example](https://jmvalin.ca/demo/rnnoise/), with one second of
silence at each end. White noise and short clicks are added at about 10 dB SNR.
At 85 percent strength, delay-aligned SNR changes from 9.98 to 15.44 dB.
Noise-only attenuation is 16.46 dB. Clean-speech output level changes by
-0.04 dB, with 18.20 dB reconstruction SNR. This single example does not
establish perceptual quality across speakers or noise types. The reference
audio is not included in the repository.

A live check uses the built-in microphone and AirPods output, at -60 dB gain,
48 kHz, and 64-frame buffers. Two 30-second runs have no callback deadline
misses, underruns, clipping, or hardware overloads. The first run has one
transport queue overrun near startup, so the full probe reports failure. The
second run has no queue overruns. Maximum DSP time is 0.472 ms. The reported
total delay is about 247 ms, including 30 ms of suppression. A bypass comparison
cannot start because the headphones disconnect. This Bluetooth check does not
establish wired monitoring latency.

Native interface inspection is unavailable because the computer-use service
times out. Listening tests, quiet speech, competing voices, wired-device
loopback, and sustained load still require hardware validation.

The numeric live check is available through:

```sh
Scripts/probe.sh --run --input INPUT_ID --output OUTPUT_ID \
  --seconds 30 --cycles 2 --frames 64 --gain -60 --profiles --suppression
```
