defmodule ApiaryWeb.Contract.PoolClaimTest do
  # `POST /v1/pools/claim` (`ApiaryWeb.Contract.PoolClaimController`): the claim answer,
  # signed, held to the vendored `claim-answer.schema.json`, a prebuild's to its pool
  # alone, an explore run's without a target with neither access nor target; the refusals
  # in their order;
  # another pool's id refused as an unknown one is; `dispatch.claim` refused or not found
  # as one answer; the hold, its wake, its end and its cap per key; and the key read again
  # after the wait. Not async: the features, the hold's settings and the registry of holds
  # are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Dispatches, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.Contract.{PoolClaimController, SignedRequest}

  @moduletag needs: :factory

  @claim "/v1/pools/claim"
  @vendored Path.expand("../../fixtures/contract", __DIR__)
  @fixtures Path.join(@vendored, "provisioner/v1/fixtures")
  @base "https://qory.dev/contracts/"
  @unknown_pool "np_0000000000000000"

  # The vendored schemas by their URL under the contracts' base. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, root) do
      file = Path.expand(path, root)

      with true <- String.starts_with?(file, root <> "/"),
           {:ok, body} <- File.read(file),
           {:ok, schema} <- Jason.decode(body) do
        {:ok, schema}
      else
        _ -> {:error, {:not_vendored, path}}
      end
    end

    def resolve(url, _root), do: {:error, {:not_vendored, url}}
  end

  setup do
    previous = Application.fetch_env(:apiary, PoolClaimController)

    on_exit(fn ->
      case previous do
        {:ok, settings} -> Application.put_env(:apiary, PoolClaimController, settings)
        :error -> Application.delete_env(:apiary, PoolClaimController)
      end
    end)

    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, pool)
    %{scope: scope, pool: pool, key: key, seed: pair.secret}
  end

  defp settings(hold, poll),
    do: Application.put_env(:apiary, PoolClaimController, hold: hold, poll: poll)

  defp now_time(offset) do
    (SignedRequest.now() + offset)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp body(attrs \\ %{}, offset \\ 0),
    do: Map.merge(%{"version" => 1, "time" => now_time(offset), "wait_seconds" => 0}, attrs)

  defp claim(ctx, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      body,
      target: @claim,
      content_type: "application/json",
      delivery: nil,
      contract_version: Keyword.get(opts, :contract_version, "3")
    )
  end

  defp prebuild!(collection, pool) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue_prebuild(collection, pool, "env-1") end)
    run
  end

  # The members of a JSON object, in their order.
  defp members(json),
    do: json |> Jason.decode!(objects: :ordered_objects) |> Map.get(:values) |> keys()

  defp queue!(work_item) do
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  defp queued!(scope), do: scope |> work_item_fixture() |> queue!()

  defp dispatches, do: Repo.aggregate(Dispatch, :count)

  defp validator(schema) do
    JSV.build!(%{"$ref" => @base <> "provisioner/v1/#{schema}.schema.json"},
      resolver: {Resolver, @vendored},
      formats: true
    )
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  describe "a claim" do
    test "takes the oldest waiting run, answered 200, signed, as the contract's claim answer",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      run = queue!(work_item)
      queued!(ctx.scope)

      conn = claim(ctx, body(%{"pool_id" => ctx.pool.public_id}))
      assert conn.status == 200
      assert signed_answer?(conn)

      answer = Jason.decode!(conn.resp_body)
      assert {:ok, _} = JSV.validate(answer, validator("claim-answer"))

      # The members, in the fixture's order.
      fixture = @fixtures |> Path.join("claim-answer/explore.json") |> File.read!()

      assert conn.resp_body
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.get(:values)
             |> keys() ==
               fixture |> Jason.decode!(objects: :ordered_objects) |> Map.get(:values) |> keys()

      dispatch = Repo.one!(from d in Dispatch, where: d.dispatch_run_id == ^run.id)
      lease_until = dispatch.lease_until |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert answer == %{
               "version" => 1,
               "revision" => 3,
               "dispatch_id" => dispatch.public_id,
               "run_id" => run.run_id,
               "pool_id" => ctx.pool.public_id,
               "lease_until" => lease_until,
               "step" => "explore",
               "access" => "read",
               "target" => %{"system" => "forge.example.com", "path" => "acme/shop"},
               "work_item" => %{
                 "id" => work_item.public_id,
                 "url" => "#{ApiaryWeb.Endpoint.url()}/work-items/#{work_item.public_id}",
                 "title" => work_item.title
               }
             }

      assert %Dispatch{pool_id: pool_id, access_key_id: key_id} = dispatch
      assert {pool_id, key_id} == {ctx.pool.id, ctx.key.id}
      assert Repo.get!(DispatchRun, run.id).state == :claimed
    end

    test "names the work item by its address of the fixture's shape, which no workspace moves",
         ctx do
      work_item = work_item_fixture(ctx.scope)
      queue!(work_item)

      # The fixture's address, its origin and its id put aside: `/work-items/` and the id.
      %{"work_item" => %{"id" => id, "url" => url}} =
        @fixtures |> Path.join("claim-answer/explore.json") |> File.read!() |> Jason.decode!()

      %URI{path: path} = URI.parse(url)
      assert path == "/work-items/" <> id

      answer = Jason.decode!(claim(ctx, body()).resp_body)
      expected = ApiaryWeb.Endpoint.url() <> "/work-items/" <> work_item.public_id
      assert answer["work_item"]["url"] == expected
      assert %URI{path: "/work-items/" <> public_id} = URI.parse(expected)
      assert public_id == work_item.public_id

      # Moved to another workspace after the claim, it has the same address.
      other = workspace_fixture(ctx.scope.organisation)

      Repo.update_all(from(w in Apiary.WorkItems.WorkItem, where: w.id == ^work_item.id),
        set: [workspace_id: other.id]
      )

      moved = Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)
      assert moved.workspace_id == other.id
      assert Apiary.WorkItems.stable_url(moved) == expected
    end

    test "without pool_id covers the key's pool; with an empty queue and no wait it is 204, signed",
         ctx do
      conn = claim(ctx, body())
      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)

      run = queued!(ctx.scope)
      conn = claim(ctx, body(%{}, 1))
      assert Jason.decode!(conn.resp_body)["run_id"] == run.run_id
    end
  end

  describe "a claim of a prebuild or of a run without a target" do
    test "takes a prebuild held for its pool, answered 200, signed, as the contract's prebuild",
         ctx do
      collection = collection_fixture(ctx.scope, target_path: "acme/shop")
      run = prebuild!(collection, ctx.pool)

      conn = claim(ctx, body(%{"pool_id" => ctx.pool.public_id}))
      assert conn.status == 200
      assert signed_answer?(conn)

      answer = Jason.decode!(conn.resp_body)
      assert {:ok, _} = JSV.validate(answer, validator("claim-answer"))

      assert members(conn.resp_body) ==
               @fixtures |> Path.join("claim-answer/prebuild.json") |> File.read!() |> members()

      dispatch = Repo.one!(from d in Dispatch, where: d.dispatch_run_id == ^run.id)
      lease_until = dispatch.lease_until |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert answer == %{
               "version" => 1,
               "revision" => 3,
               "dispatch_id" => dispatch.public_id,
               "run_id" => run.run_id,
               "pool_id" => ctx.pool.public_id,
               "lease_until" => lease_until,
               "step" => "prebuild",
               "access" => "read",
               "target" => %{"system" => "code.example.com", "path" => "acme/shop"}
             }

      assert Repo.get!(DispatchRun, run.id).state == :claimed
    end

    test "takes an explore run without a target, in the general domain: neither access nor target",
         ctx do
      scope = with_domain(ctx.scope, "general")
      work_item = work_item_fixture(scope, %{target_system: nil, target_path: nil})
      run = queue!(work_item)

      conn = claim(ctx, body())
      assert {conn.status, signed_answer?(conn)} == {200, true}
      answer = Jason.decode!(conn.resp_body)
      assert {:ok, _} = JSV.validate(answer, validator("claim-answer"))

      assert members(conn.resp_body) ==
               @fixtures
               |> Path.join("claim-answer/explore-without-target.json")
               |> File.read!()
               |> members()

      assert {answer["revision"], answer["run_id"]} == {3, run.run_id}
      assert answer["work_item"]["id"] == work_item.public_id
      refute Map.has_key?(answer, "access") or Map.has_key?(answer, "target")
    end

    test "another pool never takes a prebuild held for a pool", ctx do
      # The pool made before the collection, whose fixture applies no trigger.
      other = pool_fixture(ctx.scope)
      %{access_key: other_key, pair: other_pair} = enrolled_key_fixture(ctx.scope, other)
      run = prebuild!(collection_fixture(ctx.scope), ctx.pool)

      conn = claim(ctx, body(), key_id: other_key.key_id, seed: other_pair.secret)
      assert {conn.status, conn.resp_body} == {204, ""}
      assert Repo.get!(DispatchRun, run.id).state == :waiting
      assert dispatches() == 0
    end
  end

  describe "the refusals" do
    test "another pool's id, or one the instance does not hold, is 403 forbidden, signed, alike, and takes nothing",
         ctx do
      queued!(ctx.scope)
      other = pool_fixture(ctx.scope)

      answers =
        for {pool_id, offset} <- [{other.public_id, 0}, {@unknown_pool, 1}] do
          conn = claim(ctx, body(%{"pool_id" => pool_id}, offset))
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert [{403, ~s({"error":"forbidden"})}, {403, ~s({"error":"forbidden"})}] = answers
      assert dispatches() == 0
    end

    test "dispatch.claim refused or not found is one answer, the same 403 as another pool's id",
         ctx do
      queued!(ctx.scope)
      other = pool_fixture(ctx.scope)
      reference = claim(ctx, body(%{"pool_id" => other.public_id}))

      for {stub, offset} <- [
            {Apiary.EditionStubs.NoClaim, 1},
            {Apiary.EditionStubs.HidesClaim, 2}
          ] do
        :ok = Apiary.Edition.put_test_stub(stub)
        conn = claim(ctx, body(%{}, offset))
        assert {conn.status, conn.resp_body} == {reference.status, reference.resp_body}
        assert signed_answer?(conn)
      end

      assert dispatches() == 0
    end

    test "a choice of gateway that leads to none is 409 no_gateway, signed, and takes nothing",
         ctx do
      run = queued!(ctx.scope)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :default]
      )

      conn = claim(ctx, body(%{"wait_seconds" => 5}))
      assert json_response(conn, 409) == %{"error" => "no_gateway"}
      assert signed_answer?(conn)
      assert Repo.get!(DispatchRun, run.id).state == :waiting
    end

    test "in order: 400 invalid_request, 401 for the time, 403 another pool, 409 no_gateway",
         ctx do
      queued!(ctx.scope)
      other = pool_fixture(ctx.scope)

      Repo.update_all(from(n in Node, where: n.id == ^ctx.pool.id),
        set: [gateway_choice: :default]
      )

      # A body the contract refuses, stale and of another pool: 400.
      conn = claim(ctx, body(%{"pool_id" => other.public_id, "wait_seconds" => 26}, -86_400))
      assert json_response(conn, 400) == %{"error" => "invalid_request"}

      # Stale, of another pool, with no gateway: 401, unsigned, before anything is looked up.
      conn = claim(ctx, body(%{"pool_id" => other.public_id}, -86_400))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)

      # Another pool, with no gateway: 403.
      conn = claim(ctx, body(%{"pool_id" => other.public_id}))
      assert json_response(conn, 403) == %{"error" => "forbidden"}

      # The key's pool, with no gateway: 409.
      conn = claim(ctx, body(%{"pool_id" => ctx.pool.public_id}, 1))
      assert json_response(conn, 409) == %{"error" => "no_gateway"}

      # The same request again is a replay, before the pool is looked at.
      raw = Jason.encode!(body(%{"pool_id" => other.public_id}, 2))
      assert claim(ctx, raw).status == 403
      assert json_response(claim(ctx, raw), 401) == %{"error" => "unauthorized"}

      assert dispatches() == 0
    end
  end

  describe "the hold" do
    test "with nothing to claim, it answers 204, signed, at the end of the hold", ctx do
      settings(300, 50)
      {took, conn} = timed(fn -> claim(ctx, body(%{"wait_seconds" => 25})) end)
      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)
      assert took >= 300 and took < 5_000
    end

    test "a run queued meanwhile wakes it, ahead of the poll", ctx do
      settings(10_000, 10_000)
      work_item = work_item_fixture(ctx.scope)

      writer =
        Task.async(fn ->
          Process.sleep(200)
          queue!(work_item)
        end)

      {took, conn} = timed(fn -> claim(ctx, body(%{"wait_seconds" => 25})) end)
      run = Task.await(writer)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["run_id"] == run.run_id
      assert took >= 150 and took < 5_000
    end

    test "at the pool's limit it holds, and a slot freed meanwhile wakes it", ctx do
      settings(10_000, 10_000)
      pool = pool_fixture(ctx.scope, instance_limit: 1)
      %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, pool)
      ctx = %{ctx | key: key, seed: pair.secret}

      queued!(ctx.scope)
      second = queued!(ctx.scope)
      assert claim(ctx, body()).status == 200

      [held] = Repo.all(from d in Dispatch, where: d.pool_id == ^pool.id)

      freer =
        Task.async(fn ->
          Process.sleep(200)

          {:ok, true} =
            Repo.transact(fn -> {:ok, Slots.free_slot(held, Dispatches.now())} end)

          Dispatches.broadcast([pool.workspace_id])
        end)

      {took, conn} = timed(fn -> claim(ctx, body(%{"wait_seconds" => 25}, 1)) end)
      Task.await(freer)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["run_id"] == second.run_id
      assert took >= 150 and took < 5_000
    end

    test "a key revoked during the wait is refused 401, unsigned, and takes nothing", ctx do
      settings(10_000, 10_000)
      work_item = work_item_fixture(ctx.scope)

      writer =
        Task.async(fn ->
          Process.sleep(200)
          {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, ctx.key)
          queue!(work_item)
        end)

      conn = claim(ctx, body(%{"wait_seconds" => 25}))
      run = Task.await(writer)

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert unsigned_answer?(conn)
      assert Repo.get!(DispatchRun, run.id).state == :waiting
      assert dispatches() == 0
    end

    test "listens no longer once answered", ctx do
      settings(100, 20)
      claim(ctx, body(%{"wait_seconds" => 1}))
      Dispatches.broadcast([ctx.scope.workspace.id])
      refute_receive {Dispatches, :changed}, 50
    end
  end

  describe "the cap on holds" do
    setup do
      settings(1_500, 5_000)
      :ok
    end

    # How many of the key's slots are held now.
    defp slots(ctx) do
      Enum.count(1..PoolClaimController.holds_per_key(), fn n ->
        Registry.lookup(PoolClaimController.Holds, {ctx.key.id, n}) != []
      end)
    end

    defp until_slots(ctx, count, tries \\ 200) do
      cond do
        slots(ctx) == count -> :ok
        tries == 0 -> flunk("the key holds #{slots(ctx)} slots, not #{count}")
        true -> Process.sleep(10) && until_slots(ctx, count, tries - 1)
      end
    end

    test "two claims of a key hold; the third is answered at once, 204, and another key holds",
         ctx do
      assert PoolClaimController.holds_per_key() == 2
      wait = %{"wait_seconds" => 25}

      holders =
        for offset <- [0, 1],
            do: Task.async(fn -> timed(fn -> claim(ctx, body(wait, offset)) end) end)

      until_slots(ctx, 2)

      {took, third} = timed(fn -> claim(ctx, body(wait, 2)) end)
      assert took < 1_000
      assert {third.status, third.resp_body} == {204, ""}
      assert signed_answer?(third)

      # Another key of the same pool holds while this key's two do.
      %{access_key: other, pair: pair} = enrolled_key_fixture(ctx.scope, ctx.pool)
      other = %{ctx | key: other, seed: pair.secret}
      {other_took, other_conn} = timed(fn -> claim(other, body(wait)) end)
      assert other_took >= 1_400
      assert other_conn.status == 204

      for {held, conn} <- Task.await_many(holders, 5_000) do
        assert held >= 1_400
        assert conn.status == 204
      end

      until_slots(ctx, 0)
      {again, _conn} = timed(fn -> claim(ctx, body(wait, 3)) end)
      assert again >= 1_400
    end

    test "a claim that takes a run at its first try is no hold, whatever the key holds", ctx do
      holders =
        for offset <- [0, 1],
            do: Task.async(fn -> claim(ctx, body(%{"wait_seconds" => 25}, offset)) end)

      until_slots(ctx, 2)

      # A run written untold, so the holders, polling past their hold, never see it.
      run =
        %DispatchRun{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id
        }
        |> DispatchRun.queue_changeset(%{
          work_item_id: work_item_fixture(ctx.scope).id,
          step: "explore",
          take_in: 1,
          attempt: 1,
          of: 3,
          queued_at: Dispatches.now()
        })
        |> Repo.insert!()

      {took, third} = timed(fn -> claim(ctx, body(%{"wait_seconds" => 25}, 2)) end)
      assert took < 1_000
      assert Jason.decode!(third.resp_body)["run_id"] == run.run_id
      assert slots(ctx) == 2

      for conn <- Task.await_many(holders, 5_000), do: assert(conn.status == 204)
      until_slots(ctx, 0)
    end
  end

  defp keys(values) when is_list(values), do: Enum.map(values, &elem(&1, 0))
end
