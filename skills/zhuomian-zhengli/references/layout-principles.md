# Spatial Layout and Validation Principles

## Priority order

1. The user's explicit correction or requested relationship.
2. Preserve spatial familiarity by minimizing the number of moved items and their displacement.
3. Actual workflow and semantic relationships.
4. Clear major zones and finer subgroups.
5. Stable use of available screen space.
6. Alphabetical ordering only inside otherwise equivalent groups.

Do not sacrifice semantic proximity merely to make a category alphabetically neat.

## Planning

- Detect the live desktop view size, icon spacing, grid origin, item paths, and current coordinates.
- Snapshot all items before planning and use the current coordinates as the starting layout, not merely as rollback data.
- Filesystem folders may move when necessary, but count exactly like other icons in the movement budget. Treat virtual items as fixed by default.
- Keep unaffected icons at their current coordinates. Repair a local relationship by moving the smallest affected set; place new items in nearby suitable empty cells before shifting established blocks.
- Divide the usable grid into left, middle, and right major zones. Within each zone, use smaller blocks separated by at least one row or column when capacity allows.
- Use the far-right columns when useful; do not compress everything into the left half.
- Fixed items are obstacles/anchors. Build movable regions around them rather than shifting them.
- Give every visible item exactly one category and one unique target coordinate.
- Recompute the plan after deletion or after any desktop item-set change.

## Familiarity and movement budget

For preflight validation, a moved item is one whose target `x` or `y` differs from the live inventory. Every moved item requires a concrete `moveReason` in the plan.

Measure displacement as Manhattan grid-cell distance: `abs(deltaX / spacingX) + abs(deltaY / spacingY)`. The default change is a large reflow when either:

- moved items exceed `max(6, floor(movableItemCount * 0.25))`; or
- total displacement exceeds `max(24, round(movableItemCount * 1.25))` grid cells.

Virtual items do not count as movable. Filesystem folders do count and may move. The validator must report moved-item count, moved-folder count, total displacement, maximum single-item displacement, both computed limits, and whether the plan is a large reflow.

Do not weaken these limits inside a plan. If a necessary result exceeds them, show the movement report and reason to the user, obtain separate authorization for a broad reflow, and use the large-reflow execution token. Ordinary layout authorization is not broad-reflow authorization.

## Semantic constraints

Encode important relationships in the plan instead of relying on category membership. Examples:

- vertical stack for variants of the same application;
- adjacent row and adjacent column for a requested diagonal pair;
- compact bounding box for a primary app and its repair/restart helpers;
- adjacent launch variants, package/checksum pairs, and document/PDF counterparts;
- nearby placement for a recorder and its transcription/launch tools.

Put these checks in `constraints` using the schema in `plan-schema.md` and require them to pass before and after application.

## Technical invariants

- Identity is the full Shell parsing path mapped to the current child PIDL.
- The plan must cover the live desktop path multiset exactly once.
- Submit all PIDLs and coordinates in one `IFolderView.SelectAndPositionItems` call.
- Verify every PIDL with `IFolderView.GetItemPosition`.
- Never reuse cached ListView indices after moving any icon.
- Never declare success from an item count alone.

## Visual review

After programmatic verification, inspect a screenshot at readable scale:

- major zones are visually distinct and not glued together;
- finer subgroups have visible separation;
- related icons are genuinely adjacent in both row and column where required;
- labels do not overlap neighboring icons or leave important relationships ambiguous;
- right-side space is used when appropriate;
- folders that were not needed for the requested change remain visually where they started;
- the before/after comparison shows that unrelated blocks retained their recognizable locations and relative order;
- no icon is outside the visible work area.

If the screenshot contradicts coordinate validation, treat the visual result as a failure and do not perform sequential repair. Re-inventory and create a new complete plan.
