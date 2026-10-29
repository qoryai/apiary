defmodule Apiary.SealedRunsFixtures do
  @moduledoc """
  Test helpers for a run whose model key a gateway fetches with the secrets request: a
  model provider of the scope's organisation with one key, chosen at the workspace, and a
  run of the workspace's queue claimed with it, its run code redeemed, and attached by the
  gateway, under a key of the gateway allowed stored secrets.
  """

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Runs.{Attach, Run}

  @model_key "sk-ant-fixture-model-key-0123456789"

  @doc "The value of the provider's key, as `sealed_run_fixture/1` stores it."
  def model_key, do: @model_key

  @doc """
  A run claimed with an `anthropic` provider of the scope's organisation, whose one key
  is `model_key/0` under the value id `main`, and attached by the gateway of
  `Apiary.DispatchedRunsFixtures.handover_place_fixture/2`, under the gateway's one key,
  allowed stored secrets. Returns the place's map with `provider`, `run` (as stored after
  the attach), `attached` (the attach's answer: `settings`, its bytes, and `digest`) and
  `secrets_key: {key, seed}`.

  With `work: apply`, the work item's adapter declares the apply items `apply` before the
  claim, and its ticket's collection can change the work item's target
  (`Apiary.WorkItemsFixtures.target_candidate!/1`), so the run has the work entry
  `work-1` (`Apiary.Runs.RunCredentials.form_work/3`), and the adapter has an access key in use
  and a `call_url` that the calls' stub answers (`Req.Test`, `Apiary.Adapters.Calls`).
  The map then also has `adapter` and `adapter_seed`, the seed of the adapter's key, to
  sign the stub's answers with.

  With `place: :workspace`, the provider is added for the scope's workspace alone, its key
  a secret of that workspace (`Apiary.Connections.create_provider/3`).
  """
  def sealed_run_fixture(%Scope{} = scope, opts \\ []) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{provider: "anthropic", keys: [%{value_id: "main", value: @model_key}]},
        Keyword.get(opts, :place, :organisation)
      )

    {:ok, _choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    place = Apiary.DispatchedRunsFixtures.handover_place_fixture(scope, allow_secrets: true)
    {key, seed} = place.gateway_key

    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    adapter = if apply = opts[:work], do: callable_adapter_fixture(work_item.adapter_id, apply)
    if opts[:work], do: Apiary.WorkItemsFixtures.target_candidate!(work_item)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, claimed} = Dispatches.claim(place.key, Dispatches.now())
    run_key = Apiary.DispatchedRunsFixtures.redeemed_run_key!(claimed.run_code)

    {:ok, attach} = Attach.parse(Apiary.ContractFixtures.attach_body(run_key))

    {:ok, attached} =
      Attach.attach(key, claimed.registered.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: Apiary.ContractFixtures.instance_id()
      })

    place
    |> Map.merge(%{
      provider: provider,
      run: Repo.get!(Run, claimed.registered.id),
      attached: attached,
      secrets_key: {key, seed}
    })
    |> Map.merge(adapter || %{})
  end

  @doc """
  Makes the adapter `adapter_id` declare the apply items `apply`, and gives it an access
  key in use and a call address under `.localhost`, which the test resolver
  (`Apiary.FetchStub`) and the calls' stub answer. Returns `%{adapter: adapter,
  adapter_seed: seed}`, the seed of its key, to sign the stub's answers with
  (`Apiary.WorkCredentialStub`).
  """
  def callable_adapter_fixture(adapter_id, apply) do
    adapter = Repo.get!(Node, adapter_id)

    %{pair: pair} =
      Apiary.AccessKeysFixtures.enrolled_key_fixture(
        Apiary.OrganisationsFixtures.instance_admin_scope(),
        adapter
      )

    {1, _rows} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter_id),
        set: [
          source_apply: apply,
          call_url: "https://#{adapter.name}.localhost/calls/",
          call_instance_id: "instance-1"
        ]
      )

    %{adapter: Repo.get!(Node, adapter_id), adapter_seed: pair.secret}
  end

  @doc """
  The body of a secrets request for `run` and the digest `digest`, with `credentials`,
  at `now` (Unix seconds).
  """
  def secrets_request(%Run{node_run_id: run_id}, digest, credentials, now) do
    Jason.encode!(
      Jason.OrderedObject.new(
        version: 1,
        run_id: run_id,
        run_configuration: digest,
        credentials: credentials,
        timestamp: now
      )
    )
  end
end
