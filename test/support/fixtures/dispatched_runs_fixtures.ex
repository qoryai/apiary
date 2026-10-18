defmodule Apiary.DispatchedRunsFixtures do
  @moduledoc """
  Test helpers for the runs a workspace's queue hands over: a run of the queue, claimed by
  a node pool and handed over, with the run registered for it, written as the handover
  leaves them, and an outcome given for it as its starter gives one.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Dispatches, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Runs.{Outcome, Run}

  @doc """
  A run of a fresh work item of the scope's workspace, queued, claimed under the pool's
  `key` and handed over, with its registered run: through a gateway, of the pool's node and
  key, running, registered and its run key issued a minute ago, attached 30 seconds ago,
  last heard 5 seconds ago, with the backstop its attach sets for `explore`. `run_attrs`
  change the registered run; `unattached/0` are the ones of a run never attached. Returns `%{dispatch_run: run_of_queue, dispatch: dispatch, run: run}`,
  each as stored.
  """
  def handed_over_fixture(%Scope{} = scope, %AccessKey{} = key, run_attrs \\ %{}) do
    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    handed_over(scope, key, queued, run_attrs)
  end

  @doc """
  Claims `queued`, a waiting run of the queue of the scope's workspace and its oldest, under
  `key`, and hands it over as `handed_over_fixture/3` does.
  """
  def handed_over(%Scope{} = scope, %AccessKey{} = key, %DispatchRun{} = queued, run_attrs) do
    {:ok, %{dispatch: dispatch, run: %DispatchRun{id: id}}} =
      Dispatches.claim(key, Dispatches.now())

    ^id = queued.id
    at = dispatch.claimed_at

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id), set: [state: :handed_over])

    attrs = gateway_run_attrs(DateTime.utc_now())

    run =
      %Run{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        node_run_id: queued.run_id,
        node_id: key.node_id,
        access_key_id: key.id,
        node_instance_id: queued.run_id,
        dispatch_run_id: id
      }
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.change(
        backstop_at:
          DateTime.add(attrs.attached_at, Dispatches.backstop_seconds("explore"), :second)
      )
      |> Ecto.Changeset.change(Map.new(run_attrs))
      |> Repo.insert!()

    %{
      dispatch_run: Repo.get!(DispatchRun, id),
      dispatch: Repo.get!(Dispatch, dispatch.id),
      run: run
    }
  end

  @doc """
  What a handover needs of the scope's workspace: a gateway of the workspace, at
  `https://gateway.example`, its default, with an active key, and a node pool made after
  it, whose choice is the default and so leads to it, with a key enrolled on it. Returns
  `%{gateway: gateway, gateway_key: {key, seed}, pool: pool, key: key, seed: seed}`, each
  seed the raw secret that signs as its key.
  """
  def handover_place_fixture(%Scope{} = scope) do
    gateway = Apiary.NodesFixtures.gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_seed} =
      Apiary.ContractFixtures.contract_key_fixture(scope, node: gateway)

    pool = Apiary.NodesFixtures.pool_fixture(scope)
    :default = pool.gateway_choice
    %{access_key: key, pair: pair} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, pool)

    %{
      gateway: gateway,
      gateway_key: {gateway_key, gateway_seed},
      pool: pool,
      key: key,
      seed: pair.secret
    }
  end

  @doc """
  Claims the oldest waiting run the pool of `key` may take at `revision`, 1 unless
  given, and says the starter started its job (`Apiary.Dispatches.dispatched/3`), with
  no external job: `%{dispatch: dispatch, run: run_of_queue}`, as stored then.
  """
  def dispatched!(%AccessKey{} = key, revision \\ 1) do
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(key, Dispatches.now(), revision)

    :ok =
      Dispatches.dispatched(key, dispatch.public_id, %{revision: revision, external: nil})

    dispatch = Repo.get!(Dispatch, dispatch.id)
    %{dispatch: dispatch, run: Repo.get!(DispatchRun, dispatch.dispatch_run_id)}
  end

  @doc """
  The attributes of a run registered through a gateway as of `now`, running: registered
  and its run key issued a minute before, attached 30 seconds before, last heard 5 seconds
  before.
  """
  def gateway_run_attrs(%DateTime{} = now) do
    issued_at = DateTime.add(now, -60, :second)
    digest = "sha256=" <> String.duplicate("0", 64)

    %{
      state: "running",
      registered_at: issued_at,
      registration_labels: %{},
      registration_about: %{},
      registration_digest: :crypto.hash(:sha256, "registration"),
      registration_interval_seconds: 30,
      registration_answer_digest: digest,
      run_key_payload: "run key payload",
      run_key_signature: :binary.copy(<<0>>, 64),
      run_key_issued_at: issued_at,
      attach_by: DateTime.add(issued_at, 600, :second),
      attached_at: DateTime.add(now, -30, :second),
      attach_interval_seconds: 30,
      attach_answer_digest: digest,
      last_heartbeat_at: DateTime.add(now, -5, :second)
    }
  end

  @doc "The attributes of a run handed over that its gateway has not attached, pending."
  def unattached,
    do: %{
      state: "pending",
      attached_at: nil,
      attach_interval_seconds: nil,
      attach_answer_digest: nil,
      backstop_at: nil,
      last_heartbeat_at: nil
    }

  @doc """
  Gives `run` the outcome `state` (and `reason`, when given) under `key`, as the run
  endpoint does once the request verified: `Apiary.Runs.Outcome.give/4`'s answer.
  """
  def give_outcome(%AccessKey{} = key, %Run{node_run_id: run_id}, state, reason \\ nil) do
    time = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    body =
      %{"version" => 1, "time" => time, "state" => state}
      |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))
      |> Jason.encode!()

    {:ok, outcome} = Outcome.parse(Jason.decode!(body))
    Outcome.give(key, run_id, outcome, body)
  end
end
