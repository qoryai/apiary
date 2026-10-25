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
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Policy, Repo, SealedOpen, SigningKey, WorkCredentialStub}
  alias Apiary.Adapters.Collection
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{Run, RunCredential}
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
      assert %{"value" => model} = value(plaintext, ctx.provider.public_id)
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
  # configuration's order.
  defp names(ctx), do: [ctx.provider.public_id, "work-1"]

  defp value(plaintext, name), do: Enum.find(plaintext["values"], &(&1["credential"] == name))

  defp issues,
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "run_credential.issue",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp work_row(ctx), do: Repo.get_by!(RunCredential, run_id: ctx.run.id, purpose: :work)

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

  defp running!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "running"])
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
