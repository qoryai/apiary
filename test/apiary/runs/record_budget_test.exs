defmodule Apiary.Runs.RecordBudgetTest do
  @moduledoc """
  The read budget that needs the machine to itself: it writes some 460 MiB of events and
  measures what one process holds while reading them. Not async, so no other test's load
  is in the measure or in the way, and with a timeout of its own, over ExUnit's minute.
  """
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Projector, Record}

  setup do
    %{scope: scope_fixture()}
  end

  describe "read budgets" do
    # What a read costs this server is set by the number of rows, never by what a runner
    # put in them.
    @tag timeout: 300_000
    test "a window of 300 calls with 512 KiB responses is read in under 32 MiB", %{
      scope: scope
    } do
      run = run_fixture(scope)
      big = String.duplicate("0123456789abcdef", 32 * 1024)
      assert byte_size(big) == 512 * 1024

      events =
        [{1, "run.started", started_data()}] ++
          Enum.flat_map(1..300, fn n ->
            [
              {2 * n, "session.tool_started",
               %{
                 "tool" => "Bash",
                 "tool_use_id" => "t#{n}",
                 "input" => %{"command" => "cat big-#{n}", "stdin" => big}
               }},
              {2 * n + 1, "session.tool_finished",
               %{
                 "tool" => "Bash",
                 "tool_use_id" => "t#{n}",
                 "response" => %{"stdout" => big, "stderr" => big}
               }}
            ]
          end)

      events_fixture(run, events)
      {:ok, run} = Projector.project(run)

      index = Record.timeline(scope, run)
      light = Enum.take(index.items, 300)
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          items = Record.items(scope, run, light)
          {:memory, memory} = Process.info(self(), :memory)
          {:binary, binaries} = Process.info(self(), :binary)
          held = binaries |> Enum.map(&elem(&1, 1)) |> Enum.sum()

          send(
            parent,
            {:read, length(items), memory + held,
             items |> :erlang.term_to_binary() |> byte_size()}
          )
        end)

      # One wait for both outcomes: the reader's answer, or its death without one.
      {bytes, size} =
        receive do
          {:read, 300, bytes, size} -> {bytes, size}
          {:read, count, _bytes, _size} -> flunk("read #{count} items, not 300")
          {:DOWN, ^ref, :process, ^pid, reason} -> flunk("the reader died: #{inspect(reason)}")
        after
          240_000 -> flunk("the read did not finish in four minutes")
        end

      Process.demonitor(ref, [:flush])

      IO.puts(
        "\n[budget] 300 calls with 512 KiB payloads: the reading process held #{div(bytes, 1024)} KiB (memory + binaries); the items are #{div(size, 1024)} KiB"
      )

      assert bytes < 32 * 1024 * 1024, "held #{div(bytes, 1024)} KiB"
    end
  end
end
