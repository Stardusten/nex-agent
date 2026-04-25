# 2026-04-25 `<newmsg/>` Literal Boundary

## Conclusion

`<newmsg/>` is now a literal hard boundary wherever it appears in assistant text.

The runtime no longer requires it to be on its own line and no longer gives fenced code blocks or inline code special treatment.

## Constraints

- The token remains platform text IR, not a message mode or runtime config.
- Shared final-message splitting and streaming converters must use the same literal-token boundary.
- Prompt guidance should describe `<newmsg/>` as a hard new-message boundary, not as markdown-like prose.
- Closed phase task-plans still record the old historical contract; use `CURRENT.md` and this finding for the active behavior.
