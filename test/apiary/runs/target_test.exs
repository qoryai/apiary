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

  test "one collection of one adapter is one row, which follows its collection's address",
       ctx do
    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/shop")])
    [%Target{} = first] = Repo.all(Target)

    # The same address again writes nothing.
    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/shop")])
    assert Repo.all(Target) == [first]

    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/web")])
    assert rows(ctx.scope) == [{ctx.adapter.id, "C_1", "code.example.com", "acme/web"}]

    insert_new!(ctx.scope, [target(ctx.adapter, "C_1", nil, nil)])
    assert rows(ctx.scope) == [{ctx.adapter.id, "C_1", nil, nil}]

    assert [%Target{id: id, public_id: public_id, first_seen_at: first_seen_at}] =
             Repo.all(Target)

    assert {id, public_id, first_seen_at} == {first.id, first.public_id, first.first_seen_at}
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

  describe "id_at/3 and ids_at/2, the one target at an address, as a run's labels take it" do
    test "none where no target has the address", ctx do
      insert_new!(ctx.scope, [target(ctx.adapter, "C_1", "code.example.com", "acme/shop")])

      assert Target.id_at(ctx.scope.workspace.id, "code.example.com", "acme/web") == nil
      assert Target.ids_at(ctx.scope.workspace.id, [{"code.example.com", "acme/web"}]) == %{}
    end

    test "the one target with the address", ctx do
      insert_new!(ctx.scope, [
        target(ctx.adapter, "C_1", "code.example.com", "acme/shop"),
        target(ctx.adapter, "C_2", "code.example.com", "acme/web")
      ])

      [shop] = Repo.all(from t in Target, where: t.collection_external_ref == "C_1")
      [web] = Repo.all(from t in Target, where: t.collection_external_ref == "C_2")

      assert Target.id_at(ctx.scope.workspace.id, "code.example.com", "acme/shop") == shop.id

      assert Target.ids_at(ctx.scope.workspace.id, [
               {"code.example.com", "acme/shop"},
               {"code.example.com", "acme/web"}
             ]) == %{
               {"code.example.com", "acme/shop"} => shop.id,
               {"code.example.com", "acme/web"} => web.id
             }
    end

    test "none where two targets have the address, nor for another workspace's", ctx do
      insert_new!(ctx.scope, [
        target(ctx.adapter, "C_1", "code.example.com", "acme/shop"),
        target(ctx.adapter, "C_2", "code.example.com", "acme/shop"),
        target(ctx.adapter, "C_3", "code.example.com", "acme/web")
      ])

      %{scope: other} = sign_up_fixture()

      insert_new!(other, [target(ctx.adapter, "C_4", "code.example.com", "acme/docs")])

      assert Target.id_at(ctx.scope.workspace.id, "code.example.com", "acme/shop") == nil
      assert Target.id_at(ctx.scope.workspace.id, "code.example.com", "acme/docs") == nil

      assert ctx.scope.workspace.id
             |> Target.ids_at([
               {"code.example.com", "acme/shop"},
               {"code.example.com", "acme/web"}
             ])
             |> Map.keys() == [{"code.example.com", "acme/web"}]
    end
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
