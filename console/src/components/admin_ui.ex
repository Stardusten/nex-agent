defmodule NexAgentConsole.Components.AdminUI do
  use Nex

  alias NexAgentConsole.Components.Nav

  @page_meta %{
    "/" => %{name: "分流", group: "六层进化"},
    "/evolution" => %{name: "分流", group: "六层进化"},
    "/skills" => %{name: "能力", group: "六层进化"},
    "/memory" => %{name: "认知", group: "六层进化"},
    "/sessions" => %{name: "分流", group: "六层进化"},
    "/tasks" => %{name: "分流", group: "六层进化"},
    "/runtime" => %{name: "运行时", group: "运行侧"},
    "/code" => %{name: "代码", group: "六层进化"}
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
          <p class="page-header__eyebrow">{@page_group}</p>
          <div class="page-header__title-row">
            <h1>{@page_name}</h1>
            <span class="page-header__route">{@current_path}</span>
          </div>
          <p class="page-header__subtitle">{@subtitle}</p>
        </div>

        <div class="page-header__meta">
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
              基于 Nex
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
    <div class="dashboard-layout dashboard-layout--overview">
      <div class="dashboard-main">
        <section class="section-card section-card--hero">
          <div class="section-head">
            <div>
              <p class="section-kicker">运行总览</p>
              <h2>这里不定义进化层，只回答现在系统处于什么状态</h2>
            </div>
            <a class="ghost-link" href="/evolution">进入六层总览</a>
          </div>

          <p class="section-summary">
            控制台页只保留当前状态与入口分发。分层判断去 `/evolution`，这里负责告诉你现在该先看哪里。
          </p>

          <div class="metric-grid">
            {metric(%{label: "pending signals", value: length(@state.pending_signals), tone: "gold"})}
            {metric(%{label: "open tasks", value: @state.tasks.open, tone: "green"})}
            {metric(%{label: "recent sessions", value: length(@state.recent_sessions), tone: "ink"})}
            {metric(%{label: "gateway services", value: map_size(@state.runtime.gateway.services || %{}), tone: "rust"})}
          </div>
        </section>

        <div class="pair-layout">
          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">当前状态</p>
                <h2>先确认运行是否稳定</h2>
              </div>
            </div>

            <div class="detail-grid">
              {detail_item(%{label: "网关状态", value: @state.runtime.gateway.status})}
              {detail_item(%{label: "Provider", value: get_in(@state.runtime.gateway, [:config, :provider])})}
              {detail_item(%{label: "下一批任务", value: length(@state.tasks.upcoming)})}
              {detail_item(%{label: "最近变化", value: length(@state.recent_events)})}
            </div>

            {services_grid(%{services: @state.runtime.gateway.services || %{}})}
          </section>

          <section class="section-card">
            <div class="section-head">
              <div>
                <p class="section-kicker">建议入口</p>
                <h2>先进入真正拥有该类信息的页面</h2>
              </div>
            </div>

            {workflow_links(%{
              links: [
                %{
                  href: "/evolution",
                  title: "先看六层分流",
                  body: "#{length(@state.pending_signals)} 个信号待处理，先判断它们应落到 SOUL、USER、MEMORY、SKILL、TOOL 还是 CODE。"
                },
                %{
                  href: "/memory",
                  title: "检查认知层",
                  body: "SOUL、USER 和 MEMORY 放在一起看，先判断这是不是长期认知，而不是方法或实现问题。"
                },
                %{
                  href: "/skills",
                  title: "检查能力层",
                  body: "SKILL 和 TOOL 在这里分开看：前者是方法沉淀，后者是确定性能力。"
                },
                %{href: "/code", title: "最后才看代码层", body: "只有高层和能力层都不能解决时，才进入 `/code` 做 diff、热更和回滚。"}
              ]
            })}
          </section>
        </div>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">最近变化</p>
              <h2>跨层与运行面的最近记录</h2>
            </div>
          </div>

          {event_feed(%{events: Enum.take(@state.recent_events, 6)})}
        </section>
      </div>

      <aside class="dashboard-rail">
        <section class="section-card section-card--accent">
          <div class="section-head">
            <div>
              <p class="section-kicker">分层焦点</p>
              <h2>现在最可能触发进化判断的信号</h2>
            </div>
            <a class="ghost-link" href="/evolution">查看分层</a>
          </div>

          {signal_list(%{signals: Enum.take(@state.pending_signals, 4)})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">最近会话</p>
              <h2>近期上下文</h2>
            </div>
            <a class="ghost-link" href="/memory">回到认知层</a>
          </div>

          {session_list(%{sessions: Enum.take(@state.recent_sessions, 4), compact: true})}
        </section>
      </aside>
    </div>
    """
  end

  def evolution_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">当前判断框架</p>
            <h2>先把变化送到真正拥有它的那一层，再决定是否需要进一步操作</h2>
          </div>
          <span class="status-pill">
            最近事件：{Map.get(List.first(@state.recent_events) || %{}, "event", "暂无相关记录")}
          </span>
        </div>

        <p class="section-summary">
          `/evolution` 只负责分流，不负责展开认知原文、能力库存或代码编辑。默认顺序是先稳定高层，再沉淀方法，再扩展能力，最后才修改代码。
        </p>

        {layer_map(%{layers: @state.layers})}
      </section>

      <div class="pair-layout" id="pending-signals">
        <section class="section-card section-card--accent">
          <div class="section-head">
            <div>
              <p class="section-kicker">待分流 signals</p>
              <h2>先看有哪些变化正在请求被整理</h2>
            </div>
          </div>

          <p class="section-summary">
            这里是首屏的主证据区。先看信号，再判断它属于认知、能力还是实现问题。
          </p>

          {signal_list(%{signals: @state.pending_signals})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">建议落层</p>
              <h2>把变化送到真正拥有这类信息的页面</h2>
            </div>
          </div>

          {workflow_links(%{
            links: [
              %{
                href: "/memory",
                title: "进入认知层",
                body: "当变化更像长期原则、用户偏好或项目事实时，落到 SOUL / USER / MEMORY，而不是继续下沉到能力或代码。"
              },
              %{
                href: "/skills",
                title: "进入能力层",
                body: "当变化已经超出认知，开始变成可复用流程或确定性能力时，才进入 SKILL / TOOL 库存治理。"
              },
              %{
                href: "/code",
                title: "最后才进代码层",
                body: "只有认知层和能力层都不能解决时，才进入 `/code` 做只读审查、diff、热更和回滚。"
              },
              %{
                href: "#manual-cycle",
                title: "确认后再手动运行",
                body: "手动 cycle 是次级操作。先完成分流判断，再决定是否需要人工触发一次整理。"
              }
            ]
          })}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">最近结果</p>
            <h2>最近几次分流与进化的摘要</h2>
          </div>
        </div>

        {audit_glance(%{rows: Enum.take(@state.recent_events, 6)})}
      </section>

      <section class="section-card" id="manual-cycle">
        <div class="section-head">
          <div>
            <p class="section-kicker">手动运行</p>
            <h2>只有看完分层证据后，才建议手动触发 cycle</h2>
          </div>
        </div>

        <p class="section-summary">
          这不是默认动作。先看 `signals` 和最近结果，再决定是否需要人工触发一次分层整理。
        </p>

        <div class="actions-row">
          <form hx-post="/trigger_cycle" hx-target="#evolution-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">手动运行 cycle</button>
          </form>
          <div id="evolution-action-result" class="action-result"></div>
        </div>
      </section>

      <section class="section-card" id="evolution-audit">
        <div class="section-head">
          <div>
            <p class="section-kicker">审计流</p>
            <h2>完整进化时间线</h2>
          </div>
        </div>

        {audit_table(%{rows: @state.recent_events})}
      </section>
    </div>
    """
  end

  def skills_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">当前能力版图</p>
            <h2>这里先只看资产，以及最近实际命中记录</h2>
          </div>
        </div>

        <p class="section-summary">
          `/skills` 暂时不展开边界说明、catalog 或 lineage。先回答两件事：现在有哪些能力资产，以及最近哪些 skill 真的被命中过。
        </p>

        <div class="metric-grid">
          {metric(%{label: "本地 skills", value: length(@state.local_skills), tone: "gold"})}
          {metric(%{label: "可用 tools", value: length(@state.tools.builtin) + length(@state.tools.custom), tone: "ink"})}
          {metric(%{label: "builtin tools", value: length(@state.tools.builtin), tone: "green"})}
          {metric(%{label: "custom tools", value: length(@state.tools.custom), tone: "green"})}
        </div>
      </section>

      <section class="section-card" id="ability-inventory">
        <div class="section-head">
          <div>
            <p class="section-kicker">资产总览</p>
            <h2>先确认能力资产分布，再往下看具体清单</h2>
          </div>
        </div>

        <div class="detail-grid">
          {detail_item(%{label: "SKILL", value: length(@state.local_skills)})}
          {detail_item(%{label: "TOOL", value: length(@state.tools.builtin) + length(@state.tools.custom)})}
          {detail_item(%{label: "builtin tools", value: length(@state.tools.builtin)})}
          {detail_item(%{label: "实际命中记录", value: length(actual_hit_runs(@state.recent_runs))})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">SKILL</p>
              <h2>本地方法与流程资产</h2>
            </div>
          </div>

          {local_skills(%{skills: @state.local_skills})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">TOOL</p>
              <h2>当前可调用能力资产</h2>
            </div>
          </div>

          {tool_inventory_list(%{tools: @state.tools})}
        </section>
      </div>

      <section class="section-card" id="recent-hits">
        <div class="section-head">
          <div>
            <p class="section-kicker">最近实际命中</p>
            <h2>只看真正选中过 skill package 的运行记录</h2>
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
            <p class="section-kicker">当前认知摘要</p>
            <h2>认知页先给判断，再给原文证据</h2>
          </div>
          <a class="ghost-link" href="/evolution">回到六层</a>
        </div>

        <p class="section-summary">
          `/memory` 只处理 SOUL、USER、MEMORY 的长期认知，不负责能力沉淀和实现修改。首屏只看认知结论，原文预览全部降到下半区。
        </p>

        <div class="metric-grid">
          {metric(%{label: "SOUL", value: if(String.trim(@state.soul_preview || "") == "", do: "empty", else: "loaded"), tone: "gold"})}
          {metric(%{label: "USER", value: if(String.trim(@state.user_preview || "") == "", do: "empty", else: "loaded"), tone: "green"})}
          {metric(%{label: "MEMORY bytes", value: @state.memory_bytes, tone: "ink"})}
          {metric(%{label: "最近认知事件", value: length(@state.recent_events), tone: "rust"})}
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">认知结论</p>
            <h2>先看 SOUL、USER、MEMORY 各自正在定义什么</h2>
          </div>
        </div>

        <div class="stack-layout stack-layout--tight">
          <article class="detail-card detail-card--summary">
            <span class="section-kicker">SOUL</span>
            <strong>长期原则</strong>
            <p>{preview_glance(@state.soul_preview, "SOUL 还没有形成稳定原则。")}</p>
          </article>

          <article class="detail-card detail-card--summary">
            <span class="section-kicker">USER</span>
            <strong>用户画像</strong>
            <p>{preview_glance(@state.user_preview, "USER 还没有沉淀出稳定协作偏好。")}</p>
          </article>

          <article class="detail-card detail-card--summary">
            <span class="section-kicker">MEMORY</span>
            <strong>长期事实</strong>
            <p>{preview_glance(@state.memory_preview, "MEMORY 还没有积累出明确项目事实。")}</p>
          </article>
        </div>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">最近变化</p>
            <h2>与认知层相关的最近记录</h2>
          </div>
        </div>

        {audit_glance(%{rows: Enum.take(@state.recent_events, 8)})}
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">原文证据</p>
            <h2>SOUL、USER、MEMORY 原文按层级顺序展开</h2>
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
            <p class="section-kicker">下一步</p>
            <h2>继续分流或进入能力层</h2>
          </div>
        </div>

        {workflow_links(%{
          links: [
            %{href: "/evolution", title: "回到分层总览", body: "如果你在判断这条变化该落在哪一层，直接回 `/evolution` 看六层地图。"},
            %{href: "/skills", title: "继续看能力层", body: "如果这不是长期认知，而是可复用的方法或能力，再进入 `/skills`。"}
          ]
        })}
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
            <p class="section-kicker">会话目录</p>
            <h2>按 session 进入检查</h2>
          </div>
        </div>

        {session_list(%{sessions: @state.sessions, compact: false})}
      </section>

      <div class="split-main">
        <%= if @state.selected_session do %>
          <section class="section-card section-card--hero">
            <div class="section-head">
              <div>
                <p class="section-kicker">当前会话</p>
                <h2>{@state.selected_session.key}</h2>
              </div>
            </div>

            <p class="section-summary">
              先确认消息规模与未 consolidation 数量，再决定是整理记忆还是直接清空这个 session。
            </p>

            <div id="sessions-action-result" class="action-result"></div>

            <div class="detail-grid">
              {detail_item(%{label: "消息数", value: @state.selected_session.total_messages})}
              {detail_item(%{label: "未 consolidation", value: @state.selected_session.unconsolidated_messages})}
              {detail_item(%{label: "最后更新", value: format_timestamp(@state.selected_session.updated_at)})}
            </div>

            <div class="actions-row">
              <form hx-post="/consolidate" hx-target="#sessions-action-result" hx-swap="innerHTML">
                <input type="hidden" name="session_key" value={@state.selected_session.key} />
                <button class="action-button action-button--primary" type="submit">运行 consolidation</button>
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
                <p class="section-kicker">消息</p>
                <h2>当前会话内容</h2>
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
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">scheduled tasks</p>
            <h2>围绕 cron 和任务结果做调度管理</h2>
          </div>
        </div>

        <p class="section-summary">
          任务页只看调度和执行，不再重复展示运行时健康；先看下一批任务，再决定启停或手动触发。
        </p>

        <div class="metric-grid">
          {metric(%{label: "待处理任务", value: @state.summary.open, tone: "gold"})}
          {metric(%{label: "已完成任务", value: @state.summary.completed, tone: "green"})}
          {metric(%{label: "cron jobs", value: length(@state.cron_jobs), tone: "ink"})}
          {metric(%{label: "已启用 cron", value: @state.cron_status.enabled, tone: "rust"})}
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">cron 状态</p>
              <h2>计划任务与启停</h2>
            </div>
          </div>

          <div id="tasks-action-result" class="action-result"></div>
          {cron_table(%{jobs: @state.cron_jobs})}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">next runs</p>
              <h2>即将到来的任务</h2>
            </div>
          </div>

          {upcoming_list(%{rows: @state.summary.upcoming})}
        </section>
      </div>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">执行结果</p>
            <h2>最近任务记录</h2>
          </div>
        </div>

        {task_table(%{tasks: @state.tasks})}
      </section>
    </div>
    """
  end

  def runtime_panel(assigns) do
    assigns = Map.put_new(assigns, :trace_mode, :index)

    ~H"""
    <%= if @trace_mode == :detail do %>
      {runtime_trace_focus(%{state: @state})}
    <% else %>
      {runtime_index_panel(%{state: @state})}
    <% end %>
    """
  end

  defp runtime_index_panel(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">运行时控制</p>
            <h2>这里只保留运行状态和最近请求索引</h2>
          </div>
        </div>

        <p class="section-summary">
          单条请求详情不再和列表塞在同一页里。这里先看 runtime 是否稳定，再从最近请求里点进单条详情页。
        </p>

        <div id="runtime-action-result" class="action-result"></div>

        <div class="detail-grid">
          {detail_item(%{label: "状态", value: @state.gateway.status})}
          {detail_item(%{label: "启动时间", value: format_timestamp(@state.gateway.started_at)})}
          {detail_item(%{label: "Provider", value: get_in(@state.gateway, [:config, :provider])})}
          {detail_item(%{label: "Model", value: get_in(@state.gateway, [:config, :model])})}
          {detail_item(%{label: "Request Trace", value: readable_bool(@state.request_trace_config["enabled"])})}
          {detail_item(%{label: "最近请求", value: length(@state.recent_request_traces)})}
        </div>

        <div class="actions-row">
          <form hx-post="/start_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--primary" type="submit">启动网关</button>
          </form>

          <form hx-post="/stop_gateway" hx-target="#runtime-action-result" hx-swap="innerHTML">
            <button class="action-button action-button--danger" type="submit">停止网关</button>
          </form>
        </div>
      </section>

      <div class="pair-layout">
        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">services</p>
              <h2>运行时服务</h2>
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

      <section class="section-card" id="recent-request-list">
        <div class="section-head">
          <div>
            <p class="section-kicker">最近请求</p>
            <h2>点开后直接进入单条请求详情页</h2>
          </div>
        </div>

        <p class="section-summary">
          <%= if @state.request_trace_config["enabled"] do %>
            这里只保留请求索引。点击任意一条后，页面会直接切到该请求的详情模式，不再停留在同页深滚动。
          <% else %>
            Request trace 当前关闭。把 `request_trace.enabled` 打开后，新请求才会进入索引。
          <% end %>
        </p>

        {request_trace_list(%{
          traces: @state.recent_request_traces,
          enabled: @state.request_trace_config["enabled"],
          selected_run_id: nil
        })}
      </section>
    </div>
    """
  end

  defp runtime_trace_focus(assigns) do
    ~H"""
    <div class="stack-layout">
      <section class="section-card section-card--hero">
        <div class="section-head">
          <div>
            <p class="section-kicker">当前请求</p>
            <h2>这一页只看一条 request trace</h2>
          </div>

          <a class="ghost-link" href="/runtime">返回最近请求</a>
        </div>

        <%= if @state.selected_request_trace do %>
          <p class="section-summary">
            {trace_result_preview(@state.selected_request_trace.prompt)}
          </p>

          <div class="detail-grid">
            {detail_item(%{label: "Run ID", value: @state.selected_request_trace.run_id})}
            {detail_item(%{label: "Status", value: @state.selected_request_trace.status})}
            {detail_item(%{
              label: "时间",
              value: format_timestamp(Map.get(@state.selected_request_trace, :inserted_at))
            })}
            {detail_item(%{label: "Channel", value: @state.selected_request_trace.channel || "n/a"})}
            {detail_item(%{label: "LLM Rounds", value: @state.selected_request_trace.llm_rounds})}
            {detail_item(%{label: "Tool Calls", value: @state.selected_request_trace.tool_count})}
          </div>
        <% else %>
          {empty_state(%{title: "没有找到这条请求", body: "这条 trace 可能已经不存在，返回最近请求列表重新选择。"})}
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-head">
          <div>
            <p class="section-kicker">请求详情</p>
            <h2>skill 命中、tool 调用、agent 回合</h2>
          </div>
        </div>

        {request_trace_detail(%{
          trace: @state.selected_request_trace,
          enabled: @state.request_trace_config["enabled"],
          traces: @state.recent_request_traces
        })}
      </section>
    </div>
    """
  end

  def code_panel(assigns) do
    ~H"""
    <div class="split-layout split-layout--code">
      <aside class="split-sidebar">
        <section class="section-card section-card--accent">
          <div class="section-head">
            <div>
              <p class="section-kicker">为什么会走到代码层</p>
              <h2>只有认知层和能力层都不能解决时，才进入这里</h2>
            </div>
          </div>

          {rule_list(%{
            rules: [
              "代码层是最后一层，默认先审查，不默认直接编辑。",
              "如果问题还能被 SOUL / USER / MEMORY 或 SKILL / TOOL 解决，就不应先改实现。",
              "这里的变更操作都属于次级动作，先看源码与版本轨迹，再决定是否动手。"
            ]
          })}
        </section>

        <section class="section-card">
          <div class="section-head">
            <div>
              <p class="section-kicker">模块选择</p>
              <h2>先定位当前要审查的模块</h2>
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
              <p class="section-kicker">版本轨迹</p>
              <h2>历史版本与回滚点</h2>
            </div>
          </div>

          {version_list(%{versions: @state.versions, selected_module: @state.selected_module})}
        </section>
      </aside>

      <div class="split-main">
        <section class="section-card section-card--hero" id="source-preview">
          <div class="section-head">
            <div>
              <p class="section-kicker">只读审查</p>
              <h2>先确认为什么必须落到代码层，再查看当前源码</h2>
            </div>
          </div>

          <p class="section-summary">
            这里先回答两件事：当前模块是什么、它最近怎么变过。当前源码只在这里只读展示，不再把编辑器当成默认首屏。
          </p>

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
              <p class="section-kicker">最近 code events</p>
              <h2>先看这层最近发生过什么</h2>
            </div>
          </div>

          {audit_glance(%{rows: Enum.take(@state.recent_events, 8)})}
        </section>

        <section class="section-card section-card--editor">
          <div class="section-head">
            <div>
              <p class="section-kicker">变更操作</p>
              <h2>这是次级区，只有确认必须下沉到实现后才使用</h2>
            </div>
          </div>

          <p class="section-summary">
            先在上方只读查看当前源码。这里只有当你已经准备好候选实现时，才粘贴新源码做 diff、热更或回滚。
          </p>

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

  defp rule_list(assigns) do
    ~H"""
    <div class="rule-list">
      <%= for rule <- @rules do %>
        <article class="rule-list__item">
          <strong>{rule}</strong>
        </article>
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

  defp workflow_links(assigns) do
    ~H"""
    <div class="workflow-grid">
      <%= for link <- @links do %>
        <a class="workflow-link" href={link.href}>
          <strong class="workflow-link__title">{link.title}</strong>
          <p>{link.body}</p>
        </a>
      <% end %>
    </div>
    """
  end

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

  defp audit_table(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      {empty_state(%{title: "暂无审计事件", body: "相关动作发生后会在这里出现。"})}
    <% else %>
      <div class="audit-table">
        <%= for row <- @rows do %>
          <article class="audit-table__row">
            <time>{format_timestamp(Map.get(row, "timestamp"))}</time>
            <strong>{Map.get(row, "event")}</strong>
            <pre class="audit-table__payload"><code>{payload_preview(Map.get(row, "payload", %{}))}</code></pre>
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
                  <strong>{trace.prompt || "No prompt preview"}</strong>
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
              <p class="trace-item__hint">进入详情页查看 skill 命中、tool 调用和 agent 回合。</p>
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
        {empty_state(%{title: "选择一条请求 trace", body: "先返回最近请求列表，再进入一条具体请求的详情页。"})}
      <% true -> %>
        <div class="stack-layout stack-layout--tight">
          <div class="detail-grid">
            {detail_item(%{label: "Run ID", value: @trace.run_id})}
            {detail_item(%{label: "Status", value: @trace.status})}
            {detail_item(%{label: "Channel", value: @trace.channel || "n/a"})}
            {detail_item(%{label: "Chat ID", value: @trace.chat_id || "n/a"})}
            {detail_item(%{label: "LLM Rounds", value: @trace.llm_rounds})}
            {detail_item(%{label: "Tool Calls", value: @trace.tool_count})}
          </div>

          <article class="detail-card">
            <span class="section-kicker">prompt</span>
            {code_block(%{content: @trace.prompt || "(empty)"})}
          </article>

          <%= if @trace.selected_packages != [] do %>
            <article class="detail-card">
              <span class="section-kicker">skill 命中</span>
              {request_trace_package_cards(%{packages: @trace.selected_packages})}
            </article>
          <% end %>

          <article class="detail-card">
            <span class="section-kicker">tool 调用</span>
            {request_trace_tool_activity(%{
              available_tools: @trace.available_tools || [],
              activity: @trace.tool_activity || []
            })}
          </article>

          <article class="detail-card">
            <span class="section-kicker">agent 回合</span>
            {request_trace_llm_turns(%{turns: @trace.llm_turns || []})}
          </article>

          <%= if @trace.runtime_system_messages != [] do %>
            <article class="detail-card">
              <span class="section-kicker">runtime system messages</span>
              {code_block(%{content: Enum.join(@trace.runtime_system_messages, "\n\n---\n\n")})}
            </article>
          <% end %>

          <article class="detail-card">
            <span class="section-kicker">原始事件</span>

            <div class="audit-table">
              <%= for event <- @trace.events do %>
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

          <%= if @trace.result do %>
            <article class="detail-card">
              <span class="section-kicker">final result</span>
              {code_block(%{content: to_string(@trace.result)})}
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

  defp cron_table(assigns) do
    ~H"""
    <%= if @jobs == [] do %>
      {empty_state(%{title: "没有 cron jobs", body: "定时任务创建后，这里会出现启停和手动执行入口。"})}
    <% else %>
      <div class="cron-table">
        <%= for job <- @jobs do %>
          <article class="cron-table__row">
            <div>
              <strong>{job.name}</strong>
              <p>{inspect(job.schedule)}</p>
            </div>

            <div class="actions-row">
              <form hx-post="/run_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                <input type="hidden" name="job_id" value={job.id} />
                <button class="micro-button" type="submit">Run</button>
              </form>

              <%= if job.enabled do %>
                <form hx-post="/disable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                  <input type="hidden" name="job_id" value={job.id} />
                  <button class="micro-button micro-button--danger" type="submit">Disable</button>
                </form>
              <% else %>
                <form hx-post="/enable_job" hx-target="#tasks-action-result" hx-swap="innerHTML">
                  <input type="hidden" name="job_id" value={job.id} />
                  <button class="micro-button micro-button--ok" type="submit">Enable</button>
                </form>
              <% end %>
            </div>
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

  defp page_meta(path), do: Map.get(@page_meta, path, %{name: "分流", group: "六层进化"})

  defp preview_glance(content, fallback) do
    content
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.take(3)
    |> Enum.join(" · ")
    |> case do
      "" -> fallback
      preview -> String.slice(preview, 0, 220)
    end
  end

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
