# Desktop Cleanup Policy

Read this reference only when the user asks to delete, clean, deduplicate, or remove desktop items.

## Authorization boundary

Icon arrangement does not authorize deletion. First produce a read-only candidate list with the path, type, size, reason, evidence, retained copy, and recovery method. Obtain authorization for the proposed deletion group before mutation.

Default to the Windows Recycle Bin for personal files. Never empty the whole Recycle Bin unless the user separately and explicitly requests it. Moving an item to the Recycle Bin does not immediately free disk space, so report that distinction accurately.

## Evidence requirements

- Broken shortcuts: inspect target path, arguments, working directory, AppX identity, scripts, and removable/secondary-drive targets. A temporarily unavailable drive is not proof that a shortcut is obsolete.
- Versioned packages: verify the retained version exists, its checksum matches when supplied, and its archive is readable before recycling older versions.
- Duplicate files: filename or size alone is insufficient. Compare SHA-256 and, for archives or folder copies, required members and readability.
- Reparse points: do not traverse symbolic links or junctions while sizing, hashing, or cleaning. If the link itself is an approved candidate, act on the link entry only and report its target separately.
- Installers: keep unless installation state, newer retained version, and user intent are clear.
- Unique archives, research documents, source code, application history, and ambiguous items are protected.

## Prohibited cleanup shortcuts

Do not clear browser/application caches, stop processes, take ownership, modify registry paths, uninstall software, recursively delete directories, permanently delete files, or clean unrelated system locations as part of desktop organization.

## Cleanup report

For every changed item report its original path, reason, evidence, byte count, destination, recoverability, and result. Separately list retained candidates and why they were not removed.
