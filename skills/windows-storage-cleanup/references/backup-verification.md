# Backup and Duplicate Verification

Use this workflow when removing personal files, research material, archives, media, or project outputs on the basis
of a retained duplicate or backup. It does not require backup copies of verified reproducible caches.

## Evidence Levels

Weak evidence, insufficient for deletion:

- same filename;
- same extension;
- same displayed size;
- a cloud search result without path, version, or readability checks;
- an upload-history row without confirming final cloud metadata.

Strong evidence:

- exact byte size plus matching SHA-256;
- archive member-by-member comparison;
- a readable retained copy at the intended project/version path;
- cloud metadata that confirms name, size, parent path, identifier, and completed upload;
- a tested restore when the cloud copy would become the only remaining copy.

## File and Archive Workflow

1. Identify which copy is authoritative and why.
2. Inspect archive contents or project structure before hashing.
3. Hash both candidate and retained copy with SHA-256.
4. For two folders or differently packaged archives, compare required members rather than only container hashes.
   Confirm that the retained copy is readable and belongs to the intended project and version.
5. Record unmatched members and retain that candidate if any required file lacks a verified replacement; continue
   unrelated approved candidates.
6. Recheck hashes immediately before moving the candidate.
7. Default to Recycle Bin staging and record both original and retained paths. If the approved list also names
   permanent removal of these exact staged entries, follow the exact-entry procedure in windows-and-wiztree.md
   without asking again. Staging-only approval remains staging-only.

## Cloud Backup Semantics

Distinguish:

- **backup**: deleting local data usually does not delete the remote backup;
- **synchronization**: local deletion may propagate remotely;
- **placeholder/on-demand file**: the visible local entry may not contain a full offline copy.

Confirm the product's actual mode and, when necessary, inspect the client's metadata database read-only. Database
schemas can change; discover tables and columns before querying. If the database is locked, copy it to a temporary
read-only location when a consistent supported snapshot is possible; otherwise defer that item's verification.
Keep the sync client and user tasks running rather than stopping them for cleanup.

Some cloud clients keep local metadata databases, but their locations, schemas, and semantics are product- and
version-specific. Do not hard-code database names or paths. A cloud record does not by itself justify deleting the
only local working copy.

## Research Data Rule

Original experiment data remains protected unless the user identifies a verified derivative or duplicate and gives
explicit approval. When a result file exists in two repositories, check path dependencies, uncommitted changes, and
which repository is authoritative before removing either copy.
