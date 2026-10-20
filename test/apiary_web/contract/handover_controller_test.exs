defmodule ApiaryWeb.Contract.HandoverControllerTest do
  # `POST /v1/dispatches/<dispatch_id>/dispatched` (`ApiaryWeb.Contract.DispatchController`)
  # and `POST /v1/dispatches/<dispatch_id>/handover`
  # (`ApiaryWeb.Contract.HandoverController`), as a node pool's starter sends them: the
  # answers signed but a `401`, `Cache-Control: no-store`, the handover answer held to the
  # vendored `handover-answer.schema.json` and an explore run's input to the explore
  # contract's `inputs.schema.json`, and each refusal's status and code. The order of the
  # refusals is `Apiary.Dispatches.HandoverTest`'s; where the feature is off,
  # `ApiaryWeb.Contract.PoolRequestTest`'s. Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Run, RunKey}
  alias Apiary.Sources.{Comment, Item}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @vendored Path.expand("../../fixtures/contract", __DIR__)
  @base "https://qory.dev/contracts/"

  # The vendored schemas by their URL under the contracts' base, the explore contract's
  # from `priv/contract`, where Qory keeps them, and Forager's from its contract directory
  # (`Apiary.ContractFixtures.contract_dir/0`), which the handover answer's `run_settings`
  # refers to: a test that builds that schema is tagged `:contract`. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  setup do
    # The clock's time as the test begins, which `now_time/0` counts down from.
    Process.put(:now_time, {SignedRequest.now(), 0})
    %{scope: scope} = sign_up_fixture()
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # A request's time: one second earlier for each request the test sends, counted down from
  # the clock's time as the test began. Two requests to one target with one time are one
  # signed body, which the replay guard refuses with a 401; a time read from the clock
  # again for each request could repeat one, as the clock moves on a second between them.
  defp now_time do
    {base, sent} = Process.get(:now_time)
    Process.put(:now_time, {base, sent + 1})

    (base - sent - 1)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp post(ctx, dispatch, action, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: "/v1/dispatches/#{id(dispatch)}/#{action}",
      content_type: "application/json",
      delivery: nil,
      contract_version: "3"
    )
  end

  defp dispatched(ctx, dispatch, opts \\ []) do
    body = Map.merge(%{"version" => 1, "time" => now_time()}, Keyword.get(opts, :body, %{}))
    post(ctx, dispatch, "dispatched", body, opts)
  end

  defp handover(ctx, dispatch, opts \\ []),
    do: post(ctx, dispatch, "handover", %{"version" => 1, "time" => now_time()}, opts)

  defp id(%Dispatch{public_id: public_id}), do: public_id
  defp id(public_id) when is_binary(public_id), do: public_id

  defp queued!(ctx, attrs \\ %{}) do
    work_item = work_item_fixture(ctx.scope, attrs)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {work_item, run}
  end

  defp claimed!(ctx) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  defp started!(ctx) do
    dispatch = claimed!(ctx)
    conn = dispatched(ctx, dispatch)
    assert conn.status == 204
    dispatch
  end

  defp validator(path) do
    JSV.build!(%{"$ref" => @base <> path},
      resolver:
        {Resolver, [@vendored, Application.app_dir(:apiary, "priv/contract")] ++ forager()},
      formats: true
    )
  end

  # The directory of Forager's contracts, when its contract directory is there.
  defp forager do
    case Apiary.ContractFixtures.contract_dir() do
      nil -> []
      dir -> [Path.expand("../..", dir)]
    end
  end

  # The members of a JSON object, in their order.
  defp members(json),
    do: json |> Jason.decode!(objects: :ordered_objects) |> Map.get(:values) |> keys()

  defp keys(values), do: Enum.map(values, &elem(&1, 0))

  defp comment!(work_item, ref, name) do
    at = DateTime.utc_now(:second)

    Repo.insert!(%Comment{
      organisation_id: work_item.organisation_id,
      item_id: work_item.item_id,
      external_ref: ref,
      url: "https://forge.example.com/acme/shop/issues/12#" <> ref,
      author_name: name,
      author_kind: :person,
      body: "The cart empties itself.",
      body_format: "markdown",
      source_created_at: at,
      source_updated_at: at
    })
  end

  # An explore run's answer has `run_settings` with both features `factory` and `secrets`
  # on (`Apiary.Dispatches.RunSettings`); these tests need `factory`.
  defp run_settings, do: if(Apiary.Features.on?(:secrets), do: ~w(run_settings), else: [])

  defp refused?(conn, status, code),
    do: json_response(conn, status) == %{"error" => code} and signed_answer?(conn)

  describe "a handover" do
    @tag :contract
    test "of an explore run is 200, signed, not stored, the contract's answer with the explore input",
         ctx do
      {work_item, queued} = queued!(ctx, %{first_instruction: "Look at the cart first."})
      at = DateTime.utc_now(:second)

      Repo.insert!(%Comment{
        organisation_id: work_item.organisation_id,
        item_id: work_item.item_id,
        external_ref: "c1",
        url: "https://forge.example.com/acme/shop/issues/12#c1",
        author_name: "Avery Example",
        author_kind: :person,
        body: "The cart empties itself.",
        body_format: "markdown",
        source_created_at: at,
        source_updated_at: at
      })

      dispatch = started!(ctx)
      conn = handover(ctx, dispatch)

      assert conn.status == 200
      assert signed_answer?(conn)
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      answer = Jason.decode!(conn.resp_body)

      assert {:ok, _} =
               JSV.validate(answer, validator("provisioner/v1/handover-answer.schema.json"))

      assert {:ok, _} = JSV.validate(answer["inputs"], validator("explore/v1/inputs.schema.json"))

      assert members(conn.resp_body) ==
               ~w(version revision run_id run_key step domain access target work_item) ++
                 run_settings() ++ ~w(inputs)

      # With no model choice at any level, the run settings have the runtime alone.
      if run_settings() != [], do: assert(answer["run_settings"] == %{"runtime" => "claude"})

      assert conn.resp_body
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.get(:values)
             |> List.keyfind("inputs", 0)
             |> elem(1)
             |> Map.get(:values)
             |> keys() ==
               ~w(version work_item run ticket instruction comments comments_omitted answers target domain)

      assert answer["revision"] == 3
      assert answer["run_id"] == queued.run_id
      assert answer["step"] == "explore"
      assert answer["domain"] == "software"
      assert answer["access"] == "read"
      assert answer["target"] == %{"system" => "forge.example.com", "path" => "acme/shop"}
      assert answer["work_item"]["id"] == work_item.public_id
      assert answer["work_item"]["title"] == work_item.title

      # What the explore contract asks of the two together.
      assert answer["inputs"]["target"] == answer["target"]
      assert answer["inputs"]["domain"] == answer["domain"]
      assert answer["inputs"]["work_item"]["id"] == answer["work_item"]["id"]
      assert answer["inputs"]["instruction"]["text"] == "Look at the cart first."
      assert [%{"body" => "The cart empties itself."}] = answer["inputs"]["comments"]

      # The run key is the registered run's, bound to the pool's gateway.
      run = Repo.one!(from r in Run, where: r.dispatch_run_id == ^queued.id)
      gateway_id = ctx.gateway.id
      assert %Run{gateway_id: ^gateway_id} = run
      assert {:ok, grant, payload} = RunKey.verify(answer["run_key"])
      assert grant.run_id == queued.run_id
      assert grant.instance_id == queued.run_id
      assert payload == run.run_key_payload
    end

    test "of an explore run gives the source's names as the source sent them, held to the contract",
         ctx do
      {work_item, _queued} = queued!(ctx)
      # 100 code points, the most the contract and the columns allow, in 50 graphemes.
      longest = String.duplicate("e\u0301", 50)

      {1, _rows} =
        Repo.update_all(from(i in Item, where: i.id == ^work_item.item_id),
          set: [filed_by_name: "Avery\tExample\nof the shop"]
        )

      for {ref, name} <- [{"c1", "Blake\tExample\r\nof the shop"}, {"c2", longest}] do
        comment!(work_item, ref, name)
      end

      dispatch = started!(ctx)
      conn = handover(ctx, dispatch)

      assert conn.status == 200
      inputs = Jason.decode!(conn.resp_body)["inputs"]
      assert {:ok, _} = JSV.validate(inputs, validator("explore/v1/inputs.schema.json"))
      assert inputs["ticket"]["filed_by"]["name"] == "Avery\tExample\nof the shop"

      assert Enum.map(inputs["comments"], & &1["by"]["name"]) ==
               ["Blake\tExample\r\nof the shop", longest]
    end

    test "of an explore run never meets a source's name longer than the contract allows: none is kept",
         ctx do
      {work_item, _queued} = queued!(ctx)
      too_long = String.duplicate("a", 300)

      assert_raise Postgrex.Error, ~r/source_items_filed_by_check/, fn ->
        Repo.transact(fn ->
          Repo.update_all(from(i in Item, where: i.id == ^work_item.item_id),
            set: [filed_by_name: too_long]
          )
        end)
      end

      assert_raise Ecto.ConstraintError, ~r/source_item_comments_author_check/, fn ->
        Repo.transact(fn -> {:ok, comment!(work_item, "c1", too_long)} end)
      end

      # The input formed from what is kept holds to the contract.
      dispatch = started!(ctx)
      conn = handover(ctx, dispatch)
      assert conn.status == 200
      inputs = Jason.decode!(conn.resp_body)["inputs"]
      assert {:ok, _} = JSV.validate(inputs, validator("explore/v1/inputs.schema.json"))
      assert inputs["comments"] == []
    end

    @tag :contract
    test "of an explore run without a target, in the general domain, is 200 with its domain, no access and no target",
         ctx do
      with_domain(ctx.scope, "general")
      {work_item, queued} = queued!(ctx, %{target_system: nil, target_path: nil})
      dispatch = started!(ctx)
      conn = handover(ctx, dispatch)

      assert conn.status == 200
      assert signed_answer?(conn)
      answer = Jason.decode!(conn.resp_body)

      assert {:ok, _} =
               JSV.validate(answer, validator("provisioner/v1/handover-answer.schema.json"))

      assert {:ok, _} = JSV.validate(answer["inputs"], validator("explore/v1/inputs.schema.json"))

      assert members(conn.resp_body) ==
               ~w(version revision run_id run_key step domain work_item) ++
                 run_settings() ++ ~w(inputs)

      assert {answer["run_id"], answer["domain"]} == {queued.run_id, "general"}
      assert answer["work_item"]["id"] == work_item.public_id
      assert answer["inputs"]["domain"] == "general"
      refute Map.has_key?(answer["inputs"], "target")
    end

    @tag :contract
    test "of a prebuild is 200, signed, with no work item and its input the ref it was queued for",
         ctx do
      collection = collection_fixture(ctx.scope)

      {:ok, _queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      dispatch = started!(ctx)
      conn = handover(ctx, dispatch)

      assert conn.status == 200
      assert signed_answer?(conn)
      answer = Jason.decode!(conn.resp_body)

      assert {:ok, _} =
               JSV.validate(answer, validator("provisioner/v1/handover-answer.schema.json"))

      assert members(conn.resp_body) ==
               ~w(version revision run_id run_key step domain access target inputs)

      assert answer["revision"] == 3
      assert answer["step"] == "prebuild"
      assert answer["domain"] == "software"
      assert answer["access"] == "read"

      assert answer["target"] == %{
               "system" => collection.target_system,
               "path" => collection.target_path
             }

      assert answer["inputs"] == %{"version" => 1, "environment_ref" => "env-1"}
      ordered = Jason.decode!(conn.resp_body, objects: :ordered_objects)
      assert keys(ordered["inputs"].values) == ~w(version environment_ref)
    end

    test "is refused with each status and code, signed", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)

      # Unknown, of another pool, or of no dispatch's shape: one answer.
      assert refused?(handover(ctx, "dp_0000000000000000"), 403, "forbidden")
      assert refused?(handover(ctx, "not-a-dispatch"), 403, "forbidden")
      other = pool_fixture(ctx.scope)

      %{access_key: other_key, pair: other_pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, other)

      assert refused?(
               handover(ctx, dispatch, key_id: other_key.key_id, seed: other_pair.secret),
               403,
               "forbidden"
             )

      assert refused?(handover(ctx, dispatch), 409, "not_dispatched")
      assert dispatched(ctx, dispatch).status == 204

      {1, _rows} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
          set: [gateway_choice: :direct]
        )

      assert refused?(handover(ctx, dispatch), 409, "no_gateway")

      {1, _rows} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
          set: [gateway_choice: :default]
        )

      assert handover(ctx, dispatch).status == 200
      assert refused?(handover(ctx, dispatch), 409, "handed_over")

      # A run its handover cannot form ends, and is answered as a dispatch that ended.
      {_work_item, queued} = queued!(ctx)
      second = started!(ctx)

      {1, _rows} =
        Repo.update_all(
          from(w in WorkItem, where: w.id == ^Repo.get!(DispatchRun, queued.id).work_item_id),
          set: [item_id: nil]
        )

      assert refused?(handover(ctx, second), 410, "gone")
      assert %DispatchRun{end_cause: :ticket_gone} = Repo.get!(DispatchRun, queued.id)
      assert refused?(handover(ctx, second), 410, "gone")
    end

    test "with a lease lapsed is 409 lease_expired, signed", ctx do
      queued!(ctx)
      dispatch = started!(ctx)
      now = DateTime.utc_now()

      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
          set: [
            claimed_at: DateTime.add(now, -700, :second),
            lease_until: %{
              DateTime.truncate(DateTime.add(now, -60, :second), :second)
              | microsecond: {0, 6}
            }
          ]
        )

      assert refused?(handover(ctx, dispatch), 409, "lease_expired")
    end

    test "of a run that cannot be stored is 503 unavailable, signed, not stored, and writes nothing",
         ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = started!(ctx)

      # A row of the run's id in the workspace already, which no product path writes: the
      # registered run cannot be inserted.
      in_the_way =
        Repo.insert!(%Run{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          node_run_id: queued.run_id,
          state: "pending"
        })

      {conn, log} = ExUnit.CaptureLog.with_log(fn -> handover(ctx, dispatch) end)

      assert refused?(conn, 503, "unavailable")
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
      refute log =~ queued.run_id
      assert Repo.aggregate(Run, :count) == 1
      assert Repo.aggregate(from(e in Entry, where: e.action == "dispatch.handover"), :count) == 0

      assert %Dispatch{handed_over_at: nil, ended_at: nil, slot_freed_at: nil} =
               Repo.get!(Dispatch, dispatch.id)

      assert Repo.get!(DispatchRun, queued.id).state == :claimed

      Repo.delete!(in_the_way)
      assert handover(ctx, dispatch).status == 200
    end

    test "under a bad signature is 401, unsigned", ctx do
      queued!(ctx)
      dispatch = started!(ctx)
      conn = handover(ctx, dispatch, seed: :crypto.strong_rand_bytes(32))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert Repo.aggregate(Run, :count) == 0
    end
  end

  describe "a dispatched" do
    test "is 204, signed, with no body, the first one recorded, a later one too", ctx do
      queued!(ctx)
      dispatch = claimed!(ctx)

      external = %{
        "type" => "example-ci",
        "ref" => "run-8812",
        "url" => "https://ci.example.com/runs/8812"
      }

      conn = dispatched(ctx, dispatch, body: %{"external" => external})
      assert conn.status == 204
      assert conn.resp_body == ""
      assert signed_answer?(conn)
      assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]

      recorded = Repo.get!(Dispatch, dispatch.id)
      assert %DateTime{} = recorded.dispatched_at

      again = dispatched(ctx, dispatch)
      assert again.status == 204
      assert signed_answer?(again)
      assert Repo.get!(Dispatch, dispatch.id).dispatched_at == recorded.dispatched_at
    end

    test "is refused with each status and code, signed", ctx do
      assert refused?(dispatched(ctx, "dp_0000000000000000"), 403, "forbidden")

      collection = collection_fixture(ctx.scope)

      {:ok, _queued} =
        Repo.transact(fn -> Dispatches.queue_prebuild(collection, ctx.pool, "env-1") end)

      prebuild = claimed!(ctx)

      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^prebuild.id),
          set: [ended_at: DateTime.utc_now(), end_cause: :released]
        )

      assert refused?(dispatched(ctx, prebuild), 410, "gone")
    end

    test "with a lease lapsed is 409 lease_expired, signed, the lapse committed", ctx do
      {_work_item, queued} = queued!(ctx)
      dispatch = claimed!(ctx)
      now = DateTime.utc_now()

      {1, _rows} =
        Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
          set: [
            claimed_at: DateTime.add(now, -700, :second),
            lease_until: %{
              DateTime.truncate(DateTime.add(now, -60, :second), :second)
              | microsecond: {0, 6}
            }
          ]
        )

      assert refused?(dispatched(ctx, dispatch), 409, "lease_expired")

      assert %Dispatch{stale_at: %DateTime{}, dispatched_at: nil} =
               Repo.get!(Dispatch, dispatch.id)

      assert Repo.get!(DispatchRun, queued.id).state == :waiting
    end
  end

  test "a release accepted before the handover is 204, signed, and the handover after it is 410 gone",
       ctx do
    queued!(ctx)
    dispatch = started!(ctx)

    body = %{
      "version" => 1,
      "time" => now_time(),
      "reason" => "The job could not start.",
      "retry" => true
    }

    conn = post(ctx, dispatch, "release", body)
    assert conn.status == 204
    assert conn.resp_body == ""
    assert signed_answer?(conn)

    assert refused?(handover(ctx, dispatch), 410, "gone")
  end
end
