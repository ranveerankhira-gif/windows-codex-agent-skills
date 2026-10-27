# Layout Plan Schema

The plan is UTF-8 JSON. It must describe every item in the inventory exactly once.

```json
{
  "schemaVersion": 1,
  "inventoryCapturedAt": "2026-09-24T12:00:00+08:00",
  "grid": {
    "originX": 21,
    "originY": 2,
    "spacingX": 115,
    "spacingY": 147
  },
  "items": [
    {
      "path": "C:\\Users\\Example\\Desktop\\Example Editor.lnk",
      "x": 251,
      "y": 2,
      "group": "AI与创作",
      "fixed": false,
      "moveReason": "Place beside the existing GPT block as requested"
    },
    {
      "path": "::{645FF040-5081-101B-9F08-00AA002F954E}",
      "x": 21,
      "y": 149,
      "group": "固定",
      "fixed": true
    }
  ],
  "constraints": [
    {
      "name": "Related launchers diagonal pair",
      "type": "pair",
      "paths": ["C:\\...\\Example App A.lnk", "C:\\...\\Example App B.lnk"],
      "exactColumnDelta": 1,
      "exactRowDelta": 1,
      "firstAboveSecond": true
    },
    {
      "name": "Application helper compact block",
      "type": "compact",
      "paths": ["C:\\...\\Example Editor.lnk", "C:\\...\\Restart Example Editor.lnk"],
      "maxColumnDelta": 1,
      "maxRowDelta": 2
    }
  ],
  "zones": [
    {
      "name": "Left office block",
      "groups": ["办公"],
      "minColumn": 0,
      "maxColumn": 1,
      "minRow": 0,
      "maxRow": 8
    }
  ]
}
```

## Required fields

- `schemaVersion`: must be `1`.
- `grid`: use values from the live inventory. Do not copy the example values blindly.
- `items`: complete target layout. `path` is the exact parsing path from inventory; `x` and `y` are integer pixels; `group` is non-empty; `fixed` is Boolean. A preflight item whose target differs from the live coordinates must have a non-empty `moveReason` that explains why that specific move is necessary.

The `inventoryCapturedAt` value is informational. Live path-set and coordinate checks, not the timestamp alone, prevent stale application.

## Constraints

`pair` requires exactly two paths and accepts:

- `exactColumnDelta` or `maxColumnDelta`;
- `exactRowDelta` or `maxRowDelta`;
- `firstAboveSecond`;
- `firstLeftOfSecond`.

`compact` requires at least two paths and accepts `maxColumnDelta` and `maxRowDelta` for the group's bounding box.

All deltas are grid-cell deltas, calculated from the plan's spacing with a two-pixel tolerance.

## Zones

Zones are optional but recommended. Every non-fixed plan item whose group appears in a zone must fall within that zone's inclusive column/row bounds. A group must not appear in more than one zone.

## Movement preservation

The validator compares every planned coordinate with the live inventory. Filesystem folders are movable and count toward the same movement budget as other icons. Virtual desktop items are fixed by default.

The default budget classifies the plan as a large reflow when moved items exceed `max(6, floor(movableItemCount * 0.25))` or total Manhattan displacement exceeds `max(24, round(movableItemCount * 1.25))` grid cells. The plan cannot raise these limits. A large reflow requires separate user authorization and the execution script's large-reflow authorization token.

## Snapshot format

The layout script writes rollback snapshots with the same `grid` and `items` fields. Snapshot items are marked fixed only if they were virtual Shell items at capture time. A rollback uses the saved coordinates for all paths.
