#!/bin/sh
set -eu
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$directory/.build"
swiftc -O -framework Virtualization "$directory/PrepareVM.swift" -o "$directory/.build/prepare-browser-vm"
codesign --force --sign - --entitlements "$directory/../virtualization.entitlements" "$directory/.build/prepare-browser-vm"
codesign --verify --strict "$directory/.build/prepare-browser-vm"
