# Native Windows and Linux builds

KuroCatWork uses Swift/CoreGraphics on macOS, Win32/GDI+/Raw Input on Windows,
and GTK3/Cairo/XInput2/evdev on Linux. The native C++ ports share the work-state,
source, hook, audio, panel and accepted pickup-geometry code under `shared/work`.

## Artwork and behavior

The reference is the accepted KuroCatWork macOS v1.4.4 build 20261126.22.
The v1.4.6 input/audio correction changes work-mode routing without changing the accepted drawing geometry. The four built-in coats retain their compact
back-grip pickup, original head/ear proportions, white orange-white/shorthair paws,
held keyboard and mouse/tablet, rounded sleep and 1.2-second shake dizziness.
Native font rasterization and platform color management may differ slightly.
Platform foundations and input/recovery fixes derive from chanke17/KuroCat
commit `735970daf4858c77116458d13934b33ab269bcdd`; original MIT attribution remains.

## Work mode

Double-click toggles work mode. Ordinary mode cancels AI polling. Task checks use
a six-second schedule and quota checks use sixty seconds. Autonomous work typing owns the keyboard while active; physical typing does not interrupt it or trigger keyboard sounds.
waiting tasks stop autonomous typing. Completed tasks are dismissed on either
manual or automatic mode exit; unread waiting and failure items are retained.
The context menu includes tool selection, automatic detection, typing, expressions,
bubbles, switch sounds, pop sounds, independent volumes and optional CLI hooks.

Windows/Linux read Codex usage using the installed, signed-in Codex CLI app-server.
Claude usage uses existing Claude Code OAuth credentials. Local session records and
optional metadata-only hooks supply tasks. These ports do not embed the macOS
Claude web-login window. Unavailable windows remain N/A; no quota is invented.
Chat links are validated and only open the corresponding application/web page.
Terminal sessions without a deep link show source/project details instead.

## Build and verification

Run `windows/build.bat` from an MSVC x64 tools prompt, or `bash linux/build.sh`
with GCC, pkg-config, GTK3, Cairo, X11 and XInput2 development packages installed.
Linux packages: `bash linux/build_deb.sh 1.4.6`. Portable packages include sounds,
icons, license and per-user install scripts. Install scripts never replace KuroCat.

The manual GitHub Actions workflow has read-only repository permissions. It builds
Windows x64 and Linux x86_64/ARM64, runs isolated state/source/hook/geometry tests,
starts the native GUI, exercises double-click mode switching, and renders four
coats in six poses plus the work panel. Packages are uploaded as artifacts; the
workflow neither pushes commits nor publishes releases.

Windows is compiled with the Windows 7 SP1 API/subsystem baseline and a static
C++ runtime. Linux binaries are built against Debian 10/glibc 2.28/GCC 8, for
GTK3 3.22+ X11/XWayland environments including compatible UOS/Kylin installations.
CI runs on Windows Server 2022 and Linux virtual displays; it does not certify
physical input, suspend/fullscreen recovery or every legacy OS/distribution.
AI CLIs have their own, potentially newer, OS requirements. Wayland global-input
restrictions still apply. No upstream auto-updater is enabled in KuroCatWork.
