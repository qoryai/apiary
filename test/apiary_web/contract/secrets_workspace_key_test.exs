defmodule ApiaryWeb.Contract.SecretsWorkspaceKeyTest do
  # The secrets request (`POST /v1/secrets`) for a run whose model provider was added for
  # its workspace alone: the key, a secret of that workspace, is read under the
  # workspace's data key and sealed for a run of that workspace, and refused for a run of
  # another workspace (`Apiary.Runs.SecretsRequest`). Not async, as the other contract
  # tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, Repo, SealedOpen, SigningKey}
  alias Apiary.Audit.Entry
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Secret
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{scope: scope} = sign_up_fixture()
    scope |> sealed_run_fixture(place: :workspace) |> Map.put(:scope, scope)
  end

  defp post_secrets(ctx, body) do
    {key, seed} = ctx.secrets_key

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp request(ctx, attrs \\ []) do
    secrets_request(
      ctx.run,
      Keyword.get(attrs, :digest, ctx.attached.digest),
      Keyword.get(attrs, :credentials, [ctx.provider.public_id]),
      SignedRequest.now()
    )
  end

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  test "a key of the run's workspace is sealed to the gateway", ctx do
    assert %Secret{workspace_id: workspace_id} = Repo.get!(Secret, ctx.provider.secret_id)
    assert workspace_id == ctx.scope.workspace.id
    assert ctx.run.workspace_id == workspace_id

    {key, seed} = ctx.secrets_key
    {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
    assert conn.status == 200

    expected = %{
      access_key_id: key.key_id,
      run_id: ctx.run.node_run_id,
      run_configuration: ctx.attached.digest,
      signing_public_key: SigningKey.current().public_key,
      x25519_private_key: SealedOpen.x25519_private_key(seed)
    }

    assert {:ok, plaintext, _sealed} = SealedOpen.open(conn.resp_body, expected)
    assert plaintext =~ ~s("value":"#{model_key()}")
    assert [_entry] = seals()
    refute log =~ model_key()
  end

  test "a key of another workspace is refused, and nothing is sealed", ctx do
    billing = workspace_fixture(ctx.scope.organisation, "Billing")
    billing_scope = workspace_scope(ctx.scope.user, billing)

    {:ok, theirs} =
      Connections.create_provider(
        billing_scope,
        %{provider: "anthropic", keys: [%{value_id: "main", value: "sk-billing-key-0123"}]},
        :workspace
      )

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [provider_connection_id: theirs.id, provider_secret_id: theirs.secret_id]
      )

    # The digest of what a reload returns now, which contains their provider.
    {key, _seed} = ctx.secrets_key

    {:ok, %{digest: digest}} =
      Apiary.Runs.Registration.fetch(key, ctx.run.node_run_id, instance_id())

    log =
      capture_log(fn ->
        conn = post_secrets(ctx, request(ctx, digest: digest, credentials: [theirs.public_id]))
        assert conn.status == 409
        assert Jason.decode!(conn.resp_body)["error"] == "credential_unavailable"
      end)

    assert log =~ "#{theirs.public_id} may not be sealed for its gateway (workspace)"
    refute log =~ "sk-billing-key-0123"
    assert seals() == []
  end
end
