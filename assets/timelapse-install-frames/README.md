# Timelapse Install-Phase Frames

Canned screenshots of the Windows 11 unattended install ("Installing Windows 11 — N%
complete"), `frame-00000.png` … `frame-00024.png`, 1024x768.

`build-vm.sh --watch` prepends these to the front of the timelapse video. The live
timelapse capture (`capture_screens.ps1`) only starts once the `dev` user auto-logs on,
because it runs in the interactive desktop session — so it can't see the OS-install phase
that happens before first logon (Windows is partitioning, copying files, and rebooting,
with no interactive session and a frozen headless framebuffer). These frames fill that gap
so the video reads end-to-end from "Installing Windows 11" through "all four servers
running."

To refresh them, drop in a new contiguous `frame-NNNNN.png` sequence starting at `00000`
(same 1024x768 size as the live captures).
