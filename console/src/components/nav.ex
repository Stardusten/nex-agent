defmodule NexAgentConsole.Components.Nav do
  use Nex

  @sections [
    %{
      title: "六层进化",
      summary: "先分流，再沉淀，最后才碰实现。",
      links: [
        {"/evolution", "分流", "先判断变化该落哪一层"},
        {"/memory", "认知", "整理 SOUL / USER / MEMORY"},
        {"/skills", "能力", "治理 SKILL / TOOL 库存"},
        {"/code", "代码", "最后一层，只读审查与变更"}
      ]
    }
  ]

  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:current_path, "/")
      |> Map.put(:sections, @sections)
      |> Map.put(:current_section, current_section(Map.get(assigns, :current_path, "/")))
      |> Map.put(:current_label, current_label(Map.get(assigns, :current_path, "/")))

    ~H"""
    <nav class="console-nav">
      <div class="console-nav__rail">
        <div class="console-nav__brand">
          <span class="console-nav__eyebrow">NexAgent Console</span>
          <strong>进化控制台</strong>
          <p>分流、认知、能力、代码。</p>
        </div>

        <div class="console-nav__section">
          <div class="console-nav__section-head">
            <span class="console-nav__caption">四层目录</span>
            <span class="console-nav__current">{@current_label}</span>
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
                  <%= for {href, label, detail} <- section.links do %>
                    <a
                      href={href}
                      class={"console-nav__link #{if @current_path == href, do: "is-active", else: ""}"}
                    >
                      <div class="console-nav__link-head">
                        <span class="console-nav__label">{label}</span>
                        <span class="console-nav__link-arrow">›</span>
                      </div>
                      <small>{detail}</small>
                    </a>
                  <% end %>
                </div>
              </section>
            <% end %>
          </div>
        </div>

        <div class="console-nav__footer">
          <span>判断优先</span>
          <span>单实例</span>
        </div>
      </div>
    </nav>
    """
  end

  defp current_section(path) do
    Enum.find_value(@sections, "六层进化", fn section ->
      if Enum.any?(section.links, fn {href, _label, _detail} -> href == path end) do
        section.title
      end
    end)
  end

  defp current_label(path) do
    Enum.find_value(@sections, "分流", fn section ->
      Enum.find_value(section.links, fn {href, label, _detail} ->
        if href == path, do: label
      end)
    end)
  end
end
