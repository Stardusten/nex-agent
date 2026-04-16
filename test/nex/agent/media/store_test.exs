defmodule Nex.Agent.Media.StoreTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Media.Store

  test "put_binary persists inbound media under workspace media dir" do
    workspace = Path.join(System.tmp_dir!(), "nex-agent-media-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, attachment} =
             Store.put_binary(
               "png",
               channel: "feishu",
               kind: :image,
               mime_type: "image/png",
               filename: "image.png",
               workspace: workspace,
               platform_ref: %{"image_key" => "img_1"}
             )

    assert attachment.channel == "feishu"
    assert attachment.kind == :image
    assert attachment.local_path =~ Path.join(workspace, "media/inbound/")
    assert File.read!(attachment.local_path) == "png"
  end
end
