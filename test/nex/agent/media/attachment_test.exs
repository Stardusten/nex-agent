defmodule Nex.Agent.Media.AttachmentTest do
  use ExUnit.Case, async: true

  alias Nex.Agent.Media.Attachment

  test "kind helpers classify attachments" do
    image = %Attachment{
      id: "1",
      channel: "feishu",
      kind: :image,
      mime_type: "image/png",
      local_path: "/tmp/a.png",
      source: :inbound,
      platform_ref: %{}
    }

    audio = %{image | id: "2", kind: :audio}
    video = %{image | id: "3", kind: :video}
    file = %{image | id: "4", kind: :file}

    assert Attachment.image?(image)
    refute Attachment.image?(audio)
    assert Attachment.audio?(audio)
    assert Attachment.video?(video)
    assert Attachment.file?(file)
  end
end
