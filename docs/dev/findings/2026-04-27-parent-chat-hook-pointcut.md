# Parent Chat Hook Pointcut

## Conclusion

Runtime hooks now support a channel-agnostic `parent_chat_id` pointcut field.

The field is an exact-match parent conversation scope. For Discord, the adapter projects:

- direct parent-channel messages as `parent_chat_id == channel_id`
- messages inside threads as `parent_chat_id == parent channel_id`
- slash interactions with the same parent-channel projection

This keeps the hook contract generic while allowing one hook to apply to a Discord parent channel and all of its threads:

```json
{
  "pointcut": {
    "channel": "discord",
    "parent_chat_id": "123"
  }
}
```

`channel` remains the Nex channel instance id. Discord platform channel ids must not be overloaded into `channel`.

`parent_chat_id` is now also a first-class runtime/tool context field, not only opaque
channel metadata:

- the model sees `Chat Scope ID (parent_chat_id): <id>` in runtime context
- `Runner` passes `parent_chat_id` into tool ctx
- `hook.add_*` defaults to `%{"channel" => current_channel, "parent_chat_id" => current_parent}`
  when the caller provides no explicit pointcut

Explicit pointcuts still win. Passing `pointcut`, `session`, `channel`, `chat_id`,
`parent_chat_id`, or `target_workspace` prevents the default parent scope from being
inferred.
