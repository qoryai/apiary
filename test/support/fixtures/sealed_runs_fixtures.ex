defmodule Apiary.SealedRunsFixtures do
  @moduledoc """
  Test helpers for a run whose model key a gateway fetches with the secrets request: a
  model provider of the scope's organisation with one key, chosen at the workspace, and a
  run of the workspace's queue handed over with it and attached by the gateway, under a
  key of the gateway allowed stored secrets.
  """

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Runs.{Attach, Run}

  @model_key "sk-ant-fixture-model-key-0123456789"
  @body ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

  @doc "The value of the provider's key, as `sealed_run_fixture/1` stores it."
  def model_key, do: @model_key

  @doc """
  A run handed over with an `anthropic` provider of the scope's organisation, whose one key
  is `model_key/0` under the value id `main`, and attached by the gateway of
  `Apiary.DispatchedRunsFixtures.handover_place_fixture/2`, under the gateway's one key,
  allowed stored secrets. Returns the place's map with `provider`, `run` (as stored after
  the attach), `attached` (the attach's answer: `settings`, its bytes, and `digest`) and
  `secrets_key: {key, seed}`.
  """
  def sealed_run_fixture(%Scope{} = scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: @model_key}]
      })

    {:ok, _choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})

    place = Apiary.DispatchedRunsFixtures.handover_place_fixture(scope, allow_secrets: true)
    {key, seed} = place.gateway_key

    work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    %{dispatch: dispatch} = Apiary.DispatchedRunsFixtures.dispatched!(place.key)
    {:ok, handed} = Dispatches.handover(place.key, dispatch.public_id, %{body: @body})

    {:ok, attach} = Attach.parse(Apiary.ContractFixtures.attach_body(handed.run_key))

    {:ok, attached} =
      Attach.attach(key, handed.run.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: Apiary.ContractFixtures.instance_id()
      })

    Map.merge(place, %{
      provider: provider,
      run: Repo.get!(Run, handed.run.id),
      attached: attached,
      secrets_key: {key, seed}
    })
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
