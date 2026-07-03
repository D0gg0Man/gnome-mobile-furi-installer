#!/bin/bash
#
# install.sh -- build and install GNOME Shell Mobile (the "-furi" GNOME 49
# stack) on a FuriPhone FLX1 running FuriOS, replacing phosh.
#
# It builds the hybris/drmadapter graphics shims, the three GNOME Mobile
# components (mutter / gnome-shell / gnome-settings-daemon, GNOME 49 branches),
# the gdm-free PAM lock-screen helper, and wires up a systemd session that runs
# GNOME Shell on the Mali GPU via Android HWC2 -- with phosh kept as a fallback.
#
# Run as root from the repo root:   sudo ./install.sh
#
# Idempotent-ish: re-running rebuilds and reinstalls. Pass a component name to
# build only that part, e.g.  sudo ./install.sh shims   (shims|gnome|session|all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo" >&2; exit 1; }

GH=https://github.com/D0gg0Man
SRC=/var/tmp/gnome-mobile-furi-src
LIBDIR=/usr/lib/aarch64-linux-gnu
MULTIARCH=aarch64-linux-gnu
TARGET_USER="${SUDO_USER:-furios}"
TARGET_UID="$(id -u "$TARGET_USER")"
JOBS="$(nproc)"

# gcc-15 promotes a few warnings to errors that some Android/hybris sources trip.
RELAX="-Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"

say()  { echo -e "\n==== $* ====" ; }
clone() { # clone <repo> [branch]
    local repo="$1" branch="${2:-}"
    mkdir -p "$SRC"; cd "$SRC"
    if [ -d "$repo/.git" ]; then
        git -C "$repo" fetch --depth 1 origin "${branch:-HEAD}" 2>/dev/null || true
        [ -n "$branch" ] && git -C "$repo" checkout -q "$branch" 2>/dev/null || true
        git -C "$repo" reset -q --hard "origin/${branch:-HEAD}" 2>/dev/null || true
    else
        if [ -n "$branch" ]; then git clone --depth 1 -b "$branch" "$GH/$repo" "$repo"
        else git clone --depth 1 "$GH/$repo" "$repo"; fi
    fi
    cd "$SRC/$repo"
}
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

# --------------------------------------------------------------------------
toolchain() {
    say "Installing build toolchain"
    apt-get update
    apt_install git build-essential meson ninja-build pkg-config cmake \
        autoconf automake libtool ca-certificates curl
}

# --------------------------------------------------------------------------
# Phase 1 -- hybris/drmadapter graphics shims
# --------------------------------------------------------------------------
shims() {
    say "Shim deps"
    apt_install android-headers-30 libglvnd-dev libwayland-dev wayland-protocols \
        libwayland-egl-backend-dev libx11-dev libxext-dev libglib2.0-dev \
        libgbm-dev libdrm-dev libgralloc1 2>/dev/null || \
    apt_install android-headers-30 libglvnd-dev libwayland-dev wayland-protocols \
        libwayland-egl-backend-dev libx11-dev libxext-dev libglib2.0-dev \
        libgbm-dev libdrm-dev

    say "libhybris (glvnd, with drmadapter EGL integration)"
    clone libhybris
    cd "$SRC/libhybris/hybris"
    NOCONFIGURE=1 ./autogen.sh
    ./configure --enable-glvnd --enable-wayland --enable-arch=arm64 \
        --prefix=/usr --libdir="$LIBDIR"
    grep -q "WANT_GLVND_TRUE=''" config.log || { echo "ERROR: glvnd not enabled"; exit 1; }
    # tests/ trips gcc-15; build them relaxed, then the rest.
    make -C tests -j"$JOBS" CFLAGS="-g -O2 $RELAX" CXXFLAGS="-g -O2 $RELAX" || true
    make -j"$JOBS" CFLAGS="-g -O2 $RELAX" CXXFLAGS="-g -O2 $RELAX"
    make install CFLAGS="-g -O2 $RELAX" CXXFLAGS="-g -O2 $RELAX"
    # gralloc dev headers (needed by the GBM backend / shim builds below)
    cp -r "$SRC/libhybris/hybris/include/hybris/gralloc"      /usr/include/hybris/ 2>/dev/null || true
    cp -r "$SRC/libhybris/hybris/include/hybris/grallocusage" /usr/include/hybris/ 2>/dev/null || true
    ldconfig
    strings "$LIBDIR/libEGL_libhybris.so.0" | grep -q platform_gbm \
        || { echo "ERROR: libEGL_libhybris missing platform_gbm"; exit 1; }

    say "libgbm-hybris (hybris_gbm.so)"
    clone libgbm-hybris; make; make install   # installs $LIBDIR/gbm/hybris_gbm.so

    say "eglplatform-drmadapter"
    clone eglplatform-drmadapter; make; make install

    say "wayland-android-wlegl"
    clone wayland-android-wlegl; make; make install   # /usr/local/lib/wlegl_server.so

    say "libdrm-hybris (unified shim)"
    clone libdrm-hybris forky; make; make install     # $LIBDIR/libdrm-hybris.so
    ldconfig
}

