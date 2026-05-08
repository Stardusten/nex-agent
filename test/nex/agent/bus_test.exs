defmodule Nex.Agent.App.BusTest do
  use ExUnit.Case, async: false

  alias Nex.Agent.App.Bus

  setup do
    name = :"bus_test_#{System.unique_integer([:positive])}"
    start_supervised!({Bus, name: name})
    {:ok, bus: name}
  end

  test "unsubscribe removes one topic without crashing and preserves other topic subscription", %{
    bus: bus
  } do
    subscriber = self()

    :ok = GenServer.call(bus, {:subscribe, :first, subscriber})
    :ok = GenServer.call(bus, {:subscribe, :second, subscriber})

    assert :ok = GenServer.call(bus, {:unsubscribe, :first, subscriber})
    assert [] = GenServer.call(bus, {:subscribers, :first})
    assert [^subscriber] = GenServer.call(bus, {:subscribers, :second})

    assert :ok = GenServer.call(bus, {:unsubscribe, :second, subscriber})
    assert [] = GenServer.call(bus, {:subscribers, :second})
  end

  test "dead subscribers are removed from every topic", %{bus: bus} do
    pid = spawn(fn -> Process.sleep(:infinity) end)

    :ok = GenServer.call(bus, {:subscribe, :first, pid})
    :ok = GenServer.call(bus, {:subscribe, :second, pid})
    Process.exit(pid, :kill)

    assert eventually(fn ->
             GenServer.call(bus, {:subscribers, :first}) == [] and
               GenServer.call(bus, {:subscribers, :second}) == []
           end)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
