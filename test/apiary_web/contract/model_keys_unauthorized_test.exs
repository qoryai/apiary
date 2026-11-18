defmodule ApiaryWeb.Contract.ModelKeysUnauthorizedTest do
  # The `unauthorized` list of a gateway's model keys report (`POST /v1/runs/<run_id>/model-keys`):
  # each key of the run it names needs a new value from then on (`Apiary.ModelKeys.Rejection`),
  # until a person saves one, and the report is refused when the list is not as the contract
  # has it. The run is one of a workspace's queue, claimed with a model provider and attached
  # by the gateway (`Apiary.SealedRunsFixtures`). Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, ModelKeys, Policy, Repo}
  alias Apiary.ModelKeys.Rejection
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: [:factory, :secrets, :observability]

  setup do
    now = System.os_time(:second)
    Application.put_env(:apiary, :contract_now, fn -> now end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)

    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})

    ctx =
      sealed_run_fixture(scope,
        keys: [
          %{value_id: "main", value: "sk-ant-fixture-main-0123456789"},
          %{value_id: "spare", value: "sk-ant-fixture-spare-0123456789"}
        ]
      )
      |> Map.put(:scope, scope)

    values = Repo.all(from v in Value, where: v.secret_id == ^ctx.provider.secret_id)
    Map.put(ctx, :values, Map.new(values, &{&1.value_id, &1}))
  end

  defp now_z(offset \\ 0),
    do: (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # The credential names of the run's keys, in the run's order: the choice's key is first.
  defp name(ctx, place), do: "#{ctx.provider.public_id}-#{place}"

  defp report(ctx, unauthorized) do
    members =
      [version: 1, run_id: ctx.run.node_run_id, time: now_z(), keys: []] ++
        if(unauthorized == :none, do: [], else: [unauthorized: unauthorized])

    Jason.encode!(Jason.OrderedObject.new(members))
  end

  defp entry(credential, at \\ nil), do: %{"credential" => credential, "at" => at || now_z(-1)}

  defp post_report(ctx, body) do
    {key, seed} = ctx.secrets_key

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/runs/#{ctx.run.node_run_id}/model-keys",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp rows, do: Repo.all(from r in Rejection, order_by: r.secret_value_id)

  defp key_named(ctx, place) do
    keys = ModelKeys.run_keys(Repo.get!(Apiary.Runs.Run, ctx.run.id))
    Enum.find(keys, &(&1.name == name(ctx, place)))
  end

  test "a report with an unauthorized key moves it: the claim skips it, and the rest stay", ctx do
    first = key_named(ctx, 1)
    second = key_named(ctx, 2)
    at = now_z(-30)

    conn = post_report(ctx, report(ctx, [entry(name(ctx, 1), at)]))

    assert conn.status == 200, conn.resp_body
    assert [%Rejection{secret_value_id: id, rejected_at: rejected_at}] = rows()
    assert id == first.secret_value_id
    assert DateTime.compare(rejected_at, elem(DateTime.from_iso8601(at), 1)) == :eq

    keys = ctx.provider |> ModelKeys.claim_keys(nil, DateTime.utc_now()) |> Map.new(&{&1.id, &1})
    assert keys[first.secret_value_id].blocked == :new_key
    assert keys[second.secret_value_id].blocked == nil
  end

  test "a report that leaves the key out does not clear it", ctx do
    assert post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status == 200
    assert post_report(ctx, report(ctx, :none)).status == 200
    assert [_row] = rows()
  end

  test "a new value clears it, one equal to the stored value too", ctx do
    first = key_named(ctx, 1)
    value = Repo.get!(Value, first.secret_value_id)
    assert post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status == 200
    assert [_row] = rows()

    {:ok, _provider} =
      Connections.update_provider_key(ctx.scope, ctx.provider, value.value_id, %{
        value_id: value.value_id,
        value: "sk-ant-fixture-#{value.value_id}-0123456789"
      })

    assert rows() == []
    assert ModelKeys.rejections(ctx.provider) == %{}
  end

  test "a report of the run's old value, after a new value was saved, marks nothing", ctx do
    first = key_named(ctx, 1)
    value = Repo.get!(Value, first.secret_value_id)

    {:ok, _provider} =
      Connections.update_provider_key(ctx.scope, ctx.provider, value.value_id, %{
        value_id: value.value_id,
        value: "sk-ant-fixture-changed-0123456789"
      })

    assert post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status == 200
    assert rows() == []
  end

  test "an entry for a credential the run does not have is left out, and the report is taken",
       ctx do
    conn = post_report(ctx, report(ctx, [entry("other-1"), entry(name(ctx, 2))]))

    assert conn.status == 200
    assert [%Rejection{secret_value_id: id}] = rows()
    assert id == key_named(ctx, 2).secret_value_id
  end

  describe "refuses with 400 invalid_request" do
    test "an empty list, more than 6 entries, an entry twice", ctx do
      many = for n <- 1..7, do: entry("model-#{n}")

      for bad <- [[], many, [entry(name(ctx, 1)), entry(name(ctx, 1))]] do
        assert post_report(ctx, report(ctx, bad)).status == 400
      end

      assert rows() == []
    end

    test "an entry of the wrong type, with a member missing or one the schema does not have",
         ctx do
      for bad <- [
            ["x"],
            [%{"credential" => name(ctx, 1)}],
            [%{"at" => now_z()}],
            [Map.put(entry(name(ctx, 1)), "extra", 1)],
            [entry("Not A Name")],
            [entry(name(ctx, 1), "yesterday")],
            [entry(name(ctx, 1), now_z(3600))]
          ] do
        conn = post_report(ctx, report(ctx, bad))
        assert conn.status == 400, inspect(bad)
      end

      assert rows() == []
    end
  end
end
