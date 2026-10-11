#!/usr/bin/env bash
set -euo pipefail

# Official Linux toolchain; local installation, no root or global packages.
toolchain_root="${1:-/workspace/toolchains}"
release=swift-6.1.3-RELEASE-ubuntu24.04
archive="$toolchain_root/downloads/$release.tar.gz"
url="https://download.swift.org/swift-6.1.3-release/ubuntu2404/swift-6.1.3-RELEASE/$release.tar.gz"
key_url="https://raw.githubusercontent.com/swiftlang/swift-org-website/main/keys/all-keys.asc"
archive_sha=f19a228960e1d8174db796dcea3defe6963b588af45fa3ddf0412adbe4b7bb84
key_fingerprint=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F

mkdir -p "$toolchain_root/downloads" "$toolchain_root/gnupg" \
  "$toolchain_root/cache" "$toolchain_root/module-cache" \
  "$toolchain_root/configuration" "$toolchain_root/security"
chmod 700 "$toolchain_root/gnupg" "$toolchain_root/security"

curl --fail --location --silent --show-error --retry 2 --max-time 60 \
  "$key_url" -o "$toolchain_root/downloads/swift-all-keys.asc"
gpg --homedir "$toolchain_root/gnupg" --batch --import \
  "$toolchain_root/downloads/swift-all-keys.asc"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --show-error --retry 2 --max-time 600 \
    "$url" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
curl --fail --location --silent --show-error --retry 2 --max-time 60 \
  "$url.sig" -o "$archive.sig"
printf '%s  %s\n' "$archive_sha" "$archive" | sha256sum --check --strict
gpg --homedir "$toolchain_root/gnupg" --batch --status-fd 1 \
  --verify "$archive.sig" "$archive" \
  > "$toolchain_root/downloads/swift-signature-verification.txt" 2>&1
cat "$toolchain_root/downloads/swift-signature-verification.txt"
rg --quiet "^\[GNUPG:\] VALIDSIG $key_fingerprint " \
  "$toolchain_root/downloads/swift-signature-verification.txt"

# This old release was signed on 2025-09-05 while its official key was valid.
# GPG currently reports its later expiration. Never disable signature or TLS checks.
if [[ ! -x "$toolchain_root/$release/usr/bin/swift" ]]; then
  tar -xzf "$archive" -C "$toolchain_root"
fi
"$toolchain_root/$release/usr/bin/swift" --version
