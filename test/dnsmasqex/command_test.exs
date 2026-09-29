# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.CommandTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Command

  @moduletag :tmp_dir

  test "short commands retain output and exit status without pipe acknowledgments" do
    for _ <- 1..50 do
      assert {output, 3} = Command.run("sh", ["-c", "echo out; echo err >&2; exit 3"], 1000)
      assert Enum.sort(String.split(output)) == ["err", "out"]
    end

    assert {:error, :enoent} = Command.run("/nonexistent/dnsmasq", [], 1000)
  end

  test "a timeout terminates the OS process even when it ignores TERM", %{tmp_dir: tmpdir} do
    path = Path.join(tmpdir, "pid")
    script = "trap '' TERM; echo $$ > \"$1\"; exec sleep 60"
    assert {"", :timeout} = Command.run("sh", ["-c", script, "probe", path], 100)
    pid = path |> File.read!() |> String.trim()
    assert_stopped(pid, 100)
  end

  test "excess output is bounded and the writer is terminated" do
    assert {:error, :output_limit} = Command.run("sh", ["-c", "exec yes diagnostic"], 1000)
  end

  defp assert_stopped(pid, attempts) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 ->
        Process.sleep(20)
        assert_stopped(pid, attempts - 1)

      {_, status} ->
        assert status != 0, "timed-out OS process is still alive"
    end
  end
end
