defmodule Apiary.Runs.TargetTest do
  # A target is keyed on its adapter and the adapter's collection ref, unique per
  # workspace (`Apiary.Runs.Target.insert_new/3`); its address, a system and a path, is
  # optional, both or neither.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.NodesFixtures, only: [bare_adapter_fixture: 0]

  alias Apiary.Repo
  alias Apiary.Runs.Target

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, adapter: bare_adapter_fixture()}
  end

  defp insert_new!(scope, targets),
    do: :ok = Target.insert_new(scope.organisation.id, scope.workspace.id, targets)

  defp target(adapter, ref, system, path),
    do: %{adapter_id: adapter.id, collection_external_ref: ref, system: system, path: path}

  defp rows(scope) do
    Repo.all(
      from t in Target,
        where: t.workspace_id == ^scope.workspace.id,
        order_by: t.collection_external_ref,
        select: {t.adapter_id, t.collection_external_ref, t.system, t.path}
    )
  end

  test "two targets with the same host and different collections are two rows", ctx do
    insert_new!(ctx.scope, [
      target(ctx.adapter, "C_1", "code.example.com", "acme/shop"),
      target(ctx.adapter, "C_2", "code.example.com", "acme/shop")
    ])

    assert rows(ctx.scope) == [
             {ctx.adapter.id, "C_1", "code.example.com", "acme/shop"},
             {ctx.adapter.id, "C_2", "code.example.com", "acme/shop"}
           ]
  end

  test "one collection of one adapter is one row, which keeps its first address", ctx do
    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/shop")])
    [%Target{public_id: public_id}] = Repo.all(Target)

    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/web")])

    assert rows(ctx.scope) == [{ctx.adapter.id, "C_1", "code.example.com", "acme/shop"}]
    assert [%Target{public_id: ^public_id}] = Repo.all(Target)
  end

  test "the same ref of two adapters is two rows", ctx do
    other = bare_adapter_fixture()

    insert_new!(ctx.scope, [
      target(ctx.adapter, "C_1", nil, nil),
      target(other, "C_1", nil, nil)
    ])

    assert Enum.sort(rows(ctx.scope)) ==
             Enum.sort([{ctx.adapter.id, "C_1", nil, nil}, {other.id, "C_1", nil, nil}])
  end

  test "a target without an address is a row with no system and no path", ctx do
    insert_new!(ctx.scope, [target(ctx.adapter, "Q_support", nil, nil)])

    assert rows(ctx.scope) == [{ctx.adapter.id, "Q_support", nil, nil}]
  end

  test "the database holds a target's address to both or neither", ctx do
    row = %{
      organisation_id: ctx.scope.organisation.id,
      workspace_id: ctx.scope.workspace.id,
      adapter_id: ctx.adapter.id,
      collection_external_ref: "C_1",
      system: "code.example.com",
      path: nil,
      first_seen_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    assert_raise Postgrex.Error, ~r/targets_address_check/, fn ->
      Repo.insert_all(Target, [row])
    end
  end
end
