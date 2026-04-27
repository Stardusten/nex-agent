defmodule Nex.Agent.Media.ProjectorTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Media.{Attachment, Projector}

  test "text file attachments are projected with file content" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-projector-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "visible file body")
    on_exit(fn -> File.rm(path) end)

    attachment = %Attachment{
      id: "media_1",
      channel: "discord",
      kind: :file,
      mime_type: "text/plain",
      filename: "note.txt",
      local_path: path,
      source: :inbound,
      platform_ref: %{"url" => "https://cdn.example.test/note.txt"}
    }

    assert [
             %{
               "type" => "text",
               "text" => text
             }
           ] = Projector.project_for_model([attachment], [])

    assert text =~ "[User sent text file: note.txt; mime=text/plain]"
    assert text =~ "visible file body"
  end

  test "large text file projection reads only a bounded preview" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nex-agent-projector-large-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, String.duplicate("a", 256 * 1024) <> "tail")
    on_exit(fn -> File.rm(path) end)

    attachment = %Attachment{
      id: "media_2",
      channel: "discord",
      kind: :file,
      mime_type: "text/plain",
      filename: "large.txt",
      local_path: path,
      source: :inbound,
      platform_ref: %{"url" => "https://cdn.example.test/large.txt"}
    }

    assert [%{"type" => "text", "text" => text}] = Projector.project_for_model([attachment], [])

    assert text =~ "truncated to 262144 bytes"
    refute text =~ "tail"
  end
end
