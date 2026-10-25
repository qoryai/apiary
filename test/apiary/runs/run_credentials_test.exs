defmodule Apiary.Runs.RunCredentialsTest do
  # The work credential entry a claim records for its run (`Apiary.Runs.RunCredentials`,
  # through `Apiary.Dispatches.claim/3`): the adapter's apply items filled with the run's
  # target path, its collection as the resource and its access level; none where there is
  # no collection or no apply item, and the run ended `target_access_gone` where the
  # collection or its connection ended, or the target path is refused.
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

  # A run of the queue for a new work item of the scope, whose target is acme/shop at
  # forge.example.com, and whose ticket's adapter declares `apply` (nil for none).
  defp queued!(ctx, apply \\ @apply) do
    work_item = work_item_fixture(ctx.scope)
    set!(Node, work_item.adapter_id, source_apply: apply)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
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
      ctx = %{ctx | scope: with_domain(ctx.scope, "general")}
      {work_item, _queued} = queued!(ctx)
      set!(WorkItem, work_item.id, target_path: "Team/Shop%20Two")
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
      ctx = %{ctx | scope: with_domain(ctx.scope, "general")}

      for path <- ["acme/../shop", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] do
        {work_item, queued} = queued!(ctx)
        set!(WorkItem, work_item.id, target_path: path)
        assert claim(ctx) == {:ok, :none}, inspect(path)
        gone!(queued)
      end
    end

    test "form_work/3 refuses each refused character class before it fills", ctx do
      {work_item, queued} = queued!(ctx)

      spaces =
        [0x00, 0x09, 0x0A, 0x1F, 0x20, 0x7F, 0xFEFF, 0x85, 0xA0, 0x1680, 0x2000, 0x2005] ++
          [0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

      paths =
        ["acme/../shop", "..", "acme//shop", "acme/shop*", "acme/shop?x", "acme/shop#x"] ++
          for code <- spaces, do: "acme/sh" <> <<code::utf8>> <> "op"

      for path <- paths do
        assert RunCredentials.form_work(queued, work_item, %{
                 system: "forge.example.com",
                 path: path
               }) ==
                 {:end, :target_access_gone},
               inspect(path)
      end

      for path <- ["acme/shop", "acme/.shop", "acme./shop", "Acme/Shop%2E"] do
        assert {:ok, %RunCredential{}} =
                 RunCredentials.form_work(queued, work_item, %{
                   system: "forge.example.com",
                   path: path
                 }),
               path
      end
    end
  end

  describe "no entry, and the run runs as before" do
    test "for an adapter that declares no apply items", ctx do
      {_work_item, _queued} = queued!(ctx, nil)
      assert {:ok, %{registered: %Run{}}} = claim(ctx)
      assert entries() == []
    end

    test "for a run with no collection or no target", ctx do
      {work_item, queued} = queued!(ctx)
      target = %{system: "forge.example.com", path: "acme/shop"}

      # A work item whose ticket's row is gone; the claim ends such a run ticket_gone first.
      assert RunCredentials.form_work(queued, %{work_item | item_id: nil}, target) == {:ok, nil}
      assert RunCredentials.form_work(queued, work_item, nil) == {:ok, nil}
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
      collection = collection_fixture(ctx.scope, target_path: "acme/app")
      set!(Node, collection.adapter_id, source_apply: @apply)

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
