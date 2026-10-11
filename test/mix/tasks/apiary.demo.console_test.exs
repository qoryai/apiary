defmodule Mix.Tasks.Apiary.Demo.ConsoleTest do
  # The history writes from processes of its own: the sandbox is shared. One writer at a
  # time, so none waits on the shared connection long enough to time out on a slow machine.
  use Apiary.DataCase, async: false

  # The release whose fetch fails says so in the log.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{Accounts, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Runs.{Run, Target}
  alias Apiary.Secrets.Secret
  alias Apiary.Variables.Variable
  alias Mix.Tasks.Apiary.Demo.Console

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    # The suite's instance organisation is committed before any test: hidden as the edition
    # hides it, and every organisation marked for deletion in this test's sandbox, the
    # instance has none in use and is not set up, as a new database is not.
    Apiary.EditionKit.hide_instance_organisation()
    now = DateTime.utc_now()

    Repo.update_all(Organisation,
      set: [
        deletion_marked_at: now,
        purge_after: DateTime.add(now, 30, :day),
        purge_trigger: "grace_period"
      ]
    )

    :ok
  end

  defp fill, do: Console.run(~w(--runs 140 --days 12 --concurrency 1))

  defp count(query), do: Repo.aggregate(query, :count)

  test "fills an empty instance: the organisation, its workspaces, people and their runs" do
    fill()

    organisation = Repo.get_by!(Organisation, slug: "acme")

    # A second workspace where the edition allows one; the core's does not.
    expected =
      if Apiary.Edition.limits().workspaces == 1, do: ["main"], else: ["main", "shop-ops"]

    assert organisation.id |> workspaces() |> Enum.sort() == expected

    dana = Accounts.get_user_by_email("dana@example.com")
    assert dana.confirmed_at

    assert Repo.exists?(
             from m in Membership,
               where:
                 m.organisation_id == ^organisation.id and m.user_id == ^dana.id and
                   m.level == :owner
           )

    # The password the moduledoc gives signs her in.
    [_, password] = Regex.run(~r/the password\s+`([^`]+)`/, moduledoc())
    assert %{id: id} = Accounts.get_user_by_email_and_password("dana@example.com", password)
    assert id == dana.id

    levels =
      Repo.all(
        from m in Membership, where: m.organisation_id == ^organisation.id, select: m.level
      )

    assert :admin in levels and :member in levels

    assert Repo.exists?(
             from m in Membership,
               where: m.organisation_id == ^organisation.id and not is_nil(m.suspended_at)
           )

    assert Repo.exists?(from i in Invitation, where: i.organisation_id == ^organisation.id)

    main = Repo.get_by!(Workspace, organisation_id: organisation.id, slug: "main")

    # Repositories on the three forges, a path on more than one of them, and runs that
    # ended every way, one alive now.
    systems =
      Repo.all(
        from t in Target, where: t.workspace_id == ^main.id, distinct: true, select: t.system
      )

    assert Enum.sort(systems) == ["codeberg.org", "github.com", "gitlab.com"]
    refute Repo.exists?(from t in Target, where: t.system not in ^systems)

    shop =
      Repo.all(
        from t in Target,
          where: t.workspace_id == ^main.id and t.path == "acme/shop",
          select: t.system
      )

    assert length(shop) > 1

    states =
      Repo.all(from r in Run, where: r.workspace_id == ^main.id, distinct: true, select: r.state)

    assert "completed" in states and "failed" in states and "running" in states

    assert count(from r in Run, where: r.workspace_id == ^main.id and is_nil(r.target_id)) > 0

    # Dana pins three repositories.
    assert count(from p in Apiary.Targets.Pin, where: p.user_id == ^dana.id) == 3
  end

  test "gives Main nodes with keys, its runs placed on the history's, secrets, variables and integrations" do
    fill()

    main = main_workspace()

    nodes =
      Repo.all(from n in Node, where: n.workspace_id == ^main.id, select: {n.name, n.kind})
      |> Map.new()

    # The console's own, with no run placed on them.
    assert Map.take(nodes, ["build-01", "build-02", "spot-runners"]) ==
             %{"build-01" => :node, "build-02" => :node, "spot-runners" => :pool}

    # The history's: a node per machine group, a pool for a fleet.
    assert nodes["ci-fleet"] == :pool
    assert nodes["dana-laptop"] == :node

    console =
      Repo.all(
        from k in AccessKey,
          join: n in assoc(k, :node),
          where: k.workspace_id == ^main.id and n.name in ["build-01", "build-02", "spot-runners"]
      )

    assert Enum.any?(console, & &1.revoked_at)
    assert Enum.count(console, &is_nil(&1.revoked_at)) == 4

    assert count(
             from c in EnrolmentCode,
               where: c.workspace_id == ^main.id and not is_nil(c.cancelled_at)
           ) == 1

    assert count(
             from c in EnrolmentCode, where: c.workspace_id == ^main.id and is_nil(c.cancelled_at)
           ) == 1

    # Every run of Main is placed on a node; the history's on the instance of its host,
    # which is recorded, the recordings' on dana-laptop, as no instance.
    refute Repo.exists?(from r in Run, where: r.workspace_id == ^main.id and is_nil(r.node_id))

    refute Repo.exists?(
             from r in Run,
               join: n in assoc(r, :node),
               where: r.workspace_id == ^main.id,
               where: n.name in ["build-01", "build-02", "spot-runners"]
           )

    dana = Repo.get_by!(Node, workspace_id: main.id, name: "dana-laptop")
    assert Repo.exists?(from r in Run, where: r.node_id == ^dana.id and is_nil(r.instance_id))
    assert Repo.exists?(from i in Instance, where: i.node_id == ^dana.id and i.name == "dana-mbp")

    # Secrets, variables and integrations are the secrets feature's.
    if Apiary.Features.on?(:secrets) do
      assert count(from s in Secret, where: s.workspace_id == ^main.id) == 4
      assert count(from v in Variable, where: v.workspace_id == ^main.id and v.locked) == 2

      assert count(
               from v in Variable, where: v.workspace_id == ^main.id and not is_nil(v.target_id)
             ) > 0

      kinds =
        Repo.all(from c in Connection, where: c.workspace_id == ^main.id, select: c.kind)

      assert Enum.frequencies(kinds) == %{"runtime" => 1, "service" => 2, "integration" => 2}

      assert Repo.all(from r in Release, where: r.workspace_id == ^main.id, select: r.state)
             |> Enum.sort() == ["failed", "ready", "ready"]
    else
      refute Repo.exists?(from s in Secret, where: s.workspace_id == ^main.id)
      refute Repo.exists?(from v in Variable, where: v.workspace_id == ^main.id)
      refute Repo.exists?(from c in Connection, where: c.workspace_id == ^main.id)
    end
  end

  # Off, the `secrets` feature is absent from the fill too, the security policy kept.
  @tag with_features: [:observability, :security]
  @tag needs: :security
  test "without the secrets feature the fill makes no secret, variable or integration" do
    fill()

    workspaces =
      Repo.all(from w in Workspace, join: o in assoc(w, :organisation), where: o.slug == "acme")

    assert workspaces != []

    for workspace <- workspaces do
      refute Repo.exists?(from s in Secret, where: s.workspace_id == ^workspace.id)
      refute Repo.exists?(from v in Variable, where: v.workspace_id == ^workspace.id)
      refute Repo.exists?(from c in Connection, where: c.workspace_id == ^workspace.id)
      refute Repo.exists?(from r in Release, where: r.workspace_id == ^workspace.id)
    end
  end

  test "a second run makes nothing more of the fill, and brings a live run" do
    fill()
    targets = count(Target)
    runs = count(Run)
    keys = count(AccessKey)

    fill()

    assert count(Target) == targets
    assert count(Run) == runs + 1
    assert count(AccessKey) == keys
  end

  test "a demo whose pins were taken away in the console is still finished" do
    fill()
    Repo.delete_all(Apiary.Targets.Pin)
    runs = count(Run)

    fill()

    assert count(Run) == runs + 1
  end

  test "an instance with an organisation that is not the demo's is refused" do
    sign_up_fixture()

    assert_raise Mix.Error, ~r/not the demo's/, fn -> fill() end
    refute Repo.exists?(from o in Organisation, where: o.slug == "acme")
  end

  test "an instance with the demo's organisation and another one is refused" do
    sign_up_fixture(%{email: "dana@example.com", organisation_name: "Acme"})
    sign_up_fixture()

    assert_raise Mix.Error, ~r/not the demo's/, fn -> fill() end
    refute Repo.exists?(Run)
  end

  test "a fill that stopped before its last step is refused, not served as whole" do
    # Dana and Acme are the fill's first step; build-01's cancelled code, its last, is
    # missing.
    sign_up_fixture(%{email: "dana@example.com", organisation_name: "Acme"})

    error = assert_raise Mix.Error, fn -> fill() end
    assert error.message =~ "The demo's fill did not finish."
    assert error.message =~ "unset DATABASE_URL"
    assert error.message =~ "mix ecto.drop && mix ecto.create && mix ecto.migrate"
    refute error.message =~ "demo-up.sh"
    refute Repo.exists?(Run)
  end

  describe "the database it fills" do
    @demo %{"APIARY_DEV_DATABASE" => "apiary_redesign_demo"}

    test "is the one APIARY_DEV_DATABASE names, with no DATABASE_URL" do
      assert Console.refusal(:dev, false, "apiary_redesign_demo", @demo) == nil
    end

    test "is refused while DATABASE_URL is set, whatever it names" do
      env = Map.put(@demo, "DATABASE_URL", "ecto://postgres:postgres@localhost/apiary_dev")
      refusal = Console.refusal(:dev, false, "apiary_redesign_demo", env)

      assert refusal =~ "DATABASE_URL is set, and it replaces the database"
      assert refusal =~ "unset DATABASE_URL"
      refute refusal =~ "demo-up.sh"
    end

    test "takes an empty DATABASE_URL for unset, as Ecto does" do
      env = Map.put(@demo, "DATABASE_URL", "")
      assert Console.refusal(:dev, false, "apiary_redesign_demo", env) == nil
    end

    test "is refused when APIARY_DEV_DATABASE names none, or another than configured" do
      assert Console.refusal(:dev, false, "apiary_dev", %{}) =~ "names no database"

      assert Console.refusal(:dev, false, "apiary_dev", %{"APIARY_DEV_DATABASE" => ""}) =~
               "names no database"

      assert Console.refusal(:dev, false, "apiary_dev", @demo) =~
               ~s(configured with the database "apiary_dev")
    end

    test "is never a database people work in" do
      for database <- ~w(apiary_dev apiary_core_dev) do
        env = %{"APIARY_DEV_DATABASE" => database}

        assert Console.refusal(:dev, false, database, env) =~
                 "#{database} is a database people work in"
      end
    end

    test "has demo in its name" do
      env = %{"APIARY_DEV_DATABASE" => "apiary_review"}

      assert Console.refusal(:dev, false, "apiary_review", env) =~
               ~s(apiary_review does not have "demo" in its name)
    end

    test "is the tests' own in the test environment, under the tests alone" do
      env = %{"DATABASE_URL" => "ecto://x/y"}
      assert Console.refusal(:test, true, "apiary_test", env) == nil

      assert Console.refusal(:test, false, "apiary_test", env) =~
               "the test environment's database, apiary_test, is the tests' own"
    end
  end

  defp main_workspace do
    organisation = Repo.get_by!(Organisation, slug: "acme")
    Repo.get_by!(Workspace, organisation_id: organisation.id, slug: "main")
  end

  defp workspaces(organisation_id),
    do:
      Repo.all(from w in Workspace, where: w.organisation_id == ^organisation_id, select: w.slug)

  defp moduledoc do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Console)
    doc
  end
end
