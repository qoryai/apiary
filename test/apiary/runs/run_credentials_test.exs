defmodule Apiary.Runs.RunCredentialsTest do
  # The work credential entry a claim records for its run (`Apiary.Runs.RunCredentials`,
  # through `Apiary.Dispatches.claim/3`): the adapter's apply items filled with the run's
  # target path, its collection as the resource and its access level. The collection is a
  # prebuild's, or for a run with a work item one that can change the run's target; none
  # where there is no such collection or no apply item, and the run ended
  # `target_access_gone` where the collection or its connection ended, or the target path
  # is refused.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Run, RunCredential, RunCredentials}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @apply [
    %{
      "hosts" => ["git.example.com"],
      "scheme" => "basic",
      "username" => "token-user",
      "paths" => ["/{target.path}.git/*", "/{target.path}/*"]
    },
    %{
      "hosts" => ["api.git.example.com"],
      "scheme" => "bearer",
      "paths" => ["/repos/{target.path}", "/repos/{target.path}/*", "/repos/acme/shop"]
    }
  ]

  # The gateway's keys are allowed stored secrets: a run with a work entry ends
  # `secrets_not_allowed` under a key that is not (the last describe).
  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope, allow_secrets: true), :scope, scope)
  end

  @target %{system: "forge.example.com", path: "acme/shop"}

  # A run of the queue for a new work item of the scope, whose target is acme/shop at
  # forge.example.com, whose ticket's adapter declares `apply` (nil for none), and whose
  # ticket's collection can change that target, as a code forge's issue's does
  # (`target_candidate!/1`).
  defp queued!(ctx, apply \\ @apply) do
    work_item = work_item_fixture(ctx.scope)
    set!(Node, work_item.adapter_id, source_apply: apply)
    target_candidate!(work_item)
    {work_item, queue!(work_item)}
  end

  # A run of the queue for a new work item of the scope, whose target is acme/shop at
  # forge.example.com, from a tracker's ticket: its adapter declares `@apply` but not
  # `targets`, and its collection's target is `ticket_target` (nil for none).
  defp tracker_queued!(ctx, ticket_target \\ nil) do
    work_item = work_item_fixture(ctx.scope)
    set!(Node, work_item.adapter_id, source_apply: @apply, targets: false)

    if ticket_target do
      set!(Collection, collection_of(work_item).id,
        target_system: ticket_target.system,
        target_path: ticket_target.path
      )
    end

    {work_item, queue!(work_item)}
  end

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  # A live collection of the scope's workspace, on a connected connection, that can change
  # `target`, as a code forge's adapter's is, its adapter declaring `@apply`. It has no
  # environment, so a claim takes no prebuild of it before the run.
  defp forge_collection!(ctx, target \\ @target) do
    collection =
      collection_fixture(ctx.scope,
        target_system: target.system,
        target_path: target.path,
        environment_ref: nil
      )

    set!(Node, collection.adapter_id, source_apply: @apply, targets: true)
    collection
  end

  # The work item's target path set to `path`, and its ticket's collection's to match.
  defp retarget!(work_item, path) do
    set!(WorkItem, work_item.id, target_path: path)
    set!(Collection, collection_of(work_item).id, target_path: path)
  end

  defp set!(schema, id, fields),
    do: {1, _rows} = Repo.update_all(from(r in schema, where: r.id == ^id), set: fields)

  defp collection_of(%WorkItem{item_id: item_id}),
    do:
      Repo.one!(
        from c in Collection,
          join: i in Item,
          on: i.collection_id == c.id,
          where: i.id == ^item_id
      )

  defp claim(ctx), do: Dispatches.claim(ctx.key, Dispatches.now())

  defp entries, do: Repo.all(from c in RunCredential, order_by: c.name)

  # The run of the queue ended `target_access_gone` at its claim, with an error and no
  # dispatch or run left, and no entry.
  defp gone!(%DispatchRun{id: id}) do
    assert %DispatchRun{state: :ended, end_cause: :target_access_gone, result_outcome: :error} =
             Repo.get!(DispatchRun, id)

    assert Repo.all(from d in Dispatch, where: d.dispatch_run_id == ^id and is_nil(d.ended_at)) ==
             []

    assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^id), :count) == 0
    assert entries() == []
  end

  describe "the run of a test work item" do
    test "gets no entry, while the workspace's adapter declares apply items", ctx do
      # A work item of the workspace whose ticket's adapter declares them, its run left
      # out of the queue.
      work_item = work_item_fixture(ctx.scope)
      set!(Node, work_item.adapter_id, source_apply: @apply)

      {:ok, test_item} = Apiary.WorkItems.take_in_test(ctx.scope, "Hello! Where are you running?")
      assert {:ok, %{registered: %Run{} = run, work_item: claimed}} = claim(ctx)
      assert claimed.id == test_item.id
      assert run.registration_labels == %{}
      assert entries() == []
    end
  end

  describe "an explore run whose ticket's adapter declares apply items" do
    test "gets work-1 with the filled paths, a repeat left out, its collection and read access",
         ctx do
      {work_item, queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)
      collection = collection_of(work_item)

      assert [entry] = entries()

      assert %RunCredential{
               name: "work-1",
               purpose: :work,
               access: :read,
               placeholders: nil
             } = entry

      assert entry.run_id == run.id
      assert entry.organisation_id == ctx.scope.organisation.id
      assert entry.workspace_id == ctx.scope.workspace.id
      assert entry.connection_id == work_item.connection_id
      assert entry.adapter_id == work_item.adapter_id
      assert run.dispatch_run_id == queued.id

      assert entry.resources == [
               %{
                 "collection_id" => collection.id,
                 "external_ref" => collection.external_ref,
                 "path" => "acme/shop"
               }
             ]

      assert entry.apply == [
               %{
                 "hosts" => ["git.example.com"],
                 "scheme" => "basic",
                 "username" => "token-user",
                 "paths" => ["/acme/shop.git/*", "/acme/shop/*"]
               },
               %{
                 "hosts" => ["api.git.example.com"],
                 "scheme" => "bearer",
                 "paths" => ["/repos/acme/shop", "/repos/acme/shop/*"]
               }
             ]
    end

    test "takes the access level of its harness walk", ctx do
      {_work_item, queued} = queued!(ctx)

      case Repo.get_by(RunHarness, dispatch_run_id: queued.id) do
        nil ->
          Repo.insert!(%RunHarness{
            dispatch_run_id: queued.id,
            state: :resolved,
            origin: :none,
            access_level: :write
          })

        walk ->
          set!(RunHarness, walk.id, access_level: :write)
      end

      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert [%RunCredential{access: :write}] = entries()
    end

    test "fills the target path exactly as the adapter wrote it", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}
      {work_item, _queued} = queued!(ctx)
      retarget!(work_item, "Team/Shop%20Two")
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [%RunCredential{apply: [%{"paths" => paths} | _rest]}] = entries()
      assert paths == ["/Team/Shop%20Two.git/*", "/Team/Shop%20Two/*"]
    end

    test "ends target_access_gone when the collection ended", ctx do
      {work_item, queued} = queued!(ctx)

      set!(Collection, collection_of(work_item).id,
        ended_at: DateTime.utc_now(),
        ended_reason: :not_listed
      )

      assert claim(ctx) == {:ok, :none}
      gone!(queued)
    end

    test "form_work/3 ends target_access_gone when the collection's connection is not connected",
         ctx do
      # A connection that ends closes its work items' runs before a claim takes them
      # (`end_cause` `closed`), so the claim never reaches here for one.
      {work_item, queued} = queued!(ctx)
      target = %{system: "forge.example.com", path: "acme/shop"}

      set!(Connection, work_item.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      assert RunCredentials.form_work(queued, work_item, target) ==
               {:end, :target_access_gone}
    end

    test "ends target_access_gone for a target path the apply items refuse", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}

      for path <- ["acme/../shop", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] do
        {work_item, queued} = queued!(ctx)
        retarget!(work_item, path)
        assert claim(ctx) == {:ok, :none}, inspect(path)
        gone!(queued)
      end
    end

    test "form_work/3 refuses each refused character class before it fills", ctx do
      {work_item, queued} = queued!(ctx)

      # No U+0000: a target is a column of text, which cannot hold one, so no collection's
      # target and no work item's has one.
      spaces =
        [0x09, 0x0A, 0x1F, 0x20, 0x7F, 0xFEFF, 0x85, 0xA0, 0x1680, 0x2000, 0x2005] ++
          [0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

      paths =
        ["acme/../shop", "..", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] ++
          for code <- spaces, do: "acme/sh" <> <<code::utf8>> <> "op"

      for path <- paths do
        retarget!(work_item, path)

        assert RunCredentials.form_work(queued, work_item, %{
                 system: "forge.example.com",
                 path: path
               }) ==
                 {:end, :target_access_gone},
               inspect(path)
      end

      for path <- ["acme/shop", "acme/.shop", "acme./shop", "Acme/Shop%2E"] do
        retarget!(work_item, path)

        assert {:ok, %RunCredential{}} =
                 RunCredentials.form_work(queued, work_item, %{
                   system: "forge.example.com",
                   path: path
                 }),
               path
      end
    end
  end

  describe "the collection that can change the run's target" do
    test "is the ticket's, for a ticket from a code forge, before an older one", ctx do
      older = forge_collection!(ctx)
      set!(Collection, older.id, inserted_at: ~U[2026-01-01 00:00:00.000000Z])
      {work_item, _queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [entry] = entries()
      assert entry.connection_id == work_item.connection_id
      assert entry.adapter_id == work_item.adapter_id
      assert [%{"collection_id" => id}] = entry.resources
      assert id == collection_of(work_item).id
    end

    test "is a forge's collection of the workspace, for a ticket from a tracker", ctx do
      # The tracker's ticket's collection has the same target, and its adapter declares
      # apply items, yet it never counts: its adapter has no `targets`.
      {work_item, _queued} = tracker_queued!(ctx, @target)
      forge = forge_collection!(ctx)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [entry] = entries()
      assert entry.connection_id == forge.connection_id
      assert entry.adapter_id == forge.adapter_id
      refute entry.connection_id == work_item.connection_id

      assert entry.resources == [
               %{
                 "collection_id" => forge.id,
                 "external_ref" => forge.external_ref,
                 "path" => "acme/shop"
               }
             ]

      assert [%{"paths" => ["/acme/shop.git/*", "/acme/shop/*"]}, _api] = entry.apply
    end

    test "is found for a work item with no ticket", ctx do
      # A work item whose ticket's row is gone (`item_id` nil): the matching collections
      # are read without it. The claim ends such an explore run `ticket_gone` first.
      {work_item, queued} = tracker_queued!(ctx, @target)
      forge = forge_collection!(ctx)
      forge_id = forge.id

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^forge_id}]} = entry} =
               RunCredentials.form_work(queued, %{work_item | item_id: nil}, @target)

      assert entry.connection_id == forge.connection_id
      assert entry.adapter_id == forge.adapter_id
    end

    test "is never one of an adapter without targets, even when its target matches", ctx do
      {work_item, queued} = tracker_queued!(ctx, @target)

      for targets <- [nil, false] do
        set!(Node, work_item.adapter_id, targets: targets)
        assert RunCredentials.form_work(queued, work_item, @target) == {:ok, nil}
      end
    end

    test "is the oldest, by when it was kept, then by id", ctx do
      {work_item, queued} = tracker_queued!(ctx)
      at = ~U[2026-01-01 00:00:00.000000Z]
      [first, second, third] = for _n <- 1..3, do: forge_collection!(ctx)
      set!(Collection, first.id, inserted_at: DateTime.add(at, 1))
      set!(Collection, second.id, inserted_at: at)
      set!(Collection, third.id, inserted_at: at)
      [low, _high] = Enum.sort([second.id, third.id])

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^low}]}} =
               RunCredentials.form_work(queued, work_item, @target)
    end

    test "is a live one on a connected connection, before an older one that is not", ctx do
      {work_item, queued} = tracker_queued!(ctx)
      ended = forge_collection!(ctx)
      disconnected = forge_collection!(ctx)
      live = forge_collection!(ctx)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: :not_listed)

      set!(Connection, disconnected.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      for {collection, n} <- Enum.with_index([ended, disconnected, live]) do
        set!(Collection, collection.id,
          inserted_at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n)
        )
      end

      live_id = live.id

      assert {:ok, %RunCredential{resources: [%{"collection_id" => ^live_id}]}} =
               RunCredentials.form_work(queued, work_item, @target)
    end

    test "ends the run target_access_gone where each one ended or is disconnected", ctx do
      {_work_item, queued} = tracker_queued!(ctx)
      ended = forge_collection!(ctx)
      set!(Collection, ended.id, ended_at: DateTime.utc_now(), ended_reason: :not_listed)
      assert claim(ctx) == {:ok, :none}
      gone!(queued)

      {work_item, queued} = tracker_queued!(ctx)
      disconnected = forge_collection!(ctx)

      set!(Connection, disconnected.connection_id,
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )

      assert RunCredentials.form_work(queued, work_item, @target) ==
               {:end, :target_access_gone}
    end
  end

  describe "no entry, and the run runs as before" do
    test "for an adapter that declares no apply items", ctx do
      {_work_item, _queued} = queued!(ctx, nil)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end

    test "for a run with no target", ctx do
      {work_item, queued} = queued!(ctx)
      assert RunCredentials.form_work(queued, work_item, nil) == {:ok, nil}
    end

    test "for a run with no collection that can change its target", ctx do
      {work_item, queued} = tracker_queued!(ctx)

      # One of another target, of another system, and of another workspace.
      forge_collection!(ctx, %{@target | path: "acme/other"})
      forge_collection!(ctx, %{@target | system: "other.example.com"})
      other = collection_fixture(sign_up_fixture().scope, target_path: "acme/shop")
      set!(Collection, other.id, target_system: "forge.example.com")
      set!(Node, other.adapter_id, source_apply: @apply, targets: true)

      # One unassigned, and one in another workspace of the same organisation.
      unassigned = forge_collection!(ctx)
      set!(Collection, unassigned.id, workspace_id: nil)
      elsewhere = forge_collection!(ctx)
      workspace = workspace_fixture(ctx.scope.organisation)
      set!(Collection, elsewhere.id, workspace_id: workspace.id)

      assert RunCredentials.form_work(queued, work_item, @target) == {:ok, nil}
      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end

    test "for a run with no apply items, even when its collection ended", ctx do
      {work_item, _queued} = queued!(ctx, nil)

      set!(Collection, collection_of(work_item).id,
        ended_at: DateTime.utc_now(),
        ended_reason: :not_listed
      )

      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end
  end

  describe "a prebuild" do
    test "gets read access to its collection's target", ctx do
      # Its collection's adapter has never said `targets`, and another collection of the
      # workspace can change the same target: the prebuild takes its collection still.
      collection = collection_fixture(ctx.scope, target_path: "acme/app")
      set!(Node, collection.adapter_id, source_apply: @apply)
      assert Repo.get!(Node, collection.adapter_id).targets == nil
      forge_collection!(ctx, %{system: "code.example.com", path: "acme/app"})

      {:ok, _run} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      assert {:ok, %{registered: %Run{}}} = claim(ctx)

      assert [
               %RunCredential{
                 access: :read,
                 resources: [%{"path" => "acme/app", "collection_id" => collection_id}],
                 apply: [%{"paths" => ["/acme/app.git/*", "/acme/app/*"]}, _api]
               }
             ] = entries()

      assert collection_id == collection.id
    end
  end

  describe "the table" do
    test "keeps a row in its run's organisation and workspace, and one work entry per run",
         ctx do
      {work_item, _queued} = queued!(ctx)
      assert {:ok, %{registered: %Run{} = run}} = claim(ctx)
      [entry] = entries()
      other = sign_up_fixture().scope

      row = fn changes ->
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            organisation_id: entry.organisation_id,
            workspace_id: entry.workspace_id,
            run_id: run.id,
            connection_id: work_item.connection_id,
            adapter_id: work_item.adapter_id,
            name: "work-2",
            purpose: "work",
            access: "read",
            resources: [%{"path" => "acme/shop"}],
            apply: [%{"hosts" => ["git.example.com"], "scheme" => "bearer"}],
            inserted_at: DateTime.utc_now()
          },
          changes
        )
      end

      uuids = ~w(id organisation_id workspace_id run_id connection_id adapter_id)a

      insert = fn changes ->
        row = row.(changes)
        row = Enum.reduce(uuids, row, &Map.update!(&2, &1, fn id -> Ecto.UUID.dump!(id) end))
        Repo.insert_all("run_credentials", [row])
      end

      for {changes, constraint} <- [
            {%{}, "run_credentials_work_index"},
            # Another organisation's place: the run is not of that workspace.
            {%{
               name: "harness-2",
               purpose: "harness",
               organisation_id: other.organisation.id,
               workspace_id: other.workspace.id
             }, "run_credentials_run_id_fkey"},
            {%{name: "harness-2", purpose: "harness", workspace_id: other.workspace.id},
             "run_credentials_workspace_id_fkey"},
            {%{name: "harness-1", purpose: "harness", access: "write"},
             "run_credentials_entry_check"},
            {%{name: "harness-1"}, "run_credentials_entry_check"},
            {%{name: "work-10"}, "run_credentials_entry_check"},
            {%{name: "harness-1", purpose: "harness", apply: []}, "run_credentials_values_check"},
            {%{name: "harness-1", purpose: "harness", resources: [1]},
             "run_credentials_values_check"},
            {%{name: "harness-1", purpose: "harness", placeholders: []},
             "run_credentials_values_check"}
          ] do
        error = assert_raise Postgrex.Error, fn -> insert.(changes) end

        assert error.postgres.constraint == constraint,
               inspect({changes, error.postgres.constraint})
      end

      assert {1, _rows} = insert.(%{name: "harness-1", purpose: "harness"})

      error =
        assert_raise Postgrex.Error, fn -> insert.(%{name: "harness-1", purpose: "harness"}) end

      assert error.postgres.constraint == "run_credentials_run_id_name_index"

      # Another organisation's connection is not this run's.
      other_connection = ticket_connection_fixture(other)

      error =
        assert_raise Postgrex.Error, fn ->
          insert.(%{name: "harness-2", purpose: "harness", connection_id: other_connection.id})
        end

      assert error.postgres.constraint == "run_credentials_connection_id_fkey"

      # The rows go with their run.
      Repo.delete!(run)
      assert entries() == []
    end
  end

  describe "a gateway key made without allow_secrets" do
    setup do
      %{scope: scope} = sign_up_fixture()
      Map.put(handover_place_fixture(scope), :scope, scope)
    end

    test "ends a run with a work entry secrets_not_allowed, and stores no entry", ctx do
      {_work_item, queued} = queued!(ctx)
      assert {:ok, :none} = claim(ctx)

      assert %DispatchRun{state: :ended, end_cause: :secrets_not_allowed} =
               Repo.get!(DispatchRun, queued.id)

      assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
      assert entries() == []
    end

    test "leaves a run without a work entry as it was", ctx do
      {_work_item, queued} = queued!(ctx, nil)
      assert {:ok, %{registered: %Run{dispatch_run_id: id}}} = claim(ctx)
      assert id == queued.id
      assert entries() == []
    end
  end
end
