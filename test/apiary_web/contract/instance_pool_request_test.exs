defmodule ApiaryWeb.Contract.InstancePoolRequestTest do
  # The provisioner contract's routes for the key of the instance's node pool, which has
  # no organisation and no workspace (`ApiaryWeb.Contract.AdapterRequest` with
  # `kind: :pool`): `POST /v1/pools/claim` with `wait_seconds` 0 and above, the hold woken
  # by a run queued in any workspace, and `dispatched`, `release` and `machine-log` on a
  # dispatch it claimed, and 403 on a dispatch another pool claimed. A revoked key of the
  # instance's pool, the key of the instance's gateway, which has no place either, an
  # organisation gateway's key and an adapter's key are refused as an unknown key. Not
  # async: the instance has one pool and one gateway in use, and the hold's settings are
  # the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, MachineLog}
  alias ApiaryWeb.Contract.{PoolClaimController, SignedRequest}

  @moduletag needs: :factory

  setup do
    previous = Application.fetch_env(:apiary, PoolClaimController)

    on_exit(fn ->
      case previous do
        {:ok, settings} -> Application.put_env(:apiary, PoolClaimController, settings)
        :error -> Application.delete_env(:apiary, PoolClaimController)
      end
    end)

    gateway = instance_gateway_fixture()

    %{access_key: gateway_key, pair: gateway_pair} =
      installed_key_fixture(gateway, allow_secrets: true)

    pool = instance_pool_fixture()
    %{access_key: key, pair: pair} = installed_key_fixture(pool)
    %{scope: a} = sign_up_fixture()
    %{scope: b} = sign_up_fixture()

    %{
      pool: pool,
      key: key,
      seed: pair.secret,
      gateway_key: gateway_key,
      gateway_seed: gateway_pair.secret,
      a: a,
      b: b
    }
  end

  # The clock's time, two seconds earlier for each request a test sends, so no two of its
  # requests are one signature.
  defp now_time do
    (SignedRequest.now() - 2 * rem(System.unique_integer([:positive, :monotonic]), 125))
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp signed(ctx, target, body, opts \\ []) do
    signed_post(
      build_conn(),
      Keyword.get(opts, :key_id, ctx.key.key_id),
      Keyword.get(opts, :seed, ctx.seed),
      Map.merge(%{"version" => 1, "time" => now_time()}, body),
      target: target,
      content_type: "application/json",
      delivery: nil,
      contract_version: "1"
    )
  end

  defp claim(ctx, wait_seconds, opts \\ []),
    do: signed(ctx, "/v1/pools/claim", %{"wait_seconds" => wait_seconds}, opts)

  defp queue!(scope) do
    work_item = work_item_fixture(scope)
    {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    run
  end

  # The run and the dispatch the claim answered by `conn` took.
  defp claimed(conn) do
    %{"dispatch_id" => dispatch_id} = Jason.decode!(conn.resp_body)
    dispatch = Repo.get_by!(Dispatch, public_id: dispatch_id)
    {Repo.get!(DispatchRun, dispatch.dispatch_run_id), dispatch}
  end

  defp claimed!(ctx, scope) do
    queue!(scope)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    dispatch
  end

  defp settings(hold, poll),
    do: Application.put_env(:apiary, PoolClaimController, hold: hold, poll: poll)

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  describe "POST /v1/pools/claim by the instance's pool" do
    test "with wait_seconds 0 and nothing waiting, answers 204, signed", ctx do
      conn = claim(ctx, 0)
      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)
    end

    test "with wait_seconds 0, takes the oldest waiting run across workspaces", ctx do
      first = queue!(ctx.b)
      _second = queue!(ctx.a)

      conn = claim(ctx, 0)
      assert conn.status == 200
      assert signed_answer?(conn)
      assert %{"pool_id" => pool_id} = Jason.decode!(conn.resp_body)
      assert pool_id == ctx.pool.public_id

      {run, dispatch} = claimed(conn)
      assert run.id == first.id

      assert {dispatch.organisation_id, dispatch.workspace_id} ==
               {ctx.b.organisation.id, ctx.b.workspace.id}
    end

    test "with wait_seconds above 0 and nothing waiting, answers 204 at the end of the hold",
         ctx do
      settings(300, 50)
      {took, conn} = timed(fn -> claim(ctx, 25) end)
      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)
      assert took >= 300 and took < 5_000
    end

    test "with wait_seconds above 0, a run queued meanwhile in any workspace wakes it, ahead of the poll",
         ctx do
      settings(10_000, 10_000)
      work_item = work_item_fixture(ctx.b)

      writer =
        Task.async(fn ->
          Process.sleep(200)
          {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
          run
        end)

      {took, conn} = timed(fn -> claim(ctx, 25) end)
      run = Task.await(writer)

      assert conn.status == 200
      assert elem(claimed(conn), 0).id == run.id
      assert took >= 150 and took < 5_000
    end

    test "refuses the key of the instance's gateway as an unknown key, unsigned", ctx do
      queue!(ctx.a)
      conn = claim(ctx, 0, key_id: ctx.gateway_key.key_id, seed: ctx.gateway_seed)
      assert conn.status == 401
      assert unsigned_answer?(conn)
      assert Repo.aggregate(Dispatch, :count) == 0
    end
  end

  describe "a dispatch of the instance's pool" do
    test "dispatched answers 204, signed, and hands the dispatch over", ctx do
      dispatch = claimed!(ctx, ctx.a)
      conn = signed(ctx, "/v1/dispatches/#{dispatch.public_id}/dispatched", %{})

      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)

      assert %Dispatch{dispatched_at: %DateTime{}, handed_over_at: %DateTime{}} =
               Repo.reload!(dispatch)
    end

    test "release answers 204, signed, and the run waits again", ctx do
      dispatch = claimed!(ctx, ctx.b)

      conn =
        signed(ctx, "/v1/dispatches/#{dispatch.public_id}/release", %{
          "reason" => "The job could not start."
        })

      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)
      assert Repo.get!(DispatchRun, dispatch.dispatch_run_id).state == :waiting
    end

    @tag :tmp_dir
    test "machine-log answers 204, signed, and stores the log", ctx do
      dir = Path.join(ctx.tmp_dir, "machine-logs")
      before = Application.fetch_env(:apiary, :machine_logs_dir)
      Application.put_env(:apiary, :machine_logs_dir, dir)

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, :machine_logs_dir, value)
          :error -> Application.delete_env(:apiary, :machine_logs_dir)
        end
      end)

      dispatch = claimed!(ctx, ctx.a)

      conn =
        signed(ctx, "/v1/dispatches/#{dispatch.public_id}/machine-log", %{
          "log" => "machine started\n",
          "truncated" => false
        })

      assert {conn.status, conn.resp_body} == {204, ""}
      assert signed_answer?(conn)
      assert File.read!(Path.join(dir, dispatch.public_id)) == "machine started\n"

      assert %MachineLog{organisation_id: organisation_id, workspace_id: workspace_id} =
               Repo.one!(from l in MachineLog, where: l.dispatch_id == ^dispatch.id)

      assert {organisation_id, workspace_id} == {ctx.a.organisation.id, ctx.a.workspace.id}
    end

    test "the key of the instance's gateway is refused on dispatched, unsigned", ctx do
      dispatch = claimed!(ctx, ctx.a)

      conn =
        signed(ctx, "/v1/dispatches/#{dispatch.public_id}/dispatched", %{},
          key_id: ctx.gateway_key.key_id,
          seed: ctx.gateway_seed
        )

      assert conn.status == 401
      assert unsigned_answer?(conn)
      refute Repo.reload!(dispatch).dispatched_at
    end

    test "the instance pool's key is refused, 403, on a dispatch another pool claimed", ctx do
      %{scope: c} = sign_up_fixture()
      theirs = pool_fixture(c)
      %{access_key: their_key} = enrolled_key_fixture(c, theirs)
      Apiary.DispatchedRunsFixtures.gateway_for!(c, theirs)
      queue!(c)
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(their_key, Dispatches.now())

      for {action, body} <- [
            {"dispatched", %{}},
            {"release", %{"reason" => "The job could not start."}}
          ] do
        conn = signed(ctx, "/v1/dispatches/#{dispatch.public_id}/#{action}", body)

        assert {conn.status, Jason.decode!(conn.resp_body)} == {403, %{"error" => "forbidden"}}
        assert signed_answer?(conn)
      end

      assert %Dispatch{dispatched_at: nil, ended_at: nil} = Repo.reload!(dispatch)
    end
  end

  describe "a key of another shape on the provisioner routes" do
    test "the instance pool's key, revoked, is refused as an unknown key, unsigned", ctx do
      queue!(ctx.a)
      {:ok, _revoked} = Apiary.Adapters.revoke_key(instance_admin_scope(), ctx.key)

      conn = claim(ctx, 0)
      assert conn.status == 401
      assert unsigned_answer?(conn)
      assert Repo.aggregate(Dispatch, :count) == 0
    end

    test "an organisation gateway's key and an adapter's key are refused, unsigned", ctx do
      queue!(ctx.a)
      organisation_gateway = organisation_gateway_fixture(ctx.b)

      %{access_key: gateway_key, pair: gateway_pair} =
        enrolled_key_fixture(ctx.b, organisation_gateway)

      %{access_key: adapter_key, pair: adapter_pair} =
        installed_key_fixture(installed_adapter_fixture())

      for {key, pair} <- [{gateway_key, gateway_pair}, {adapter_key, adapter_pair}] do
        conn = claim(ctx, 0, key_id: key.key_id, seed: pair.secret)
        assert conn.status == 401
        assert unsigned_answer?(conn)
      end

      assert Repo.aggregate(Dispatch, :count) == 0
    end
  end
end
