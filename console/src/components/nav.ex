defmodule NexAgentConsole.Components.Nav do
  use Nex

  @sections [
    %{
      title: "进化层",
      summary: "分流、认知、能力、代码",
      links: [
        {"/evolution", "分流", "信号分层判断"},
        {"/memory", "认知", "SOUL / USER / MEMORY"},
        {"/skills", "能力", "SKILL / TOOL 库存"},
        {"/code", "代码", "只读审查与变更"}
      ]
    },
    %{
      title: "运行侧",
      summary: "运行时、调度、会话",
      links: [
        {"/runtime", "运行时", "网关与请求追踪"},
        {"/tasks", "调度", "cron 与任务执行"},
        {"/sessions", "会话", "消息与记忆整理"}
      ]
    }
  ]

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:current_path, "/")
      |> Map.put(:sections, @sections)
      |> Map.put(:current_section, current_section(Map.get(assigns, :current_path, "/")))

    ~H"""
    <nav class="console-nav">
      <div class="console-nav__rail">
        <div class="console-nav__brand">
          <span class="console-nav__eyebrow">NexAgent Console</span>
          <strong>控制台</strong>
          <p>Runtime Inspector</p>
        </div>

        <div class="console-nav__groups">
          <%= for section <- @sections do %>
            <section
              class={"console-nav__group #{if @current_section == section.title, do: "is-active", else: ""}"}
            >
              <header class="console-nav__group-head">
                <strong>{section.title}</strong>
                <p>{section.summary}</p>
              </header>

              <div class="console-nav__links">
                <%= for {href, label, _detail} <- section.links do %>
                  <a
                    href={href}
                    class={"console-nav__link #{if @current_path == href, do: "is-active", else: ""}"}
                  >
                    <span class="console-nav__label">{label}</span>
                  </a>
                <% end %>
              </div>
            </section>
          <% end %>
        </div>

        <div class="console-nav__footer">
          <span>单实例</span>
          <span>判断优先</span>
          <span>实时检查</span>
        </div>
      </div>
    </nav>
    """
  end

  defp current_section(path) do
    Enum.find_value(@sections, "", fn section ->
      if Enum.any?(section.links, fn {href, _label, _detail} -> href == path end) do
        section.title
      end
    end)
  end
end
