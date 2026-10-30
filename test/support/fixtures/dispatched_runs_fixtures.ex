defmodule Apiary.DispatchedRunsFixtures do
  @moduledoc """
  Test helpers for the runs a workspace's queue hands over: a run of the queue, claimed by
  a node pool, with the run its claim registered, handed over, and an outcome given for it
  as its starter gives one.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Dispatches, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.{Outcome, Run}

  @doc """
  Writes the harness walk of `run`, a run of the queue whose workspace has a workflow,
  resolved, as its job writes it (`Apiary.Harnesses.WalkJob`), with the origin `:none`
  unless `changes` sets one, and no adapter called: a claim takes the run then. Returns
  the walk as stored.
  """
  def walk_resolved!(%DispatchRun{id: id}, changes \\ []) do
    RunHarness
    |> Repo.get_by!(dispatch_run_id: id)
    |> Ecto.Changeset.change(Keyword.merge([state: :resolved, origin: :none], changes))
    |> Repo.update!()
  end

  @doc """
  A run of a fresh work item of the scope's workspace, queued, claimed under the pool's
  `key` and handed over, with the run its claim registered: through the gateway the pool's
  choice resolves to, or, when it resolves to none, a fresh gateway the pool is pointed at
  (`gateway_for!/2`); of the pool's node and key, running, registered and its run key
  issued a minute ago, attached 30 seconds ago, last heard 5 seconds ago, with the
  backstop its attach sets for `explore`. `run_attrs` change the registered run;
  `unattached/0` are the ones of a run never attached. Returns `%{dispatch_run:
  run_of_queue, dispatch: dispatch, run: run}`, each as stored.
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
    %{dispatch: dispatch, run: %DispatchRun{id: id}, registered: registered} =
      claim_through_gateway!(scope, key)

    ^id = queued.id
    at = dispatch.claimed_at

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: at, handed_over_at: at]
      )

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id), set: [state: :handed_over])

    attrs = gateway_run_attrs(DateTime.utc_now())

    # Its code redeemed: a run with a code has a run key payload with the public key that
    # redeemed it.
    run =
      registered
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.change(run_code_public_key: :binary.copy(<<1>>, 32))
      |> Ecto.Changeset.change(
        backstop_at:
          DateTime.add(attrs.attached_at, Dispatches.backstop_seconds("explore"), :second)
      )
      |> Ecto.Changeset.change(Map.new(run_attrs))
      |> Repo.update!()

    %{
      dispatch_run: Repo.get!(DispatchRun, id),
      dispatch: Repo.get!(Dispatch, dispatch.id),
      run: run
    }
  end

  # A claim under `key` that took a run. A pool whose choice resolves to no gateway is
  # pointed at a fresh gateway of the scope's workspace first (`gateway_for!/2`).
  defp claim_through_gateway!(scope, key) do
    case Dispatches.claim(key, Dispatches.now()) do
      {:ok, %{dispatch: %Dispatch{}} = claimed} ->
        claimed

      {:error, :no_gateway} ->
        _gateway = gateway_for!(scope, Repo.get!(Apiary.Nodes.Node, key.node_id))
        {:ok, %{dispatch: %Dispatch{}} = claimed} = Dispatches.claim(key, Dispatches.now())
        claimed
    end
  end

  @doc """
  What a claim needs of the scope's workspace: a gateway of the workspace, at
  `https://gateway.example`, its default, with an active key, and a node pool made after
  it, whose choice is the default and so leads to it, with a key enrolled on it. Returns
  `%{gateway: gateway, gateway_key: {key, seed}, pool: pool, key: key, seed: seed}`, each
  seed the raw secret that signs as its key. With `allow_secrets: true` in `opts`, the
  gateway's key is enrolled with the stored-secrets flag, as a run with a model provider
  needs; else it is made in a browser, without the flag.
  """
  def handover_place_fixture(%Scope{} = scope, opts \\ []) do
    gateway = Apiary.NodesFixtures.gateway_fixture(scope)
    {gateway_key, gateway_seed} = gateway_key(scope, gateway, opts[:allow_secrets] == true)

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
  A gateway of the scope's workspace, at `https://gateway.example`, with an active key:
  the workspace's default when it is its first gateway, so a node pool made after it,
  whose choice is the default, claims through it. Returns the gateway.
  """
  def workspace_gateway!(%Scope{} = scope) do
    gateway = Apiary.NodesFixtures.gateway_fixture(scope)
    _key = gateway_key(scope, gateway, false)
    gateway
  end

  @doc """
  Points `pool`'s choice at a fresh gateway of the scope's workspace, at
  `https://gateway.example`, with an active key, so a claim of the pool resolves to it.
  Returns the gateway.
  """
  def gateway_for!(%Scope{} = scope, %Apiary.Nodes.Node{kind: :pool, id: id}) do
    gateway = Apiary.NodesFixtures.gateway_fixture(scope)
    _key = gateway_key(scope, gateway, false)

    {1, _rows} =
      Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^id),
        set: [gateway_choice: :named, gateway_id: gateway.id]
      )

    gateway
  end

  defp gateway_key(scope, gateway, false) do
    %{access_key: key, secret: seed} =
      Apiary.ContractFixtures.contract_key_fixture(scope, node: gateway)

    {key, seed}
  end

  defp gateway_key(scope, gateway, true) do
    %{access_key: key, pair: pair} =
      Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, gateway, %{allow_secrets: true})

    {:ok, key} = Apiary.AccessKeys.fetch_for_verification(key.key_id)
    {key, pair.secret}
  end

  @doc """
  Claims the oldest waiting run the pool of `key` may take, and says the starter started
  its machine (`Apiary.Dispatches.dispatched/3`), with no external job, which hands the
  dispatch over: `%{dispatch: dispatch, run: run_of_queue, registered: registered_run}`,
  as stored then.
  """
  def dispatched!(%AccessKey{} = key) do
    {:ok, %{dispatch: dispatch, registered: registered, run_code: code}} =
      Dispatches.claim(key, Dispatches.now())

    :ok = Dispatches.dispatched(key, dispatch.public_id, %{external: nil})

    dispatch = Repo.get!(Dispatch, dispatch.id)

    %{
      dispatch: dispatch,
      run: Repo.get!(DispatchRun, dispatch.dispatch_run_id),
      registered: Repo.get!(Run, registered.id),
      run_code: code
    }
  end

  @doc """
  An image by its digest, `@sha256:` and `digest`, 64 lower-case hex digits, under the
  registry's place of the organisation `organisation_id` (`Apiary.Registry.Names`), at
  `targets/` and `name`, 16 hex digits: `Apiary.Environments.image_for/3` gives it to a
  run of the organisation. With the `registry` feature on.
  """
  def registry_image(organisation_id, digest, name \\ "0123456789abcdef")
      when byte_size(digest) == 64 do
    "#{Apiary.Registry.service()}/#{Apiary.InstanceConfig.registry_instance()}/" <>
      "#{Apiary.Registry.Names.organisation(organisation_id)}/targets/#{name}@sha256:#{digest}"
  end

  @doc """
  The member `member` of the documents the claim sent the registered run `run`
  (`runs.run_documents`), such as `"image_destination"`; nil where they have none.
  """
  def sent(%Run{run_documents: documents}, member) when is_binary(documents),
    do: Jason.decode!(documents)[member]

  @doc """
  An image by its digest at the `image_destination` the claim sent the registered
  prebuild `run`: `@sha256:` and `digest`, 64 lower-case hex digits.
  """
  def destination_image(%Run{} = run, digest) when byte_size(digest) == 64,
    do: sent(run, "image_destination") <> "@sha256:" <> digest

  @doc """
  Queues a prebuild of `collection` for its `environment_ref` for every live node pool
  of its workspace (`Apiary.Dispatches.queue_prebuild/3`), with its environment record:
  the prebuilds queued.
  """
  def queue_builds!(%Apiary.Adapters.Collection{workspace_id: workspace_id} = collection) do
    {:ok, queued} =
      Repo.transact(fn ->
        pools =
          Repo.all(
            from n in Apiary.Nodes.Node,
              where: n.workspace_id == ^workspace_id and n.kind == :pool,
              where: is_nil(n.deleted_at),
              order_by: n.id
          )

        {:ok,
         for pool <- pools do
           {:ok, run} = Dispatches.queue_prebuild(collection, pool, collection.environment_ref)
           run
         end}
      end)

    queued
  end

  @doc """
  A prebuild of a fresh collection of the scope's workspace, with a target and the
  `environment_ref` `env-1` unless `collection_attrs` say otherwise, queued for every
  pool of the workspace (`queue_builds!/1`), with its environment record, then claimed
  under `key`, which registers its run, and its machine started, which hands it over
  (`dispatched!/1`). The workspace has no other waiting run the pool may take. Returns `%{collection: collection, dispatch: dispatch, dispatch_run:
  run_of_queue, run: registered_run}`, each as stored then.
  """
  def prebuild_handed_over!(%Scope{} = scope, %AccessKey{} = key, collection_attrs \\ %{}) do
    collection = Apiary.NodesFixtures.collection_fixture(scope, collection_attrs)
    _queued = queue_builds!(collection)

    %{dispatch: dispatch, run: dispatch_run, registered: run} = dispatched!(key)

    %{collection: collection, dispatch: dispatch, dispatch_run: dispatch_run, run: run}
  end

  @doc """
  A second prebuild of the collection of `older`, a prebuild `prebuild_handed_over!/3`
  made and that has not ended: the collection's `environment_ref` set to `env-2` and
  queued (`queue_builds!/1`), so it is queued after `older`'s, then claimed under `key` and its machine
  started. Returns as `prebuild_handed_over!/3` does.
  """
  def newer_prebuild_handed_over!(%AccessKey{} = key, %{collection: %{id: id}}) do
    {1, _rows} =
      Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.id == ^id),
        set: [environment_ref: "env-2"]
      )

    [queued] = queue_builds!(Repo.get!(Apiary.Adapters.Collection, id))

    %{dispatch: dispatch, run: dispatch_run, registered: run} = dispatched!(key)
    true = dispatch.dispatch_run_id == queued.id

    %{
      collection: Repo.get!(Apiary.Adapters.Collection, id),
      dispatch: dispatch,
      dispatch_run: dispatch_run,
      run: run
    }
  end

  @doc """
  The enrolment request a machine sends to redeem the run code `code`, its proof under
  the key pair `pair` (`Apiary.AccessKeysFixtures.ed25519_key_pair/0`), at `at`, named
  `run-01`.
  """
  def run_code_request(code, pair, %DateTime{} = at) do
    timestamp = DateTime.to_unix(at)
    message = Apiary.Contract.SignedMessage.enrolment(code, pair.encoded, "run-01", timestamp)

    proof =
      :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])
      |> Apiary.Contract.Ed25519.encode()

    {:ok, request} =
      Apiary.Contract.Enrolment.decode(
        Jason.encode!(%{
          version: 1,
          code: code,
          name: "run-01",
          public_key: pair.encoded,
          timestamp: timestamp,
          proof: proof
        })
      )

    request
  end

  @doc """
  Redeems the run code `code` now, under a fresh key pair, as a machine does through the
  gateway the claim bound the code to: the run key (`Apiary.Runs.RunCode.redeem/2`).
  """
  def redeemed_run_key!(code) do
    pair = Apiary.AccessKeysFixtures.ed25519_key_pair()

    {:ok, %{run_key: run_key}} =
      Apiary.Runs.RunCode.redeem(run_code_request(code, pair, DateTime.utc_now()),
        relayed_by: bound_gateway(code)
      )

    run_key
  end

  @doc """
  The id of the gateway the claim bound the run code `code` to (`runs.gateway_id`), the
  node whose relay `Apiary.Runs.RunCode.redeem/2` takes it from (`relayed_by`); nil for a
  code no run has.
  """
  def bound_gateway(code) do
    [head | _fingerprints] = String.split(code, ".")
    hash = Apiary.AccessKeys.EnrolmentCode.hash(head)
    Repo.one(from r in Run, where: r.run_code_sha256 == ^hash, select: r.gateway_id)
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
