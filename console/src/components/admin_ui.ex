defmodule NexAgentConsole.Components.AdminUI do
  use Nex

  alias NexAgentConsole.Components.Nav

  @page_meta %{
    "/" => %{name: "分流", group: "进化层"},
    "/evolution" => %{name: "分流", group: "进化层"},
    "/skills" => %{name: "能力", group: "进化层"},
    "/memory" => %{name: "认知", group: "进化层"},
    "/code" => %{name: "代码", group: "进化层"},
    "/sessions" => %{name: "会话", group: "运行侧"},
    "/tasks" => %{name: "调度", group: "运行侧"},
    "/runtime" => %{name: "运行时", group: "运行侧"}
  }

  def page_shell(assigns) do
    path = Map.get(assigns, :current_path)

    assigns =
      assigns
      |> Map.put_new(:page_name, page_name(path))
      |> Map.put_new(:page_group, page_group(path))
      |> Map.put_new(:primary_action_label, nil)
      |> Map.put_new(:primary_action_href, nil)

    ~H"""
    <section class="page-shell">
      <header class="page-header">
        <div class="page-header__main">
          <div class="page-header__title-row">
            <p class="page-header__eyebrow">{@page_group}</p>
            <span class="page-header__route">{@current_path}</span>
          </div>
          <h1>{@page_name}</h1>
          <p class="page-header__subtitle">{@subtitle}</p>
        </div>

        <div class="page-statusbar">
          <span class="status-pill status-pill--live">
            <span class="status-pill__dot"></span>
            <span data-live-summary>等待实时事件</span>
          </span>

          <div class="page-header__actions">
            <%= if @primary_action_href do %>
              <a class="action-button action-button--primary" href={@primary_action_href}>
                {@primary_action_label}
              </a>
            <% end %>

            <a class="ghost-link" href="https://github.com/gofenix/nex" target="_blank" rel="noreferrer">
              Nex Runtime
            </a>
          </div>
        </div>
      </header>

      <section
        class="panel-slot"
        hx-get={@panel_path}
        hx-trigger="load, admin-event from:body delay:250ms"
        hx-swap="innerHTML"
      >
        <div class="loading-panel">加载控制台面板...</div>
      </section>
    </section>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="console-frame">
      <div class="console-shell">
        {Nav.render(%{current_path: @current_path})}

        <main class="console-main">
          <div class="console-main__inner">{raw(@inner_content)}</div>
        </main>
      </div>
    </div>
    """
  end

  def overview_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">overview</p>
            <h2>系统状态</h2>
          </div>
        </div>

        <div class="metric-grid">
          {metric(%{label: "gateway", value: @state.runtime.gateway.status, tone: "rust"})}
          {metric(%{label: "pending signals", value: length(@state.pending_signals), tone: "gold"})}
          {metric(%{label: "open tasks", value: @state.tasks.open, tone: "green"})}
          {metric(%{label: "cron enabled", value: Map.get(@state.cron, :enabled, 0), tone: "ink"})}
          {metric(%{label: "sessions", value: length(@state.recent_sessions), tone: "ink"})}
          {metric(%{label: "recent events", value: length(@state.recent_events), tone: "ink"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">recent</p>
              <h2>最近事件</h2>
            </div>
          </div>

          {event_feed(%{events: Enum.take(@state.recent_events, 6)})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">signals</p>
              <h2>待分流</h2>
            </div>
            <a class="ghost-link" href="/evolution">查看全部</a>
          </div>

          {signal_list(%{signals: Enum.take(@state.pending_signals, 4)})}
        </section>
      </div>
    </div>
    """
  end

  def evolution_panel(assigns) do
    assigns =
      assigns
      |> Map.put(
        :selected_signal,
        selected_or_first_signal(
          assigns.state.pending_signals,
          Map.get(assigns, :selected_signal_id)
        )
      )
      |> Map.put(:last_cycle_event, last_cycle_event(assigns.state.recent_events))

    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--toolbar">
        <div class="detail-grid">
          {detail_item(%{label: "待处理信号", value: length(@state.pending_signals)})}
          {detail_item(%{label: "层级目标", value: length(@state.layers)})}
          {detail_item(%{label: "最近进化事件", value: length(@state.recent_events)})}
          {detail_item(%{
            label: "上次 cycle",
            value: if(@last_cycle_event, do: format_timestamp(Map.get(@last_cycle_event, "timestamp")), else: "n/a")
          })}
        </div>
      </section>

      <div class="inspector-layout" id="pending-signals">
        <section class="section-card inspector-layout__list">
          <div class="section-head">
            <div>
              <p class="section-kicker">signal inbox</p>
              <h2>当前待分流</h2>
            </div>
          </div>

          {signal_selection_list(%{
            signals: @state.pending_signals,
            selected_signal_id: signal_id(@selected_signal)
          })}
        </section>

        <section class="section-card inspector-layout__detail">
          <div class="section-head">
            <div>
              <p class="section-kicker">inspector</p>
              <h2>当前信号</h2>
            </div>
          </div>

          <div id="evolution-action-result" class="action-result"></div>
          {signal_inspector(%{signal: @selected_signal})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">layer targets</p>
            <h2>分流目标</h2>
          </div>
        </div>

        {layer_map(%{layers: @state.layers})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">last cycle</p>
            <h2>上次进化</h2>
          </div>
        </div>

        {last_cycle_summary(%{events: @state.recent_events})}
      </section>
    </div>
    """
  end

  def skills_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">inventory</p>
            <h2>能力资产</h2>
          </div>
        </div>

        <div class="metric-grid">
          {metric(%{label: "本地 skills", value: length(@state.local_skills), tone: "gold"})}
          {metric(%{label: "可用 tools", value: length(@state.tools.builtin) + length(@state.tools.custom), tone: "ink"})}
          {metric(%{label: "builtin tools", value: length(@state.tools.builtin), tone: "green"})}
          {metric(%{label: "custom tools", value: length(@state.tools.custom), tone: "green"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">skills</p>
              <h2>本地方法</h2>
            </div>
          </div>

          {local_skills(%{skills: @state.local_skills})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">tools</p>
              <h2>可调用工具</h2>
            </div>
          </div>

          {tool_inventory_list(%{tools: @state.tools})}
        </section>
      </div>

      <section class="section-card" id="recent-hits">
        <div class="section-head">
          <div>
            <p class="section-kicker">hits</p>
            <h2>命中记录</h2>
          </div>
        </div>

        {run_list(%{runs: actual_hit_runs(@state.recent_runs)})}
      </section>
    </div>
    """
  end

  def memory_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero" id="memory-summary">
        <div class="section-head">
          <div>
            <p class="section-kicker">cognition</p>
            <h2>认知状态</h2>
          </div>
          <a class="ghost-link" href="/evolution">回到分流</a>
        </div>

        <div class="metric-grid">
          {metric(%{label: "SOUL", value: if(String.trim(@state.soul_preview || "") == "", do: "empty", else: "loaded"), tone: "gold"})}
          {metric(%{label: "USER", value: if(String.trim(@state.user_preview || "") == "", do: "empty", else: "loaded"), tone: "green"})}
          {metric(%{label: "MEMORY", value: format_bytes(@state.memory_bytes), tone: "ink"})}
          {metric(%{label: "认知事件", value: length(@state.recent_events), tone: "rust"})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">evidence</p>
            <h2>原文预览</h2>
          </div>
        </div>

        <div class="stack-layout stack-layout--tight">
          <article class="detail-card">
            <span class="section-kicker">SOUL.md</span>
            {code_block(%{content: @state.soul_preview})}
          </article>

          <article class="detail-card">
            <span class="section-kicker">USER.md</span>
            {code_block(%{content: @state.user_preview})}
          </article>

          <article class="detail-card">
            <span class="section-kicker">MEMORY.md</span>
            {code_block(%{content: @state.memory_preview})}
          </article>
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">changes</p>
            <h2>认知变更记录</h2>
          </div>
        </div>

        {cognition_changelog(%{events: Enum.take(@state.recent_events, 12)})}
      </section>
    </div>
    """
  end

  def sessions_panel(assigns) do
    ~H"""
    <div class="split-layout split-layout--sessions">
      <section class="section-card split-sidebar">
        <div class="section-head">
          <div>
            <p class="section-kicker">directory</p>
            <h2>会话列表</h2>
          </div>
        </div>

        {session_list(%{sessions: @state.sessions, compact: false})}
      </section>

      <div class="split-main">
        <%= if @state.selected_session do %>
          <section class="section-card section-card--hero">
            <div class="section-head">
              <div>
                <p class="section-kicker">session</p>
                <h2>{@state.selected_session.key}</h2>
              </div>
            </div>

            <div id="sessions-action-result" class="action-result"></div>

            <div class="detail-grid">
              {detail_item(%{label: "消息数", value: @state.selected_session.total_messages})}
              {detail_item(%{label: "未 consolidation", value: @state.selected_session.unconsolidated_messages})}
              {detail_item(%{label: "最后更新", value: format_timestamp(@state.selected_session.updated_at)})}
            </div>

            <div class="actions-row">
              <form hx-post="/consolidate" hx-target="#sessions-action-result" hx-swap="innerHTML" hx-indicator="#consolidate-spinner">
                <input type="hidden" name="session_key" value={@state.selected_session.key} />
                <button class="action-button action-button--primary" type="submit">运行 consolidation</button>
                <span id="consolidate-spinner" class="htmx-indicator">执行中...</span>
              </form>

              <form
                hx-post="/reset"
                hx-target="#sessions-action-result"
                hx-swap="innerHTML"
                hx-confirm="确认清空这个 session 吗？"
              >
                <input type="hidden" name="session_key" value={@state.selected_session.key} />
                <button class="action-button action-button--danger" type="submit">清空会话</button>
              </form>
            </div>
          </section>

          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">messages</p>
                <h2>会话消息</h2>
              </div>
            </div>

            <div class="message-log">
              <%= for msg <- @state.selected_session.messages do %>
                <article class="message-log__item">
                  <header>
                    <strong>{msg["role"]}</strong>
                    <span>{format_timestamp(msg["timestamp"])}</span>
                  </header>
                  <p>{msg["content"]}</p>
                </article>
              <% end %>
            </div>
          </section>
        <% else %>
          <section class="section-card">
            {empty_state(%{title: "没有找到 session", body: "先让 agent 跑起来，控制台才有可检查的会话。"})}
          </section>
        <% end %>
      </div>
    </div>
    """
  end

  def tasks_panel(assigns) do
    assigns =
      assigns
      |> Map.put(
        :selected_job,
        selected_or_first_job(assigns.state.cron_jobs, Map.get(assigns, :selected_job_id))
      )

    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--toolbar">
        <div class="metric-grid">
          {metric(%{label: "待处理任务", value: @state.summary.open, tone: "gold"})}
          {metric(%{label: "已完成任务", value: @state.summary.completed, tone: "green"})}
          {metric(%{label: "cron jobs", value: length(@state.cron_jobs), tone: "ink"})}
          {metric(%{label: "已启用 cron", value: @state.cron_status.enabled, tone: "rust"})}
          {metric(%{label: "下次唤醒", value: format_relative_time(Map.get(@state.cron_status, :next_wakeup_in) || Map.get(@state.cron_status, "next_wakeup_in")), tone: "ink"})}
        </div>
      </section>

      <div class="inspector-layout">
        <section class="section-card inspector-layout__list">
          <div class="section-head">
            <div>
              <p class="section-kicker">job list</p>
              <h2>计划任务</h2>
            </div>
          </div>

          {job_selection_list(%{
            jobs: @state.cron_jobs,
            selected_job_id: job_field(@selected_job, :id)
          })}
        </section>

        <section class="section-card inspector-layout__detail">
          <div class="section-head">
            <div>
              <p class="section-kicker">inspector</p>
              <h2>当前任务</h2>
            </div>
          </div>

          <div id="tasks-action-result" class="action-result"></div>
          {job_inspector(%{job: @selected_job})}
        </section>
      </div>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">upcoming</p>
              <h2>即将执行</h2>
            </div>
          </div>

          {upcoming_list(%{rows: @state.summary.upcoming})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">results</p>
              <h2>执行记录</h2>
            </div>
          </div>

          {task_table(%{tasks: @state.tasks})}
        </section>
      </div>
    </div>
    """
  end

  def runtime_panel(assigns) do
    assigns =
      assigns
      |> Map.put(:selected_trace, selected_or_first_trace(assigns.state))

    runtime_index_panel(assigns)
  end

  defp runtime_index_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--toolbar">
        <div id="runtime-action-result" class="action-result"></div>

        <div class="metric-grid">
          {metric(%{label: "gateway", value: gateway_status_label(@state.gateway), tone: "ink"})}
          {metric(%{label: "provider", value: get_in(@state.gateway, [:config, :provider]) || "n/a", tone: "ink"})}
          {metric(%{label: "model", value: get_in(@state.gateway, [:config, :model]) || "n/a", tone: "ink"})}
          {metric(%{label: "request trace", value: readable_bool(@state.request_trace_config["enabled"]), tone: "gold"})}
          {metric(%{label: "最近请求", value: length(@state.recent_request_traces), tone: "green"})}
          {metric(%{label: "启动时间", value: format_timestamp(@state.gateway.started_at), tone: "ink"})}
        </div>

        <%= if Map.get(@state.gateway, :external) do %>
          <p class="section-summary">网关通过独立进程运行，在此控制台无法启停</p>
        <% else %>
          <div class="actions-row">
            <%= if @state.gateway.status != :running do %>
              <form hx-post="/start_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
                <button class="action-button action-button--primary" type="submit">启动网关</button>
              </form>
            <% else %>
              <form hx-post="/stop_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
                <button class="action-button action-button--danger" type="submit">停止网关</button>
              </form>
            <% end %>
          </div>
        <% end %>
      </section>

      <div class="inspector-layout" id="recent-request-list">
        <section class="section-card inspector-layout__list">
          <div class="section-head">
            <div>
              <p class="section-kicker">traces</p>
              <h2>请求列表</h2>
            </div>
          </div>

          <%= if not @state.request_trace_config["enabled"] do %>
            <p class="section-summary">Request trace 当前关闭</p>
          <% end %>

          {request_trace_list(%{
            traces: @state.recent_request_traces,
            enabled: @state.request_trace_config["enabled"],
            selected_run_id: @selected_trace && @selected_trace.run_id
          })}
        </section>

        <section class="section-card inspector-layout__detail">
          <div class="section-head">
            <div>
              <p class="section-kicker">inspector</p>
              <h2>当前请求</h2>
            </div>
          </div>

          {request_trace_detail(%{
            trace: @selected_trace,
            enabled: @state.request_trace_config["enabled"],
            traces: @state.recent_request_traces
          })}
        </section>
      </div>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">services</p>
              <h2>注册服务</h2>
            </div>
          </div>

          {services_grid(%{services: @state.gateway.services || %{}})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">heartbeat</p>
              <h2>维护节拍</h2>
            </div>
          </div>

          <div class="detail-grid">
            {detail_item(%{label: "Enabled", value: readable_bool(@state.heartbeat.enabled)})}
            {detail_item(%{label: "Running", value: readable_bool(@state.heartbeat.running)})}
            {detail_item(%{label: "Interval", value: @state.heartbeat.interval})}
          </div>
        </section>
      </div>
    </div>
    """
  end

  def code_panel(assigns) do
    ~H"""
    <div class="split-layout split-layout--code">
      <aside class="split-sidebar">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">module</p>
              <h2>选择模块</h2>
            </div>
          </div>

          <form method="get" action="/code" class="inline-form">
            <label for="module">当前模块</label>
            <select id="module" name="module">
              <%= for module <- @state.modules do %>
                <option value={module} selected={module == @state.selected_module}>{module}</option>
              <% end %>
            </select>
            <button class="action-button" type="submit">加载模块</button>
          </form>
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">versions</p>
              <h2>版本轨迹</h2>
            </div>
          </div>

          {version_list(%{versions: @state.versions, selected_module: @state.selected_module})}
        </section>
      </aside>

      <div class="split-main">
        <section class="section-card section-card--hero" id="source-preview">
          <div class="section-head">
            <div>
              <p class="section-kicker">source</p>
              <h2>当前源码</h2>
            </div>
          </div>

          <div class="detail-grid">
            {detail_item(%{label: "当前模块", value: @state.selected_module})}
            {detail_item(%{label: "版本数", value: length(@state.versions)})}
            {detail_item(%{label: "最近代码事件", value: length(@state.recent_events)})}
          </div>

          {code_block(%{content: @state.current_source})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">events</p>
              <h2>代码变更记录</h2>
            </div>
          </div>

          {audit_glance(%{rows: Enum.take(@state.recent_events, 8)})}
        </section>

        <section class="section-card section-card--editor">
          <div class="section-head">
            <div>
              <p class="section-kicker">editor</p>
              <h2>热更与回滚</h2>
            </div>
          </div>

          <div id="code-action-result" class="action-result"></div>

          <form class="editor-form editor-form--candidate">
            <input type="hidden" name="module" value={@state.selected_module} />

            <label for="reason">变更原因</label>
            <input id="reason" type="text" name="reason" value="Console hot upgrade" />

            <label for="code">候选新源码</label>
            <textarea
              id="code"
              name="code"
              placeholder="把候选源码粘贴到这里，再预览 diff 或应用热更。当前源码请看上方只读预览。"
            ></textarea>

            <div class="actions-row">
              <button
                type="submit"
                class="action-button"
                hx-post="/preview"
                hx-target="#code-action-result"
                hx-swap="innerHTML"
              >
                预览 diff
              </button>

              <button
                type="submit"
                class="action-button action-button--primary"
                hx-post="/hot_upgrade"
                hx-target="#code-action-result"
                hx-swap="innerHTML"
              >
                应用热更
              </button>
            </div>
          </form>

          <form class="inline-form" hx-post="/rollback" hx-target="#code-action-result" hx-swap="innerHTML">
            <input type="hidden" name="module" value={@state.selected_module} />
            <label for="version_id">回滚目标</label>
            <select id="version_id" name="version_id">
              <option value="">最近一个历史版本</option>
              <%= for version <- @state.versions do %>
                <option value={version.id}>{version.id}</option>
              <% end %>
            </select>
            <button class="action-button action-button--danger" type="submit">回滚</button>
          </form>
        </section>
      </div>
    </div>
    """
  end

  def notice(assigns) do
    ~H"""
    <article class={"notice notice--#{@tone}"}>
      <strong>{@title}</strong>
      <p>{@body}</p>
    </article>
    """
  end

  def diff_preview(assigns) do
    ~H"""
    <section class="diff-preview">
      <header class="section-head">
        <div>
          <p class="section-kicker">Preview</p>
          <h2>{@module}</h2>
        </div>
      </header>

      {code_block(%{content: @diff})}
    </section>
    """
  end

  defp layer_map(assigns) do
    ~H"""
    <div class="layer-grid">
      <%= for layer <- @layers do %>
        <a class="layer-card" href={layer.href}>
          <header class="layer-card__head">
            <strong>{layer.key}</strong>
            <span>进入</span>
          </header>
          <p class="layer-card__summary">{layer.summary}</p>
          <small class="layer-card__meta">{compress_layer_detail(layer.detail)}</small>
        </a>
      <% end %>
    </div>
    """
  end

  defp tool_inventory_list(assigns) do
    ~H"""
    <div class="tool-clusters">
      <section class="tool-cluster">
        <header class="tool-cluster__head">
          <strong>builtin tools</strong>
          <span>{length(@tools.builtin)}</span>
        </header>
        {tool_entries(%{entries: @tools.builtin, empty_title: "没有 builtin tools", empty_body: "Registry 里没有检测到可展示的内置工具。"})}
      </section>

      <section class="tool-cluster">
        <header class="tool-cluster__head">
          <strong>custom tools</strong>
          <span>{length(@tools.custom)}</span>
        </header>
        {tool_entries(%{entries: @tools.custom, empty_title: "没有 custom tools", empty_body: "tools/ 下还没有自定义能力。"})}
      </section>
    </div>
    """
  end

  defp tool_entries(assigns) do
    ~H"""
    <%= if @entries == [] do %>
      {empty_state(%{title: @empty_title, body: @empty_body})}
    <% else %>
      <div class="stack-list">
        <%= for entry <- @entries do %>
          <article class="stack-list__item">
            <header>
              <strong>{entry["name"]}</strong>
              <span>{Enum.map_join(entry["layers"] || ["tool"], " / ", &String.upcase/1)}</span>
            </header>
            <p>{entry["description"] || entry["module"] || entry["origin"] || "No description"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp last_cycle_summary(assigns) do
    completed =
      Enum.find(assigns.events, fn e ->
        Map.get(e, "event") == "evolution.cycle_completed"
      end)

    assigns = Map.put(assigns, :completed, completed)

    ~H"""
    <%= if @completed do %>
      <div class="detail-grid">
        {detail_item(%{label: "时间", value: format_timestamp(Map.get(@completed, "timestamp"))})}
        {detail_item(%{label: "触发方式", value: get_in(@completed, ["payload", "trigger"]) || "n/a"})}
        {detail_item(%{label: "Soul 更新", value: get_in(@completed, ["payload", "soul_updates"]) || 0})}
        {detail_item(%{label: "Memory 更新", value: get_in(@completed, ["payload", "memory_updates"]) || 0})}
        {detail_item(%{label: "Skill 候选", value: get_in(@completed, ["payload", "skill_candidates"]) || 0})}
      </div>
    <% else %>
      {empty_state(%{title: "还没有执行过 cycle", body: "点击上方按钮手动触发一次进化。"})}
    <% end %>
    """
  end

  defp cognition_changelog(assigns) do
    assigns = Map.put(assigns, :events, assigns.events |> Enum.map(&classify_cognition_event/1))

    ~H"""
    <%= if @events == [] do %>
      {empty_state(%{title: "暂无认知变更", body: "进化 cycle 执行后，这里会按层显示变更记录。"})}
    <% else %>
      <div class="stack-list">
        <%= for {layer, event} <- @events do %>
          <article class="stack-list__item">
            <header>
              <span class={"status-pill status-pill--#{layer_tone(layer)}"}>{layer}</span>
              <span>{format_timestamp(Map.get(event, "timestamp"))}</span>
            </header>
            <p>{get_in(event, ["payload", "content"]) || payload_summary(Map.get(event, "payload", %{}))}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp classify_cognition_event(event) do
    case Map.get(event, "event", "") do
      "evolution.soul_updated" -> {"SOUL", event}
      "evolution.user_updated" -> {"USER", event}
      "evolution.memory_updated" -> {"MEMORY", event}
      "memory." <> _ -> {"MEMORY", event}
      _ -> {"OTHER", event}
    end
  end

  defp layer_tone("SOUL"), do: "gold"
  defp layer_tone("USER"), do: "green"
  defp layer_tone("MEMORY"), do: "ink"
  defp layer_tone(_), do: "ink"

  defp audit_glance(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "暂无相关记录", body: "相关动作发生后，这里会出现最近几条摘要。"})}
    <% else %>
      <div class="stack-list">
        <%= for row <- @rows do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(row, "event")}</strong>
              <span>{format_timestamp(Map.get(row, "timestamp"))}</span>
            </header>
            <p>{payload_summary(Map.get(row, "payload", %{}))}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp metric(assigns) do
    ~H"""
    <article class={"metric-card metric-card--#{@tone}"}>
      <span class="metric-card__label">{@label}</span>
      <strong class="metric-card__value">{@value}</strong>
    </article>
    """
  end

  defp services_grid(assigns) do
    ~H"""
    <div class="service-grid">
      <%= for {name, alive} <- Enum.sort(@services) do %>
        <article class="service-chip">
          <span class="service-chip__label">{name}</span>

          <span class={"status-pill #{if alive, do: "status-pill--ok", else: "status-pill--dead"}"}>
            {if alive, do: "up", else: "down"}
          </span>
        </article>
      <% end %>
    </div>
    """
  end

  defp job_selection_list(assigns) do
    ~H"""
    <%= if @jobs == [] do %>
      {empty_state(%{title: "没有 cron jobs", body: "定时任务创建后，这里会出现可选中的任务对象。"})}
    <% else %>
      <div class="selection-list">
        <%= for job <- @jobs do %>
          <% job_id = job |> job_field(:id) |> to_string() %>
          <a
            class={"selection-card #{if @selected_job_id == job_id, do: "is-active", else: ""}"}
            href={"/tasks?job=#{URI.encode_www_form(job_id)}"}
          >
            <header class="selection-card__header">
              <div class="selection-card__main">
                <strong>{clamp_text(to_string(job_field(job, :name) || ""), 56)}</strong>
                <div class="selection-card__meta">
                  <span>{format_schedule(job_field(job, :schedule) || %{})}</span>
                  <span>{job_field(job, :channel) || "default"}</span>
                  <span>next {format_timestamp(job_field(job, :next_run))}</span>
                </div>
              </div>
              <span class={"status-pill #{if job_field(job, :enabled), do: "status-pill--ok", else: "status-pill--ink"}"}>
                {if job_field(job, :enabled), do: "enabled", else: "disabled"}
              </span>
            </header>
          </a>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp job_inspector(assigns) do
    ~H"""
    <%= if is_nil(@job) do %>
      {empty_state(%{title: "没有可检查的任务", body: "先创建或启用一个 cron job，再从左侧列表里选中它。"})}
    <% else %>
      <div class="stack-layout stack-layout--tight">
        <div class="detail-grid">
          {detail_item(%{label: "状态", value: job_status_label(@job)})}
          {detail_item(%{label: "Schedule", value: format_schedule(job_field(@job, :schedule) || %{})})}
          {detail_item(%{label: "Channel", value: job_field(@job, :channel) || "default"})}
          {detail_item(%{label: "下次执行", value: format_timestamp(job_field(@job, :next_run))})}
          {detail_item(%{label: "最近执行", value: format_timestamp(job_field(@job, :last_run))})}
          {detail_item(%{label: "最近结果", value: job_field(@job, :last_status) || "n/a"})}
        </div>

        <article class="detail-card">
          <span class="section-kicker">message</span>
          <p>{to_string(job_field(@job, :message) || "(empty)")}</p>
        </article>

        <div class="actions-row">
          <form hx-post="/run_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
            <input type="hidden" name="job_id" value={job_field(@job, :id)} />
            <button class="action-button action-button--primary" type="submit">Run Now</button>
          </form>

          <%= if job_field(@job, :enabled) do %>
            <form hx-post="/disable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
              <input type="hidden" name="job_id" value={job_field(@job, :id)} />
              <button class="action-button action-button--danger" type="submit">Disable</button>
            </form>
          <% else %>
            <form hx-post="/enable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
              <input type="hidden" name="job_id" value={job_field(@job, :id)} />
              <button class="action-button action-button--secondary" type="submit">Enable</button>
            </form>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp signal_selection_list(assigns) do
    ~H"""
    <%= if @signals == [] do %>
      {empty_state(%{title: "目前没有 pending signals", body: "这通常意味着最近的自我修正已被整理进记忆或进化流程。"})}
    <% else %>
      <div class="selection-list">
        <%= for signal <- @signals do %>
          <% current_signal_id = signal_id(signal) %>
          <a
            class={"selection-card #{if @selected_signal_id == current_signal_id, do: "is-active", else: ""}"}
            href={"/evolution?signal=#{URI.encode_www_form(current_signal_id)}"}
          >
            <header class="selection-card__header">
              <div class="selection-card__main">
                <strong>{Map.get(signal, "source", "unknown")}</strong>
                <p>{clamp_text(Map.get(signal, "signal", ""), 96)}</p>
              </div>
              <span class={"status-pill status-pill--#{signal_layer_tone(signal)}"}>{signal_layer_label(signal)}</span>
            </header>
            <div class="selection-card__meta">
              <span>{format_timestamp(Map.get(signal, "timestamp"))}</span>
            </div>
          </a>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp signal_inspector(assigns) do
    ~H"""
    <%= if is_nil(@signal) do %>
      {empty_state(%{title: "当前没有待处理信号", body: "如果你仍想主动整理一次，可以直接手动运行 cycle。"})}
      <div class="actions-row">
        <form hx-post="/trigger_cycle" hx-target="#evolution-action-result" hx-swap="innerHTML" hx-indicator="#cycle-spinner">
          <button class="action-button action-button--primary" type="submit">手动运行 cycle</button>
          <span id="cycle-spinner" class="htmx-indicator">执行中...</span>
        </form>
      </div>
    <% else %>
      <div class="stack-layout stack-layout--tight">
        <div class="detail-grid">
          {detail_item(%{label: "来源", value: Map.get(@signal, "source", "unknown")})}
          {detail_item(%{label: "时间", value: format_timestamp(Map.get(@signal, "timestamp"))})}
          {detail_item(%{label: "建议落层", value: signal_layer_label(@signal)})}
          {detail_item(%{label: "目标页", value: signal_target_label(@signal)})}
        </div>

        <article class="detail-card">
          <span class="section-kicker">signal</span>
          <p>{Map.get(@signal, "signal", "")}</p>
        </article>

        <%= if signal_context_present?(@signal) do %>
          <article class="detail-card">
            <span class="section-kicker">context</span>
            {code_block(%{content: payload_dump(Map.get(@signal, "context", %{}))})}
          </article>
        <% end %>

        <div class="actions-row">
          <form hx-post="/trigger_cycle" hx-target="#evolution-action-result" hx-swap="innerHTML" hx-indicator="#cycle-spinner">
            <button class="action-button action-button--primary" type="submit">Run Cycle</button>
            <span id="cycle-spinner" class="htmx-indicator">执行中...</span>
          </form>

          <%= if href = signal_target_href(@signal) do %>
            <a class="action-button action-button--secondary" href={href}>打开目标层</a>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp signal_list(assigns) do
    ~H"""
    <%= if @signals == [] do %>
      {empty_state(%{title: "目前没有 pending signals", body: "这通常意味着最近的自我修正已被整理进记忆或进化流程。"})}
    <% else %>
      <div class="stack-list">
        <%= for signal <- @signals do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(signal, "source", "unknown")}</strong>
            </header>
            <p>{Map.get(signal, "signal", "")}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp session_list(assigns) do
    ~H"""
    <%= if @sessions == [] do %>
      {empty_state(%{title: "还没有 session", body: "先通过聊天入口或手工 prompt 跑一次 agent。"})}
    <% else %>
      <div class="stack-list">
        <%= for session <- @sessions do %>
          <a class="stack-list__item" href={"/sessions?session_key=#{URI.encode(session.key)}"}>
            <header>
              <strong>{session.key}</strong>
              <span>{session.total_messages} msgs</span>
            </header>
            <p>{session.last_message || "No messages yet"}</p>
          </a>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp upcoming_list(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "没有即将到来的提醒", body: "当前没有待触发的任务或 follow-up。"})}
    <% else %>
      <div class="stack-list">
        <%= for row <- @rows do %>
          <article class="stack-list__item">
            <header>
              <strong>{Map.get(row, "title")}</strong>
              <span>{Map.get(row, "status")}</span>
            </header>
            <p>{Map.get(row, "summary") || "No summary"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp event_feed(assigns) do
    ~H"""
    <%= if @events == [] do %>
      {empty_state(%{title: "暂无实时事件", body: "Gateway、任务或进化动作发生后，这里会持续更新。"})}
    <% else %>
      <div class="event-feed">
        <%= for event <- @events do %>
          <article class="event-feed__item">
            <header>
              <span class="status-pill">{event["topic"]}</span>
              <time>{format_timestamp(event["timestamp"])}</time>
            </header>
            <strong>{event["summary"]}</strong>
            <p>{event["kind"]}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp local_skills(assigns) do
    ~H"""
    <%= if @skills == [] do %>
      {empty_state(%{title: "没有检测到本地 skills", body: "skills 目录为空时，这里不会渲染任何条目。"})}
    <% else %>
      <div class="stack-list">
        <%= for skill <- @skills do %>
          <article class="stack-list__item">
            <header>
              <strong>{skill_name(skill)}</strong>
              <span>{if skill_draft?(skill), do: "draft", else: "published"}</span>
            </header>
            <p>{skill_description(skill)}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp run_list(assigns) do
    ~H"""
    <%= if @runs == [] do %>
      {empty_state(%{title: "最近还没有实际命中记录", body: "只有这次运行真的选中了 skill package，才会出现在这里。"})}
    <% else %>
      <div class="audit-table">
        <%= for run <- @runs do %>
          <article class="audit-table__row">
            <time>{format_timestamp(run.inserted_at)}</time>
            <strong>{hit_run_title(run)}</strong>
            <p>{run.prompt || "No prompt preview"}</p>
            <%= if result = hit_run_result(run) do %>
              <p>{result}</p>
            <% end %>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp request_trace_list(assigns) do
    ~H"""
    <%= cond do %>
      <% @traces == [] and not @enabled -> %>
        {empty_state(%{title: "Request trace 未开启", body: "先在配置里打开 `request_trace.enabled`，之后的新请求才会落到这里。"})}
      <% @traces == [] -> %>
        {empty_state(%{title: "还没有 request trace", body: "先跑一条新请求，运行时页才会出现可查看的轨迹。"})}
      <% true -> %>
        <div class="stack-list trace-index">
          <%= for trace <- @traces do %>
            <a
              class={"stack-list__item trace-item #{if @selected_run_id == trace.run_id, do: "is-active", else: ""}"}
              href={"/runtime?trace=#{URI.encode_www_form(trace.run_id)}"}
            >
              <header class="trace-item__head">
                <div class="trace-item__title">
                  <strong>{clamp_text(trace.prompt || "No prompt preview", 72)}</strong>
                  <small>{trace.run_id}</small>
                </div>
                <div class="trace-item__status">
                  <span class={"status-pill #{trace_status_class(trace.status)}"}>{trace.status}</span>
                  <small>{format_timestamp(Map.get(trace, :inserted_at))}</small>
                </div>
              </header>
              <div class="trace-meta-line">
                <span>{trace.llm_rounds} rounds</span>
                <span>{trace.tool_count} tool results</span>
                <%= if (Map.get(trace, :skill_call_count, 0) || 0) > 0 do %>
                  <span>{Map.get(trace, :skill_call_count, 0)} skill calls</span>
                <% end %>
                <%= if skill_names = request_trace_package_name_list(trace.selected_packages) do %>
                  <span>{"skills: " <> Enum.join(skill_names, ", ")}</span>
                <% end %>
              </div>
            </a>
          <% end %>
        </div>
    <% end %>
    """
  end

  defp request_trace_detail(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@trace) and @traces == [] and not @enabled -> %>
        {empty_state(%{title: "Trace 当前关闭", body: "首版 trace 默认关闭；打开配置后，这里会开始累积新请求的完整回合。"})}
      <% is_nil(@trace) -> %>
        {empty_state(%{title: "选择一条请求 trace", body: "从左侧请求列表中选中一条记录，再在这里查看细节。"})}
      <% true -> %>
        <div class="stack-layout stack-layout--tight">
          <div class="detail-grid">
            {detail_item(%{label: "Run ID", value: Map.get(@trace, :run_id)})}
            {detail_item(%{label: "Status", value: Map.get(@trace, :status)})}
            {detail_item(%{label: "Channel", value: Map.get(@trace, :channel) || "n/a"})}
            {detail_item(%{label: "Chat ID", value: Map.get(@trace, :chat_id) || "n/a"})}
            {detail_item(%{label: "LLM Rounds", value: Map.get(@trace, :llm_rounds)})}
            {detail_item(%{label: "Tool Calls", value: Map.get(@trace, :tool_count)})}
          </div>

          <article class="detail-card">
            <span class="section-kicker">prompt</span>
            {code_block(%{content: Map.get(@trace, :prompt) || "(empty)"})}
          </article>

          <%= if Map.get(@trace, :selected_packages, []) != [] do %>
            <article class="detail-card">
              <span class="section-kicker">skill 命中</span>
              {request_trace_package_cards(%{packages: Map.get(@trace, :selected_packages, [])})}
            </article>
          <% end %>

          <article class="detail-card">
            <span class="section-kicker">tool 调用</span>
            {request_trace_tool_activity(%{
              available_tools: Map.get(@trace, :available_tools, []),
              activity: Map.get(@trace, :tool_activity, [])
            })}
          </article>

          <article class="detail-card">
            <span class="section-kicker">agent 回合</span>
            {request_trace_llm_turns(%{turns: Map.get(@trace, :llm_turns, [])})}
          </article>

          <%= if Map.get(@trace, :runtime_system_messages, []) != [] do %>
            <article class="detail-card">
              <span class="section-kicker">runtime system messages</span>
              {code_block(%{content: Enum.join(Map.get(@trace, :runtime_system_messages, []), "\n\n---\n\n")})}
            </article>
          <% end %>

          <article class="detail-card">
            <span class="section-kicker">原始事件</span>

            <div class="audit-table">
              <%= for event <- Map.get(@trace, :events, []) do %>
                <article class="audit-table__row">
                  <time>{format_timestamp(Map.get(event, "inserted_at"))}</time>
                  <strong>{request_trace_event_title(event)}</strong>
                  <p>{request_trace_event_summary(event)}</p>
                  <details>
                    <summary>查看原文</summary>
                    {code_block(%{content: payload_dump(event)})}
                  </details>
                </article>
              <% end %>
            </div>
          </article>

          <%= if Map.get(@trace, :result) do %>
            <article class="detail-card">
              <span class="section-kicker">final result</span>
              {code_block(%{content: to_string(Map.get(@trace, :result))})}
            </article>
          <% end %>
        </div>
    <% end %>
    """
  end

  defp trace_chip_row(assigns) do
    ~H"""
    <div class="trace-chip-row">
      <span class="trace-chip-row__label">{@label}</span>
      <div class="trace-chip-row__items">
        <%= for item <- @items do %>
          <span class={"trace-chip trace-chip--#{@tone}"}>{item}</span>
        <% end %>
      </div>
    </div>
    """
  end

  defp request_trace_package_cards(assigns) do
    ~H"""
    <div class="trace-package-grid">
      <%= for package <- @packages do %>
        <article class="trace-package-card">
          <header>
            <strong>{package["name"] || package[:name] || "unknown skill"}</strong>
            <span>{package["execution_mode"] || package[:execution_mode] || "knowledge"}</span>
          </header>
          <p>
            <%= if tool_name = package["tool_name"] || package[:tool_name] do %>
              {"通过 " <> trace_display_tool_name(tool_name) <> " 实际执行"}
            <% else %>
              作为提示约束注入当前回合
            <% end %>
          </p>
        </article>
      <% end %>
    </div>
    """
  end

  defp request_trace_tool_activity(assigns) do
    ~H"""
    <div class="stack-layout stack-layout--tight">
      <%= if @activity == [] do %>
        {empty_state(%{title: "这条请求没有实际 tool 调用", body: "如果本轮只靠提示词和历史上下文回答，这里会保持为空。"})}
      <% else %>
        <div class="stack-list trace-call-list">
          <%= for activity <- @activity do %>
            <article class={"stack-list__item trace-call-card #{if activity.kind == :skill, do: "trace-call-card--skill", else: ""}"}>
              <header>
                <div class="trace-call-card__title">
                  <strong>{trace_display_tool_name(activity.name)}</strong>
                  <small>
                    {"round " <> to_string(activity.iteration || "?") <> " · " <>
                       to_string(activity.tool_call_id || "no id")}
                  </small>
                </div>
                <span class={"status-pill #{trace_result_tone(activity.result)}"}>{trace_kind_label(activity.kind)}</span>
              </header>
              <p>{trace_result_preview(activity.result)}</p>
              <details>
                <summary>查看参数和结果</summary>
                <%= if activity.arguments do %>
                  <span class="section-kicker">arguments</span>
                  {code_block(%{content: payload_dump(activity.arguments)})}
                <% end %>
                <span class="section-kicker">result</span>
                {code_block(%{content: to_string(activity.result || "(no recorded result)")})}
              </details>
            </article>
          <% end %>
        </div>
      <% end %>

      <%= if @available_tools != [] do %>
        <details class="trace-subsection">
          <summary>{"查看这一轮可用的 tools（" <> to_string(length(@available_tools)) <> "）"}</summary>
          {trace_chip_row(%{
            label: "available",
            items: Enum.map(@available_tools, &trace_display_tool_name(&1.name)),
            tone: "tool"
          })}

          <div class="stack-list">
            <%= for tool <- @available_tools do %>
              <article class="stack-list__item">
                <header>
                  <strong>{trace_display_tool_name(tool.name)}</strong>
                  <span>{if trace_skill_tool_name?(tool.name), do: "skill", else: "tool"}</span>
                </header>
                <p>{tool.description || "No description"}</p>
                <details>
                  <summary>查看参数</summary>
                  {code_block(%{content: payload_dump(tool.parameters)})}
                </details>
              </article>
            <% end %>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  defp request_trace_llm_turns(assigns) do
    ~H"""
    <%= if @turns == [] do %>
      {empty_state(%{title: "没有 LLM 回合记录", body: "这通常意味着请求还没真正进入模型调用。"})}
    <% else %>
      <div class="stack-list trace-turn-list">
        <%= for turn <- @turns do %>
          <article class="stack-list__item trace-turn">
            <header>
              <div class="trace-turn__title">
                <strong>{"Round " <> to_string(turn.iteration || "?")}</strong>
                <small>{format_timestamp(turn.inserted_at)}</small>
              </div>
              <span>{trace_turn_meta(turn)}</span>
            </header>

            <%= if turn.available_tool_names != [] do %>
              {trace_chip_row(%{
                label: "visible tools",
                items: Enum.map(turn.available_tool_names, &trace_display_tool_name/1),
                tone: "tool"
              })}
            <% end %>

            <%= if turn.tool_calls != [] do %>
              {trace_chip_row(%{
                label: "requested calls",
                items: Enum.map(turn.tool_calls, &trace_display_tool_name(&1.name)),
                tone: "skill"
              })}
            <% end %>

            <p>{trace_result_preview(turn.content)}</p>

            <details>
              <summary>查看本轮 request / response</summary>
              <span class="section-kicker">request</span>
              {code_block(%{content: payload_dump(turn.request)})}
              <span class="section-kicker">response</span>
              {code_block(%{content: payload_dump(turn.response)})}
            </details>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp task_table(assigns) do
    ~H"""
    <%= if @tasks == [] do %>
      {empty_state(%{title: "没有任务记录", body: "任务工具开始使用后，这里会展示完整任务列表。"})}
    <% else %>
      <div class="audit-table">
        <%= for task <- Enum.take(@tasks, 30) do %>
          <article class="audit-table__row">
            <time>{format_timestamp(task["updated_at"])}</time>
            <strong>{task["title"]}</strong>
            <p>{task["status"]} · {task["summary"] || "No summary"}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp version_list(assigns) do
    ~H"""
    <%= if @versions == [] do %>
      {empty_state(%{title: "还没有 code versions", body: "第一次热更成功后，这里会出现版本轨迹。"})}
    <% else %>
      <div class="audit-table">
        <%= for version <- @versions do %>
          <article class="audit-table__row">
            <time>{version.timestamp}</time>
            <strong>{version.id}</strong>
            <p>{@selected_module}</p>
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp detail_item(assigns) do
    ~H"""
    <article class="detail-item">
      <span>{@label}</span>
      <strong>{@value || "n/a"}</strong>
    </article>
    """
  end

  defp code_block(assigns) do
    ~H"""
    <pre class="code-block"><code>{@content || "(empty)"}</code></pre>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <article class="empty-state">
      <strong>{@title}</strong>
      <p>{@body}</p>
    </article>
    """
  end

  defp page_name(path), do: path |> page_meta() |> Map.get(:name)
  defp page_group(path), do: path |> page_meta() |> Map.get(:group)

  defp page_meta(path), do: Map.get(@page_meta, path, %{name: "分流", group: "进化层"})

  defp payload_preview(payload) do
    inspect(payload, pretty: true, printable_limit: 4_000, limit: 80)
  end

  defp payload_dump(payload) do
    inspect(payload, pretty: true, printable_limit: 100_000, limit: :infinity)
  end

  defp payload_summary(payload) when payload in [%{}, nil], do: "没有额外 payload"

  defp payload_summary(payload) do
    payload
    |> payload_preview()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
  end

  defp format_timestamp(nil), do: "n/a"
  defp format_timestamp(""), do: "n/a"

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> "n/a"
  end

  defp format_timestamp(%DateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp format_timestamp(%NaiveDateTime{} = value),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  defp format_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      _ -> value
    end
  end

  defp readable_bool(true), do: "yes"
  defp readable_bool(false), do: "no"
  defp readable_bool(nil), do: "n/a"
  defp readable_bool(value), do: to_string(value)

  defp format_schedule(%{type: :every, seconds: s}) when s < 60, do: "every #{s}s"
  defp format_schedule(%{type: :every, seconds: s}) when s < 3600, do: "every #{div(s, 60)}m"
  defp format_schedule(%{type: :every, seconds: s}), do: "every #{div(s, 3600)}h"
  defp format_schedule(%{type: :cron, expr: expr}), do: expr
  defp format_schedule(%{type: :at, timestamp: ts}), do: "once at #{format_timestamp(ts)}"
  defp format_schedule(%{"type" => "every", "seconds" => s}) when s < 60, do: "every #{s}s"

  defp format_schedule(%{"type" => "every", "seconds" => s}) when s < 3600,
    do: "every #{div(s, 60)}m"

  defp format_schedule(%{"type" => "every", "seconds" => s}), do: "every #{div(s, 3600)}h"
  defp format_schedule(%{"type" => "cron", "expr" => expr}), do: expr

  defp format_schedule(%{"type" => "at", "timestamp" => ts}),
    do: "once at #{format_timestamp(ts)}"

  defp format_schedule(other), do: inspect(other)

  defp clamp_text(nil, _), do: ""
  defp clamp_text(s, max) when byte_size(s) <= max, do: s
  defp clamp_text(s, max), do: String.slice(s, 0, max) <> "..."

  defp format_relative_time(nil), do: "n/a"
  defp format_relative_time(seconds) when is_number(seconds) and seconds < 60, do: "#{seconds}s"

  defp format_relative_time(seconds) when is_number(seconds) and seconds < 3600,
    do: "#{div(trunc(seconds), 60)}m"

  defp format_relative_time(seconds) when is_number(seconds),
    do: "#{div(trunc(seconds), 3600)}h #{rem(div(trunc(seconds), 60), 60)}m"

  defp format_relative_time(_), do: "n/a"

  defp format_bytes(nil), do: "n/a"
  defp format_bytes(bytes) when is_number(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when is_number(bytes) and bytes < 1_048_576,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when is_number(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(_), do: "n/a"

  defp gateway_status_label(%{external: true, status: status}), do: "#{status} (独立进程)"
  defp gateway_status_label(%{status: status}), do: status

  defp job_field(%{__struct__: _} = job, key), do: Map.get(job, key)
  defp job_field(job, key) when is_map(job), do: Map.get(job, key) || Map.get(job, to_string(key))

  defp selected_or_first_job(jobs, selected_job_id) do
    jobs
    |> Enum.find(fn job -> to_string(job_field(job, :id)) == to_string(selected_job_id || "") end)
    |> case do
      nil -> List.first(jobs)
      job -> job
    end
  end

  defp selected_or_first_signal(signals, selected_signal_id) do
    signals
    |> Enum.find(fn signal -> signal_id(signal) == to_string(selected_signal_id || "") end)
    |> case do
      nil -> List.first(signals)
      signal -> signal
    end
  end

  defp selected_or_first_trace(state) do
    Map.get(state, :selected_request_trace) ||
      List.first(Map.get(state, :recent_request_traces, []))
  end

  defp last_cycle_event(events) do
    Enum.find(events, fn event ->
      Map.get(event, "event") == "evolution.cycle_completed"
    end)
  end

  defp job_status_label(job) do
    enabled = job_field(job, :enabled)
    last_status = job_field(job, :last_status)

    cond do
      enabled && is_binary(last_status) && last_status != "" -> "enabled · #{last_status}"
      enabled -> "enabled"
      is_binary(last_status) && last_status != "" -> "disabled · #{last_status}"
      true -> "disabled"
    end
  end

  defp signal_id(nil), do: nil

  defp signal_id(signal) do
    timestamp = Map.get(signal, "timestamp", "")
    source = Map.get(signal, "source", "unknown")
    "#{timestamp}:#{source}"
  end

  defp signal_layer(signal) do
    signal
    |> Map.get("context", %{})
    |> case do
      %{} = context -> Map.get(context, "layer") || Map.get(context, :layer)
      _ -> nil
    end
    |> case do
      nil -> nil
      layer -> layer |> to_string() |> String.upcase()
    end
  end

  defp signal_layer_label(signal), do: signal_layer(signal) || "待判断"

  defp signal_layer_tone(signal) do
    case signal_layer(signal) do
      "SOUL" -> "gold"
      "USER" -> "green"
      "MEMORY" -> "ink"
      "SKILL" -> "live"
      "TOOL" -> "live"
      "CODE" -> "dead"
      _ -> "ink"
    end
  end

  defp signal_target_href(signal) do
    case signal_layer(signal) do
      "SOUL" -> "/memory"
      "USER" -> "/memory"
      "MEMORY" -> "/memory"
      "SKILL" -> "/skills"
      "TOOL" -> "/skills"
      "CODE" -> "/code"
      _ -> nil
    end
  end

  defp signal_target_label(signal) do
    case signal_target_href(signal) do
      "/memory" -> "认知"
      "/skills" -> "能力"
      "/code" -> "代码"
      _ -> "待判断"
    end
  end

  defp signal_context_present?(signal) do
    case Map.get(signal, "context") do
      %{} = context -> map_size(context) > 0
      _ -> false
    end
  end

  defp compress_layer_detail(detail) do
    detail
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 68)
  end

  defp skill_name(skill), do: Map.get(skill, :name) || Map.get(skill, "name")

  defp skill_description(skill) do
    Map.get(skill, :display_description) || Map.get(skill, "display_description") ||
      Map.get(skill, :description) || Map.get(skill, "description") || "No description"
  end

  defp skill_draft?(skill), do: Map.get(skill, :draft) == true or Map.get(skill, "draft") == true

  defp request_trace_package_name_list(packages) when is_list(packages) do
    packages
    |> Enum.map(fn package -> Map.get(package, "name") || Map.get(package, :name) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      names -> names
    end
  end

  defp request_trace_package_name_list(_), do: nil

  defp trace_status_class("completed"), do: "status-pill--ok"
  defp trace_status_class("ok"), do: "status-pill--ok"
  defp trace_status_class("failed"), do: "status-pill--dead"
  defp trace_status_class("error"), do: "status-pill--dead"
  defp trace_status_class(_status), do: "status-pill--live"

  defp trace_kind_label(:skill), do: "skill"
  defp trace_kind_label(_kind), do: "tool"

  defp trace_result_tone(result) when is_binary(result) do
    if String.starts_with?(result, "Error:"), do: "status-pill--dead", else: "status-pill--live"
  end

  defp trace_result_tone(_result), do: "status-pill--live"

  defp trace_display_tool_name(name) when is_binary(name) do
    name
    |> String.replace_prefix("skill_run__", "skill:")
  end

  defp trace_display_tool_name(name), do: to_string(name || "unknown")

  defp trace_skill_tool_name?(name) when is_binary(name),
    do: String.starts_with?(name, "skill_run__")

  defp trace_skill_tool_name?(_name), do: false

  defp trace_result_preview(content) do
    content
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> "没有可展示的文本内容"
      text -> String.slice(text, 0, 220)
    end
  end

  defp trace_turn_meta(turn) do
    [
      "#{turn.message_count || 0} messages",
      "#{length(turn.tool_calls || [])} calls",
      turn.duration_ms && "#{turn.duration_ms} ms",
      turn.finish_reason
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp request_trace_event_title(%{"type" => "request_started"}), do: "Request Started"
  defp request_trace_event_title(%{"type" => "request_completed"}), do: "Request Completed"

  defp request_trace_event_title(%{"type" => "llm_request"} = event),
    do: "LLM Request · Round #{Map.get(event, "iteration", "?")}"

  defp request_trace_event_title(%{"type" => "llm_response"} = event),
    do: "LLM Response · Round #{Map.get(event, "iteration", "?")}"

  defp request_trace_event_title(%{"type" => "tool_result"} = event),
    do: "Tool Result · #{Map.get(event, "tool", "unknown")}"

  defp request_trace_event_title(event), do: Map.get(event, "type", "trace_event")

  defp request_trace_event_summary(%{"type" => "request_started"} = event) do
    prompt = Map.get(event, "prompt", "") |> to_string() |> String.slice(0, 180)
    channel = Map.get(event, "channel") || "unknown"
    chat_id = Map.get(event, "chat_id") || "n/a"
    "#{channel} · #{chat_id} · #{prompt}"
  end

  defp request_trace_event_summary(%{"type" => "llm_request"} = event) do
    messages = Map.get(event, "messages", [])
    tools = Map.get(event, "tools", [])
    "#{length(messages)} messages · #{length(tools)} tools"
  end

  defp request_trace_event_summary(%{"type" => "llm_response"} = event) do
    tool_calls = Map.get(event, "tool_calls", [])
    content = Map.get(event, "content", "") |> to_string() |> String.slice(0, 180)

    cond do
      is_list(tool_calls) and tool_calls != [] -> "#{length(tool_calls)} tool calls"
      content != "" -> content
      true -> "No assistant text content"
    end
  end

  defp request_trace_event_summary(%{"type" => "tool_result"} = event) do
    Map.get(event, "content", "")
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
  end

  defp request_trace_event_summary(%{"type" => "request_completed"} = event) do
    status = Map.get(event, "status", "completed")
    result = Map.get(event, "result", "") |> to_string() |> String.slice(0, 180)

    if result == "" do
      status
    else
      "#{status} · #{result}"
    end
  end

  defp request_trace_event_summary(event) do
    event
    |> payload_preview()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 180)
  end

  defp actual_hit_runs(runs) do
    runs
    |> Enum.filter(fn run ->
      run
      |> Map.get(:packages, Map.get(run, "packages", []))
      |> case do
        packages when is_list(packages) -> packages != []
        _ -> false
      end
    end)
    |> Enum.take(12)
  end

  defp hit_run_title(run) do
    names =
      run
      |> Map.get(:packages, Map.get(run, "packages", []))
      |> Enum.map(fn package -> Map.get(package, "name") || Map.get(package, :name) end)
      |> Enum.reject(&is_nil/1)

    case names do
      [] -> Map.get(run, :run_id) || Map.get(run, "run_id") || "runtime hit"
      _ -> Enum.join(names, " + ")
    end
  end

  defp hit_run_result(run) do
    run
    |> Map.get(:result, Map.get(run, "result"))
    |> case do
      result when is_binary(result) and result != "" -> result
      _ -> nil
    end
  end
end
