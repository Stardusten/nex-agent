defmodule Nex.Agent.Interface.Media.HydratorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nex.Agent.Interface.Media.{Hydrator, Ref}

  test "unsupported media refs stay unresolved without warning noise" do
    ref = %Ref{
      channel: "feishu",
      kind: :file,
      message_id: "om_1",
      mime_type: "text/plain",
      filename: "note.txt",
      platform_ref: %{"file_key" => "file_1"}
    }

    log =
      capture_log(fn ->
        assert {[], [^ref]} =
                 Hydrator.hydrate_refs([ref],
                   fetch_binary_fun: fn _ref -> {:error, :unsupported_media_ref} end
                 )
      end)

    assert log == ""
  end
end
