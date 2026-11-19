defmodule ApiaryWeb.Contract.SecretsControllerTest do
  # The secrets request (`POST /v1/secrets`): a run's model key, sealed to the gateway's
  # access key, and each refusal in the order of the contract and
  # `Apiary.Runs.SecretsRequest`; and a run's work entry, whose credential the stub
  # adapter issues (`Apiary.Runs.WorkCredential`). Not async, as the other contract tests
  # of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [capture_log: 1, capture_log: 2, with_log: 1]
  import Apiary.ContractFixtures
  import Apiary.ModelKeysFixtures, only: [stored_keys: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Policy, Repo, SealedOpen, SigningKey, WorkCredentialStub}
  alias Apiary.Adapters.Collection
  alias Apiary.Audit.Entry
  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelKeys.Copy
  alias Apiary.Runs.{ModelKey, Run, RunCredential}
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  # Without the `registry` feature, whose credential `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  # The apply items the work item's adapter declares for a test tagged `work`, and the
  # work entry's items they fill with the target's path, `acme/shop`.
  @apply [
    %{
      "hosts" => ["git.example.com"],
      "scheme" => "basic",
      "username" => "x-access",
      "paths" => ["/{target.path}.git/*", "/{target.path}/*"]
    }
  ]

  @entry_apply [
    %{
      "hosts" => ["git.example.com"],
      "scheme" => "basic",
      "username" => "x-access",
      "paths" => ["/acme/shop.git/*", "/acme/shop/*"]
    }
  ]

  @token "fixture-work-token-for-tests-only-7f3a"
  @push_token "fixture-push-token-for-tests-only-91c2"
  @branch "refs/heads/qory/wi_0123456789abcdef"

  setup ctx do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    opts = if ctx[:work], do: [work: @apply], else: []
    scope |> sealed_run_fixture(opts) |> Map.put(:scope, scope)
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
      Keyword.get(attrs, :credentials, [start(ctx)]),
      Keyword.get(attrs, :now, SignedRequest.now())
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

  # The credential name of the run's start key, its first: the provider's public id and
  # its place.
  defp start(ctx), do: "#{ctx.provider.public_id}-1"

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

      name = start(ctx)

      assert plaintext ==
               ~s({"version":1,"run_configuration":"#{ctx.attached.digest}",) <>
                 ~s("credentials":["#{name}"],"values":[{"credential":"#{name}",) <>
                 ~s("value":"#{model_key()}"}]})

      # The seal is in the trail, with the run and the provider, never the value.
      assert [entry] = seals()
      assert entry.organisation_id == ctx.scope.organisation.id
      assert entry.subject_id == ctx.run.id
      assert entry.details["provider_id"] == ctx.provider.public_id
      assert entry.details["credential"] == name
      assert entry.details["credentials"] == [name]
      refute inspect(entry) =~ model_key()
      refute log =~ model_key()
      refute log =~ conn.resp_body
    end

    test "is answered only the keys it names, of the run's keys" do
      # A run of another organisation, with two keys: the provider's default key, spare,
      # then main.
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})

      ctx =
        sealed_run_fixture(scope,
          keys: [
            %{value_id: "main", value: model_key()},
            %{value_id: "spare", value: "sk-ant-spare-0123456789"}
          ],
          before_claim: fn provider ->
            {:ok, _provider} = Apiary.Connections.put_default_key(scope, provider, "spare")
          end
        )

      p = ctx.provider.public_id

      for {names, values} <- [
            {["#{p}-1"], ["sk-ant-spare-0123456789"]},
            {["#{p}-2"], [model_key()]},
            {["#{p}-1", "#{p}-2"], ["sk-ant-spare-0123456789", model_key()]}
          ] do
        conn = post_secrets(ctx, request(ctx, credentials: names))
        assert conn.status == 200, inspect(names)
        {_bytes, plaintext} = opened(ctx, conn)
        assert Enum.map(plaintext["values"], & &1["credential"]) == names
        assert Enum.map(plaintext["values"], & &1["value"]) == values
        assert names in Enum.map(seals(), & &1.details["credentials"])
      end
    end

    test "keeps when the value it sealed was set, the last request's", ctx do
      %{secret_value_id: id} = hd(stored_keys(ctx.run))
      value = Repo.get!(Value, id)
      copies = fn -> Repo.all(from c in Copy, where: c.run_id == ^ctx.run.id) end

      assert post_secrets(ctx, request(ctx)).status == 200
      assert [%Copy{secret_value_id: ^id, value_set_at: set_at}] = copies.()
      assert set_at == value.value_set_at

      # A new value of the key: the next request seals it, and keeps its time.
      {:ok, _provider} =
        Apiary.Connections.set_provider_key(
          ctx.scope,
          ctx.provider,
          value.value_id,
          "sk-ant-new-0123456789",
          nil
        )

      assert post_secrets(ctx, request(ctx)).status == 200
      assert [%Copy{value_set_at: new_set_at}] = copies.()
      assert new_set_at == Repo.get!(Value, id).value_set_at
      assert DateTime.after?(new_set_at, set_at)
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

    @tag needs: [:factory, :observability]
    test "200 for a running run a member cancelled, while it is live", ctx do
      assert post_secrets(ctx, request(ctx)).status == 200

      # Running, as a member can cancel it.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [state: "running", started_at: DateTime.utc_now()]
        )

      {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))

      # The gateway opens the run and ends it at its next batch, by the `end` there.
      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200
      assert signed_answer?(conn)
    end

    test "200 for a run lost after its attach and not lost for good", ctx do
      lost!(ctx, [])

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200
      assert signed_answer?(conn)
      assert [_entry] = seals()
    end

    test "410, with no body, for a run lost for good, or lost with its exit or pruned events",
         ctx do
      for changes <- ended_lost_cases() do
        ended_lost!(ctx, changes)

        conn = post_secrets(ctx, request(ctx))
        assert conn.status == 410
        assert conn.resp_body == ""
        assert signed_answer?(conn)
      end

      assert seals() == []
    end

    test "a run lost and not lost for good keeps its provider from deletion until lost for good",
         ctx do
      {:ok, _choice} = Apiary.ModelChoices.delete_choice(ctx.scope, :workspace)
      lost!(ctx, [])

      assert Connections.delete_provider(ctx.scope, ctx.provider) ==
               {:error, {:provider_in_use, %{places: [], runs: [ctx.run.public_id]}}}

      for changes <- ended_lost_cases() do
        ended_lost!(ctx, changes)

        assert {:error, :deleted} =
                 Repo.transaction(fn ->
                   {:ok, _deleted} = Connections.delete_provider(ctx.scope, ctx.provider)
                   Repo.rollback(:deleted)
                 end)
      end
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

    # A run claimed before runs kept their keys as rows has none: its run configuration no
    # longer has its model keys, so the digest its gateway read at the attach is
    # superseded.
    test "410 run_configuration_superseded for a run whose key rows are gone since its digest was read",
         ctx do
      assert {count, _rows} =
               Repo.delete_all(from k in ModelKey, where: k.run_id == ^ctx.run.id)

      assert count > 0

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 410
      assert code(conn) == "run_configuration_superseded"
      assert signed_answer?(conn)
      assert seals() == []
    end

    test "409 credentials_differ for a credential the run does not have", ctx do
      for credentials <- [["forge"], [start(ctx), "forge"], [ctx.provider.public_id]] do
        conn = post_secrets(ctx, request(ctx, credentials: credentials))
        assert conn.status == 409
        assert code(conn) == "credentials_differ"
        assert signed_answer?(conn)
      end

      assert seals() == []
    end

    test "409 credential_unavailable for a run whose key rows have no provider or secret",
         ctx do
      for set <- [
            [connection_id: nil],
            [secret_id: nil],
            [connection_id: nil, secret_id: nil]
          ] do
        keys = stored_keys(ctx.run)

        {1, _rows} =
          Repo.update_all(from(k in ModelKey, where: k.run_id == ^ctx.run.id), set: set)

        {conn, _log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
        assert conn.status == 409, inspect(set)
        assert code(conn) == "credential_unavailable"

        restore(keys)
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
          from(v in Value, where: v.secret_id == ^ctx.provider.secret_id),
          set: [nonce: :crypto.strong_rand_bytes(12)]
        )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "cannot be decrypted"
      refute log =~ model_key()
      assert seals() == []
    end

    test "409 credential_unavailable for a key deleted since the claim", ctx do
      {:ok, _provider} =
        Apiary.Connections.add_provider_key(ctx.scope, provider(ctx), %{
          value_id: "spare",
          value: "sk-ant-spare-0123456789"
        })

      {:ok, _provider} = Apiary.Connections.put_default_key(ctx.scope, provider(ctx), "spare")
      {:ok, _provider} = Apiary.Connections.delete_provider_key(ctx.scope, provider(ctx), "main")

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"

      assert log =~
               "the key #{start(ctx)} of the model provider #{ctx.provider.public_id} " <>
                 "cannot be read (not_found)"

      refute log =~ model_key()
      assert seals() == []
    end

    test "a key renamed since the claim is revealed under its new value id", ctx do
      # The default key is not renamed: another key becomes the default first.
      {:ok, _provider} =
        Apiary.Connections.add_provider_key(ctx.scope, provider(ctx), %{
          value_id: "spare",
          value: "sk-ant-spare-0123456789"
        })

      {:ok, _provider} = Apiary.Connections.put_default_key(ctx.scope, provider(ctx), "spare")

      {:ok, _provider} =
        Apiary.Connections.rename_provider_key(ctx.scope, provider(ctx), "main", "renamed")

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200
      assert {_bytes, %{"values" => [value]}} = opened(ctx, conn)
      assert value == %{"credential" => start(ctx), "value" => model_key()}
    end

    test "409 credential_unavailable for a key of another organisation on the run's list",
         ctx do
      %{scope: other} = sign_up_fixture()
      %{provider: theirs} = sealed_run_fixture(other)
      [theirs_key] = Repo.all(from v in Value, where: v.secret_id == ^theirs.secret_id)

      # The run's key row, written past the claim, has their key's row id in place of the
      # run's key's.
      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.run_id == ^ctx.run.id),
          set: [secret_value_id: theirs_key.id]
        )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "the key #{start(ctx)} of the model provider"
      refute log =~ model_key()
      assert seals() == []
    end

    test "409 credentials_differ for a key of the provider not on the run's list", ctx do
      {:ok, _provider} =
        Apiary.Connections.add_provider_key(ctx.scope, provider(ctx), %{
          value_id: "spare",
          value: "sk-ant-spare-0123456789"
        })

      # The provider's second key came after the claim: the run's list has the one key,
      # and a request for a second name finds no such credential.
      conn =
        post_secrets(ctx, request(ctx, credentials: [start(ctx), "#{ctx.provider.public_id}-2"]))

      assert conn.status == 409
      assert code(conn) == "credentials_differ"
      assert seals() == []
    end

    test "409 credential_unavailable for a provider of another organisation", ctx do
      %{scope: other} = sign_up_fixture()
      %{provider: theirs} = sealed_run_fixture(other)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [provider_connection_id: theirs.id]
        )

      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.run_id == ^ctx.run.id),
          set: [connection_id: theirs.id, secret_id: theirs.secret_id]
        )

      # The digest of what a reload returns now, which contains their provider.
      {key, _seed} = ctx.secrets_key

      {:ok, %{digest: digest}} =
        Apiary.Runs.Registration.fetch(key, ctx.run.node_run_id, instance_id())

      log =
        capture_log(fn ->
          conn =
            post_secrets(ctx, request(ctx, digest: digest, credentials: [start(ctx)]))

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

  describe "a run with keys of two providers" do
    @checkout_key "sk-ant-checkout-0123456789"

    # A second provider of the organisation, Checkout keys, whose key is the run's second
    # key, `<its public id>-1`, as a claim stores the key of a later session's provider;
    # and the digest of the run configuration that a reload returns now.
    setup ctx do
      {:ok, checkout} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Checkout keys",
          keys: [%{value_id: "main", value: @checkout_key}]
        })

      [value] = Repo.all(from v in Value, where: v.secret_id == ^checkout.secret_id)

      Apiary.ModelKeysFixtures.run_keys!(ctx.run, [
        %{
          provider: checkout,
          secret_value_id: value.id,
          position: 2,
          name: "#{checkout.public_id}-1",
          start: false
        }
      ])

      %{checkout: checkout, digest: digest(ctx)}
    end

    defp digest(ctx) do
      {key, _seed} = ctx.secrets_key

      {:ok, %{digest: digest}} =
        Apiary.Runs.Registration.fetch(key, ctx.run.node_run_id, instance_id())

      digest
    end

    defp both(ctx), do: [start(ctx), "#{ctx.checkout.public_id}-1"]

    defp opened_at(ctx, conn, digest) do
      {key, seed} = ctx.secrets_key

      expected = %{
        access_key_id: key.key_id,
        run_id: ctx.run.node_run_id,
        run_configuration: digest,
        signing_public_key: SigningKey.current().public_key,
        x25519_private_key: SealedOpen.x25519_private_key(seed)
      }

      assert {:ok, plaintext, _sealed} = SealedOpen.open(conn.resp_body, expected)
      Jason.decode!(plaintext)
    end

    test "is answered the key of each provider it names", ctx do
      conn = post_secrets(ctx, request(ctx, digest: ctx.digest, credentials: both(ctx)))
      assert conn.status == 200

      # The values are in the order of their credential names.
      expected =
        Enum.sort_by(
          [
            %{"credential" => start(ctx), "value" => model_key()},
            %{"credential" => "#{ctx.checkout.public_id}-1", "value" => @checkout_key}
          ],
          & &1["credential"]
        )

      assert opened_at(ctx, conn, ctx.digest)["values"] == expected
    end

    test "409 credential_unavailable for the whole request where one provider's secret changed",
         ctx do
      # Checkout keys' rows keep a secret that is no longer the provider's.
      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.connection_id == ^ctx.checkout.id),
          set: [secret_id: ctx.provider.secret_id]
        )

      {conn, log} =
        with_log(fn ->
          post_secrets(ctx, request(ctx, digest: digest(ctx), credentials: both(ctx)))
        end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{ctx.checkout.public_id} may not be sealed for its gateway (secret)"
      refute conn.resp_body =~ model_key()
      refute log =~ model_key()
      assert seals() == []
    end

    test "409 credential_unavailable for the whole request where a second row of one provider has another secret",
         ctx do
      # Checkout keys' second row, `<its public id>-2`, keeps a secret that is not the
      # provider's; its first row is as the claim wrote it.
      [value] = Repo.all(from v in Value, where: v.secret_id == ^ctx.checkout.secret_id)
      second = "#{ctx.checkout.public_id}-2"

      Apiary.ModelKeysFixtures.run_keys!(ctx.run, [
        %{
          provider: ctx.checkout,
          secret_value_id: value.id,
          position: 3,
          name: second,
          start: false
        }
      ])

      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.name == ^second),
          set: [secret_id: ctx.provider.secret_id]
        )

      {conn, log} =
        with_log(fn ->
          post_secrets(ctx, request(ctx, digest: digest(ctx), credentials: both(ctx) ++ [second]))
        end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "#{ctx.checkout.public_id} may not be sealed for its gateway (secret)"
      refute conn.resp_body =~ @checkout_key
      refute log =~ @checkout_key
      assert seals() == []
    end

    test "409 credentials_differ for a name of a provider's key the run has no row of", ctx do
      for credentials <- [
            both(ctx) ++ ["#{ctx.checkout.public_id}-2"],
            [start(ctx), "#{ctx.checkout.public_id}-2"]
          ] do
        conn = post_secrets(ctx, request(ctx, digest: ctx.digest, credentials: credentials))
        assert conn.status == 409, inspect(credentials)
        assert code(conn) == "credentials_differ"
      end

      assert seals() == []
    end

    test "409 credential_unavailable, revealing nothing, for a key row of one provider with a key of the other",
         ctx do
      # Checkout keys' row has the row id of the start provider's key in place of its key.
      %{secret_value_id: theirs} = hd(stored_keys(ctx.run))

      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.connection_id == ^ctx.checkout.id),
          set: [secret_value_id: theirs]
        )

      for credentials <- [both(ctx), ["#{ctx.checkout.public_id}-1"]] do
        {conn, log} =
          with_log(fn ->
            post_secrets(ctx, request(ctx, digest: digest(ctx), credentials: credentials))
          end)

        assert conn.status == 409, inspect(credentials)
        assert code(conn) == "credential_unavailable"

        assert log =~
                 "the key #{ctx.checkout.public_id}-1 of the model provider " <>
                   "#{ctx.checkout.public_id} cannot be read (not_found)"

        refute conn.resp_body =~ model_key()
        refute log =~ model_key()
      end

      assert seals() == []
    end
  end

  describe "where the factory feature is off and the registry feature on" do
    @describetag :work

    # The run was claimed under these features too: a run keeps the ones it was claimed
    # with (`Apiary.Runs.Run`, `features`).
    setup ctx do
      previous = Application.get_env(:apiary, :features)
      {:ok, features} = Apiary.Features.parse("observability,security,registry")
      Application.put_env(:apiary, :features, features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [features: Apiary.Features.recorded()]
      )

      {key, _seed} = ctx.secrets_key

      {:ok, %{digest: digest}} =
        Apiary.Runs.Registration.fetch(key, ctx.run.node_run_id, instance_id())

      %{digest: digest}
    end

    test "a request for the registry credential alone is answered", ctx do
      conn = post_secrets(ctx, request(ctx, digest: ctx.digest, credentials: ["registry"]))
      assert conn.status == 200, conn.resp_body
    end

    test "a request that names the model key finds no such credential", ctx do
      conn = post_secrets(ctx, request(ctx, digest: ctx.digest))
      assert conn.status == 409
      assert code(conn) == "credentials_differ"
    end

    test "a request that names the work entry is not found, with no call and no entry", ctx do
      {conn, log} =
        with_log(fn ->
          post_secrets(ctx, request(ctx, digest: ctx.digest, credentials: ["work-1"]))
        end)

      assert conn.status == 404
      assert code(conn) == "not_found"
      assert signed_answer?(conn)
      assert log =~ ctx.run.node_run_id
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end
  end

  # A run keeps the features it was claimed with (`Apiary.Runs.Run`, `features`), and the
  # reads of its requests follow them, whatever the instance has since: a feature turned
  # off after the claim still applies to the run, and one turned on after it does not.
  describe "a run whose features change after its claim" do
    setup ctx do
      previous = Application.get_env(:apiary, :features)
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      %{plain: {plain, seed}}
    end

    test "registry off since the claim: a key not allowed stored secrets passes step 3",
         ctx do
      keep_features!(ctx, Apiary.Features.recorded() ++ ["registry"])

      # Past step 3 the key is not among the run key's, so the request stops at step 4.
      conn = post_secrets(ctx, request(ctx), key: ctx.plain)
      assert conn.status == 404
      assert code(conn) == "not_found"
    end

    test "registry on since a claim without it: a key not allowed stored secrets is refused at step 3",
         ctx do
      instance_with!(:registry)

      conn = post_secrets(ctx, request(ctx), key: ctx.plain)
      assert conn.status == 409
      assert code(conn) == "secrets_not_allowed"
    end

    test "factory off since the claim: the secrets request is still answered", ctx do
      instance_without!(:factory)

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200, conn.resp_body
      assert signed_answer?(conn)
    end

    test "factory off since the claim, the run ended: the access key may not seal its key",
         ctx do
      {key, _seed} = ctx.secrets_key
      scope = Apiary.Accounts.Scope.for_access_key(Repo.preload(key, [:node, :workspace]))
      instance_without!(:factory)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      assert Apiary.Access.check(scope, :"secret.seal", Repo.get!(Run, ctx.run.id)) ==
               {:error, :not_found}
    end

    test "factory off since the claim: the run is still given its model key", ctx do
      instance_without!(:factory)
      run = Repo.get!(Run, ctx.run.id)

      assert Apiary.Runs.ProviderCredential.applies?(run.features)
      assert {:ok, %{keys: [_ | _]}} = Apiary.Runs.ProviderCredential.for_run(run)
      assert [_ | _] = Apiary.ModelKeys.run_keys(run)
    end

    test "factory on since a claim without it: the run is given no model key", ctx do
      keep_features!(ctx, Apiary.Features.recorded() -- ["factory", "workflow_model"])
      run = Repo.get!(Run, ctx.run.id)

      refute Apiary.Runs.ProviderCredential.applies?(run.features)
      assert {:ok, nil} = Apiary.Runs.ProviderCredential.for_run(run)
      assert Apiary.ModelKeys.run_keys(run) == []
    end

    test "factory off since the claim: the run's document is still composed with its model key",
         ctx do
      instance_without!(:factory)
      run = Repo.get!(Run, ctx.run.id)

      assert {:ok, %{credential: %{keys: [_ | _]}}} =
               Apiary.Policy.ComposedConfiguration.members(run)
    end

    test "factory on since a claim without it: the run's document has no model key", ctx do
      keep_features!(ctx, Apiary.Features.recorded() -- ["factory", "workflow_model"])
      run = Repo.get!(Run, ctx.run.id)

      assert {:ok, members} = Apiary.Policy.ComposedConfiguration.members(run)
      assert is_nil(members) or is_nil(members.credential)
    end

    test "registry off since the claim: the run keeps its registry access", ctx do
      keep_features!(ctx, Apiary.Features.recorded() ++ ["registry"])
      assert Apiary.Registry.RunAccess.applies?(Repo.get!(Run, ctx.run.id))
    end

    test "registry on since a claim without it: the run has no registry access", ctx do
      instance_with!(:registry)
      refute Apiary.Registry.RunAccess.applies?(Repo.get!(Run, ctx.run.id))
    end

    test "factory off since the claim: the access key may still seal the run's key", ctx do
      {key, _seed} = ctx.secrets_key
      scope = Apiary.Accounts.Scope.for_access_key(Repo.preload(key, [:node, :workspace]))

      instance_without!(:factory)

      assert Apiary.Access.check(scope, :"secret.seal", Repo.get!(Run, ctx.run.id)) == :ok
    end

    test "factory on since a claim without it: the access key may not seal the run's key",
         ctx do
      {key, _seed} = ctx.secrets_key
      scope = Apiary.Accounts.Scope.for_access_key(Repo.preload(key, [:node, :workspace]))
      run = Repo.get!(Run, ctx.run.id)
      assert Apiary.Access.check(scope, :"secret.seal", run) == :ok

      keep_features!(ctx, Apiary.Features.recorded() -- ["factory", "workflow_model"])

      assert Apiary.Access.check(scope, :"secret.seal", Repo.get!(Run, ctx.run.id)) ==
               {:error, :not_found}
    end

    test "registry off since the claim: the key's document lists the secrets endpoint while the run is live",
         ctx do
      {plain, _seed} = ctx.plain
      plain = Repo.preload(plain, [:node, :workspace])
      refute document_secrets?(plain)

      keep_features!(ctx, Apiary.Features.recorded() ++ ["registry"])
      assert document_secrets?(plain)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      refute document_secrets?(plain)
    end

    test "factory off since the claim: an allowed key's document lists the secrets endpoint while the run is live",
         ctx do
      {key, _seed} = ctx.secrets_key
      key = Repo.preload(key, [:node, :workspace])
      assert document_secrets?(key)

      instance_without!(:factory)
      assert document_secrets?(key)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      refute document_secrets?(key)
    end
  end

  describe "a request that names the work entry" do
    @describetag :work

    test "at the run's start, is answered the adapter's credential beside the model key",
         ctx do
      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply)
      )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)

      assert conn.status == 200, conn.resp_body
      assert signed_answer?(conn)
      {bytes, plaintext} = opened(ctx, conn)
      assert Apiary.ForagerSchemas.validate("sealed-plaintext.schema.json", bytes) == :ok
      assert plaintext["credentials"] == Enum.sort(names(ctx))
      assert %{"value" => model} = value(plaintext, start(ctx))
      assert model == model_key()
      work = value(plaintext, "work-1")
      assert Map.keys(work) == ~w(apply credential expires_at value)
      assert %{"value" => @token, "apply" => @entry_apply} = work

      # The call: the entry's connection, its one collection, its access, for the work.
      row = work_row(ctx)
      connection = Repo.get!(Apiary.Adapters.Connection, row.connection_id)
      [%{"external_ref" => ref, "collection_id" => collection_id}] = row.resources
      assert [{"/calls/run-credential", body}] = WorkCredentialStub.calls()

      assert Map.delete(body, "time") == %{
               "version" => 1,
               "connection_id" => connection.public_id,
               "resources" => [ref],
               "access" => "read",
               "purpose" => "work"
             }

      # The first credential's items are kept; nothing of the token is.
      assert row.issued_apply == @entry_apply

      {key, _seed} = ctx.secrets_key
      assert [entry] = issues()
      assert entry.organisation_id == ctx.scope.organisation.id
      assert {entry.subject_kind, entry.subject_id} == {"run", ctx.run.id}
      assert {entry.actor_kind, entry.actor_id} == {:access_key, key.id}

      assert entry.details == %{
               "run_id" => ctx.run.node_run_id,
               "connection_id" => connection.public_id,
               "adapter_id" => ctx.adapter.public_id,
               "collection_id" => Repo.get!(Collection, collection_id).public_id,
               "target_path" => "acme/shop",
               "access" => "read",
               "purpose" => "work",
               "credential" => "work-1",
               "expires_at" => work["expires_at"],
               "outcome" => "issued"
             }

      assert length(seals()) == 1
      refute log =~ @token
    end

    test "for a write run, is answered a read work-1 and a push-1 with the entry's push_ref",
         ctx do
      {ctx, pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end)
      assert conn.status == 200, conn.resp_body
      {bytes, plaintext} = opened(ctx, conn)
      assert Apiary.ForagerSchemas.validate("sealed-plaintext.schema.json", bytes) == :ok
      assert plaintext["credentials"] == Enum.sort(all(ctx))

      # Each name has a different token, never the other's, and only push-1's items have a
      # branch.
      assert %{"value" => @token, "apply" => @entry_apply} = value(plaintext, "work-1")
      assert %{"value" => @push_token, "apply" => ^pushing} = value(plaintext, "push-1")
      refute inspect(value(plaintext, "work-1")) =~ "push_ref"

      # Two calls, both for the work: the access differs, and neither has a branch. The
      # calls run in parallel, so they arrive in either order; sorted by access, read is
      # first.
      assert [{"/calls/run-credential", read}, {"/calls/run-credential", write}] =
               Enum.sort_by(WorkCredentialStub.calls(), fn {_path, body} -> body["access"] end)

      assert {read["access"], read["purpose"]} == {"read", "work"}
      assert {write["access"], write["purpose"]} == {"write", "work"}
      assert Map.delete(read, "access") == Map.delete(write, "access")
      refute inspect({read, write}) =~ "push_ref"

      # Each row keeps its first credential's items, and one Activity entry each.
      assert work_row(ctx).issued_apply == @entry_apply
      assert push_row(ctx).issued_apply == pushing

      assert [{"work-1", "read", "work"}, {"push-1", "write", "push"}] ==
               for(
                 %Entry{details: %{"outcome" => "issued"} = d} <- issues(),
                 do: {d["credential"], d["access"], d["purpose"]}
               )

      assert length(seals()) == 1
      refute log =~ @token
      refute log =~ @push_token
    end

    test "at a renewal, a request by the name of one entry is answered that entry's credential",
         ctx do
      {ctx, pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)
      assert post_secrets(ctx, request(ctx, credentials: all(ctx))).status == 200
      WorkCredentialStub.calls()
      running!(ctx)

      for {name, token, items, access} <- [
            {"push-1", @push_token, pushing, "write"},
            {"work-1", @token, @entry_apply, "read"},
            {"push-1", @push_token, pushing, "write"}
          ] do
        conn = post_secrets(ctx, request(ctx, credentials: [name]))
        assert conn.status == 200, conn.resp_body
        {_bytes, plaintext} = opened(ctx, conn)
        assert plaintext["credentials"] == [name]

        assert [%{"credential" => ^name, "value" => ^token, "apply" => ^items}] =
                 plaintext["values"]

        assert [{"/calls/run-credential", %{"access" => ^access}}] = WorkCredentialStub.calls()
      end
    end

    test "at a renewal, push-1 items whose push_ref differs from the start's are refused",
         ctx do
      {ctx, pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)
      assert post_secrets(ctx, request(ctx, credentials: all(ctx))).status == 200
      assert push_row(ctx).issued_apply == pushing

      # The start's items had another branch.
      started =
        Enum.map(@entry_apply, &Map.put(&1, "push_ref", "refs/heads/qory/wi_ffffffffffffffff"))

      {1, _rows} =
        Repo.update_all(from(c in RunCredential, where: c.id == ^push_row(ctx).id),
          set: [issued_apply: started]
        )

      running!(ctx)

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: ["push-1"])) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert push_row(ctx).issued_apply == started
      assert ["issued", "issued", "apply_moved"] = Enum.map(issues(), & &1.details["outcome"])
      assert log =~ "cause=apply_moved"
      assert log =~ "credential=push-1"
    end

    test "a refusal of the write credential refuses the whole request, work-1's included",
         ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)

      WorkCredentialStub.issue_by_access(ctx.adapter_seed, %{
        "read" => WorkCredentialStub.credential(@token, @entry_apply),
        "write" => {403, ~s({"error":"access_not_granted"})}
      })

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end)
      assert conn.status == 409
      assert conn.resp_body == ~s({"error":"credential_unavailable"})
      refute log =~ @token

      # Nothing is sealed, no items are kept, and each entry has its Activity entry: the
      # read credential was issued and not sent, the push entry refused.
      assert seals() == []
      assert work_row(ctx).issued_apply == nil
      assert push_row(ctx).issued_apply == nil
      refute inspect(Enum.map(issues(), & &1.details)) =~ "access_not_granted"

      # The adapter's refusal is the run's, as for a refusal of the read credential: the run
      # of the queue records it, and the run's page shows it as it shows any adapter's.
      assert %DispatchRun{adapter_failure: :refused, adapter_failure_code: "access_not_granted"} =
               Repo.get!(DispatchRun, ctx.run.dispatch_run_id)

      assert [{"push-1", "refused"}, {"work-1", "other_credential_failed"}] ==
               for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]})

      # The work entry's credential is still answered alone, as a request by the sessions'
      # gateway for the read credential.
      assert post_secrets(ctx, request(ctx, credentials: ["work-1"])).status == 200
    end

    test "a push-1 whose kept items moved rolls back the items kept for work-1", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)

      started =
        Enum.map(@entry_apply, &Map.put(&1, "push_ref", "refs/heads/qory/wi_ffffffffffffffff"))

      {1, _rows} =
        Repo.update_all(from(c in RunCredential, where: c.id == ^push_row(ctx).id),
          set: [issued_apply: started]
        )

      running!(ctx)

      {conn, log} =
        with_log(fn -> post_secrets(ctx, request(ctx, credentials: ["work-1", "push-1"])) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "cause=apply_moved"
      refute log =~ @token
      refute log =~ @push_token

      # Work-1's items were written before push-1's comparison failed, and are written no more.
      assert work_row(ctx).issued_apply == nil
      assert push_row(ctx).issued_apply == started
      assert seals() == []

      assert [{"push-1", "apply_moved"}, {"work-1", "not_recorded"}] ==
               Enum.sort(for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]}))
    end

    test "a seal that fails after both credentials were issued refuses both and keeps nothing",
         ctx do
      # The push entry's push_ref is longer than the 255 characters a sealed item may have:
      # the adapter's answers pass every check, and the seal refuses the plaintext.
      long = "refs/heads/qory/" <> String.duplicate("a", 300)
      {ctx, _pushing} = push_entry!(ctx, long)
      issue_both!(ctx)

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert log =~ "could not be sealed"
      refute log =~ @token
      refute log =~ @push_token

      assert length(WorkCredentialStub.calls()) == 2
      assert seals() == []
      assert work_row(ctx).issued_apply == nil
      assert push_row(ctx).issued_apply == nil

      assert [{"push-1", "seal_failed"}, {"work-1", "seal_failed"}] ==
               Enum.sort(for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]}))
    end

    test "a failed check of the first credential refuses the second, whose call was sent",
         ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      wider = [%{hd(@entry_apply) | "paths" => ["/other/*"]}]

      WorkCredentialStub.issue_by_access(ctx.adapter_seed, %{
        "read" => WorkCredentialStub.credential(@token, wider),
        "write" => WorkCredentialStub.credential(@push_token, @entry_apply)
      })

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      refute log =~ @token
      refute log =~ @push_token

      # Both calls are made together; the read call is among those sent.
      assert Enum.any?(WorkCredentialStub.calls(), &match?({_, %{"access" => "read"}}, &1))

      assert [{"work-1", "path_outside_entry"}, {"push-1", "other_credential_failed"}] ==
               for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]})

      assert seals() == []
      assert work_row(ctx).issued_apply == nil
      assert push_row(ctx).issued_apply == nil
    end

    test "a work entry with write access is never issued", ctx do
      {1, _rows} =
        Repo.update_all(from(c in RunCredential, where: c.id == ^work_row(ctx).id),
          set: [access: :write]
        )

      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply)
      )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert WorkCredentialStub.calls() == []
      assert seals() == []
      assert issues() == []
      assert work_row(ctx).issued_apply == nil
      assert log =~ "the entry work-1 has write access"
      refute log =~ @token
    end

    test "409 secrets_not_allowed for a key without allow_secrets that names push-1", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)

      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      list_key!(ctx.run, plain.public_key)
      conn = post_secrets(ctx, request(ctx, credentials: ["push-1"]), key: {plain, seed})
      assert conn.status == 409
      assert code(conn) == "secrets_not_allowed"
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end

    test "404 for a key the run key does not list that names push-1", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)

      %{access_key: later, pair: pair} =
        Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, ctx.gateway, %{
          allow_secrets: true
        })

      conn = post_secrets(ctx, request(ctx, credentials: all(ctx)), key: {later, pair.secret})
      assert conn.status == 404
      assert WorkCredentialStub.calls() == []
      assert seals() == []
      assert issues() == []
    end

    test "409 credentials_differ for push-1 on a run that has no push entry, before any call",
         ctx do
      for credentials <- [["push-1"], ["work-1", "push-1"], all(ctx)] do
        conn = post_secrets(ctx, request(ctx, credentials: credentials))
        assert conn.status == 409
        assert code(conn) == "credentials_differ"
      end

      assert WorkCredentialStub.calls() == []
      assert issues() == []
      assert seals() == []
    end

    # The adapter limits the paths of a credential by its access (a read call is answered
    # the read paths, a write call the push paths). Qory Apiary checks only that an item
    # lies inside the entry, by prefix, and the entry has the paths of both entries.
    test "a read call answered with the push paths is accepted: the adapter's duty", ctx do
      pushing = [%{hd(@entry_apply) | "paths" => ["/acme/shop.git/git-receive-pack"]}]
      WorkCredentialStub.issue(ctx.adapter_seed, WorkCredentialStub.credential(@token, pushing))

      conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
      assert conn.status == 200, conn.resp_body
      {_bytes, plaintext} = opened(ctx, conn)
      assert %{"value" => @token, "apply" => ^pushing} = value(plaintext, "work-1")
    end

    test "at the run's start, takes the run's row before the work entry's, as a deletion does",
         ctx do
      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply)
      )

      handler = "secrets-lock-order-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == test, do: send(test, {:statement, source, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert post_secrets(ctx, request(ctx, credentials: names(ctx))).status == 200
      :telemetry.detach(handler)

      # The copies' statement takes the run's row `FOR KEY SHARE`; the work entry's update
      # locks its `run_credentials` row. A run's deletion locks the run, then that row.
      writes = statements() |> Enum.filter(&(&1 in [:copies, :work_entry])) |> Enum.dedup()
      assert writes == [:copies, :work_entry]
    end

    test "a request for both entries takes the run's row before either entry's update", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)
      assert post_secrets(ctx, request(ctx, credentials: all(ctx))).status == 200
      running!(ctx)

      handler = "secrets-both-lock-order-#{System.unique_integer()}"
      test = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == test, do: send(test, {:statement, source, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      _earlier = statements()

      assert post_secrets(ctx, request(ctx, credentials: ["work-1", "push-1"])).status == 200
      :telemetry.detach(handler)

      writes = statements() |> Enum.filter(&(&1 in [:run_lock, :work_entry])) |> Enum.dedup()
      assert writes == [:run_lock, :work_entry]
    end

    test "at a renewal of work-1 alone, is answered a new credential and no model key", ctx do
      issued!(ctx)
      running!(ctx)
      seals = seals()

      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential("fixture-work-token-renewed-0002", @entry_apply)
      )

      conn = post_secrets(ctx, request(ctx, credentials: ["work-1"]))
      assert conn.status == 200, conn.resp_body
      {_bytes, plaintext} = opened(ctx, conn)
      assert plaintext["credentials"] == ["work-1"]

      assert [%{"credential" => "work-1", "value" => "fixture-work-token-renewed-0002"}] =
               plaintext["values"]

      # The model key is neither revealed nor sealed again.
      assert seals() == seals
      assert ["issued", "issued"] = Enum.map(issues(), & &1.details["outcome"])
    end

    test "at a renewal, an answer whose apply items differ from the start's is refused",
         ctx do
      issued!(ctx)
      running!(ctx)
      narrower = [%{hd(@entry_apply) | "paths" => ["/acme/shop.git/*"]}]

      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential("fixture-work-token-moved-0003", narrower)
      )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: ["work-1"])) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert work_row(ctx).issued_apply == @entry_apply
      assert ["issued", "apply_moved"] = Enum.map(issues(), & &1.details["outcome"])
      assert log =~ "cause=apply_moved"
      refute log =~ "fixture-work-token-moved-0003"
      # A running run's failure is a log line only.
      assert %DispatchRun{adapter_failure: nil} = Repo.get!(DispatchRun, ctx.run.dispatch_run_id)
    end

    test "410 for a run that ended during the call: nothing sealed, kept or said received",
         ctx do
      end_run = fn ->
        {1, _rows} =
          Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])
      end

      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply),
        end_run
      )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)
      assert conn.status == 410
      assert conn.resp_body == ""
      assert [{"/calls/run-credential", _body}] = WorkCredentialStub.calls()
      assert [%Entry{details: %{"outcome" => "run_not_live"}} = entry] = issues()
      assert work_row(ctx).issued_apply == nil
      assert seals() == []
      refute log =~ @token

      sentence =
        Enum.find_value(
          ApiaryWeb.Activity.Describer.describers(),
          & &1.sentence(:"run_credential.issue", entry, %{})
        )

      assert sentence =~ "Was refused read access to acme/shop for the run: the run ended"
      refute sentence =~ "Received"
    end

    test "for a run lost after its attach and not lost for good, is answered its credential",
         ctx do
      lost!(ctx, [])

      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply)
      )

      conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
      assert conn.status == 200, conn.resp_body
      {_bytes, plaintext} = opened(ctx, conn)
      assert %{"value" => @token} = value(plaintext, "work-1")
      assert [%Entry{details: %{"outcome" => "issued"}}] = issues()
    end

    test "409 credentials_differ for its names out of order, before any call", ctx do
      conn = post_secrets(ctx, request(ctx, credentials: Enum.reverse(names(ctx))))
      assert conn.status == 409
      assert code(conn) == "credentials_differ"
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end

    test "410 run_configuration_superseded for a superseded digest, before any call", ctx do
      stale =
        request(ctx, credentials: names(ctx), digest: "sha256=" <> String.duplicate("0", 64))

      conn = post_secrets(ctx, stale)
      assert conn.status == 410
      assert code(conn) == "run_configuration_superseded"
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end

    test "409 secrets_not_allowed for a key not allowed stored secrets, before any call", ctx do
      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      list_key!(ctx.run, plain.public_key)
      conn = post_secrets(ctx, request(ctx, credentials: ["work-1"]), key: {plain, seed})
      assert conn.status == 409
      assert code(conn) == "secrets_not_allowed"
      assert WorkCredentialStub.calls() == []
      assert issues() == []
    end

    test "503 for a call that timed out, written on the pending run's queue entry", ctx do
      fast_calls!()
      WorkCredentialStub.slow(300)

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)
      assert conn.status == 503
      assert code(conn) == "unavailable"
      assert [%Entry{details: %{"outcome" => "timeout"}}] = issues()
      assert log =~ "cause=timeout"
      assert seals() == []

      assert %DispatchRun{adapter_failure: :timeout, adapter_failure_call: "run-credential"} =
               Repo.get!(DispatchRun, ctx.run.dispatch_run_id)
    end

    test "the calls of a request for both entries run together: the time of one, not the sum",
         ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      deadline!(5_000)

      WorkCredentialStub.issue_by_access(
        ctx.adapter_seed,
        %{
          "read" => WorkCredentialStub.credential(@token, @entry_apply),
          "write" => WorkCredentialStub.credential(@push_token, @entry_apply)
        },
        %{"read" => 1_500, "write" => 1_500}
      )

      {time, conn} =
        :timer.tc(fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end, :millisecond)

      assert conn.status == 200, conn.resp_body
      # One after the other, the calls would take 3 seconds and more.
      assert time >= 1_500 and time < 2_800, "took #{time} ms"
      assert length(WorkCredentialStub.calls()) == 2
      assert ["issued", "issued"] = Enum.map(issues(), & &1.details["outcome"])
      assert work_row(ctx).issued_apply == @entry_apply
    end

    test "two calls that together pass the deadline: both are refused as timed out, nothing kept",
         ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      deadline!(600)

      WorkCredentialStub.issue_by_access(
        ctx.adapter_seed,
        %{
          "read" => WorkCredentialStub.credential(@token, @entry_apply),
          "write" => WorkCredentialStub.credential(@push_token, @entry_apply)
        },
        %{"read" => 5_000, "write" => 5_000}
      )

      {{time, conn}, log} =
        with_log(fn ->
          :timer.tc(
            fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end,
            :millisecond
          )
        end)

      assert conn.status == 503
      assert code(conn) == "unavailable"
      assert time >= 600 and time < 1_300, "took #{time} ms"
      assert log =~ "cause=timeout"
      refute log =~ @token
      refute log =~ @push_token

      assert seals() == []
      assert work_row(ctx).issued_apply == nil
      assert push_row(ctx).issued_apply == nil

      assert [{"push-1", "timeout"}, {"work-1", "timeout"}] ==
               Enum.sort(for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]}))

      # No call outlives the deadline, and no process of the request is left.
      assert no_calls_left?()
    end

    test "a call that fails at once cancels the slow one: the request does not wait", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      deadline!(3_000)

      WorkCredentialStub.issue_by_access(
        ctx.adapter_seed,
        %{
          "read" => WorkCredentialStub.credential(@token, @entry_apply),
          "write" => {403, ~s({"error":"access_not_granted"})}
        },
        %{"read" => 5_000}
      )

      {{time, conn}, log} =
        with_log(fn ->
          :timer.tc(
            fn -> post_secrets(ctx, request(ctx, credentials: all(ctx))) end,
            :millisecond
          )
        end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert time < 2_000, "took #{time} ms"
      refute log =~ @token
      assert seals() == []
      assert work_row(ctx).issued_apply == nil

      assert [{"push-1", "refused"}, {"work-1", "other_credential_failed"}] ==
               for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]})

      # The slow call, which the stub answers after 5 seconds, is stopped with the request:
      # no process is left within a second.
      assert no_children?(Apiary.Runs.TaskSupervisor)
      assert no_calls_left?()
    end

    test "the request that names one entry is bounded by the same deadline", ctx do
      deadline!(500)

      WorkCredentialStub.issue_by_access(
        ctx.adapter_seed,
        %{"read" => WorkCredentialStub.credential(@token, @entry_apply)},
        %{"read" => 5_000}
      )

      {time, conn} =
        :timer.tc(
          fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end,
          :millisecond
        )

      assert conn.status == 503
      assert time >= 500 and time < 1_200, "took #{time} ms"
      assert [%Entry{details: %{"outcome" => "timeout"}}] = issues()
      assert seals() == []
      assert work_row(ctx).issued_apply == nil
      assert no_calls_left?()
    end

    test "an entry that fails its check before any call leaves the other entry no call", ctx do
      {ctx, _pushing} = push_entry!(ctx, @branch)
      issue_both!(ctx)

      # The push entry's connection is no longer its adapter's: `connection_gone`.
      {key, _seed} = ctx.secrets_key
      gateway = Repo.get!(Apiary.AccessKeys.AccessKey, key.id)

      {1, _rows} =
        Repo.update_all(from(c in RunCredential, where: c.id == ^push_row(ctx).id),
          set: [adapter_id: gateway.node_id]
        )

      conn = post_secrets(ctx, request(ctx, credentials: ["work-1", "push-1"]))
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert WorkCredentialStub.calls() == []
      assert seals() == []
      assert work_row(ctx).issued_apply == nil

      # Only the entry that failed has an Activity entry: work-1 was not attempted.
      assert [{"push-1", "connection_gone"}] ==
               for(%Entry{details: d} <- issues(), do: {d["credential"], d["outcome"]})
    end

    test "a check of the answer that raises is call_failed, and no token is logged", ctx do
      WorkCredentialStub.issue(
        ctx.adapter_seed,
        WorkCredentialStub.credential(@token, @entry_apply)
      )

      {key, _seed} = ctx.secrets_key
      key = Repo.preload(Repo.get!(Apiary.AccessKeys.AccessKey, key.id), [:workspace, :node])
      run = Repo.get!(Run, ctx.run.id)

      # A time `DateTime.from_unix!/1` refuses raises inside the check, after the call.
      {result, log} =
        with_log(fn ->
          Apiary.Runs.WorkCredential.issue_all(
            run,
            [work_row(ctx)],
            key,
            1_000_000_000_000_000_000,
            System.monotonic_time(:millisecond) + 5_000
          )
        end)

      assert result == {:error, :credential_unavailable}
      assert log =~ "cause=call_failed"
      refute log =~ @token
      refute log =~ "** ("
      assert [%Entry{details: %{"outcome" => "call_failed"}}] = issues()
    end

    test "503 for a call that reached no one", ctx do
      fast_calls!()
      WorkCredentialStub.slow(0)

      conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
      assert conn.status == 503
      assert [%Entry{details: %{"outcome" => "unreachable"}}] = issues()
    end

    test "409 credential_unavailable for a refusal of the adapter, with none of its words",
         ctx do
      WorkCredentialStub.answer(ctx.adapter_seed, 403, ~s({"error":"resource_not_covered"}))

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)
      assert conn.status == 409
      assert conn.resp_body == ~s({"error":"credential_unavailable"})
      assert [%Entry{details: %{"outcome" => "refused"} = details}] = issues()
      refute inspect(details) =~ "resource_not_covered"
      refute log =~ "resource_not_covered"
      assert seals() == []

      assert %DispatchRun{adapter_failure: :refused, adapter_failure_code: "resource_not_covered"} =
               Repo.get!(DispatchRun, ctx.run.dispatch_run_id)
    end

    test "409 credential_unavailable for an answer wider than the entry", ctx do
      wider = [%{hd(@entry_apply) | "hosts" => ["git.example.com", "other.example.com"]}]
      WorkCredentialStub.issue(ctx.adapter_seed, WorkCredentialStub.credential(@token, wider))

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx, credentials: names(ctx))) end)
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert [%Entry{details: %{"outcome" => "host_outside_entry"}}] = issues()
      assert work_row(ctx).issued_apply == nil
      refute log =~ @token

      assert %DispatchRun{adapter_failure: :invalid_answer} =
               Repo.get!(DispatchRun, ctx.run.dispatch_run_id)
    end

    test "409 credential_unavailable, with no call, for a connection no longer connected",
         ctx do
      row = work_row(ctx)

      {1, _rows} =
        Repo.update_all(from(c in Apiary.Adapters.Connection, where: c.id == ^row.connection_id),
          set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
        )

      conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert WorkCredentialStub.calls() == []
      assert [%Entry{details: %{"outcome" => "connection_gone"}}] = issues()
    end

    test "409 credential_unavailable, with no call, for an adapter with no key in use", ctx do
      {_count, _rows} =
        Repo.update_all(
          from(k in Apiary.AccessKeys.AccessKey, where: k.node_id == ^ctx.adapter.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
      assert conn.status == 409
      assert WorkCredentialStub.calls() == []
      assert [%Entry{details: %{"outcome" => "adapter_key_missing"}}] = issues()
    end

    test "leaves the token in no table, no log line at any level and no Activity entry",
         ctx do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      issued = WorkCredentialStub.credential(@token, @entry_apply)
      seed = ctx.adapter_seed

      answers = [
        # Issued and sealed.
        {200, fn -> WorkCredentialStub.issue(seed, issued) end},
        # A member the answer's schema does not define, beside the token.
        {409, fn -> WorkCredentialStub.issue(seed, Map.put(issued, "note", @token)) end},
        # A token outside the check's form, which the call's schema takes: a control
        # character in it.
        {409,
         fn -> WorkCredentialStub.issue(seed, %{issued | "token" => @token <> "\u0001x"}) end},
        # A body that is not JSON.
        {409,
         fn ->
           WorkCredentialStub.answer(seed, 200, ~s({"version":1,"credential":{"token":"#{@token}))
         end}
      ]

      for {status, stub} <- answers do
        stub.()

        log =
          capture_log([level: :debug], fn ->
            conn = post_secrets(ctx, request(ctx, credentials: names(ctx)))
            assert conn.status == status, conn.resp_body
          end)

        refute log =~ @token
      end

      assert Enum.map(issues(), & &1.details["outcome"]) ==
               ["issued", "invalid_answer", "token_control_character", "invalid_answer"]

      refute inspect(Repo.all(Entry)) =~ @token
      # The scan's queries have the token as a parameter: their log lines are left out.
      capture_log(fn -> assert columns_with(@token) == [] end)
    end
  end

  # The credential names of a run with a model key and a work entry, in the run
  # configuration's order, and of a write run, which has a push entry after it.
  defp names(ctx), do: [start(ctx), "work-1"]
  defp all(ctx), do: names(ctx) ++ ["push-1"]

  defp provider(ctx), do: Repo.get!(Connection, ctx.provider.id)

  defp value(plaintext, name), do: Enum.find(plaintext["values"], &(&1["credential"] == name))

  defp issues,
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "run_credential.issue",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  # The statements the test's process sent so far, in order: `:copies` for a write of
  # `model_key_copies`, `:work_entry` for an update of `run_credentials`, else `:other`.
  defp statements do
    receive do
      {:statement, source, query} -> [statement(source, query) | statements()]
    after
      0 -> []
    end
  end

  defp statement("model_key_copies", "INSERT" <> _rest), do: :copies
  defp statement("run_credentials", "UPDATE" <> _rest), do: :work_entry

  defp statement("runs", "SELECT" <> rest),
    do: if(rest =~ "FOR KEY SHARE", do: :run_lock, else: :other)

  defp statement(_source, _query), do: :other

  defp work_row(ctx), do: Repo.get_by!(RunCredential, run_id: ctx.run.id, purpose: :work)
  defp push_row(ctx), do: Repo.get_by!(RunCredential, run_id: ctx.run.id, purpose: :push)

  # The adapter's answers to a write run: its read credential for the call with access
  # `read`, and another for the call with access `write`. The adapter's items have no
  # push_ref: the claim's entry has it.
  defp issue_both!(ctx) do
    WorkCredentialStub.issue_by_access(ctx.adapter_seed, %{
      "read" => WorkCredentialStub.credential(@token, @entry_apply),
      "write" => WorkCredentialStub.credential(@push_token, @entry_apply)
    })
  end

  # The plaintext of an answer, as the gateway opens it: its bytes and as decoded.
  defp opened(ctx, conn) do
    {key, seed} = ctx.secrets_key

    expected = %{
      access_key_id: key.key_id,
      run_id: ctx.run.node_run_id,
      run_configuration: ctx.attached.digest,
      signing_public_key: SigningKey.current().public_key,
      x25519_private_key: SealedOpen.x25519_private_key(seed)
    }

    assert {:ok, plaintext, _sealed} = SealedOpen.open(conn.resp_body, expected)
    {plaintext, Jason.decode!(plaintext)}
  end

  # The run's start: the model key and the work entry's first credential, sealed.
  defp issued!(ctx) do
    WorkCredentialStub.issue(
      ctx.adapter_seed,
      WorkCredentialStub.credential(@token, @entry_apply)
    )

    assert post_secrets(ctx, request(ctx, credentials: names(ctx))).status == 200
    [_call] = WorkCredentialStub.calls()
  end

  # The features the run kept when it was claimed (`Apiary.Runs.Run`, `features`).
  defp keep_features!(ctx, recorded) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [features: recorded])
  end

  # The instance's features with `feature` turned on, or off with the features that need
  # it, as a save on Instance settings › Features writes them.
  defp instance_with!(feature) do
    enabled = Apiary.Features.enabled()

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(enabled, enabled ++ [feature])
    )
  end

  defp instance_without!(feature) do
    enabled = Apiary.Features.enabled()

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(enabled, enabled -- [feature])
    )
  end

  # Whether the configuration document of `key` lists the secrets endpoint.
  defp document_secrets?(key) do
    {body, _digest} = ApiaryWeb.Contract.Configuration.document(key)
    Map.has_key?(Jason.decode!(body), "secrets")
  end

  # The run, attached, as the lost-run check leaves it 300 seconds after its loss, its
  # backstop ahead, with whatever else `changes` sets.
  defp lost!(ctx, changes) do
    now = DateTime.utc_now()

    # Each call starts again from a lost run with no end, whatever an earlier call set.
    set = [
      state: "lost",
      lost_at: DateTime.add(now, -300, :second),
      backstop_at: DateTime.add(now, 3600, :second),
      silenced_at: nil,
      exited_at: nil,
      exit_state: nil,
      events_pruned_at: nil
    ]

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: Keyword.merge(set, changes)
      )
  end

  # The ways a run lost after its attach has ended: lost for good, by its silence or past
  # its backstop; with its exit, folded (`exited_at`, `exit_state`) or only stored (the
  # `dev.qory.run.exited` event); or with its events pruned. The stored exit comes last,
  # as `lost!/2` does not delete events.
  defp ended_lost_cases do
    now = DateTime.utc_now()

    [
      [silenced_at: DateTime.add(now, -60, :second)],
      [backstop_at: DateTime.add(now, -1, :second)],
      [exited_at: now],
      [exit_state: "completed"],
      [events_pruned_at: now],
      :stored_exit
    ]
  end

  defp ended_lost!(ctx, :stored_exit) do
    lost!(ctx, [])
    Apiary.RunEventsFixtures.event_fixture(Repo.get!(Run, ctx.run.id), 99, "run.exited", %{})
  end

  defp ended_lost!(ctx, changes), do: lost!(ctx, changes)

  # The run made a write run, as the claim of a write run records it: a push entry beside
  # its read work entry, whose items have the push_ref `branch`, and the run configuration's
  # digest after it. `{ctx, items}`, the context with the new digest, and the push items.
  defp push_entry!(ctx, branch) do
    pushing = Enum.map(@entry_apply, &Map.put(&1, "push_ref", branch))
    item = %Apiary.WorkItems.WorkItem{public_id: Path.basename(branch)}

    assert %RunCredential{apply: ^pushing} =
             push = Apiary.Runs.RunCredentials.push_from(work_row(ctx), :write, item)

    Repo.insert!(%{Ecto.put_meta(push, state: :built) | id: nil, issued_apply: nil})

    {key, _seed} = ctx.secrets_key

    assert {:ok, %{digest: digest, settings: settings}} =
             Apiary.Runs.Registration.fetch(
               key,
               ctx.run.node_run_id,
               Apiary.ContractFixtures.instance_id()
             )

    assert settings =~ ~s("push_ref":"#{branch}")
    assert settings =~ ~s("name":"push-1","purpose":"push")
    {put_in(ctx.attached.digest, digest), pushing}
  end

  defp running!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "running"])
  end

  # The time the whole request has, in milliseconds, until the test ends.
  defp deadline!(ms) do
    saved = Application.get_env(:apiary, Apiary.Runs.SecretsRequest)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:apiary, Apiary.Runs.SecretsRequest, saved),
        else: Application.delete_env(:apiary, Apiary.Runs.SecretsRequest)
    end)

    Application.put_env(:apiary, Apiary.Runs.SecretsRequest, deadline: ms)
  end

  # Whether no process of a call to an adapter is left, within a second of asking.
  defp no_calls_left?, do: no_children?(Apiary.Adapters.Calls.Supervisor)

  # Whether `supervisor` has no child, polled for up to a second.
  defp no_children?(supervisor, tries \\ 20) do
    cond do
      Task.Supervisor.children(supervisor) == [] ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        no_children?(supervisor, tries - 1)
    end
  end

  # Calls to an adapter with short times, so a timeout takes milliseconds, until the test
  # ends.
  defp fast_calls! do
    saved = Application.get_env(:apiary, Apiary.Adapters.Calls)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Adapters.Calls, saved) end)

    Application.put_env(
      :apiary,
      Apiary.Adapters.Calls,
      Keyword.merge(saved, attempt: 100, total: 250, retry_wait: {1, 2})
    )
  end

  # Every column of a text, bytea, JSON or array type, of every table and view, that
  # contains `needle`, as `{table, column}`.
  defp columns_with(needle) do
    %{rows: columns} =
      Repo.query!("""
      SELECT table_name, column_name, data_type FROM information_schema.columns
      WHERE table_schema = 'public'
        AND data_type IN ('text', 'character varying', 'character', 'bytea', 'jsonb',
                          'json', 'ARRAY')
      """)

    for [table, column, type] <- columns,
        contains?(table, column, type, needle),
        do: {table, column}
  end

  defp contains?(table, column, "bytea", needle),
    do:
      count(
        ~s|SELECT count(*) FROM "#{table}" WHERE position($1::bytea in "#{column}") > 0|,
        needle
      )

  defp contains?(table, column, _type, needle),
    do: count(~s|SELECT count(*) FROM "#{table}" WHERE strpos("#{column}"::text, $1) > 0|, needle)

  defp count(sql, needle) do
    %{rows: [[count]]} = Repo.query!(sql, [needle])
    count > 0
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

  # Writes back the provider and the secret of each key row of `keys`.
  defp restore(keys) do
    for %ModelKey{} = key <- keys do
      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.id == ^key.id),
          set: [connection_id: key.connection_id, secret_id: key.secret_id]
        )
    end
  end
end
