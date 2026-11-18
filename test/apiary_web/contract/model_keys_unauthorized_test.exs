defmodule ApiaryWeb.Contract.ModelKeysUnauthorizedTest do
  # The `unauthorized` list of a gateway's model keys report
  # (`POST /v1/runs/<run_id>/model-keys`):
  # each key of the run it names needs a new value from then on (`Apiary.ModelKeys.Rejection`),
  # until a person saves one, and the report is refused when the list is not as the contract
  # has it. The run is one of a workspace's queue, claimed with a model provider and attached
  # by the gateway (`Apiary.SealedRunsFixtures`). Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.DebugLog
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

  test "an unauthorized that is null is refused, as is one that is not a list", ctx do
    for bad <- [nil, "x", 5, %{}] do
      conn = post_report(ctx, report(ctx, bad))
      assert conn.status == 400, inspect(bad)
    end

    assert rows() == []
  end

  describe "the time of a 401" do
    test "from before the run started marks nothing, at the epoch or a day early", ctx do
      started = Repo.get!(Apiary.Runs.Run, ctx.run.id).registered_at

      for at <- [
            "1970-01-01T00:00:00Z",
            started
            |> DateTime.add(-86_400)
            |> DateTime.truncate(:second)
            |> DateTime.to_iso8601()
          ] do
        conn = post_report(ctx, report(ctx, [entry(name(ctx, 1), at)]))
        assert conn.status == 200, at
        assert rows() == []
      end

      # The gateway's clock may be 5 minutes behind: a 401 at that bound marks the key.
      near = started |> DateTime.add(-120) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      assert post_report(ctx, report(ctx, [entry(name(ctx, 1), near)])).status == 200
      assert [_row] = rows()
    end
  end

  describe "a run that ended" do
    setup ctx do
      Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))

      ended = fn seconds_ago ->
        Apiary.RunEventsFixtures.event_fixture(ctx.run, 1, "run.exited", %{},
          received_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        )

        {1, _} =
          Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^ctx.run.id),
            set: [state: "completed"]
          )
      end

      %{ended: ended}
    end

    test "marks a key when its last report comes within 60 s of the exit, and not later", ctx do
      ctx.ended.(61)
      assert post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status == 410
      assert rows() == []

      Repo.delete_all(from(e in Apiary.Runs.Event, where: e.run_id == ^ctx.run.id))
      ctx.ended.(59)
      assert post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status == 410
      assert [_row] = rows()
    end
  end

  describe "two reports at once" do
    test "for two keys mark both, and for one key keep the later time", ctx do
      first = name(ctx, 1)
      second = name(ctx, 2)
      older = now_z(-60)
      newer = now_z(-10)

      both =
        for body <- [report(ctx, [entry(first, older)]), report(ctx, [entry(second, older)])] do
          Task.async(fn -> post_report(ctx, body).status end)
        end

      assert Enum.map(both, &Task.await(&1, 30_000)) == [200, 200]
      assert length(rows()) == 2

      same =
        for at <- [older, newer, older, newer] do
          Task.async(fn -> post_report(ctx, report(ctx, [entry(first, at)])).status end)
        end

      assert Enum.map(same, &Task.await(&1, 30_000)) == [200, 200, 200, 200]

      assert %{rejected_at: at} =
               Enum.find(rows(), &(&1.secret_value_id == key_named(ctx, 1).secret_value_id))

      assert DateTime.compare(at, elem(DateTime.from_iso8601(newer), 1)) == :eq
    end

    test "and a new value saved at the same time leave no key that counts as marked", ctx do
      first = key_named(ctx, 1)
      value = Repo.get!(Value, first.secret_value_id)

      save =
        Task.async(fn ->
          Connections.update_provider_key(ctx.scope, ctx.provider, value.value_id, %{
            value_id: value.value_id,
            value: "sk-ant-fixture-raced-0123456789"
          })
        end)

      report = Task.async(fn -> post_report(ctx, report(ctx, [entry(name(ctx, 1))])).status end)

      assert {:ok, _provider} = Task.await(save, 30_000)
      assert Task.await(report, 30_000) == 200

      # The report either came first and the new value cleared it, or its key's value had
      # changed (the run's copy is the old one) and it marked nothing.
      assert ModelKeys.rejections(ctx.provider) == %{}
    end
  end

  test "no log line of any level has a key's value, and the page shows none", ctx do
    secret = "sk-ant-fixture-main-0123456789"

    {conn, log} =
      with_debug_log(fn -> post_report(ctx, report(ctx, [entry(name(ctx, 1))])) end)

    assert conn.status == 200
    refute_secrets(log, [secret, "sk-ant-fixture-spare-0123456789"])
    refute_secrets(conn.resp_body, [secret])
  end
end
