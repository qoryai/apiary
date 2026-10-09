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
