defmodule Apiary.Connections.SettingsBudgetTest do
  # The budget of the settings check (`Apiary.Integrations.Description.check_settings/2`),
  # end to end: a release found as the product finds it, whose settings schema makes the
  # check's work grow exponentially, and the writes of Connections, which check settings
  # while they hold the organisation's integrations lock. Each is refused as invalid
  # settings within the budget, the warning it logs says which it ran out of, reductions
  # or heap, the caller lives on and the next write takes the lock. Not async: the time
  # asserted is the write's alone.
  use Apiary.DataCase, async: false

  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Integrations}
  alias Apiary.Connections.Connection

  @moduletag needs: :secrets

  # Each write is refused within 350 ms; this leaves room for a slow machine. Without the
  # budget, the checks of the writes below took 33 s, 5.7 s and 1.19 GB, and 24.5 s.
  @refused_within_ms 1000

  @url "https://downloads.example.com/acme/tracker/description.json"

  @refused {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

  setup do
    %{scope: sign_up_fixture().scope}
  end

  # A ready release of the tracker at `@url`, its setting `url` described by `url` and
  # its settings' definitions `defs`.
  defp release!(scope, url, defs \\ %{}, version \\ "0.3.0") do
    description =
      tracker_description(%{
        "program_version" => version,
        "settings" => %{
          "type" => "object",
          "properties" => %{
            "url" => url,
            "api_key" => %{"type" => "string", "writeOnly" => true},
            "api_key_file" => %{"type" => "string"}
          },
          "$defs" => defs
        }
      })

    bytes = encode(description)

    files = %{
      "/acme/tracker/description.json" => bytes,
      "/acme/tracker/checksums.txt" => checksums(bytes)
    }

    Req.Test.stub(Apiary.Integrations.Fetch, fn conn ->
      case Map.fetch(files, conn.request_path) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    {:ok, release} = Integrations.request_release(scope, %{source: @url})
    {:ok, %{state: "ready"} = release} = Integrations.fetch_release(scope, release.id)
    release
  end

  # Definitions whose every level refers twice to the next, in allOf: 2^levels checks of
  # one value, which the last level takes as a string.
  defp doubling(levels) do
    Map.new(1..levels, fn i ->
      next = %{"$ref" => "#/$defs/d#{i + 1}"}
      {"d#{i}", %{"allOf" => [next, next]}}
    end)
    |> Map.put("d#{levels + 1}", %{"type" => "string"})
  end

  # `write` refused within the budget, its warning naming `reason`, "reductions" or
  # "heap"; and nothing of the check left with the caller.
  defp over_budget(write, reason) do
    flush()
    monitors = Process.info(self(), :monitors)

    {{microseconds, result}, log} = with_log(fn -> :timer.tc(write) end)

    assert result == @refused
    assert log =~ "settings check was stopped name=acme-tracker"
    assert log =~ ~r/reason=#{reason}$/m
    assert div(microseconds, 1000) < @refused_within_ms, "took #{div(microseconds, 1000)} ms"
    assert Process.info(self(), :monitors) == monitors
    refute_received _any
  end

  # Takes the messages before the write, such as the sign-up's email.
  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  test "create_integration refuses settings whose check runs out of reductions",
       %{scope: scope} do
    release = release!(scope, %{"$ref" => "#/$defs/d1"}, doubling(24))

    over_budget(
      fn ->
        Connections.create_integration(scope, release.id, %{"settings" => %{"url" => "s"}})
      end,
      "reductions"
    )

    assert Repo.aggregate(Connection, :count) == 0

    # The lock is free again: the same write without the setting is taken.
    assert {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
  end

  test "update_connection refuses settings whose check runs out of heap", %{scope: scope} do
    release = release!(scope, %{"$ref" => "#/$defs/d1"}, doubling(20))
    {:ok, connection} = Connections.create_integration(scope, release.id, %{})

    # The leaf refuses the value at each of the 2^20 paths, and JSV keeps every error.
    over_budget(
      fn -> Connections.update_connection(scope, connection, %{"settings" => %{"url" => 1}}) end,
      "heap"
    )

    assert Repo.get!(Connection, connection.id).settings == connection.settings

    assert {:ok, _connection} =
             Connections.update_connection(scope, connection, %{"applies_to" => "all"})
  end

  test "change_release refuses settings that the new release's check runs out of reductions on",
       %{scope: scope} do
    first = release!(scope, %{"type" => "string"})
    url = String.duplicate("a", 60_000) <> "!"

    {:ok, connection} =
      Connections.create_integration(scope, first.id, %{"settings" => %{"url" => url}})

    # 1000 backtracking patterns, each spending the pattern budget of JSV on the setting.
    patterns = %{"anyOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}
    second = release!(scope, %{"$ref" => "#/$defs/p"}, %{"p" => patterns}, "0.4.0")

    over_budget(
      fn -> Connections.change_release(scope, connection, second.id) end,
      "reductions"
    )

    assert Repo.get!(Connection, connection.id).release_id == first.id
  end
end
