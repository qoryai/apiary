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
  alias Apiary.Adapters
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release
  alias Apiary.Nodes.{Instance, Node}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Runs.{Run, Target}
  alias Apiary.Secrets.Secret
  alias Apiary.Sources.Item
  alias Apiary.Stacks
  alias Apiary.Variables.Variable
  alias Apiary.WorkItems.WorkItem
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

  @tag :feature_sets
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
    # ended every way, one alive now. With the factory feature, the tracker's
    # repositories are on git.example.com too.
    systems =
      Repo.all(
        from t in Target, where: t.workspace_id == ^main.id, distinct: true, select: t.system
      )

    forges = ["codeberg.org", "github.com", "gitlab.com"]

    expected =
      if Apiary.Features.on?(:factory), do: ["git.example.com" | forges], else: forges

    assert Enum.sort(systems) == Enum.sort(expected)
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

  @tag :feature_sets
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

    assert Repo.exists?(
             from r in Run, where: r.node_id == ^dana.id and is_nil(r.node_instance_id)
           )

    assert Repo.exists?(from i in Instance, where: i.node_id == ^dana.id and i.name == "dana-mbp")

    # Secrets, variables and integrations are the secrets feature's.
    if Apiary.Features.on?(:secrets) do
      assert count(from s in Secret, where: s.workspace_id == ^main.id) == 4
      assert count(from v in Variable, where: v.workspace_id == ^main.id and v.locked) == 2

      assert count(
               from v in Variable, where: v.workspace_id == ^main.id and not is_nil(v.target_id)
             ) > 0

      kinds =
        Repo.all(
          from c in Connection, where: c.organisation_id == ^main.organisation_id, select: c.kind
        )

      assert Enum.frequencies(kinds) == %{"runtime" => 1, "service" => 2, "integration" => 2}

      assert Repo.all(
               from r in Release,
                 where: r.organisation_id == ^main.organisation_id,
                 select: r.state
             )
             |> Enum.sort() == ["failed", "ready", "ready"]
    else
      refute Repo.exists?(from s in Secret, where: s.workspace_id == ^main.id)
      refute Repo.exists?(from v in Variable, where: v.workspace_id == ^main.id)
      refute Repo.exists?(from c in Connection, where: c.organisation_id == ^main.organisation_id)
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

      refute Repo.exists?(
               from c in Connection, where: c.organisation_id == ^workspace.organisation_id
             )

      refute Repo.exists?(
               from r in Release, where: r.organisation_id == ^workspace.organisation_id
             )
    end
  end

  @tag needs: :factory
  test "with the factory feature: two adapters connected for Acme, their collections, tickets and work items" do
    fill()

    main = main_workspace()
    one_workspace? = Apiary.Edition.limits().workspaces == 1

    adapters =
      Repo.all(from n in Node, where: n.kind == :adapter and is_nil(n.deleted_at))
      |> Map.new(&{&1.name, &1})

    assert Map.keys(adapters) == ["Helpdesk", "Tracker"]
    %{"Tracker" => tracker, "Helpdesk" => helpdesk} = adapters
    assert tracker.connect_url == "https://tracker.example.com/connect"
    assert Adapters.item_noun(tracker) == %{one: "ticket", other: "tickets"}
    assert Adapters.collection_noun(tracker) == %{one: "repository", other: "repositories"}
    assert helpdesk.connect_url == "https://helpdesk.example.com/connect"
    assert Adapters.item_noun(helpdesk) == %{one: "incident", other: "incidents"}
    assert Adapters.collection_noun(helpdesk) == %{one: "queue", other: "queues"}

    connections = Repo.all(Adapters.Connection) |> Map.new(&{&1.adapter_id, &1})
    assert map_size(connections) == 2

    for adapter <- [tracker, helpdesk] do
      assert %{state: :connected, listed_at: %DateTime{}} = connection = connections[adapter.id]
      assert connection.organisation_id == main.organisation_id
    end

    # Nine repositories: seven in Main, acme/warehouse in Shop ops or, with one
    # workspace, in Main, and acme/sandbox in none.
    places = places(tracker)
    assert map_size(places) == 9
    assert places["acme/sandbox"] == nil
    assert places["acme/warehouse"] == if(one_workspace?, do: "main", else: "shop-ops")

    assert places |> Map.values() |> Enum.count(&(&1 == "main")) ==
             if(one_workspace?, do: 8, else: 7)

    assert %{backlog: false} = Repo.get_by!(Adapters.Collection, title: "acme/infra")

    # Two queues, with no target, in Support, or in Main where the edition allows one
    # workspace.
    support = if one_workspace?, do: "main", else: "support"

    assert places(helpdesk) ==
             %{"acme/customer-support" => support, "acme/billing-support" => support}

    refute Repo.exists?(
             from c in Adapters.Collection,
               where: c.adapter_id == ^helpdesk.id and not is_nil(c.target_system)
           )

    assert states(tracker) == %{open: 34, closed: 8}
    assert states(helpdesk) == %{open: 8, closed: 4}
    # Each ticket has the comments its count says.
    comments = Repo.all(from i in Item, select: i.comment_count) |> Enum.sum()
    assert comments == 55 + 9
    assert count(Apiary.Sources.Comment) == comments

    work_items = Repo.all(from w in WorkItem, where: w.workspace_id == ^main.id)
    assert Enum.all?(work_items, &(&1.adapter_id == tracker.id))
    refute Repo.exists?(from w in WorkItem, where: w.adapter_id == ^helpdesk.id)

    assert work_items |> Enum.map(& &1.state) |> Enum.frequencies() ==
             %{exploring: 7, closed: 2, undone: 1}

    # The stack of Main's runs: one row, at the workspace, for the workflow hello; and no
    # harness choice. A run reads its repository's harness file first, under any choice.
    assert [%Stacks.Stack{} = stack] = Repo.all(where(Stacks.Stack, [s], not is_nil(s.workflow)))
    assert {stack.workspace_id, stack.target_id, stack.workflow} == {main.id, nil, "hello"}
    assert Stacks.choice(main) == nil

    assert {:ok, %{"extends" => base}} = Apiary.Harnesses.Reader.document(stack.harness)

    assert base == %{
             "git" => "https://github.com/qoryai/qory",
             "ref" => "2148b3ae11eff8ccbeb93d1a7c10aeb05595c95b",
             "path" => "examples/hello"
           }

    assert Stacks.Document.errors(stack.harness) == []

    assert Stacks.workflow(main, nil) == "hello"

    # Spread across members, seven people own the live ones.
    owners = for %{state: :exploring, owner_id: id} <- work_items, uniq: true, do: id
    assert length(owners) == 7

    live = for %{state: :exploring, id: id} <- work_items, do: id

    assert live |> Apiary.WorkItems.Explore.statuses() |> Map.values() |> Enum.frequencies() ==
             %{queued: 7}

    # The Backlog and the Work items list, as Lea, a member, reads them.
    lea = scope_of("lea@example.com", main)

    assert %{rows: [_ | _], counts: counts} =
             Apiary.Sources.Backlog.list_tickets(lea, view: :open)

    # Open in Main, without acme/infra's three, whose Backlog is off, and without
    # acme/warehouse's three where it is in Shop ops; with the incidents, eight open and
    # four closed, where the queues are in Main.
    open = if one_workspace?, do: 31 + 8, else: 28
    closed = if one_workspace?, do: 8 + 4, else: 8

    assert counts == %{
             open: open - 7,
             taken: 7,
             declined: 0,
             closed: closed,
             total: open + closed
           }

    for view <- [:taken, :closed] do
      assert %{rows: [_ | _]} = Apiary.Sources.Backlog.list_tickets(lea, view: view)
    end

    assert %{rows: rows} = Apiary.WorkItems.list_work_items(lea, view: :open)
    assert length(rows) == 7

    # The incidents in the Backlog of the queues' workspace, to a member of it: in Main,
    # beside the repositories, a page names neither adapter's words.
    desk =
      if one_workspace?,
        do: lea,
        else: scope_of("dana@example.com", Repo.get_by!(Workspace, slug: "support"))

    for {queue, open, closed} <- [{"acme/customer-support", 5, 2}, {"acme/billing-support", 3, 2}] do
      for {view, n} <- [open: open, closed: closed] do
        assert %{rows: rows} =
                 Apiary.Sources.Backlog.list_tickets(desk, view: view, search: queue)

        assert length(rows) == n
        assert Enum.all?(rows, &(&1.repository == queue))
      end
    end

    if one_workspace? do
      assert Adapters.workspace_collection_noun(desk) == nil
      assert Adapters.workspace_item_noun(desk) == nil
    else
      assert Adapters.workspace_collection_noun(desk) == %{one: "queue", other: "queues"}
      assert Adapters.workspace_item_noun(desk) == %{one: "incident", other: "incidents"}
    end
  end

  # The titles of `adapter`'s collections in use, with the slug of each one's workspace.
  defp places(adapter) do
    Repo.all(
      from c in Adapters.Collection,
        left_join: w in assoc(c, :workspace),
        where: c.adapter_id == ^adapter.id and is_nil(c.ended_at),
        select: {c.title, w.slug}
    )
    |> Map.new()
  end

  defp states(adapter) do
    Repo.all(from i in Item, where: i.adapter_id == ^adapter.id, select: i.state)
    |> Enum.frequencies()
  end

  # Off, the `factory` feature is absent from the fill, which completes all the same.
  @tag with_features: [:observability, :security, :secrets]
  test "without the factory feature the fill makes no adapter, ticket or work item" do
    fill()

    assert Repo.exists?(from o in Organisation, where: o.slug == "acme")
    refute Repo.exists?(from n in Node, where: n.kind == :adapter)
    refute Repo.exists?(Adapters.Collection)
    refute Repo.exists?(Item)
    refute Repo.exists?(WorkItem)
    refute Repo.exists?(Stacks.Stack)
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
               "the test environment's database, apiary_test, belongs to the tests"
    end
  end

  defp main_workspace do
    organisation = Repo.get_by!(Organisation, slug: "acme")
    Repo.get_by!(Workspace, organisation_id: organisation.id, slug: "main")
  end

  # The person's scope of `workspace`, as their page has it.
  defp scope_of(email, workspace) do
    user = Accounts.get_user_by_email(email)

    {:ok, scope} =
      Apiary.Organisations.resolve_scope(
        Apiary.Accounts.Scope.for_user(user),
        "acme",
        workspace.slug
      )

    scope
  end

  defp workspaces(organisation_id),
    do:
      Repo.all(from w in Workspace, where: w.organisation_id == ^organisation_id, select: w.slug)

  defp moduledoc do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Console)
    doc
  end
end
