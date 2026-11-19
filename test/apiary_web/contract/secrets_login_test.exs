defmodule ApiaryWeb.Contract.SecretsLoginTest do
  # The secrets request for a run whose model key is a sign-in (`Apiary.ModelKeys.Login`):
  # the access token, sealed with `expires_at` so the gateway renews it, refreshed first when
  # that is due; the renewal after a 401 (`unauthorized` of the request), at most once in 5
  # minutes per sign-in; and each refusal. Every call to the provider goes to the `Req.Test`
  # stub of `LoginRefresh`; no token reaches a log line or an audit entry. Not async, as the
  # other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.DebugLog
  import Apiary.ContractFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Policy, Repo, SealedOpen, SigningKey}
  alias Apiary.Audit.Entry
  alias Apiary.ModelKeys.{Copy, Login, LoginRefresh}
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory
  setup {Apiary.DataCase, :without_registry}

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    tokens = login_tokens(expires_in: 3600)

    ctx =
      sealed_run_fixture(scope,
        kind: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}],
        choice: %{runtime: "codex", model: "gpt-6-sol"}
      )

    value = Repo.one!(from v in Value, where: v.secret_id == ^ctx.provider.secret_id)
    Map.merge(ctx, %{scope: scope, tokens: tokens, value: value})
  end

  defp stub!(answer \\ nil) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})

      case answer do
        nil ->
          tokens = login_tokens(tag: "renewed")

          Req.Test.json(conn, %{
            "access_token" => tokens.access_token,
            "refresh_token" => tokens.refresh_token
          })

        {status, body} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, body} -> requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp post_secrets(ctx, body) do
    {key, seed} = ctx.secrets_key

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp request(ctx, unauthorized \\ :none) do
    names = [start(ctx)]

    members =
      [
        version: 1,
        run_id: ctx.run.node_run_id,
        run_configuration: ctx.attached.digest,
        credentials: names
      ] ++
        if(unauthorized == :none, do: [], else: [unauthorized: unauthorized]) ++
        [timestamp: SignedRequest.now()]

    Jason.encode!(Jason.OrderedObject.new(members))
  end

  defp start(ctx), do: "#{ctx.provider.public_id}-1"
  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]

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
    Jason.decode!(plaintext)
  end

  defp aged!(ctx, seconds \\ 3600) do
    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^ctx.value.id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -seconds)]
      )
  end

  describe "a request for a sign-in" do
    test "is answered the access token with the time it expires, and a call to no one", ctx do
      stub!()
      body = request(ctx)
      assert Apiary.ForagerSchemas.validate("secrets-request.schema.json", body) == :ok

      {conn, log} = with_log(fn -> post_secrets(ctx, body) end)

      assert conn.status == 200

      assert Apiary.ForagerSchemas.validate(
               "sealed-plaintext.schema.json",
               opened(ctx, conn) |> Jason.encode!()
             ) == :ok

      assert %{
               "values" => [%{"credential" => name, "value" => value, "expires_at" => expires_at}]
             } =
               opened(ctx, conn)

      assert name == start(ctx)
      assert value == ctx.tokens.access_token
      assert {:ok, at, 0} = DateTime.from_iso8601(expires_at)
      assert abs(DateTime.diff(at, DateTime.add(DateTime.utc_now(), 3600))) < 10
      assert requests() == []

      refute_secrets(log, [ctx.tokens.access_token, ctx.tokens.refresh_token])
      assert [entry] = Repo.all(from e in Entry, where: e.action == "secret.seal")
      refute_secrets(inspect(entry), [ctx.tokens.access_token])

      # The copy of the key the run keeps is the value's time, as for any key.
      assert [%Copy{}] = Repo.all(Copy)
    end

    test "refreshes a token that is due, and seals the new one", ctx do
      stub!()

      {1, _rows} =
        Repo.update_all(Login,
          set: [access_expires_at: DateTime.add(DateTime.utc_now(), 60)]
        )

      conn = post_secrets(ctx, request(ctx))

      assert conn.status == 200
      assert [%{"value" => value}] = opened(ctx, conn)["values"]
      refute value == ctx.tokens.access_token
      assert [%{"refresh_reason" => "proactive_expiry"}] = requests()
    end

    test "after a 401 listed in unauthorized refreshes at most once in 5 minutes", ctx do
      stub!()
      aged!(ctx)

      conn = post_secrets(ctx, request(ctx, [start(ctx)]))
      assert conn.status == 200
      assert [%{"value" => value}] = opened(ctx, conn)["values"]
      refute value == ctx.tokens.access_token
      assert [%{"refresh_reason" => "unauthorized_recovery"}] = requests()

      conn = post_secrets(ctx, request(ctx, [start(ctx)]))
      assert conn.status == 503
      assert code(conn) == "unavailable"
      assert requests() == []
    end

    test "after a 401 for a token older than the one the key holds, serves the key's token, with no call",
         ctx do
      stub!()
      aged!(ctx)

      # The run is sealed the token the key had at its sign-in, as a gateway starts a run.
      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200
      assert [%{"value" => first}] = opened(ctx, conn)["values"]
      assert first == ctx.tokens.access_token
      assert [%Copy{login_at: %DateTime{} = sealed}] = Repo.all(Copy)
      assert sealed == Repo.one!(Login).signed_in_at

      # Another run's request refreshes the key, 10 seconds ago.
      renewed = login_tokens(tag: "renewed")
      store_access_token!(ctx.provider, ctx.value.id, renewed.access_token)

      {1, _rows} =
        Repo.update_all(Login, set: [refreshed_at: DateTime.add(DateTime.utc_now(), -10)])

      # The run's gateway got 401 for the token it has: the older one.
      conn = post_secrets(ctx, request(ctx, [start(ctx)]))

      assert conn.status == 200
      assert [%{"value" => value}] = opened(ctx, conn)["values"]
      assert value == renewed.access_token
      assert requests() == []
      assert Repo.one!(Login).state == "signed_in"
      assert [%Copy{login_at: now_sealed}] = Repo.all(Copy)
      assert now_sealed == Repo.one!(Login).refreshed_at
    end

    test "after a 401 for the token the key holds, refreshes it once, then 503 for 5 minutes",
         ctx do
      stub!()
      aged!(ctx)

      conn = post_secrets(ctx, request(ctx))
      assert conn.status == 200
      assert [%Copy{login_at: sealed}] = Repo.all(Copy)
      assert sealed == Repo.one!(Login).signed_in_at

      # The 401 is for the token the key holds: the renewal refreshes it.
      conn = post_secrets(ctx, request(ctx, [start(ctx)]))
      assert conn.status == 200
      assert [%{"value" => value}] = opened(ctx, conn)["values"]
      refute value == ctx.tokens.access_token
      assert [%{"refresh_reason" => "unauthorized_recovery"}] = requests()

      # The run's copy has the time of the refresh that made its token, so a 401 for that
      # token is for the token the key holds, and no refresh is made inside 5 minutes.
      assert [%Copy{login_at: refreshed}] = Repo.all(Copy)
      assert refreshed == Repo.one!(Login).refreshed_at

      conn = post_secrets(ctx, request(ctx, [start(ctx)]))
      assert conn.status == 503
      assert requests() == []
    end

    test "409 credential_unavailable for a sign-in that needs a new one, with no call", ctx do
      stub!()

      Repo.update_all(Login,
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      {conn, log} = with_log(fn -> post_secrets(ctx, request(ctx)) end)

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert requests() == []
      refute_secrets(log, [ctx.tokens.access_token])
    end

    test "409 credential_unavailable for a token with no account id, with no call", ctx do
      stub!()

      store_access_token!(
        ctx.provider,
        ctx.value.id,
        login_tokens(account: false, tag: "x").access_token
      )

      conn = post_secrets(ctx, request(ctx))

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert requests() == []
    end

    test "503 unavailable for a token that expired when the provider cannot refresh it now",
         ctx do
      stub!({503, %{}})

      {:ok, _provider} =
        Apiary.Connections.update_provider_key(ctx.scope, ctx.provider, "main", %{
          value_id: "main",
          value: device_login(tokens: login_tokens(expires_in: -60, tag: "old"))
        })

      conn = post_secrets(ctx, request(ctx))

      assert conn.status == 503
      assert code(conn) == "unavailable"
      assert [_one] = requests()
    end

    test "409 credential_unavailable after the provider rejects the refresh for good", ctx do
      stub!({400, %{"error" => "invalid_grant"}})
      aged!(ctx)

      conn = post_secrets(ctx, request(ctx, [start(ctx)]))

      assert conn.status == 409
      assert code(conn) == "credential_unavailable"
      assert Repo.one!(Login).state == "sign_in_needed"
    end
  end

  describe "the wait for a refresh" do
    setup do
      previous = Application.get_env(:apiary, Apiary.Runs.SecretsRequest)
      on_exit(fn -> Application.put_env(:apiary, Apiary.Runs.SecretsRequest, previous || []) end)
    end

    defp slow_stub!(milliseconds) do
      test = self()

      Req.Test.stub(LoginRefresh, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, Jason.decode!(raw)})
        Process.sleep(milliseconds)
        tokens = login_tokens(tag: "slow")

        Req.Test.json(conn, %{
          "access_token" => tokens.access_token,
          "refresh_token" => tokens.refresh_token
        })
      end)
    end

    # The stored token has ended, so no old token is served while the refresh runs.
    defp expired!(ctx) do
      {:ok, _provider} =
        Apiary.Connections.update_provider_key(ctx.scope, ctx.provider, "main", %{
          value_id: "main",
          value: device_login(tokens: login_tokens(expires_in: -60, tag: "old"))
        })
    end

    defp due!,
      do: Repo.update_all(Login, set: [access_expires_at: DateTime.add(DateTime.utc_now(), 60)])

    test "ends 2 s before the request's deadline: a refresh that is slower is 503", ctx do
      Application.put_env(:apiary, Apiary.Runs.SecretsRequest, deadline: 2_500)
      slow_stub!(1_500)
      expired!(ctx)

      conn = post_secrets(ctx, request(ctx))

      assert conn.status == 503
      assert code(conn) == "unavailable"
    end

    test "leaves a refresh that fits in the wait to end the request with the new token", ctx do
      Application.put_env(:apiary, Apiary.Runs.SecretsRequest, deadline: 5_000)
      slow_stub!(500)
      due!()

      conn = post_secrets(ctx, request(ctx))

      assert conn.status == 200
      assert [%{"value" => value}] = opened(ctx, conn)["values"]
      refute value == ctx.tokens.access_token
    end
  end

  describe "the log, the audit trail and the answer" do
    test "have no token and no account id at any level, through each way a request ends", ctx do
      secrets = [ctx.tokens.access_token, ctx.tokens.refresh_token, ctx.tokens.account_id]
      renewed = login_tokens(tag: "renewed")
      all = secrets ++ [renewed.access_token, renewed.refresh_token]

      {conn, log} =
        with_debug_log(fn ->
          stub!()
          due!()
          conn = post_secrets(ctx, request(ctx))
          aged!(ctx)
          _again = post_secrets(ctx, request(ctx, [start(ctx)]))
          _recovery = post_secrets(ctx, request(ctx, [start(ctx)]))
          Repo.update_all(Login, set: [state: "sign_in_needed", sign_in_cause: "invalid_grant"])
          _refused = post_secrets(ctx, request(ctx))
          conn
        end)

      assert conn.status == 200
      refute_secrets(log, all)

      for entry <- Repo.all(Entry), do: refute_secrets(inspect(entry), all)
    end
  end

  describe "the unauthorized member" do
    test "is optional and checked: 1 to 6 names, each once, each a credential name", ctx do
      stub!()

      bad_lists = [
        [],
        [start(ctx), start(ctx)],
        ["Not A Name"],
        [5],
        "x",
        nil,
        for(n <- 1..7, do: "key-#{n}")
      ]

      for bad <- bad_lists do
        conn = post_secrets(ctx, request(ctx, bad))
        assert conn.status == 400, inspect(bad)
        assert code(conn) == "invalid_request"
      end

      assert post_secrets(ctx, request(ctx)).status == 200
    end

    test "a name that is not one of the run's credentials is ignored, as if absent", ctx do
      stub!()

      conn = post_secrets(ctx, request(ctx, ["other-1"]))
      assert conn.status == 200
      assert requests() == []

      # With the run's own credential beside it, the list is that credential alone, in any
      # order: the key is renewed after its 401, once.
      aged!(ctx)
      conn = post_secrets(ctx, request(ctx, ["other-1", start(ctx)]))
      assert conn.status == 200
      assert [%{"refresh_reason" => "unauthorized_recovery"}] = requests()
    end
  end
end
