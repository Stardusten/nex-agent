defmodule Nex.Agent.CodeLayerBoundaryTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.Tool.{Reflect, UpgradeCode}

  test "upgrade_code rejects workspace custom tool module" do
    assert {:error, msg} =
             UpgradeCode.execute(
               %{
                 "module" => "Nex.Agent.Tool.Custom.WeatherShenzhen",
                 "code" => "defmodule Nex.Agent.Tool.Custom.WeatherShenzhen do end",
                 "reason" => "test"
               },
               %{}
             )

    assert msg =~ "CODE-layer framework modules"
  end

  test "reflect rejects source inspection for custom tool modules" do
    assert {:error, msg} =
             Reflect.execute(
               %{"action" => "source", "module" => "Nex.Agent.Tool.Custom.WeatherShenzhen"},
               %{}
             )

    assert msg =~ "CODE-layer framework modules"
  end
end
