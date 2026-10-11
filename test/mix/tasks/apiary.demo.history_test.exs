defmodule Mix.Tasks.Apiary.Demo.HistoryTest do
  # The task writes from processes of its own: the sandbox is shared. One writer at a time, so
  # none waits on the shared connection long enough to time out on a slow machine.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Instance
  alias Apiary.Organisations.{Invitation, Membership}
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run, Target}
  alias Mix.Tasks.Apiary.Demo.History

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    %{scope: sign_up_fixture().scope}
  end

  defp fill(scope, extra \\ []) do
    History.run(
      [
        "--workspace",
        "#{scope.organisation.slug}/#{scope.workspace.slug}",
        "--runs",
        "120",
        "--repositories",
        "12",
        "--days",
        "20",
        "--concurrency",
        "1"
      ] ++ extra
    )
  end

  defp runs(scope), do: Repo.all(from r in Run, where: r.workspace_id == ^scope.workspace.id)

  test "the history's runs are stored and projected, across repositories and outcomes",
       %{scope: scope} do
    fill(scope, ["--skip-members"])

    runs = runs(scope)
    assert length(runs) == 120

    # Every event was folded, and the fold named the repositories the labels gave.
    refute Repo.exists?(from e in Event, where: is_nil(e.projected_at))

    assert Repo.aggregate(from(t in Target, where: t.workspace_id == ^scope.workspace.id), :count) >
             1

    states = runs |> Enum.map(& &1.state) |> Enum.uniq()
    assert "completed" in states
    assert "failed" in states

    # The runs happened over the days asked for, not at once.
    starts = runs |> Enum.map(& &1.started_at) |> Enum.reject(&is_nil/1)
    oldest = Enum.min(starts, DateTime)
    assert DateTime.diff(DateTime.utc_now(), oldest, :day) >= 5
  end

  # The starter's reasons the history gives, generic, and Forager's own codes; never the old
  # names of the contract before the starter.
  @starter_reasons ~w(all_checks_passed checks_failed no_longer_needed)
  @forager_reasons ~w(timeout quiet credential_expired stopped session_lost gateway_lost
                      batch_refused credential_check_unreachable credential_check_invalid
                      run_closed)

  test "the runs end completed, failed, cancelled and lost, by the contract's exits and generic reasons",
       %{scope: scope} do
    # Cancelled and lost runs are a few in a hundred. This seed and this end give a small
    # history that holds every kind, the same on any day.
    fill(scope, ["--skip-members", "--seed", "1", "--until", "2026-06-01T12:00:00Z"])

    runs = runs(scope)
    by_state = Enum.group_by(runs, & &1.state)

    # Every run is stored under a state of today's names; none under an older one.
    assert Enum.all?(runs, &(&1.state in Run.states()))
    for state <- ~w(completed failed cancelled lost), do: assert(by_state[state], state)

    # Cancelled at the time limit, after its hour, and by the starter; lost by silence, and
    # by an exit that says how, at the exit's time.
    reasons = fn state -> by_state[state] |> Enum.map(& &1.reason) |> Enum.uniq() end
    assert "timeout" in reasons.("cancelled")
    assert "no_longer_needed" in reasons.("cancelled")
    assert Enum.all?(by_state["cancelled"], &(&1.reason in ~w(timeout no_longer_needed)))

    for run <- by_state["cancelled"], run.reason == "timeout" do
      assert run.duration_ms == 3_600_000
    end

    assert nil in reasons.("lost")
    assert "session_lost" in reasons.("lost")
    assert "gateway_lost" in reasons.("lost")

    for run <- by_state["lost"], run.reason do
      assert run.reason in ~w(session_lost gateway_lost)
      assert run.lost_at == run.exited_at
    end

    assert "all_checks_passed" in reasons.("completed")
    assert "checks_failed" in reasons.("failed")

    # No end reason outside the starter's generic codes and Forager's own.
    for run <- runs, run.reason do
      assert run.reason in @starter_reasons or run.reason in @forager_reasons, run.reason
    end

    # Every exit says its state in the contract's names, and a starter's reason comes only
    # on a run whose starter gave it its run credential.
    events =
      Repo.all(
        from e in Event,
          where:
            e.workspace_id == ^scope.workspace.id and
              e.type in ["dev.qory.run.exited", "dev.qory.run.started"],
          select: {e.run_id, e.type, e.data}
      )

    for {_run, "dev.qory.run.exited", data} <- events do
      assert data["state"] in ~w(succeeded failed cancelled)
    end

    # Each reason comes with its own state, and every stop and loss with exit -1: no exit
    # status of the runtime's ended those.
    exits = %{
      "all_checks_passed" => {"succeeded", 0},
      "checks_failed" => {"failed", :any},
      "timeout" => {"cancelled", -1},
      "no_longer_needed" => {"cancelled", -1},
      "session_lost" => {"failed", -1},
      "gateway_lost" => {"failed", -1}
    }

    for {_run, "dev.qory.run.exited", %{"reason" => reason} = data} <- events do
      {state, code} = Map.fetch!(exits, reason)
      assert data["state"] == state, reason
      assert code == :any or data["exit_code"] == code, reason
    end

    started = for {run, "dev.qory.run.started", data} <- events, into: %{}, do: {run, data}

    for run <- runs, run.reason in @starter_reasons do
      assert started[run.id]["credential"] == "starter"
    end
  end

  test "the runs say what they are about, as a caller would, on hosts under example.com",
       %{scope: scope} do
    fill(scope, ["--skip-members"])

    runs = runs(scope)
    kinds = runs |> Enum.map(& &1.about_kind) |> Enum.uniq()
    assert "Implementation" in kinds
    assert Enum.all?(kinds, &(&1 in [nil, "Implementation", "Review", "Maintenance", "Audit"]))

    fix = Enum.find(runs, &(&1.about_kind == "Implementation"))
    assert "Fix ENG-" <> _ = fix.about_title
    assert [%{"type" => "ticket"}, %{"type" => "pull request"} | _] = fix.about_subjects
    assert %{"branch" => "qory/eng-" <> _, "attempt" => attempt} = fix.about_details
    assert is_integer(attempt) and attempt >= 1

    # Every url a subject gives is on example.com; a subject may have none.
    for run <- runs, %{"url" => url} <- run.about_subjects do
      assert String.ends_with?(URI.parse(url).host, ".example.com"), url
    end

    for run <- runs, run.about_kind == "Review" do
      assert [%{"type" => "pull request", "url" => "https://git.example.com/" <> _}] =
               run.about_subjects
    end

    for run <- runs, run.about_kind == "Audit" do
      assert run.about_title == "Nightly audit"
      assert run.about_details == %{"schedule" => "0 2 * * *"}
    end
  end

  test "nodes and keys are made per machine, one revoked and one never used; people join at every level",
       %{scope: scope} do
    fill(scope)

    keys =
      Repo.all(from k in AccessKey, where: k.workspace_id == ^scope.workspace.id, preload: :node)

    by_label = Map.new(keys, &{&1.label, &1})

    assert by_label["legacy-ci"].revoked_at
    assert is_nil(by_label["staging-bot"].last_used_at)
    assert by_label["ci-fleet"].last_used_at
    assert by_label["ci-fleet"].node.kind == :pool
    assert by_label["dana-laptop"].node.kind == :node
    assert Enum.all?(keys, &(&1.public_key && &1.received_at))

    # ci-fleet holds a second key, as when its key is replaced.
    assert by_label["ci-fleet-next"].node_id == by_label["ci-fleet"].node_id
    assert is_nil(by_label["ci-fleet-next"].revoked_at)

    # Each run is on its machine's node, as the instance of its host, recorded.
    runs = runs(scope)
    assert Enum.all?(runs, &(&1.node_id && &1.instance_id))
    fleet = by_label["ci-fleet"].node_id

    names =
      Repo.all(from i in Instance, where: i.node_id == ^fleet, select: i.name)

    assert names != [] and Enum.all?(names, &String.starts_with?(&1, "ci-runner-"))

    levels =
      Repo.all(
        from m in Membership,
          where: m.organisation_id == ^scope.organisation.id,
          select: m.level
      )

    assert :owner in levels and :admin in levels and :member in levels
    assert Repo.exists?(from i in Invitation, where: i.organisation_id == ^scope.organisation.id)
  end

  test "a second fill adds another history and keeps the keys and people it made",
       %{scope: scope} do
    fill(scope)
    fill(scope)

    assert length(runs(scope)) == 240

    labels =
      Repo.all(
        from k in AccessKey,
          where: k.workspace_id == ^scope.workspace.id and is_nil(k.revoked_at),
          select: k.label
      )

    assert labels == Enum.uniq(labels)
  end

  test "a workspace that does not exist is refused" do
    assert_raise Mix.Error, ~r/no workspace/, fn ->
      History.run(["--workspace", "nobody/nowhere"])
    end
  end
end
