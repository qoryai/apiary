defmodule ApiaryWeb.Contract.RunFeaturesTest do
  # A run keeps the features it was claimed or registered with (`Apiary.Runs.Run`,
  # `features`), and its requests are checked against them
  # (`ApiaryWeb.Contract.RunFeatures`, `Apiary.Access`): a run already running finishes
  # with the features it started with when the instance's features change, and an ended
  # run follows the instance's features. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  @moduletag needs: :security
  @moduletag :feature_sets

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}

  setup do
    previous = Application.get_env(:apiary, :features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)

    Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^node.id),
      set: [gateway_choice: :direct]
    )

    %{key: {key, secret}}
  end

  defp register({key, secret}, run_id),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id)))

  defp deliver({key, secret}, run_id) do
    {_subject, events} = first_events(run_id)
    signed_post(build_conn(), key.key_id, secret, events)
  end

  defp outcome({key, secret}, run_id) do
    time =
      ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

    signed_post(
      build_conn(),
      key.key_id,
      secret,
      Jason.encode!(%{"version" => 1, "state" => "succeeded", "time" => time}),
      target: "/v1/runs/#{run_id}/outcome",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  defp events(run_id) do
    run = run(run_id)
    Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count)
  end

  test "a registration keeps the instance's features on the run", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200
    assert run(run_id).features == Apiary.Features.recorded()
  end

  # An events batch is checked against `observability` alone, which every instance has:
  # its body is not read for its run (`ApiaryWeb.Contract.RunFeatures`).
  test "a run whose observability goes off still sends its outcome", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200

    # The instance's features change while the run runs.
    Application.put_env(:apiary, :features, [])

    assert deliver(ctx.key, run_id).status == 404
    assert events(run_id) == 0

    conn = outcome(ctx.key, run_id)
    assert conn.status in [200, 202]
    assert run(run_id).outcome_state == "succeeded"
  end

  test "a run that kept no features follows the instance's", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200
    Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id), set: [features: nil])

    Application.put_env(:apiary, :features, [])

    assert deliver(ctx.key, run_id).status == 404
    assert outcome(ctx.key, run_id).status == 404
    assert events(run_id) == 0
  end

  test "a run that has ended follows the instance's", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200

    Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
      set: [state: "completed", exited_at: DateTime.utc_now()]
    )

    Application.put_env(:apiary, :features, [])

    assert outcome(ctx.key, run_id).status == 404
  end

  # A lost run has not ended while a heartbeat can revive it, so it keeps its features. One
  # with its exit, silenced, past its backstop, or never attached and past its attach
  # window is lost for good, and has ended.
  test "a lost run keeps its features until it is lost for good; a paused one does not", ctx do
    now = DateTime.utc_now()
    past = DateTime.add(now, -60, :second)
    future = DateTime.add(now, 600, :second)

    # A run key issued before its attach window ends, and an attach.
    gateway = fn attach_by ->
      [
        run_key_payload: "run key",
        run_key_issued_at: DateTime.add(now, -120),
        attach_by: attach_by
      ]
    end

    attached = [attached_at: past, attach_interval_seconds: 30, attach_answer_digest: "digest"]

    cases = [
      {[state: "lost"], true},
      {[state: "lost", backstop_at: future], true},
      {[state: "lost", exited_at: past], false},
      {[state: "lost", silenced_at: past], false},
      {[state: "lost", backstop_at: past], false},
      {[state: "lost"] ++ gateway.(future), true},
      {[state: "lost"] ++ gateway.(past), false},
      {[state: "lost"] ++ gateway.(past) ++ attached, true},
      {[state: "paused"], false}
    ]

    runs =
      for {set, kept?} <- cases do
        run_id = Ecto.UUID.generate()
        assert register(ctx.key, run_id).status == 200
        Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id), set: set)
        {run_id, set, kept?}
      end

    Application.put_env(:apiary, :features, [])

    for {run_id, set, kept?} <- runs do
      status = outcome(ctx.key, run_id).status

      if kept?,
        do: assert(status in [200, 202], inspect(set)),
        else: assert(status == 404, inspect(set))
    end
  end

  # The gate reads the run once, and the controller takes what it read.
  test "the gate keeps the features it read for the controller", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200
    {key, _secret} = ctx.key
    kept = run(run_id).features

    conn =
      build_conn()
      |> Plug.Conn.assign(:access_key, key)
      |> Map.put(:path_params, %{"run_id" => run_id})

    {true, conn} = ApiaryWeb.Contract.RunFeatures.gate(conn, [:observability])
    Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id), set: [features: []])

    assert ApiaryWeb.Contract.RunFeatures.recorded(conn) == kept
  end

  test "a run's features are kept until it has ended" do
    features = ["observability"]
    now = DateTime.utc_now()
    past = DateTime.add(now, -60, :second)
    kept = &Run.kept_features(struct(Run, [features: features] ++ &1))

    for state <- ~w(pending running lost), do: assert(kept.(state: state) == features)
    future = DateTime.add(now, 600, :second)
    assert kept.(state: "lost", backstop_at: future) == features

    for state <- ~w(completed failed cancelled paused) do
      assert Run.ended?(%Run{state: state})
      assert kept.(state: state) == nil
    end

    assert kept.(state: "lost", attach_by: future) == features
    assert kept.(state: "lost", attach_by: past, attached_at: past) == features

    for set <- [[exited_at: past], [silenced_at: past], [backstop_at: past], [attach_by: past]] do
      assert Run.ended?(struct(Run, [state: "lost"] ++ set))
      assert kept.([state: "lost"] ++ set) == nil
    end

    assert Run.lost_for_good?(%Run{state: "lost", backstop_at: past}, now)
    refute Run.lost_for_good?(%Run{state: "lost", backstop_at: now}, now)
    refute Run.lost_for_good?(%Run{state: "lost", attach_by: now}, now)
    assert Run.ended_states() -- Run.states() == []
    assert Run.kept_features(nil) == nil
  end

  # The body's `run_id` is read on the secrets request alone, and only where a feature
  # other than `observability` is checked.
  test "the body's run_id is read on the secrets request alone", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200
    {key, _secret} = ctx.key
    key = Repo.preload(key, [:node, :workspace])

    conn = fn controller ->
      %Plug.Conn{
        assigns: %{access_key: key, raw_body: Jason.encode!(%{"run_id" => run_id})},
        private: %{phoenix_controller: controller}
      }
    end

    secrets = conn.(ApiaryWeb.Contract.SecretsController)
    pool = conn.(ApiaryWeb.Contract.PoolClaimController)

    assert ApiaryWeb.Contract.RunFeatures.recorded(secrets) == run(run_id).features
    assert ApiaryWeb.Contract.RunFeatures.recorded(pool) == nil

    Application.put_env(:apiary, :features, [])
    refute ApiaryWeb.Contract.RunFeatures.on?(secrets, [:observability])
    assert ApiaryWeb.Contract.RunFeatures.on?(secrets, [:security])
    refute ApiaryWeb.Contract.RunFeatures.on?(pool, [:security])
  end

  test "a request about another run, or about none, follows the instance's", ctx do
    run_id = Ecto.UUID.generate()
    assert register(ctx.key, run_id).status == 200
    Application.put_env(:apiary, :features, [])

    assert outcome(ctx.key, Ecto.UUID.generate()).status == 404
    assert register(ctx.key, Ecto.UUID.generate()).status == 404
  end
end
