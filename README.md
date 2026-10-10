# Sidetone

Native macOS app for low-latency, real-time microphone monitoring through headphones.

Sidetone lives in the menu bar. Select a microphone and headphones, set the volume, and turn monitoring on. Choose Direct, Natural, or Voice sound. Audio stays on your Mac.

## Install

Download the app from [GitHub Releases](https://github.com/KarstenEconomou/sidetone/releases). Extract the ZIP file, move Sidetone to Applications, and open it. Allow microphone access when macOS asks.

Sidetone supports macOS 13 and later on Apple Silicon and Intel. Downloads use ad hoc signing and are not notarized. macOS can show a security warning.

Use headphones to prevent feedback.

## Build and test

Use Xcode 26 or its Command Line Tools, with Swift 6 and the macOS 26 SDK.

```sh
Scripts/build.sh
Scripts/test.sh
```

The app is in `dist/Sidetone.app`. To build for Apple Silicon and Intel:

```sh
BUILD_ARCHITECTURES='arm64 x86_64' Scripts/build.sh
```

See [Engineering](docs/Engineering.md) for the audio engine and DSP design.

## Development and releases

Work on a branch and open a pull request to `main`. Use a Conventional Commit title: `type(scope): description`. CI checks the title, version, tests, and universal app build. Use a squash merge.

`VERSION` is the app version. A breaking change uses `!` in the commit title or a `BREAKING CHANGE:` line in the commit body. Breaking changes increase the major version. Features increase the minor version. Other changes increase the patch version. The first release is `1.0.0`.

To prepare the next release, run this command from a clean `main` branch:

```sh
Scripts/release.sh
```

The script creates a version branch and pull request. Merge it after CI passes. Then run the Release workflow with that version:

```sh
gh workflow run release.yml -f version=1.0.0
```

The workflow tests the app and creates a draft GitHub release with a universal ZIP file, a SHA-256 checksum, and release notes. Review the draft and publish it on GitHub. Published versions and tags must not change.

## License

Sidetone is licensed under [GPL-3.0-only](LICENSE).

Developer: [@KarstenEconomou](https://github.com/KarstenEconomou).
