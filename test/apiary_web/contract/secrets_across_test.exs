defmodule ApiaryWeb.Contract.SecretsAcrossTest do
  # The instance's gateway, which serves every organisation, at the secrets request: a
  # run's model key of the organisation's chain (`Apiary.Runs.ProviderCredential`) and its
  # work credential (`Apiary.Runs.WorkCredential`) are sealed for it, in the run's
  # organisation's trail; the instance pool's key gets none. Which gateways a key may be
  # sealed for is in `Apiary.Runs.ProviderCredentialTest` and
  # `Apiary.Runs.WorkCredentialTest`.
  # Not async, as the other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures, only: [stored_keys: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{
    AccessKeys,
    Connections,
    Dispatches,
    ModelChoicesFixtures,
    Repo,
    WorkCredentialStub
  }

  alias Apiary.Audit.Entry
  alias Apiary.Runs.{Attach, Registration, Run, Sender}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: model_key()}]
      })

    %{scope: scope, other: other, provider: provider}
  end

  # The instance's gateway, the default of every workspace that has no other default, with
  # one key allowed stored secrets.
  defp instance_gateway do
    %{access_key: key, pair: pair} =
      installed_key_fixture(instance_gateway_fixture(), allow_secrets: true)

    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)
    {key, pair.secret}
  end

  # A pool of the scope's workspace, whose choice is the default (the instance's gateway),
  # and an explore run of a fresh work item claimed by its key: `{:ok, %{run: run,
  # run_key: run_key}}`, the registered run and the run key its code was redeemed for, or
  # `{:error, :gone}` for a run the claim ended; and the run of the queue.
  #
  # With `apply`, the work item's adapter declares those apply items and its ticket's
  # collection can change its target (`Apiary.WorkItemsFixtures.target_candidate!/1`), so
  # the run has the work entry `work-1`, and the map also has `adapter_seed`, to sign the stub adapter's
  # answers with (`Apiary.SealedRunsFixtures.callable_adapter_fixture/2`).
  defp hand_over(ctx_or_scope, apply \\ nil)

  defp hand_over(%{scope: scope}, apply), do: hand_over(scope, apply)

  defp hand_over(scope, apply) do
    pool = pool_fixture(scope)
    :default = pool.gateway_choice
    %{access_key: pool_key} = enrolled_key_fixture(scope, pool)
    work_item = work_item_fixture(scope)
    adapter = if apply, do: callable_adapter_fixture(work_item.adapter_id, apply), else: %{}
    if apply, do: target_candidate!(work_item)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    case Apiary.DispatchedRunsFixtures.walked_claim(pool_key, Dispatches.now()) do
      {:ok, :none} ->
        {{:error, :gone}, queued}

      {:ok, claimed} ->
        run_key = redeemed_run_key!(claimed.run_code)
        handed = %{run: claimed.registered, run_key: run_key}
        {{:ok, Map.merge(handed, Map.take(adapter, [:adapter_seed]))}, queued}
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

  # The digest a reload of `run` by `key` returns now.
  defp digest({key, _seed}, run) do
    {:ok, %{digest: digest}} = Registration.fetch(key, run.node_run_id, instance_id())
    digest
  end

  defp post_secrets({key, seed}, run, digest, provider) do
    body = secrets_request(run, digest, ["#{provider.public_id}-1"], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  defp seals_of(scope),
    do: Enum.filter(seals(), &(&1.organisation_id == scope.organisation.id))

  @apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
  ]
  @entry_apply [
    %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/acme/shop/*"]}
  ]
  @token "fixture-work-token-across-0001"

  defp issues, do: Repo.all(from e in Entry, where: e.action == "run_credential.issue")

  # The secrets request for the run's work entry alone, its credential issued by the stub
  # adapter.
  defp post_work({key, seed}, handed, run, digest) do
    WorkCredentialStub.issue(
      handed.adapter_seed,
      WorkCredentialStub.credential(@token, @entry_apply)
    )

    body = secrets_request(run, digest, ["work-1"], SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  describe "a run's work credential" do
    test "is sealed for the instance's gateway, in the run's organisation's trail", ctx do
      gateway_key = instance_gateway()
      {{:ok, handed}, _queued} = hand_over(ctx, @apply)
      run = attach!(gateway_key, handed)

      conn = post_work(gateway_key, handed, run, digest(gateway_key, run))
      assert conn.status == 200, conn.resp_body

      {key, _seed} = gateway_key
      assert [%Entry{} = entry] = issues()
      assert entry.organisation_id == ctx.scope.organisation.id
      assert entry.workspace_id == ctx.scope.workspace.id
      assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
    end
  end

  describe "the instance's gateway" do
    test "is sealed a key of each organisation's chain, in each run's organisation's trail",
         ctx do
      gateway_key = instance_gateway()

      {:ok, theirs} =
        Connections.create_provider(ctx.other, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: model_key()}]
        })

      for {scope, provider} <- [{ctx.scope, ctx.provider}, {ctx.other, theirs}] do
        {:ok, _choice} =
          ModelChoicesFixtures.put_choice(scope, :workspace, %{
            provider: provider.public_id
          })

        {{:ok, handed}, _queued} = hand_over(scope)
        run = attach!(gateway_key, handed)
        assert run.organisation_id == scope.organisation.id
        assert [%{chain: "organisation"}] = stored_keys(run)

        conn = post_secrets(gateway_key, run, digest(gateway_key, run), provider)
        assert conn.status == 200
        assert signed_answer?(conn)

        # In the run's organisation's trail, about the run, by the gateway's key.
        {key, _seed} = gateway_key
        assert [%Entry{} = entry] = seals_of(scope)
        assert {entry.subject_kind, entry.subject_id} == {"run", run.id}
        assert entry.workspace_id == scope.workspace.id
        assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}
        assert entry.details["provider_id"] == provider.public_id
      end

      assert length(seals()) == 2
    end

    test "the instance pool's key is never sealed the key of a run it claimed", ctx do
      gateway_key = instance_gateway()

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
          provider: ctx.provider.public_id
        })

      %{access_key: pool_key, pair: pair} =
        installed_key_fixture(instance_pool_fixture(), allow_secrets: true)

      {:ok, pool_key} = AccessKeys.fetch_for_verification(pool_key.key_id)

      # The scope's workspace has no pool in use: the instance's pool claims its run,
      # which goes through the instance's gateway.
      work_item = work_item_fixture(ctx.scope)
      {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {:ok, claimed} = Apiary.DispatchedRunsFixtures.walked_claim(pool_key, Dispatches.now())
      handed = %{run: claimed.registered, run_key: redeemed_run_key!(claimed.run_code)}
      run = attach!(gateway_key, handed)
      assert run.node_id == pool_key.node_id
      digest = digest(gateway_key, run)

      # The pool's key reads the run, as its pool claimed it: the refusal is of the key,
      # which the run key does not list among the gateway's keys.
      assert %Run{id: id} = Repo.one(Sender.run_query(pool_key, run.node_run_id))
      assert id == run.id

      conn = post_secrets({pool_key, pair.secret}, run, digest, ctx.provider)
      assert conn.status == 404
      assert code(conn) == "not_found"
      assert seals() == []
    end
  end
end
