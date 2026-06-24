# gnome-mobile-furi-installer

Build and install **GNOME Shell Mobile** (the GNOME 49 "-furi" stack) on a
**FuriPhone FLX1** running FuriOS, replacing phosh. GNOME Shell runs on the
Mali GPU through the Android HWC2 composer via a hybris/drmadapter EGL path.

## Quick start

On a FuriOS device (fresh phosh + hwcomposer install):

    git clone https://github.com/D0gg0Man/gnome-mobile-furi-installer
    cd gnome-mobile-furi-installer
    sudo ./install.sh

Then reboot. The greeter-less session takes over tty7; **phosh stays installed
as an automatic fallback** (gnome-mali.service `OnFailure=phosh.service`).

Run a single phase with `sudo ./install.sh shims|gnome|session`.

## What it installs

Graphics shims (built from the `D0gg0Man` repos):

- **libhybris** -- glvnd build that advertises `EGL_KHR_platform_gbm` and
  contains the drmadapter EGL integration (routes `EGL_PLATFORM_GBM_KHR` to the
  hybris/HWC2 path, remaps gralloc visual ids).
- **libgbm-hybris** -- `hybris_gbm.so` GBM backend (`GBM_BACKEND=hybris`).
- **eglplatform-drmadapter** -- `HYBRIS_EGLPLATFORM=drmadapter` EGL platform;
  presents mutter's frames through HWC2.
- **wayland-android-wlegl** -- `wlegl_server.so` buffer-sharing companion.
- **libdrm-hybris** -- the unified `LD_PRELOAD` shim (libseat fake, DRM-cap /
  KMS faking, `android_wlegl` injection, and synthetic page-flip events so the
  frame clock survives output reconfigures).

GNOME Mobile (GNOME 49 branches), installed over the stock packages:

- **mutter-mobile-furi** (`mobile-shell-devel-49`) -- refresh-rate fix for the
  MediaTek panel. Builds against the stock distro `gnome-settings-daemon`
  (no settings-daemon fork needed -- power/backlight is handled by the shell
  and the device `gsd-adapter`).
- **gnome-shell-mobile-furi** (`mobile-shell-devel-49`) -- gdm-free PAM lock
  screen.
- **gnome-mobile-pam-helper** -- setuid helper the lock screen authenticates
  against (no GDM on this device).

Session wiring (in `session/`):

- `gnome-mali.service` -- system service modelled on phosh.service (waits for
  the hwcomposer android prop, owns tty7, falls back to phosh).
- `gnome-mali-session` / `gnome-shell-session-wrapper` -- launcher that sets the
  drmadapter env (`GBM_BACKEND=hybris`, `HYBRIS_EGLPLATFORM=drmadapter`, ...).
- `gnome-mali.session` / `gnome-mali.desktop` -- gnome-session definition + entry.
- `session.conf` -- `gnome-session@gnome-mali.target.d` drop-in (GNOME-49 form:
  requires `org.gnome.Shell.target`).
- `android-uphold-gnome-mali.conf` -- makes the Android hwcomposer service
  uphold the GNOME session instead of phosh.
- `/etc/ld.so.preload` gets **only** `libdrm-hybris.so`.

## Notes / status

- Targets FuriOS *forky* on aarch64; the dependency lists are tuned for it.
- Panel resolution and refresh are **not hardcoded** -- queried from HWC2 / the
  DRM mode at runtime.
- Known limitation: changing the display **scale** at runtime is being worked
  on. Normal use is unaffected.
