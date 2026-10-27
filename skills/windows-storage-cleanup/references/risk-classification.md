# Risk Classification

Classify by recoverability, reproducibility, ownership, and current use. File extension alone is not enough.

## Official Cleanup Only

Do not delete these paths or file types directly:

- `C:\Windows\WinSxS`
- `C:\Windows\Installer`
- Windows driver store and servicing directories
- `pagefile.sys`, `hiberfil.sys`, swap files, and crash-dump configuration
- Docker, WSL, Hyper-V, or application VHD/VHDX files
- WindowsApps and packaged-app internals

Use documented Windows cleanup, application settings, or the registered uninstaller.

## Low Risk After Preapproval

Include verified candidates in the concrete cleanup list. Once the list and method are approved, execute without
another confirmation; a safe official online cleanup may be used while its application runs:

- package-manager download caches such as npm, pip, Bun, or uv;
- stale installer download caches whose owning application documents them as disposable;
- completed crash dumps and diagnostic output no longer under investigation;
- residual files left after a verified official uninstall;
- clearly obsolete retained application versions when one working current version remains.

Cache directories can regenerate. Explain this before cleanup when recurrence matters to the user.

## Verified Uninstall Residuals

Treat a directory as an uninstall residual only after evidence shows that the owning application is gone and the
directory is not shared with another installed application. Check all applicable ownership surfaces:

1. Machine-wide and per-user uninstall registrations, including 32-bit and 64-bit registry views.
2. AppX/MSIX package registration and package-manager records.
3. Expected installation directories under Program Files, ProgramData, LocalAppData, and Roaming AppData.
4. Running processes, Windows services, drivers, startup entries, and scheduled tasks.
5. Start-menu and desktop shortcuts, protocol handlers, shell integration, and file associations.
6. Application recovery, autosave, templates, profiles, and user-created documents that may be stored beside program
   files.

The absence of an uninstall entry or active process is only one signal. A vendor directory remains protected when an
installed or running product from the same vendor still owns files inside it. Likewise, a shared runtime remains
protected when another installed application declares or contains a dependency on it, even if no runtime process is
currently active. Inspect application manifests, package metadata, configuration files such as
`*.runtimeconfig.json`, bundled launchers, and documented runtime requirements before recommending removal.

Examples of the decision boundary:

- A directory with no uninstall registration, package, process, program files, recovery material, or user documents
  can become a residual candidate after its contents and ownership are verified.
- A vendor directory containing files used by a currently running companion application is active application data,
  not an uninstall residual.
- An inactive shared runtime referenced by another application's runtime configuration is a dependency and must be
  kept. “No process is using it now” is not sufficient evidence.

Use the registered uninstaller when the application is still installed. After verifying residual ownership and
excluding user data and dependencies, use the approved list's method: official cleanup, direct deletion, or Recycle
Bin staging. State any recovery limits before approval; do not add a second approval for unchanged residuals already
included in that list.

## Confirm as a Group

Group by source and purpose in the list for one batch confirmation. Reuse an existing accurate authorization:

- installers, ISO images, and extracted installation media;
- old presentations, rendered videos, raw media, and project exports;
- chat attachments, downloads, and received archives;
- duplicate archives and duplicated project outputs;
- model weights, offline maps, speech models, and other optional assets;
- old application versions whose rollback value is uncertain.

## Protected by Default

- original experiment data and instrument captures;
- source repositories, uncommitted work, and environment definitions;
- unique project archives, PCB/CAD source, and editable Office originals;
- session history, research notes, and user-created recordings;
- active application data and locked files;
- the only local working copy, even when a cloud backup exists.

Research roots, source repositories, active editor/application data, browser profiles, containers, and research-tool
data remain protected unless explicitly reviewed. Resolve their actual roots from current evidence instead of
hard-coding a private machine path or product-specific folder convention.

## Stable Reclaim and Recurring Growth

Ordinary cleanup prioritizes large, verified disposable items. Do not require a preliminary choice between temporary
relief and long-term management. Explain that caches regrow when relevant; only an explicit request to solve recurring
space exhaustion calls for investigating growth and proposing cache locations or retention changes, under the
appropriate authorization.

When stable reclaimed space is the stated success criterion, review in this order:

1. Rarely used applications and confirmed obsolete versions, using registered uninstallers.
2. Verified residuals after completed uninstall and ownership checks.
3. One-time backups, installation media, and verified duplicates.
4. Regenerating caches last; exclude them from stable-reclaim totals.

Stop extending the list when the remaining benefit is small relative to the task. Do not impose a universal MB
threshold or automatically uninstall additional software or change settings to increase the reported benefit.

## Decision Test

Before recommending a cleanup method, establish:

1. What owns the content, and does any current work or dependency need it?
2. When removal relies on another copy, has that copy been verified beyond name and size? For disposable caches,
   establish reproducibility instead of creating an unnecessary backup.
3. Can the proposed method run safely now? A busy or locked item is skipped without stopping its application.
4. What can be restored or regenerated, and what permanent loss must the list explain?
5. Does the approved batch include this exact content and handling method?

Resolve facts locally where possible. Preserve an uncertain item and continue the other approved items; ask only
when the remaining uncertainty requires a consequential user decision. A risk label does not add approval rounds.