# --------------------------------------------------------------------------
# Phase 2 -- GNOME Mobile (-furi) components + PAM helper
# --------------------------------------------------------------------------
gnome() {
    say "GNOME build deps"
    apt_install \
        libcups2-dev libfontconfig-dev libgcr-4-dev libgcr-3-dev libgck-1-dev \
        libgeocode-glib-dev libgweather-4-dev libgeoclue-2-dev libnm-dev libnotify-dev \
        libpulse-dev libmm-glib-dev libpolkit-gobject-1-dev libupower-glib-dev \
        libcanberra-dev libgudev-1.0-dev libwacom-dev systemd-dev libasound2-dev \
        libatk1.0-dev libcairo2-dev libcolord-dev libgles-dev libfribidi-dev \
        libglycin-2-dev libgnome-desktop-4-dev libgraphene-1.0-dev \
        gsettings-desktop-schemas-dev libgtk-3-dev libgtk-4-dev libharfbuzz-dev \
        liblcms2-dev libadwaita-1-dev libdisplay-info-dev libei-dev libeis-dev \
        libevdev-dev libinput-dev libpipewire-0.3-dev libstartup-notification0-dev \
        libsystemd-dev libudev-dev libpango1.0-dev libpixman-1-dev libsysprof-6-dev \
        libsysprof-capture-4-dev libumockdev-dev libxcb-randr0-dev libxcb-res0-dev \
        libxcomposite-dev libxcursor-dev libxdamage-dev libxfixes-dev libxi-dev \
        libxinerama-dev libxkbcommon-dev libxkbcommon-x11-dev libxkbfile-dev xkb-data \
        libxrandr-dev libxtst-dev libxau-dev xwayland python3-argcomplete xcvt \
        python3-docutils libx11-xcb-dev gobject-introspection libgirepository1.0-dev \
        libgjs-dev libgirepository-2.0-dev libgnome-autoar-0-dev libjson-glib-dev \
        libsecret-1-dev libxml2-dev libpolkit-agent-1-dev libgdk-pixbuf-2.0-dev \
        evolution-data-server-dev libecal2.0-dev libedataserver1.2-dev \
        gnome-control-center-dev libatk-bridge2.0-dev bash-completion sassc \
        libpam0g-dev gnome-settings-daemon-dev

    # No gnome-settings-daemon fork: mutter-mobile-furi builds against the stock
    # distro gnome-settings-daemon (its meson dep is just a version gate +
    # gsd-enums.h; the gsd D-Bus interfaces it needs are bundled in mutter).
    # On FuriOS power/backlight is handled by the shell + the device gsd-adapter,
    # so the stock gnome-settings-daemon is all that's required at runtime.
    # Build order: mutter first, then gnome-shell (links libmutter).
    say "mutter-mobile-furi"
    clone mutter-mobile-furi mobile-shell-devel-49
    meson setup _b --wipe --prefix=/usr --libdir="lib/$MULTIARCH" \
        -Dtests=disabled -Dcogl_tests=false -Dclutter_tests=false \
        -Dinstalled_tests=false -Ddocs=false -Dprofiler=false
    ninja -C _b; ninja -C _b install; ldconfig

    say "gnome-shell-mobile-furi"
    clone gnome-shell-mobile-furi mobile-shell-devel-49
    meson setup _b --wipe --prefix=/usr --libdir="lib/$MULTIARCH" -Dtests=false -Dman=false
    ninja -C _b; ninja -C _b install

    say "gnome-mobile-pam-helper (setuid)"
    clone gnome-mobile-pam-helper; make; make install
    glib-compile-schemas /usr/share/glib-2.0/schemas || true
}

