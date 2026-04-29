defmodule Nex.Agent.Interface.Workbench.Shell do
  @moduledoc false

  alias Nex.Agent.Interface.Workbench.AppManifest

  @spec html() :: String.t()
  def html do
    path = Path.join([priv_dir(), "workbench", "shell.html"])

    case File.read(path) do
      {:ok, body} -> body
      {:error, _reason} -> fallback_html()
    end
  end

  @spec app_frame(AppManifest.t()) :: String.t()
  def app_frame(%AppManifest{} = manifest) do
    permissions =
      manifest.permissions
      |> Enum.map(&"<li>#{escape(&1)}</li>")
      |> Enum.join("\n")

    metadata = Jason.encode!(manifest.metadata, pretty: true)

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{escape(manifest.title)}</title>
      <style>
        :root {
          color-scheme: light;
          --ink: #20211d;
          --muted: #697064;
          --line: #d9ddcf;
          --paper: #fbfaf4;
          --wash: #eef1e5;
          --accent: #176f62;
          --warm: #b65d3a;
        }

        * { box-sizing: border-box; }

        body {
          margin: 0;
          min-height: 100vh;
          font-family: "Avenir Next", "Segoe UI", sans-serif;
          color: var(--ink);
          background:
            linear-gradient(90deg, rgba(23, 111, 98, 0.08) 1px, transparent 1px),
            linear-gradient(180deg, rgba(182, 93, 58, 0.06) 1px, transparent 1px),
            var(--paper);
          background-size: 42px 42px;
        }

        main {
          min-height: 100vh;
          padding: clamp(24px, 5vw, 56px);
          display: grid;
          align-content: center;
          gap: 22px;
        }

        h1 {
          margin: 0;
          max-width: 14ch;
          font-size: clamp(44px, 9vw, 108px);
          line-height: 0.88;
          font-weight: 800;
          letter-spacing: 0;
        }

        .meta {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
          gap: 1px;
          background: var(--line);
          border: 1px solid var(--line);
          max-width: 840px;
        }

        .cell {
          background: rgba(251, 250, 244, 0.92);
          padding: 16px;
          min-height: 96px;
        }

        .label {
          color: var(--muted);
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: .08em;
          margin-bottom: 10px;
        }

        code, pre {
          font-family: "SFMono-Regular", Consolas, monospace;
          font-size: 12px;
        }

        pre {
          white-space: pre-wrap;
          overflow-wrap: anywhere;
          margin: 0;
        }

        ul {
          margin: 0;
          padding-left: 18px;
        }
      </style>
    </head>
    <body>
      <main>
        <h1>#{escape(manifest.title)}</h1>
        <section class="meta" aria-label="App manifest">
          <div class="cell">
            <div class="label">App ID</div>
            <code>#{escape(manifest.id)}</code>
          </div>
          <div class="cell">
            <div class="label">Entry</div>
            <code>#{escape(manifest.entry)}</code>
          </div>
          <div class="cell">
            <div class="label">Permissions</div>
            <ul>#{permissions}</ul>
          </div>
          <div class="cell">
            <div class="label">Metadata</div>
            <pre>#{escape(metadata)}</pre>
          </div>
        </section>
      </main>
    </body>
    </html>
    """
  end

  @spec inject_sdk_bootstrap(String.t(), String.t() | nil) :: String.t()
  def inject_sdk_bootstrap(html, app_id \\ nil) when is_binary(html) do
    html = inject_app_base_tag(html, app_id)
    script = sdk_bootstrap()

    inject_script(html, script)
  end

  defp inject_script(html, script) do
    cond do
      Regex.match?(~r/<\/head\s*>/i, html) ->
        Regex.replace(~r/<\/head\s*>/i, html, script <> "\n</head>", global: false)

      Regex.match?(~r/<html[^>]*>/i, html) ->
        Regex.replace(~r/<html[^>]*>/i, html, "\\0\n<head>\n" <> script <> "\n</head>",
          global: false
        )

      Regex.match?(~r/<body[^>]*>/i, html) ->
        Regex.replace(~r/<body[^>]*>/i, html, "\\0\n" <> script, global: false)

      true ->
        script <> "\n" <> html
    end
  end

  defp inject_app_base_tag(html, app_id) do
    case app_base_tag(html, app_id) do
      nil ->
        html

      base ->
        cond do
          Regex.match?(~r/<head[^>]*>/i, html) ->
            Regex.replace(~r/<head[^>]*>/i, html, "\\0\n" <> base, global: false)

          Regex.match?(~r/<html[^>]*>/i, html) ->
            Regex.replace(~r/<html[^>]*>/i, html, "\\0\n<head>\n" <> base <> "\n</head>",
              global: false
            )

          true ->
            base <> "\n" <> html
        end
    end
  end

  defp app_base_tag(html, app_id) when is_binary(app_id) and app_id != "" do
    if Regex.match?(~r/<base\s/i, html) do
      nil
    else
      ~s(<base href="/app-assets/#{escape(app_id)}/">)
    end
  end

  defp app_base_tag(_html, _app_id), do: nil

  @spec frame_error(String.t(), String.t()) :: String.t()
  def frame_error(title, message) do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{escape(title)}</title>
      <style>
        body {
          margin: 0;
          min-height: 100vh;
          display: grid;
          place-items: center;
          font-family: "Avenir Next", "Segoe UI", sans-serif;
          color: #20251f;
          background: #f4f7f1;
        }

        main {
          width: min(620px, calc(100vw - 40px));
          border: 1px solid #c9d3c4;
          background: #fffef9;
          padding: 24px;
          display: grid;
          gap: 12px;
        }

        h1 {
          margin: 0;
          font-size: 22px;
        }

        p {
          margin: 0;
          color: #637062;
          overflow-wrap: anywhere;
        }
      </style>
    </head>
    <body>
      <main>
        <h1>#{escape(title)}</h1>
        <p>#{escape(message)}</p>
      </main>
    </body>
    </html>
    """
  end

  @spec missing_app(String.t()) :: String.t()
  def missing_app(app_id) do
    frame_error("Missing app", app_id)
  end

  defp sdk_bootstrap do
    """
    <script>
    (() => {
      if (window.Nex) return;

      const pending = new Map();

      function randomCallId() {
        const suffix = Math.random().toString(36).slice(2);
        return `call_${Date.now().toString(36)}_${suffix}`;
      }

      function boundedMessage(error) {
        const message = error && error.message ? error.message : String(error || "Nex bridge call failed");
        return message.length > 500 ? `${message.slice(0, 500)}...[truncated]` : message;
      }

      function call(method, params = {}, options = {}) {
        if (typeof method !== "string" || method.trim() === "") {
          return Promise.reject(new Error("Nex method is required"));
        }

        const callId = options.call_id || randomCallId();
        const timeoutMs = Number.isFinite(options.timeout_ms) ? options.timeout_ms : 30000;

        return new Promise((resolve, reject) => {
          const timeout = window.setTimeout(() => {
            pending.delete(callId);
            reject(new Error("Nex bridge call timed out"));
          }, timeoutMs);

          pending.set(callId, { resolve, reject, timeout });

          window.parent.postMessage({
            nex: "workbench.bridge.request",
            version: 1,
            call_id: callId,
            method,
            params: params && typeof params === "object" ? params : {}
          }, "*");
        });
      }

      window.addEventListener("message", (event) => {
        const data = event.data || {};
        if (!data || data.nex !== "workbench.bridge.response" || data.version !== 1) return;

        const pendingCall = pending.get(data.call_id);
        if (!pendingCall) return;

        window.clearTimeout(pendingCall.timeout);
        pending.delete(data.call_id);

        if (data.ok === true) {
          pendingCall.resolve(data.result || {});
        } else {
          const error = data.error || {};
          const message = typeof error.message === "string" ? error.message : boundedMessage(error);
          const bridgeError = new Error(message);
          bridgeError.code = error.code || "bridge_failed";
          pendingCall.reject(bridgeError);
        }
      });

      window.Nex = Object.freeze({
        call,
        permissions: () => call("permissions.current", {}),
        observe: Object.freeze({
          query: (filters = {}) => call("observe.query", filters),
          summary: (params = {}) => call("observe.summary", params)
        }),
        notes: Object.freeze({
          roots: () => call("notes.roots.list", {}),
          files: (params = {}) => call("notes.files.list", params),
          read: (params = {}) => call("notes.file.read", params),
          write: (params = {}) => call("notes.file.write", params),
          remove: (params = {}) => call("notes.file.delete", params),
          search: (params = {}) => call("notes.search", params)
        }),
        tasks: Object.freeze({
          scheduled: Object.freeze({
            list: (params = {}) => call("tasks.scheduled.list", params),
            status: () => call("tasks.scheduled.status", {}),
            add: (params = {}) => call("tasks.scheduled.add", params),
            update: (params = {}) => call("tasks.scheduled.update", params),
            remove: (params = {}) => call("tasks.scheduled.remove", params),
            enable: (params = {}) => call("tasks.scheduled.enable", params),
            disable: (params = {}) => call("tasks.scheduled.disable", params),
            run: (params = {}) => call("tasks.scheduled.run", params)
          })
        })
      });
    })();
    </script>
    """
  end

  defp priv_dir do
    case :code.priv_dir(:nex_agent) do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("priv")
    end
  end

  defp fallback_html do
    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Nex Workbench</title></head>
    <body><main id="app">Nex Workbench</main></body>
    </html>
    """
  end

  defp escape(nil), do: ""

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
