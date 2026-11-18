#!/bin/sh
# Build the Flatpak. Pass --install to also install it for the current user.
# Needs org.gnome.Sdk//51 and either flatpak-builder or org.flatpak.Builder.
set -e
cd "$(dirname "$0")/.."

if command -v flatpak-builder >/dev/null 2>&1; then
    builder=flatpak-builder
else
    builder="flatpak run org.flatpak.Builder"
fi

mkdir -p build/fltpk
$builder build/fltpk/ com.github.Darazaki.Spedread.json --user --force-clean --keep-build-dirs "$@"
