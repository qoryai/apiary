defmodule Mix.Tasks.Apiary.Demo.HistoryTest do
  # The task writes from processes of its own: the sandbox is shared. One writer at a time, so
  # none waits on the shared connection long enough to time out on a slow machine.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.AccessKeys.AccessKey
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
    assert "succeeded" in states
    assert "failed" in states

    # The runs happened over the days asked for, not at once.
    starts = runs |> Enum.map(& &1.started_at) |> Enum.reject(&is_nil/1)
    oldest = Enum.min(starts, DateTime)
    assert DateTime.diff(DateTime.utc_now(), oldest, :day) >= 5
  end

  test "keys are made per machine, one revoked and one never used; people join at every level",
       %{scope: scope} do
    fill(scope)

    keys = Repo.all(from k in AccessKey, where: k.workspace_id == ^scope.workspace.id)
    by_label = Map.new(keys, &{&1.label, &1})

    assert by_label["legacy-ci"].revoked_at
    assert is_nil(by_label["staging-bot"].last_used_at)
    assert by_label["ci-fleet"].last_used_at

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
