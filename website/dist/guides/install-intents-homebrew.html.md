# Install Intents with Homebrew on Apple silicon

Canonical page: https://intents-workbench.coryparry.chatgpt.site/guides/install-intents-homebrew

## Short answer

With Homebrew already installed, run brew install --cask coryparrry/tap/intents to install Intents on Apple silicon and macOS 27 or later. The cask currently points to Intents 1.5.2. Open the app from Applications, enable Apple Intelligence, and finish its model download before trying the default on-device evaluation provider.

## Check the requirements

The cask targets Apple silicon and macOS 27+. If Homebrew is not installed, follow the [official Homebrew instructions](https://brew.sh), or use the direct disk-image download below. Do not install a package manager just to try the app if the disk image suits you.

## Install and open

```sh
brew install --cask coryparrry/tap/intents
```

Open **Intents** from Applications. Enable Apple Intelligence and allow its model to download. Follow [Getting started](/getting-started#first-evaluation) to create a small case. An ordinary on-device suite does not require Xcode.

## Upgrade an existing Homebrew installation

```sh
brew update
brew upgrade --cask --greedy coryparrry/tap/intents
```

The cask declares automatic app updates, so `--greedy` includes it in Homebrew’s upgrade check. The command installs the version currently recorded in the tap; future releases may be newer than this guide’s checked version.

## Inspect the cask before installing

```sh
brew info --cask coryparrry/tap/intents
```

The [published cask](https://github.com/coryparrry/homebrew-tap/blob/main/Casks/intents.rb) records version 1.5.2, its GitHub DMG URL, SHA-256 checksum, Apple silicon architecture, and macOS requirement. Check the [release notes and checksums](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) when investigating a version mismatch.

## Prefer the disk image?

Download the DMG, open it, drag **Intents** to **Applications**, eject the disk image, and open the app. Intents was previously Foundation Evals; [the rename guide](/compare/foundation-evals) explains old names. These instructions do not remove your existing evaluation workspace.

## Try Intents 1.5.2

[Download for macOS · v1.5.2](https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg) · [Getting started](/getting-started)

```sh
brew install --cask coryparrry/tap/intents
```

Free, MIT licensed, macOS 27+, Apple silicon. Enable Apple Intelligence and download its model for the default on-device provider. Ordinary model suites do not require Xcode.

## Sources and corrections

Facts checked 30 October 2026. [Intents release](https://github.com/coryparrry/Intents/releases/tag/v1.5.2) · [User guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Home.md) · [MCP guide](https://github.com/coryparrry/Intents/blob/v1.5.2/docs/wiki/Codex-and-MCP.md). [Report a correction](https://github.com/coryparrry/Intents/issues).

[All comparisons](/compare) · [Evaluate on a Mac](/guides/evaluate-apple-foundation-models-mac) · [Connect an agent](/guides/intents-mcp-coding-agents)

Project page: https://coryparry.dev/projects/intents
