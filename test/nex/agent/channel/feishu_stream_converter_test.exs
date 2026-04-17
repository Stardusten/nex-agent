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

  test "single newmsg splits into two cards" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "one\n\n<newmsg/>\n\ntwo")
    {:ok, c} = StreamConverter.finish(c)

    assert c.active_text == "two"
    assert c.completed
    refute c.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 2
  end

  test "newmsg split across flush boundary still rotates card" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    # First chunk ends with partial "<newmsg/>" → held back
    {:ok, c} = StreamConverter.push_text(c, "one\n\n<new")
    assert c.pending_buffer == "\n<new"
    assert c.active_text =~ "one"

    # Second chunk completes the boundary → card rotated, "two" goes to new card
    {:ok, c} = StreamConverter.push_text(c, "msg/>\n\ntwo")

    {:ok, c} = StreamConverter.finish(c)
    assert c.active_text == "two"
    refute c.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 2
  end

  test "newmsg after code block rotates card (no in_code_block tracking needed)" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "```json\n{\"key\": true}\n```\n\n<newmsg/>\n\nsecond")
    {:ok, c} = StreamConverter.finish(c)

    assert c.active_text == "second"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 2
  end

  test "multiple newmsgs with code blocks across flushes" do
    {:ok, c} = StreamConverter.start("ou_123", %{})

    {:ok, c} = StreamConverter.push_text(c, "# Card 1\n\n```bash\necho hi\n```")
    {:ok, c} = StreamConverter.push_text(c, "\n\n<newmsg/>\n\n# Card 2\n\n```json\n{\"a\":1}")
    {:ok, c} = StreamConverter.push_text(c, "\n```\n\n<newmsg/>\n\n# Card 3\nFinal.")
    {:ok, c} = StreamConverter.finish(c)

    assert c.active_text =~ "Card 3"
    refute c.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    # Thinking... card reused for Card 1, then Card 2, then Card 3
    assert length(card_creates) == 3
  end

  test "inline newmsg mention does not rotate" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "Use `<newmsg/>` to split messages.")
    {:ok, c} = StreamConverter.finish(c)

    assert c.active_text =~ "`<newmsg/>`"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 1
  end

  test "newmsg not on its own line does not rotate" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "some text <newmsg/> more text")
    {:ok, c} = StreamConverter.finish(c)

    assert c.active_text =~ "<newmsg/>"

    posts = collect_http_posts([])
    card_creates = Enum.filter(posts, fn {url, _body} -> url =~ "/cardkit/v1/cards" end)
    assert length(card_creates) == 1
  end

  test "close_streaming_mode called on rotate and finish" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "one\n\n<newmsg/>\n\ntwo")
    {:ok, c} = StreamConverter.finish(c)

    assert c.completed

    puts = collect_http_puts([])
    settings_calls = Enum.filter(puts, fn {url, _body} -> url =~ "/settings" end)
    # One for rotate (card 1), one for finish (card 2)
    assert length(settings_calls) == 2
  end

  test "fail with active card appends error" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    {:ok, c} = StreamConverter.push_text(c, "partial content")
    {:ok, c} = StreamConverter.fail(c, "something went wrong")

    assert c.completed
    assert c.active_text =~ "partial content"
    assert c.active_text =~ "Error: something went wrong"
  end

  test "fail without active card creates error card" do
    {:ok, c} = StreamConverter.start("ou_123", %{})
    # Simulate: card rotated away, no active card
    c = %{c | active_card_id: nil, active_text: ""}
    {:ok, c} = StreamConverter.fail(c, "total failure")

    assert c.completed
    assert c.active_text == "Error: total failure"
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
