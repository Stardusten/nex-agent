defmodule Nex.Agent.Channel.FeishuStreamConverterTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.{Bus, Config}
  alias Nex.Agent.Channel.Feishu
  alias Nex.Agent.Channel.Feishu.StreamConverter

  setup do
    if Process.whereis(Bus) == nil do
      start_supervised!({Bus, name: Bus})
    end

    parent = self()

    http_post_fun = fn url, body, headers ->
      send(parent, {:http_post, url, body, headers})

      cond do
        String.contains?(url, "/auth/v3/tenant_access_token/internal") ->
          {:ok, %{"code" => 0, "tenant_access_token" => "tenant-token", "expire" => 7200}}

        String.contains?(url, "/im/v1/messages") ->
          {:ok, %{"code" => 0, "data" => %{"message_id" => "om_123"}}}

        String.contains?(url, "/cardkit/v1/cards") ->
          id = "card_" <> Integer.to_string(System.unique_integer([:positive]))
          {:ok, %{"code" => 0, "data" => %{"card_id" => id}}}

        true ->
          {:ok, %{"code" => 1, "msg" => "unexpected"}}
      end
    end

    http_put_fun = fn url, body, headers ->
      send(parent, {:http_put, url, body, headers})
      {:ok, %{"code" => 0, "data" => %{}}}
    end

    config = %Config{Config.default() | feishu: %{"enabled" => false}}

    pid =
      start_supervised!(
        {Feishu,
         config: config,
         http_post_fun: http_post_fun,
         http_put_fun: http_put_fun,
         http_post_multipart_fun: fn _url, _body, _headers -> {:error, :unused} end,
         http_get_fun: fn _url, _headers -> {:error, :unused} end}
      )

    :sys.replace_state(pid, fn state ->
      %{state | enabled: true, app_id: "cli_test", app_secret: "sec_test"}
    end)

    :ok
  end

  test "newmsg defers opening the next active card until a later push or finish" do
    assert {:ok, converter} = StreamConverter.start("ou_123", %{})
    assert {:ok, converter} = StreamConverter.push_text(converter, "one\n<newmsg/>\ntwo")

    assert converter.active_card_id == nil
    assert converter.active_text == ""
    assert converter.pending_buffer == "two"

    posts_before_finish = collect_http_posts([])
    card_creates_before_finish = Enum.filter(posts_before_finish, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates_before_finish) == 1

    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.active_text == "two"
    assert converter.completed

    posts = posts_before_finish ++ collect_http_posts([])
    puts = collect_http_puts([])

    assert Enum.any?(posts, fn {url, body} ->
             url =~ "/cardkit/v1/cards" and
               (body["data"] |> Jason.decode!() |> get_in(["body", "elements", Access.at(0), "content"])) ==
                 "Thinking..."
           end)

    assert Enum.any?(posts, fn {url, body} ->
             url =~ "/cardkit/v1/cards" and
               (body["data"] |> Jason.decode!() |> get_in(["body", "elements", Access.at(0), "content"])) ==
                 "two"
           end)
    refute Enum.any?(puts, fn {_url, body} ->
             is_binary(body["content"]) and body["content"] =~ "<newmsg/>"
           end)
  end

  test "newmsg split across flushes still rotates to the next card" do
    assert {:ok, converter} = StreamConverter.start("ou_123", %{})
    assert {:ok, converter} = StreamConverter.push_text(converter, "one\n\n<new")

    assert converter.pending_buffer == "<new"
    assert converter.active_text == "one\n\n"

    assert {:ok, converter} = StreamConverter.push_text(converter, "msg/>\n\ntwo")

    assert converter.active_card_id == nil
    assert converter.pending_buffer == "two"

    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.active_text == "two"
    refute converter.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])

    assert Enum.any?(posts, fn {url, body} ->
             url =~ "/cardkit/v1/cards" and
               (body["data"] |> Jason.decode!() |> get_in(["body", "elements", Access.at(0), "content"])) ==
                 "two"
           end)
  end

  test "newmsg inside fenced code block does not rotate card" do
    assert {:ok, converter} = StreamConverter.start("ou_123", %{})

    text = "```txt\n<newmsg/>\n```\nafter"
    assert {:ok, converter} = StreamConverter.push_text(converter, text)
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.active_text == text

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 1
  end

  test "newmsg split across chunks does not rotate when current line is not blank" do
    assert {:ok, converter} = StreamConverter.start("ou_123", %{})
    assert {:ok, converter} = StreamConverter.push_text(converter, "第三段。\n\n> 说明 `")
    assert {:ok, converter} = StreamConverter.push_text(converter, "<newmsg/>")
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.active_text =~ "`<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 1
  end

  test "newmsg after fenced code block rotates to a new card" do
    assert {:ok, converter} = StreamConverter.start("ou_123", %{})

    assert {:ok, converter} =
             StreamConverter.push_text(
               converter,
               "第三段。\n\n## 引用和代码块\n\n> 如果这段能单独显示，\n> 说明 `<newmsg/>` 已经正常工作了。\n\n```bash\necho \"feishu markdown-like ir test\"\npwd\ndate\n```"
             )

    assert {:ok, converter} = StreamConverter.push_text(converter, "\n\n<newmsg/>\n\n第四段。\n\n## 表格测试\n")
    assert {:ok, converter} = StreamConverter.finish(converter)

    assert converter.active_text =~ "第四段。"
    refute converter.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 2
  end

  defp collect_http_posts(acc) do
    receive do
      {:http_post, url, body, _headers} ->
        collect_http_posts([{url, body} | acc])
    after
      150 ->
        Enum.reverse(acc)
    end
  end

  defp collect_http_puts(acc) do
    receive do
      {:http_put, url, body, _headers} ->
        collect_http_puts([{url, body} | acc])
    after
      150 ->
        Enum.reverse(acc)
    end
  end
end
