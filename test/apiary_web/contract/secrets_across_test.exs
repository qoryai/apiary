defmodule ApiaryWeb.Contract.SecretsAcrossTest do
  # A run's model key and the gateway's organisation (`Apiary.Runs.ProviderCredential`):
  # a key of a provider of the organisation's chain goes only to a gateway of the run's
  # organisation, and a key of a provider of an operator's chain only to a gateway of an
  # operator that serves the run's organisation, at the claim and at the secrets
  # request. The edition's seams are `Apiary.EditionStubs.ServesAcrossWithChain`: the
  # operator's organisation-level gateways serve the client's workspaces. Not async, as the
  # other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{AccessKeys, Connections, Dispatches, Edition, EditionStubs, ModelChoices, Repo}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Kinds.Coded
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Runs.{Attach, Registration, Run}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  @api %{
    "format" => "anthropic-messages",
    "endpoint" => "https://api.anthropic.com",
    "auth" => %{"scheme" => "header", "header" => "x-api-key"}
  }

  setup do
    %{scope: client} = sign_up_fixture()
    %{scope: operator} = sign_up_fixture()
    :ok = Edition.put_test_stub(EditionStubs.ServesAcrossWithChain)
    EditionStubs.ServesAcross.put([{operator.organisation.id, client.organisation.id}])

    {:ok, provider} =
      Connections.create_provider(client, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: model_key()}]
      })

    %{client: client, operator: operator, provider: provider}
  end

  # A gateway with one key allowed stored secrets, as a verified request carries it, and
  # the key's seed.
  defp keyed(scope, gateway) do
    %{access_key: key, pair: pair} = enrolled_key_fixture(scope, gateway, %{allow_secrets: true})
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {key, pair.secret}
  end

  defp operator_gateway(ctx), do: keyed(ctx.operator, organisation_gateway_fixture(ctx.operator))
  defp client_gateway(ctx), do: keyed(ctx.client, gateway_fixture(ctx.client))

  # A pool of the client's workspace, made after its gateway, whose choice is the default,
  # and an explore run of a fresh work item claimed by its key: `{:ok, %{run: run,
  # run_key: run_key}}`, the registered run and the run key its code was redeemed for, or
  # `{:error, :gone}` for a run the claim ended; and the run of the queue.
  defp hand_over(ctx) do
    pool = pool_fixture(ctx.client)
    :default = pool.gateway_choice
    %{access_key: pool_key} = enrolled_key_fixture(ctx.client, pool)
    work_item = work_item_fixture(ctx.client)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    case Dispatches.claim(pool_key, Dispatches.now()) do
      {:ok, :none} ->
        {{:error, :gone}, queued}

      {:ok, claimed} ->
        run_key = redeemed_run_key!(claimed.run_code)
        {{:ok, %{run: claimed.registered, run_key: run_key}}, queued}
    end
  end

  defp attach!({key, _seed}, handed) do
    {:ok, attach} = Attach.parse(attach_body(handed.run_key))

    {:ok, _attached} =
      Attach.attach(key, handed.run.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: instance_id()
      })

    Repo.get!(Run, handed.run.id)
  end

  # The provider written on the run past the claim, as a run whose claim set it would keep
  # it.
  defp set_provider!(%Run{id: id}, provider, chain) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [
          provider_connection_id: provider.id,
          provider_secret_id: provider.secret_id,
          provider_value_id: "main",
          provider_chain: chain,
          provider_api: @api
        ]
      )

    Repo.get!(Run, id)
  end

  # The provider moved to an operator's chain, coded again as a save codes it, with a
  # choice of the operator's chain for the client's workspace; the edition then returns
  # "operator" for every organisation.
  defp operator_chain!(ctx, choose? \\ true) do
    if choose? do
      {:ok, %ModelChoice{} = choice} =
        ModelChoices.put_choice(ctx.client, :workspace, %{provider: ctx.provider.public_id})

      Repo.insert!(%ModelChoice{
        choice
        | id: Ecto.UUID.generate(),
          chain: "operator",
          inserted_at: nil,
          updated_at: nil
      })
    end

    provider =
      Connection
      |> Repo.get!(ctx.provider.id)
      |> Ecto.Changeset.change(chain: "operator")
      |> Coded.seal()
      |> Repo.update!()

    EditionStubs.ServesAcrossWithChain.chain("operator")
    provider
  end

  # The digest a reload of `run` by `key` returns now.
  defp digest({key, _seed}, run) do
    {:ok, %{digest: digest}} = Registration.fetch(key, run.node_run_id, instance_id())
    digest
  end

  defp post_secrets({key, seed}, run, digest, provider) do
    body = secrets_request(run, digest, [provider.public_id], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  defp ended!(queued) do
    assert %DispatchRun{state: :ended, end_cause: :secrets_not_allowed, result_outcome: :error} =
             Repo.get!(DispatchRun, queued.id)

    assert Repo.aggregate(from(r in Run, where: r.dispatch_run_id == ^queued.id), :count) == 0
  end

  describe "a provider of the organisation's chain" do
    test "ends the run at the claim through an operator's gateway", ctx do
      operator_gateway(ctx)

      {:ok, _choice} =
        ModelChoices.put_choice(ctx.client, :workspace, %{provider: ctx.provider.public_id})

      {answer, queued} = hand_over(ctx)
      assert answer == {:error, :gone}
      ended!(queued)
    end

    test "is not sealed for an operator's gateway that serves the client", ctx do
      gateway_key = operator_gateway(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = gateway_key |> attach!(handed) |> set_provider!(ctx.provider, "organisation")

      {conn, log} =
        with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), ctx.provider) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert signed_answer?(conn)
      assert log =~ "#{ctx.provider.public_id} may not be sealed for its gateway (gateway)"
      refute log =~ model_key()
      assert seals() == []
    end
  end

  describe "a provider of an operator's chain" do
    test "is sealed for the operator's gateway, in the operator's trail", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)

      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      assert run.provider_chain == "operator"

      conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
      assert conn.status == 200
      assert signed_answer?(conn)
      # In the operator's trail, about its gateway, with the run's id.
      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = seals()
      assert entry.organisation_id == ctx.operator.organisation.id
      assert {entry.subject_kind, entry.subject_id} == {"node", key.node_id}
      assert entry.details["run_id"] == run.node_run_id
    end

    test "is refused once the organisation's chain is no longer the operator's", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcrossWithChain.chain("organisation")

      {conn, log} = with_log(fn -> post_secrets(gateway_key, run, digest, provider) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "may not be sealed for its gateway (gateway)"
      assert seals() == []
    end

    test "410 workspace_not_served once the operator no longer serves the client", ctx do
      gateway_key = operator_gateway(ctx)
      provider = operator_chain!(ctx)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = attach!(gateway_key, handed)
      digest = digest(gateway_key, run)

      EditionStubs.ServesAcross.switch(:off)

      conn = post_secrets(gateway_key, run, digest, provider)
      assert conn.status == 410
      assert code(conn) == "workspace_not_served"
      assert signed_answer?(conn)
      assert seals() == []
    end

    test "ends the run at the claim through the client's gateway", ctx do
      client_gateway(ctx)
      operator_chain!(ctx)

      {answer, queued} = hand_over(ctx)
      assert answer == {:error, :gone}
      ended!(queued)
    end

    test "is not sealed for the client's gateway", ctx do
      gateway_key = client_gateway(ctx)
      # No choice of the operator's chain: the run is claimed with the runtime alone.
      provider = operator_chain!(ctx, false)
      {{:ok, handed}, _queued} = hand_over(ctx)
      run = gateway_key |> attach!(handed) |> set_provider!(provider, "operator")

      {conn, log} =
        with_log(fn -> post_secrets(gateway_key, run, digest(gateway_key, run), provider) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{provider.public_id} may not be sealed for its gateway (gateway)"
      assert seals() == []
    end
  end
end
