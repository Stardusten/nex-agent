defmodule Nex.Automation.WorkerRunnerTest do
  use ExUnit.Case, async: false

  alias Nex.Automation.WorkerRunner

  test "runs a worker command and reports completion" do
    assert {:ok, pid} =
             WorkerRunner.start_link(
               id: {:issue, 42},
               command: ["sh", "-c", "printf ready"],
               cwd: System.tmp_dir!(),
               notify: self(),
               timeout_ms: 5_000
             )

    ref = Process.monitor(pid)

    assert_receive {:worker_finished, {:issue, 42}, result}, 2_000
    assert result.status == :completed
    assert result.exit_code == 0
    assert result.output =~ "ready"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "cancel stops a running worker and reports cancellation" do
    assert {:ok, pid} =
             WorkerRunner.start_link(
               id: {:issue, 99},
               command: ["sh", "-c", "sleep 30"],
               cwd: System.tmp_dir!(),
               notify: self(),
               timeout_ms: 30_000
             )

    ref = Process.monitor(pid)

    assert :ok = WorkerRunner.cancel(pid)

    assert_receive {:worker_finished, {:issue, 99}, result}, 2_000
    assert result.status == :cancelled
    assert result.exit_code == nil
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end
end
