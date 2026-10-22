defmodule ApiaryWeb.Contract.SecretsControllerTest do
  # The secrets request (`POST /v1/secrets`): a run's model key, sealed to the gateway's
  # access key, and each refusal in the order of the contract and
  # `Apiary.Runs.SecretsRequest`. Not async, as the other contract tests of a
  # pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Policy, Repo, SealedOpen, SigningKey}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    scope |> sealed_run_fixture() |> Map.put(:scope, scope)
  end

  defp post_secrets(ctx, body, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.secrets_key)

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp request(ctx, attrs \\ []) do
    secrets_request(
      Keyword.get(attrs, :run, ctx.run),
      Keyword.get(attrs, :digest, ctx.attached.digest),
      Keyword.get(attrs, :credentials, [ctx.provider.public_id]),
      Keyword.get(attrs, :now, SignedRequest.now())
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp seals, do: Repo.all(from e in Entry, where: e.action == "secret.seal")

  describe "a request for a live run" do
    test "is answered the key sealed to the gateway's access key", ctx do
      {key, seed} = ctx.secrets_key
      body = request(ctx)
      assert Apiary.ForagerSchemas.validate("secrets-request.schema.json", body) == :ok

      {conn, log} = with_log(fn -> post_secrets(ctx, body) end)

      assert conn.status == 200
      assert signed_answer?(conn)
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert byte_size(conn.resp_body) <= 5 * 1024 * 1024
      assert Apiary.ForagerSchemas.validate("secrets-answer.schema.json", conn.resp_body) == :ok

      expected = %{
        access_key_id: key.key_id,
        run_id: ctx.run.node_run_id,
        run_configuration: ctx.attached.digest,
        signing_public_key: SigningKey.current().public_key,
        x25519_private_key: SealedOpen.x25519_private_key(seed)
      }

      assert {:ok, plaintext, sealed} = SealedOpen.open(conn.resp_body, expected)
      now = SignedRequest.now()
      assert sealed["exp"] in (now + 590)..(now + 610)

      assert Apiary.ForagerSchemas.validate("sealed-plaintext.schema.json", plaintext) == :ok

      name = ctx.provider.public_id

      assert plaintext ==
               ~s({"version":1,"run_configuration":"#{ctx.attached.digest}",) <>
                 ~s("credentials":["#{name}"],"values":[{"credential":"#{name}",) <>
                 ~s("value":"#{model_key()}"}]})

      # The seal is in the trail, with the run and the provider, never the value.
      assert [entry] = seals()
      assert entry.organisation_id == ctx.scope.organisation.id
      assert entry.subject_id == ctx.run.id
      assert entry.details["provider_id"] == name
      assert entry.details["credential"] == name
      refute inspect(entry) =~ model_key()
      refute log =~ model_key()
      refute log =~ conn.resp_body
    end

    test "is answered again for a second request, under a fresh ephemeral key", ctx do
      one = post_secrets(ctx, request(ctx))
      two = post_secrets(ctx, request(ctx))
      assert one.status == 200 and two.status == 200

      assert Jason.decode!(one.resp_body)["sealed"]["enc"] !=
               Jason.decode!(two.resp_body)["sealed"]["enc"]

      assert length(seals()) == 2
    end
  end

  describe "the refusals" do
    test "400 invalid_request for a body that fails the schema", ctx do
      good = Jason.decode!(request(ctx))

      for body <- [
            "not json",
            Jason.encode!(Map.put(good, "version", 2)),
            Jason.encode!(Map.put(good, "extra", true)),
            Jason.encode!(Map.delete(good, "credentials")),
            Jason.encode!(Map.put(good, "credentials", [])),
            Jason.encode!(Map.put(good, "credentials", ["a", "a"])),
            Jason.encode!(Map.put(good, "run_id", String.upcase(ctx.run.node_run_id))),
            Jason.encode!(Map.put(good, "run_configuration", "sha256=00")),
            Jason.encode!(Map.put(good, "timestamp", -1)),
            String.replace(request(ctx), ~s("version":1), ~s("version":1,"version":1))
          ] do
        conn = post_secrets(ctx, body)
        assert conn.status == 400, body
        assert code(conn) == "invalid_request"
        assert signed_answer?(conn)
      end

      assert seals() == []
    end

    test "413 for a body over 32 KiB, before the signature", ctx do
      conn = post_secrets(ctx, String.duplicate(" ", 32 * 1024 + 1))
      assert conn.status == 413
    end

    test "401, unsigned, for a timestamp outside the window", ctx do
      conn = post_secrets(ctx, request(ctx, now: SignedRequest.now() - 301))
      assert conn.status == 401
      assert unsigned_answer?(conn)
    end

    test "409 secrets_not_allowed for a key not allowed stored secrets", ctx do
      # A key of the gateway made in a browser after the handover, without the flag.
      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      conn = post_secrets(ctx, request(ctx), key: {plain, seed})
      assert conn.status == 409
      assert code(conn) == "secrets_not_allowed"
      assert signed_answer?(conn)
    end

    test "404 for a key that is not the run's gateway's", ctx do
      %{access_key: other, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(
          ctx.scope,
          Apiary.NodesFixtures.gateway_fixture(ctx.scope),
          %{allow_secrets: true}
        )

      conn = post_secrets(ctx, request(ctx), key: {other, pair.secret})
      assert conn.status == 404
      assert signed_answer?(conn)
      assert seals() == []
    end

    test "404 for a key of the run's gateway that its run key does not list", ctx do
      # Enrolled after the handover, allowed stored secrets.
      %{access_key: later, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, ctx.gateway, %{
          allow_secrets: true
        })

      conn = post_secrets(ctx, request(ctx), key: {later, pair.secret})
      assert conn.status == 404
      assert signed_answer?(conn)
      assert seals() == []
    end

    test "410, with no body, for a run that is not live", ctx do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 410
      assert conn.resp_body == ""
      assert signed_answer?(conn)
    end

    test "410 run_configuration_superseded for a digest the run is not answered now", ctx do
      stale = request(ctx, digest: "sha256=" <> String.duplicate("0", 64))
      conn = post_secrets(ctx, stale)
      assert conn.status == 410
      assert code(conn) == "run_configuration_superseded"
      assert signed_answer?(conn)

      # A policy changed since the attach: the attach's digest is superseded too.
      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "docs.example"})
      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 410
      assert code(conn) == "run_configuration_superseded"
      assert seals() == []
    end

    test "409 credentials_differ for a credential the run does not have", ctx do
      for credentials <- [["forge"], [ctx.provider.public_id, "forge"]] do
        conn = post_secrets(ctx, request(ctx, credentials: credentials))
        assert conn.status == 409
        assert code(conn) == "credentials_differ"
        assert signed_answer?(conn)
      end

      assert seals() == []
    end

    test "409 credential_unavailable for a run whose provider columns are empty", ctx do
      for set <- [
            [provider_connection_id: nil],
            [provider_secret_id: nil],
            [provider_connection_id: nil, provider_secret_id: nil]
          ] do
        run = Repo.get!(Run, ctx.run.id)
        {1, _rows} = Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: set)

        conn = post_secrets(ctx, request(ctx))
        assert conn.status == 409, inspect(set)
        assert code(conn) == "credential_unavailable"

        restore(run)
      end

      assert seals() == []
    end

    test "409 credential_unavailable for a provider row that fails its integrity code", ctx do
      # Changed after the request's digest was read from a reload.
      {1, _rows} =
        Repo.update_all(from(c in Connection, where: c.id == ^ctx.provider.id),
          set: [name: "Changed past the save"]
        )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{ctx.provider.public_id} fails its integrity code"
      refute log =~ model_key()
    end

    test "409 credential_unavailable for a key whose row is not the one written", ctx do
      {1, _rows} =
        Repo.update_all(
          from(v in Value, where: v.secret_id == ^ctx.run.provider_secret_id),
          set: [nonce: :crypto.strong_rand_bytes(12)]
        )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "cannot be decrypted"
      refute log =~ model_key()
      assert seals() == []
    end

    test "409 credential_unavailable for a key the run no longer has", ctx do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [provider_value_id: "gone"]
        )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{ctx.provider.public_id} cannot be read (not_found)"
    end

    test "409 credential_unavailable for a provider of another organisation", ctx do
      %{scope: other} = sign_up_fixture()
      %{provider: theirs} = sealed_run_fixture(other)

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
          conn =
            post_secrets(ctx, request(ctx, digest: digest, credentials: [theirs.public_id]))

          assert conn.status == 409
          assert code(conn) == "credential_unavailable"
        end)

      assert log =~ "#{theirs.public_id} may not be sealed for its gateway (organisation)"
      refute log =~ model_key()
      assert seals() == []
    end

    test "409 credential_unavailable for a key whose public key fails a key check", ctx do
      %{public_key: fixture, seed: fixture_seed} = fixture_key!("gateway_key")
      {key, _seed} = ctx.secrets_key

      # A key of the gateway with the fixture's public key, written past the key checks,
      # which refuse it: the request verifies under it, and nothing is sealed to it.
      row =
        %Apiary.AccessKeys.AccessKey{
          id: Ecto.UUID.generate(),
          organisation_id: key.organisation_id,
          workspace_id: key.workspace_id,
          node_id: key.node_id,
          key_id: Apiary.AccessKeys.AccessKey.generate_key_id(),
          public_key: fixture,
          created_by_id: ctx.scope.user.id,
          arrived_by: :browser,
          received_at: DateTime.utc_now()
        }
        |> Apiary.AccessKeys.AccessKey.insert_changeset(%{allow_secrets: true, label: "fixture"})
        |> Apiary.AccessKeys.AccessKey.put_integrity()
        |> Repo.insert!()

      list_key!(ctx.run, fixture)

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx), key: {row, fixture_seed}) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert signed_answer?(conn)
      assert log =~ "fails the key check fixture"
      assert seals() == []
    end
  end

  # The run's run key payload with `public_key` added to the gateway's keys it lists, as
  # a handover would have written it had the gateway held that key then.
  defp list_key!(%Run{id: id}, public_key) do
    %Run{run_key_payload: payload} = Repo.get!(Run, id)
    %Jason.OrderedObject{values: values} = Jason.decode!(payload, objects: :ordered_objects)

    values =
      Enum.map(values, fn
        {"gateway_public_key", keys} ->
          entry =
            Jason.OrderedObject.new(
              alg: "ed25519",
              public_key: Apiary.Contract.Ed25519.encode(public_key)
            )

          {"gateway_public_key", keys ++ [entry]}

        member ->
          member
      end)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [run_key_payload: Jason.encode!(Jason.OrderedObject.new(values))]
      )
  end

  defp restore(%Run{} = run) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          provider_connection_id: run.provider_connection_id,
          provider_secret_id: run.provider_secret_id,
          provider_value_id: run.provider_value_id,
          provider_api: run.provider_api
        ]
      )
  end
end