# --------------------------------------------------------------------------
# Phase 3 -- session wiring + replace phosh
# --------------------------------------------------------------------------
session() {
    say "Installing the GNOME Mobile session"
    local S="$SCRIPT_DIR/session"

    # launcher + wrapper
    install -m 755 "$S/gnome-mali-session"          /usr/libexec/gnome-mali-session
    install -m 755 "$S/gnome-shell-session-wrapper" /usr/libexec/gnome-shell-session-wrapper
    # gnome-session session + greeter desktop entry
    install -Dm 644 "$S/gnome-mali.session"  /usr/share/gnome-session/sessions/gnome-mali.session
    install -Dm 644 "$S/gnome-mali.desktop"  /usr/share/wayland-sessions/gnome-mali.desktop
    # GNOME-49 session target drop-in + hwcomposer-env strip unit (user manager)
    install -Dm 644 "$S/session.conf" \
        /usr/lib/systemd/user/gnome-session@gnome-mali.target.d/session.conf
    install -Dm 644 "$S/gnome-mali-strip-hwcomposer.service" \
        /usr/lib/systemd/user/gnome-mali-strip-hwcomposer.service
    # gnome-shell env guard: guarantee the compositor's environment regardless
    # of what a previous (phosh) session imported into the user manager
    install -Dm 644 "$S/user-units/org.gnome.Shell@wayland.service.d-gnome-mali-env.conf" \
        /usr/lib/systemd/user/org.gnome.Shell@wayland.service.d/gnome-mali-env.conf
    # system session service (replaces phosh's role on tty7) + its PAM stack
    install -Dm 644 "$S/gnome-mali.service" /etc/systemd/system/gnome-mali.service
    install -Dm 644 "$S/pam-gnome-mali"     /etc/pam.d/gnome-mali

    # drm-adapter activation: ONLY libdrm-hybris.so in ld.so.preload
    if ! grep -qxF "$LIBDIR/libdrm-hybris.so" /etc/ld.so.preload 2>/dev/null; then
        echo "$LIBDIR/libdrm-hybris.so" >> /etc/ld.so.preload
    fi

    # Make the Android hwcomposer service uphold the GNOME session instead of
    # phosh (a same-named /etc drop-in shadows the packaged 20-phosh.conf).
    install -Dm 644 "$S/android-uphold-gnome-mali.conf" \
        /etc/systemd/system/android-service@hwcomposer.service.d/20-phosh.conf

    # User=32011 is hardcoded in gnome-mali.service for FuriOS; rewrite if the
    # target user differs.
    sed -i "s/^User=.*/User=$TARGET_UID/" /etc/systemd/system/gnome-mali.service

    systemctl daemon-reload
    echo
    echo "Done. Reboot to start GNOME Shell Mobile (phosh remains as a fallback)."
    echo "To switch now without rebooting:  systemctl start gnome-mali.service"
}

case "${1:-all}" in
    toolchain) toolchain ;;
    shims)     toolchain; shims ;;
    gnome)     toolchain; gnome ;;
    session)   session ;;
    all)       toolchain; shims; gnome; session ;;
    *) echo "usage: $0 [all|shims|gnome|session|toolchain]"; exit 1 ;;
esac
