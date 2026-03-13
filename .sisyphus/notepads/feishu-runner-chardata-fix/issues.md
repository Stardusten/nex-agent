
- `mix test test/nex/agent/runner_evolution_test.exs` now reproduces two Runner crashes.
- Structured tool args path: `tool_calls[].function.arguments = [%{"a" => 1}]` crashes in `lib/nex/agent/runner.ex:446` while formatting tool hints; decoded list falls through `normalize_tool_hint_args/2` to `to_string/1` and raises `ArgumentError` (`cannot convert the given list to a string`).
- Structured content path: `response.content = [%{"nested" => [%{"x" => 1}]}]` crashes in `lib/nex/agent/runner.ex:481` inside `strip_think_tags/1`; `maybe_send_progress/3` passes non-binary content into `String.replace/4`, raising `FunctionClauseError`.
- Duplicate tool exposure repro is now real: a registry tool named `skill_message` plus an injected Markdown skill named `message` causes `Runner` to pass two `skill_message` definitions to `llm_client`; the failing assertion is in `test/nex/agent/tool_alignment_test.exs:113`.
- `InboundWorker` test initially assumed the first Feishu outbound would always be a progress payload; actual ordering includes multiple progress publishes before the final `done`, so the stable assertion is to collect outbound payloads and check for both `_progress=true` and final `done`.
- Regression: Add failing duplicate-tool-definition regression (test verifies dedupe when registry and skill tool definitions collide by name).
- Implement Step 1: Encoded in test the registry precedence rule and ensure the merged tool list contains the colliding name exactly once.
- Note: Step 2-5 are pending and will be implemented in subsequent steps.
