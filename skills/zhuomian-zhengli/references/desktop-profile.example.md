# Desktop profile example

Keep the real profile outside the Skill directory. Do not commit real filenames, parsing paths, coordinates, monitor identifiers, account names, or screenshots.

```yaml
version: 1
captured_at: 2030-01-01T00:00:00Z
preferences:
  preserve_unaffected_positions: true
  maximum_default_grid_displacement: 12
semantic_groups:
  - name: communication
    members: [example-chat-shortcut, example-mail-shortcut]
  - name: work
    members: [example-editor-shortcut, example-terminal-shortcut]
```

Resolve every member against the live Shell inventory. Never treat example names or stored coordinates as authority.
