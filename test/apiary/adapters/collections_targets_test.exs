defmodule Apiary.Adapters.CollectionsTargetsTest do
  # The targets an assign makes: a collection with a target, linked to a workspace, makes
  # that target there, as a run of it would name it, once; a move makes the new
  # workspace's too; an unlink, a move away or an end leaves it; and a run of the target,
  # with the labels a dispatched run carries, lands on it. A listing's part makes them
  # too: where it links a collection to the organisation's only workspace, and where it
  # changes the target of a collection assigned to a workspace. And whether a connection
  # has a live collection with a target (`Collections.targets?/1`).
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{AccessKeys, Repo, Targets}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{Run, Target}

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]
  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  @shop %{system: "code.example.com", path: "acme/shop"}
  @api %{system: "code.example.com", path: "acme/api"}

  # An organisation with two workspaces, so a collection is linked to none as it is made.
  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    other_workspace = workspace_fixture(scope.organisation, "Second")
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      user: user,
      workspace: scope.workspace,
      other_workspace: other_workspace,
      adapter: connectable.adapter,
      key_scope: key_scope(connectable.access_key),
      connection: connection
    }
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # A disconnect of `ref` under this test's connection, as the wire reads one.
  defp disconnect(ctx, ref),
    do:
      Collections.disconnect(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        collection_ref: ref
      })

  # One part of a listing naming `collections`, `{ref, target}` each.
  defp post(ctx, collections, opts \\ []) do
    Collections.post_listing(ctx.key_scope, %{
      time: DateTime.utc_now(:second),
      connection_id: ctx.connection.public_id,
      collections:
        for {ref, target} <- collections do
          %{ref: ref, url: "https://tracker.acme.example/" <> ref, title: ref, target: target}
        end,
      listing: %{
        id: Keyword.get(opts, :id, "listing-1"),
        part: 1,
        started_at: Keyword.get(opts, :started_at, @started),
        complete: Keyword.get(opts, :complete, false)
      }
    })
  end

  defp ids(ctx, refs) do
    Repo.all(
      from c in Collection,
        where: c.connection_id == ^ctx.connection.id and c.external_ref in ^refs,
        where: is_nil(c.ended_at),
        select: c.id
    )
  end

  defp assign(ctx, refs, workspace),
    do: Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, refs), workspace)

  defp targets(%Workspace{id: id}) do
    Repo.all(
      from t in Target,
        where: t.workspace_id == ^id,
        order_by: [t.system, t.path]
    )
  end

  defp pairs(workspace), do: Enum.map(targets(workspace), &{&1.system, &1.path})

  test "assigning makes the target in the workspace, of the organisation, first seen now",
       ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    before = DateTime.utc_now()

    assert {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

    assert [%Target{} = target] = targets(ctx.workspace)
    assert {target.system, target.path} == {"code.example.com", "acme/shop"}
    assert target.organisation_id == ctx.scope.organisation.id
    assert DateTime.compare(target.first_seen_at, before) != :lt
    assert target.public_id =~ ~r/\Atg_[0-9a-hjkmnp-tv-z]{16}\z/
    assert targets(ctx.other_workspace) == []
  end

  test "assigning again, or two collections of one target, makes one target and keeps its first sighting",
       ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"MIRROR", @shop}, {"API", @api}])

    assert {:ok, 2} = assign(ctx, ["SHOP", "MIRROR"], ctx.workspace)
    assert pairs(ctx.workspace) == [{"code.example.com", "acme/shop"}]
    [shop] = targets(ctx.workspace)

    # A first sighting the insert would never write: one it overwrote would show.
    Repo.update_all(from(t in Target, where: t.id == ^shop.id), set: [first_seen_at: @long_ago])

    # As asked already, then away and back, then beside another.
    assert {:ok, 0} = assign(ctx, ["SHOP"], ctx.workspace)
    assert {:ok, 2} = assign(ctx, ["SHOP", "MIRROR"], nil)
    assert {:ok, 3} = assign(ctx, ["SHOP", "MIRROR", "API"], ctx.workspace)

    assert pairs(ctx.workspace) == [
             {"code.example.com", "acme/api"},
             {"code.example.com", "acme/shop"}
           ]

    assert %Target{first_seen_at: @long_ago, public_id: public_id} = Repo.get!(Target, shop.id)
    assert public_id == shop.public_id
  end

  test "a move makes the new workspace's target and keeps the old one", ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
    [old] = targets(ctx.workspace)

    assert {:ok, 1} = assign(ctx, ["SHOP"], ctx.other_workspace)

    assert targets(ctx.workspace) == [old]
    assert [new] = targets(ctx.other_workspace)
    assert {new.system, new.path} == {old.system, old.path}
    assert new.id != old.id
  end

  test "unlinking or ending the collection keeps its target", ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"API", @api}])
    {:ok, 2} = assign(ctx, ["SHOP", "API"], ctx.workspace)
    kept = targets(ctx.workspace)
    assert length(kept) == 2

    {:ok, 1} = assign(ctx, ["SHOP"], nil)
    assert targets(ctx.workspace) == kept

    # A complete listing that leaves API out ends it.
    {:ok, :accepted} =
      post(ctx, [{"SHOP", @shop}],
        id: "listing-2",
        started_at: DateTime.add(@started, 60),
        complete: true
      )

    assert ids(ctx, ["API"]) == []
    assert targets(ctx.workspace) == kept
  end

  test "a collection without a target makes none", ctx do
    {:ok, :accepted} = post(ctx, [{"TRK", nil}])

    assert {:ok, 1} = assign(ctx, ["TRK"], ctx.workspace)
    assert targets(ctx.workspace) == []
  end

  test "a run of the target, with the labels a dispatched run carries, lands on the target the assign made",
       ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
    [target] = targets(ctx.workspace)

    run = started_run(ctx.scope, %{"forge" => @shop.system, "repository" => @shop.path})

    assert Repo.get!(Run, run.id).target_id == target.id
    assert targets(ctx.workspace) == [target]
  end

  test "the workspace's domain names the target, as it reads a run's labels", ctx do
    example =
      %Workspace{organisation_id: ctx.scope.organisation.id}
      |> Workspace.create_changeset(%{name: "Example", domain: "example"})
      |> Workspace.put_slug("example")
      |> Repo.insert!()

    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    {:ok, 1} = assign(ctx, ["SHOP"], example)
    assert [target] = targets(example)

    scope = workspace_scope(ctx.user, example)
    run = started_run(scope, %{"platform" => @shop.system, "account" => @shop.path})

    assert Repo.get!(Run, run.id).target_id == target.id
  end

  test "the Repositories list shows it with no run, in All and in Never, and the workspace counts it",
       ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}])
    {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)

    assert %{rows: [row], total: 1} = Targets.page(ctx.scope, %{})
    assert {row.target.system, row.target.path} == {"code.example.com", "acme/shop"}
    assert row.runs == 0 and row.last == nil and Enum.sum(row.days) == 0

    assert %{rows: [never]} = Targets.page(ctx.scope, %{view: :never})
    assert never.target.id == row.target.id
    assert %{rows: []} = Targets.page(ctx.scope, %{view: :active})
    assert Targets.view_counts(ctx.scope) == %{all: 1, active: 0, never: 1}
    assert Targets.count_by_workspace(ctx.scope) == %{ctx.workspace.id => 1}
  end

  test "a part that links a collection to the only workspace makes its target, listed with no run, where a run lands",
       ctx do
    # Another organisation, with one workspace, connected to the same adapter.
    %{scope: scope} = sign_up_fixture()
    {connection, _nonce} = connection_fixture(scope, ctx.adapter, :connected)
    ctx = %{ctx | connection: connection}

    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"API", @api}, {"TRK", nil}])

    assert [%Collection{workspace_id: workspace_id}] =
             Repo.all(
               from c in Collection,
                 where: c.external_ref == "SHOP" and c.connection_id == ^connection.id
             )

    assert workspace_id == scope.workspace.id

    assert pairs(scope.workspace) == [
             {"code.example.com", "acme/api"},
             {"code.example.com", "acme/shop"}
           ]

    assert %{rows: rows, total: 2} = Targets.page(scope, %{})
    assert Enum.all?(rows, &(&1.runs == 0 and &1.last == nil))

    shop = Enum.find(targets(scope.workspace), &(&1.path == "acme/shop"))
    run = started_run(scope, %{"forge" => @shop.system, "repository" => @shop.path})

    assert Repo.get!(Run, run.id).target_id == shop.id
    assert length(targets(scope.workspace)) == 2
  end

  test "a part that changes the target of an assigned collection makes the new one and keeps the old",
       ctx do
    {:ok, :accepted} = post(ctx, [{"SHOP", @shop}, {"API", @api}])
    {:ok, 1} = assign(ctx, ["SHOP"], ctx.workspace)
    [old] = targets(ctx.workspace)

    # API, linked to none, changes its target too, and makes none.
    {:ok, :accepted} =
      post(ctx, [{"SHOP", %{@shop | path: "acme/moved"}}, {"API", %{@api | path: "acme/other"}}],
        id: "listing-2",
        started_at: DateTime.add(@started, 60)
      )

    assert pairs(ctx.workspace) == [
             {"code.example.com", "acme/moved"},
             {"code.example.com", "acme/shop"}
           ]

    assert Repo.get!(Target, old.id) == old
    assert targets(ctx.other_workspace) == []

    assert %{rows: rows, total: 2} = Targets.page(ctx.scope, %{})
    assert Enum.all?(rows, &(&1.runs == 0))

    # An older listing changes nothing: the collection keeps the newer target.
    {:ok, :accepted} =
      post(ctx, [{"SHOP", %{@shop | path: "acme/stale"}}],
        id: "listing-0",
        started_at: DateTime.add(@started, -60)
      )

    assert length(targets(ctx.workspace)) == 2
  end

  describe "targets?/1" do
    test "false with no collections, and with live ones that have no target", ctx do
      refute Collections.targets?(ctx.connection)

      {:ok, :accepted} = post(ctx, [{"TRK", nil}])
      refute Collections.targets?(ctx.connection)
    end

    test "true when only some of its collections have a target", ctx do
      {:ok, :accepted} = post(ctx, [{"TRK", nil}, {"SHOP", @shop}, {"NOTES", nil}])

      assert Collections.targets?(ctx.connection)
    end

    test "the target of an ended collection counts not", ctx do
      {:ok, :accepted} = post(ctx, [{"TRK", nil}, {"SHOP", @shop}])
      assert Collections.targets?(ctx.connection)

      {:ok, :disconnected} = disconnect(ctx, "SHOP")

      assert ids(ctx, ["SHOP"]) == []
      assert length(ids(ctx, ["TRK"])) == 1
      refute Collections.targets?(ctx.connection)
    end

    test "the target of another connection's collection counts not", ctx do
      {:ok, :accepted} = post(ctx, [{"TRK", nil}])

      # Another organisation, connected to the same adapter, with a target.
      %{scope: scope} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(scope, ctx.adapter, :connected)
      {:ok, :accepted} = post(%{ctx | connection: theirs}, [{"THEIRS", @shop}])

      assert Collections.targets?(theirs)
      refute Collections.targets?(ctx.connection)
    end
  end
end
