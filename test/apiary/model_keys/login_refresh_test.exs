defmodule Apiary.ModelKeys.LoginRefreshTest do
  # The refresh of the sign-in of a model key of an OpenAI subscription
  # (`Apiary.ModelKeys.Login.access_token/3`, `Apiary.ModelKeys.LoginRefresh`): when it is
  # due, the call and its body, one refresh at a time per login, the lease, a result that is
  # dropped when the key changed meanwhile, each outcome of the provider, the entry of each
  # call, and the sweep. Every call goes to the `Req.Test` stub of `LoginRefresh`; no token
  # reaches a log line, an audit entry or a return value other than the access token.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.Providers
  alias Apiary.ModelKeys.{Login, LoginRefresh, LoginSweep}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @day 86_400

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  # A provider with one key, `main`, whose login expires `expires_in` seconds from now.
  defp subscription!(scope, opts \\ []) do
    tokens = login_tokens(opts)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: login_paste(tokens: tokens)}]
      })

    {provider, tokens}
  end

  defp plain(provider), do: Repo.get!(Connection, provider.id)
  defp value(provider, name \\ "main"), do: key_value!(provider, name)
  defp row(provider, name \\ "main"), do: Repo.get!(Login, value(provider, name).id)

  defp stored(provider, name \\ "main") do
    assert {:ok, tokens} = Login.tokens(plain(provider), value(provider, name).id)
    tokens
  end

  defp token(provider, opts \\ []) do
    id = value(provider, Keyword.get(opts, :key, "main")).id
    opts = Keyword.put_new(opts, :trigger, {:run, "run-1"})
    Login.access_token(plain(provider), id, Keyword.delete(opts, :key))
  end

  # Moves the login's times, as seconds from now (negative for the past).
  defp set_login!(provider, changes, name \\ "main") do
    changes =
      for {field, seconds} <- changes do
        {field, seconds && DateTime.add(DateTime.utc_now(), seconds)}
      end

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, name).id),
      set: changes
    )
  end

  # The key's stored access token is opaque, with no `exp` to read, and its row has no expiry
  # (what a refresh that answers such a token leaves).
  defp opaque!(provider, tokens) do
    id = value(provider).id
    {:ok, _plaintext, snapshot} = Secrets.reveal_login_snapshot(plain(provider), id)

    document =
      Jason.encode!(%{
        "version" => 1,
        "access_token" => "opaque-access-token",
        "refresh_token" => tokens.refresh_token
      })

    :ok = Secrets.write_refreshed_key(plain(provider), id, document, snapshot)
    set_login!(provider, access_expires_at: nil)
  end

  # Another process holds the login's lease for `seconds` more (negative: it lapsed).
  defp hold_lease!(provider, seconds, name \\ "main") do
    Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, name).id),
      set: [
        lease_id: Ecto.UUID.generate(),
        lease_until: DateTime.add(DateTime.utc_now(), seconds)
      ]
    )
  end

  defp trail(provider) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^provider.organisation_id and e.action == "model_key.refresh",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  # The refresh answers `answer`, a function of the decoded request or a map, and tells the
  # test about each request.
  defp stub!(answer) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, raw})

      case answer do
        fun when is_function(fun, 2) -> fun.(conn, Jason.decode!(raw))
        %{} = body -> Req.Test.json(conn, body)
        {status, body} when is_binary(body) -> Plug.Conn.send_resp(conn, status, body)
        {status, body} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  defp new_tokens(tag, opts \\ []) do
    tokens = login_tokens([tag: tag] ++ opts)
    %{"access_token" => tokens.access_token, "refresh_token" => tokens.refresh_token}
  end

  defp requests(acc \\ []) do
    receive do
      {:request, conn, raw} -> requests([{conn, Jason.decode!(raw)} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp secrets_of(tokens),
    do: [tokens.access_token, tokens.refresh_token, tokens.id_token]

  describe "when no refresh is due" do
    test "returns the stored access token and its expiry with no call", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 3600)
      stub!(%{})

      assert {:ok, access, expires_at} = token(provider)
      assert access == tokens.access_token
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 3590..3600
      assert requests() == []
      assert trail(provider) == []
      assert %Login{lease_id: nil, failures: 0, refreshed_at: nil} = row(provider)
    end

    # The clock is fixed with `now:`, so the boundary does not move with the test's speed.
    test "a run's request is due 330 seconds before the expiry, not 331", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 3600)
      expires_at = row(provider).access_expires_at
      stub!(new_tokens("due"))

      assert {:ok, access, _at} = token(provider, now: DateTime.add(expires_at, -331))
      assert access == tokens.access_token
      assert requests() == []

      assert {:ok, access, _at} = token(provider, now: DateTime.add(expires_at, -329))
      assert access != tokens.access_token
      assert [{_conn, %{"refresh_reason" => "proactive_expiry"}}] = requests()
    end

    test "the schedule trigger is due 300 seconds before the expiry, not 301", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 3600)
      expires_at = row(provider).access_expires_at
      stub!(new_tokens("scheduled"))

      assert {:ok, access, _at} =
               token(provider, trigger: :schedule, now: DateTime.add(expires_at, -301))

      assert access == tokens.access_token
      assert requests() == []

      assert {:ok, access, _at} =
               token(provider, trigger: :schedule, now: DateTime.add(expires_at, -299))

      assert access != tokens.access_token
      assert [{_conn, %{"refresh_reason" => "proactive_expiry"}}] = requests()
      assert [%Entry{details: %{"trigger" => "schedule"}}] = trail(provider)
    end

    test "a login of 7 days with an expiry in the year 9999 is not refreshed", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, exp: 253_402_300_799)
      stub!(%{})
      set_login!(provider, signed_in_at: -7 * @day)

      assert {:ok, _access, _at} = token(provider)
      assert requests() == []
    end

    test "a login that waits for its retry gets no call", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 100)
      set_login!(provider, retry_at: 30)
      stub!(%{})

      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token
      assert requests() == []
    end
  end

  describe "when a refresh is due" do
    test "an access token that expired refreshes now", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: -60)
      stub!(new_tokens("fresh"))

      assert {:ok, access, expires_at} = token(provider)
      refute access == tokens.access_token
      assert DateTime.diff(expires_at, DateTime.utc_now()) > 800_000
      assert [{_conn, %{"refresh_reason" => "proactive_expiry"}}] = requests()
    end

    test "a readable exp far ahead is not refreshed after 8 days, nor after 400", %{scope: scope} do
      {provider, tokens} = subscription!(scope, exp: 253_402_300_799)
      stub!(%{})
      set_login!(provider, signed_in_at: -400 * @day, refreshed_at: -9 * @day)

      assert {:ok, access, expires_at} = token(provider)
      assert access == tokens.access_token
      assert expires_at.year == 9999
      assert requests() == []
    end

    test "a login with no readable exp refreshes 8 days after the last refresh, not before",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, exp: 253_402_300_799)
      stub!(%{})
      opaque!(provider, tokens)
      set_login!(provider, signed_in_at: -8 * @day + 60)

      assert {:ok, "opaque-access-token", nil} = token(provider)
      assert requests() == []

      stub!(new_tokens("eight"))
      set_login!(provider, signed_in_at: -8 * @day - 60)
      assert {:ok, fresh, expires_at} = token(provider)
      refute fresh == "opaque-access-token"
      assert expires_at != nil
      assert [{_conn, %{"refresh_reason" => "scheduled"}}] = requests()
      assert %Login{refreshed_at: %DateTime{}} = row(provider)
    end

    test "counts the 8 days from the last refresh, not from the sign-in", %{scope: scope} do
      {provider, tokens} = subscription!(scope, exp: 253_402_300_799)
      stub!(%{})
      opaque!(provider, tokens)
      set_login!(provider, signed_in_at: -30 * @day, refreshed_at: -7 * @day)

      assert {:ok, _access, nil} = token(provider)
      assert requests() == []

      set_login!(provider, refreshed_at: -9 * @day)
      stub!(new_tokens("old", exp: 253_402_300_798))
      assert {:ok, _access, _at} = token(provider)
      assert [{_conn, %{"refresh_reason" => "scheduled"}}] = requests()
    end

    test "sends one JSON request with the grant, the client of the entry and no scope",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 60)
      stub!(new_tokens("body"))
      {:ok, entry} = Providers.fetch("openai-subscription")
      %{"oauth_refresh" => %{"client_id" => client_id, "url" => url}} = hd(entry.apis)

      assert {:ok, _access, _at} = token(provider)

      assert [{conn, body}] = requests()
      assert conn.method == "POST"
      assert url == "https://auth.openai.com/oauth/token"

      assert {conn.scheme, conn.host, conn.request_path} ==
               {:https, "auth.openai.com", "/oauth/token"}

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["qory-apiary"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      assert body == %{
               "grant_type" => "refresh_token",
               "client_id" => client_id,
               "refresh_token" => tokens.refresh_token,
               "refresh_reason" => "proactive_expiry"
             }

      refute Map.has_key?(body, "scope")
    end

    test "stores the new tokens, keeps the old refresh token when none comes, and writes the row",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 60)
      value_before = Repo.get!(Value, value(provider).id)
      key_state!(provider, "main", until: in_seconds(3600))
      fresh = new_tokens("a")
      stub!(%{"access_token" => fresh["access_token"], "id_token" => "ignored.id.token"})

      assert {:ok, access, _at} = token(provider)
      assert access == fresh["access_token"]

      assert stored(provider) == %{
               access_token: fresh["access_token"],
               refresh_token: tokens.refresh_token
             }

      after_value = Repo.get!(Value, value(provider).id)
      assert after_value.value_set_at == value_before.value_set_at
      assert after_value.ciphertext != value_before.ciphertext
      assert Apiary.ModelKeys.provider_states(provider, DateTime.utc_now())[after_value.id]

      assert %Login{
               state: "signed_in",
               failures: 0,
               retry_at: nil,
               last_failure: nil,
               lease_id: nil,
               lease_until: nil,
               generation: 1,
               refreshed_at: %DateTime{}
             } = login = row(provider)

      assert DateTime.diff(login.refreshed_at, DateTime.utc_now()) in -5..5

      next = new_tokens("b")
      stub!(next)
      set_login!(provider, access_expires_at: 10, refreshed_at: -120)
      assert {:ok, second, _at} = token(provider)
      assert stored(provider).refresh_token == next["refresh_token"]
      assert second == next["access_token"]
    end

    test "a login refreshed in the last second needs no second call", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      stub!(new_tokens("once"))

      assert {:ok, access, _at} = token(provider)
      assert {:ok, ^access, _at} = token(provider)
      assert length(requests()) == 1
    end

    test "a refreshed token with no readable exp is stored, with no expiry", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      stub!(%{"access_token" => "opaque-access-token", "refresh_token" => "next-refresh"})

      assert {:ok, "opaque-access-token", nil} = token(provider)

      assert stored(provider) == %{
               access_token: "opaque-access-token",
               refresh_token: "next-refresh"
             }

      assert %Login{access_expires_at: nil, failures: 0, refreshed_at: %DateTime{}} =
               row(provider)

      assert [%Entry{details: %{"outcome" => "refreshed"}}] = trail(provider)
    end

    test "a due refresh in an organisation marked for deletion is refused by access: no call, no entry",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 60)
      stub!(new_tokens("refused"))

      Repo.update_all(
        from(o in Apiary.Organisations.Organisation, where: o.id == ^provider.organisation_id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), 30 * @day),
          purge_trigger: "grace_period"
        ]
      )

      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token
      assert requests() == []
      assert trail(provider) == []
      assert %Login{lease_id: nil, failures: 0, refreshed_at: nil} = row(provider)
    end
  end

  describe "one refresh at a time" do
    test "two callers on one expiring login send one request and both get the new token",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      fresh = new_tokens("race")
      test = self()

      Req.Test.stub(LoginRefresh, fn conn ->
        send(test, :request)
        Process.sleep(500)
        Req.Test.json(conn, fresh)
      end)

      calls =
        for _caller <- 1..2 do
          Task.async(fn -> token(provider, poll: 20) end)
        end

      assert [{:ok, access, expires_at}, {:ok, access_too, expires_at_too}] =
               Task.await_many(calls, 20_000)

      assert access == fresh["access_token"]
      assert {access_too, expires_at_too} == {access, expires_at}

      assert_received :request
      refute_received :request

      assert stored(provider).refresh_token == fresh["refresh_token"]
      assert %Login{lease_id: nil, failures: 0} = row(provider)
      assert [%Entry{details: %{"outcome" => "refreshed"}}] = trail(provider)
    end

    test "a caller that waits returns the old token while it is valid, when the wait ends",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 200)
      hold_lease!(provider, 30)
      stub!(%{})

      started = System.monotonic_time(:millisecond)
      assert {:ok, access, _at} = token(provider, wait: 300, poll: 50)
      assert access == tokens.access_token
      assert System.monotonic_time(:millisecond) - started >= 300
      assert requests() == []
    end

    test "a caller that waits gets :unavailable once the old token expired", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -10)
      hold_lease!(provider, 30)
      stub!(%{})

      assert token(provider, wait: 200, poll: 50) == {:error, :unavailable}
      assert requests() == []
    end

    test "a lease past lease_until is taken over", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      hold_lease!(provider, -1)
      fresh = new_tokens("takeover")
      stub!(fresh)

      assert {:ok, access, _at} = token(provider)
      assert access == fresh["access_token"]
      assert length(requests()) == 1
      assert %Login{lease_id: nil, lease_until: nil} = row(provider)
    end

    test "the lease lasts 60 seconds by the database's clock", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      test = self()

      Req.Test.stub(LoginRefresh, fn conn ->
        send(test, {:during, row(provider)})
        Req.Test.json(conn, new_tokens("lease"))
      end)

      assert {:ok, _access, _at} = token(provider)
      assert_received {:during, %Login{lease_id: lease_id, lease_until: lease_until}}
      assert is_binary(lease_id)
      assert DateTime.diff(lease_until, DateTime.utc_now()) in 55..60
    end

    test "a call that comes in while the lease is held by a refresh that fails takes the old token",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 200)
      test = self()

      Req.Test.stub(LoginRefresh, fn conn ->
        send(test, :request)
        Process.sleep(300)
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{})
      end)

      calls =
        for _caller <- 1..2, do: Task.async(fn -> token(provider, poll: 20) end)

      assert [{:ok, first, _}, {:ok, second, _}] = Task.await_many(calls, 20_000)
      assert {first, second} == {tokens.access_token, tokens.access_token}
      assert_received :request
      refute_received :request
      assert %Login{failures: 1} = row(provider)
    end
  end

  describe "a result that is dropped" do
    test "a login pasted during the call stays, and the result is dropped", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      pasted = login_tokens(tag: "pasted")
      fresh = new_tokens("lost")

      stub!(fn conn, _body ->
        {:ok, _} =
          Connections.update_provider_key(scope, plain(provider), "main", %{
            "value_id" => "main",
            "value" => login_paste(tokens: pasted)
          })

        Req.Test.json(conn, fresh)
      end)

      assert {:ok, access, _at} = token(provider)
      assert access == pasted.access_token

      assert stored(provider) == %{
               access_token: pasted.access_token,
               refresh_token: pasted.refresh_token
             }

      assert %Login{generation: 2, lease_id: nil, failures: 0} = row(provider)

      assert trail(provider) == []

      assert length(requests()) == 1
    end

    test "a key deleted during the call is gone, and nothing is written", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tag: "spare")
        })

      spare_id = value(provider, "spare").id
      set_login!(provider, [access_expires_at: 60], "spare")

      stub!(fn conn, _body ->
        {:ok, _} = Connections.delete_provider_key(scope, plain(provider), "spare")
        Req.Test.json(conn, new_tokens("gone"))
      end)

      assert Login.access_token(plain(provider), spare_id, trigger: {:run, "run-1"}) ==
               {:error, :not_found}

      assert Repo.get(Value, spare_id) == nil
      assert Repo.get(Login, spare_id) == nil

      assert trail(provider) == []
    end

    test "a key renamed during the call keeps the rotated token under the new name",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope)
      spare = login_tokens(tag: "spare", expires_in: 60)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "spare",
          value: login_paste(tokens: spare)
        })

      id = value(provider, "spare").id
      fresh = new_tokens("renamed")

      stub!(fn conn, _body ->
        {:ok, _} = Connections.rename_provider_key(scope, plain(provider), "spare", "renamed")
        Req.Test.json(conn, fresh)
      end)

      assert {:ok, access, _at} = token(provider, key: "spare")
      assert access == fresh["access_token"]
      assert length(requests()) == 1
      assert value(provider, "renamed").id == id

      assert stored(provider, "renamed") == %{
               access_token: fresh["access_token"],
               refresh_token: fresh["refresh_token"]
             }

      assert %Login{lease_id: nil, failures: 0, refreshed_at: %DateTime{}} =
               row(provider, "renamed")

      # The next call reads the new token and makes no second call.
      assert {:ok, ^access, _at} = token(provider, key: "renamed")
      assert requests() == []

      # The entry names the key as it is named when the outcome is written.
      assert [%Entry{details: %{"outcome" => "refreshed", "value_id" => "renamed"}}] =
               trail(provider)
    end

    test "a lease taken over during the call drops the result", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      other = Ecto.UUID.generate()

      stub!(fn conn, _body ->
        Repo.update_all(from(l in Login), set: [lease_id: other])
        Req.Test.json(conn, new_tokens("late"))
      end)

      assert {:ok, _access, _at} = token(provider)
      assert %Login{lease_id: ^other} = row(provider)
      assert stored(provider).refresh_token != new_tokens("late")["refresh_token"]
      assert trail(provider) == []
    end
  end

  describe "a refusal that stays" do
    for {name, status, body, cause} <- [
          {"expired", 401, %{"error" => "refresh_token_expired"}, "refresh_token_expired"},
          {"reused", 400, %{"error" => %{"code" => "refresh_token_reused"}},
           "refresh_token_reused"},
          {"invalidated", 403, %{"code" => "REFRESH_TOKEN_INVALIDATED"},
           "refresh_token_invalidated"},
          {"invalid_grant", 400, %{"error" => "invalid_grant"}, "invalid_grant"},
          {"unauthorized", 401, %{"error" => "some_other_code"}, "refresh_unauthorized"},
          {"unauthorized without a body", 401, "", "refresh_unauthorized"}
        ] do
      test "#{name} sets sign_in_needed and no later call is sent", %{scope: scope} do
        {provider, tokens} = subscription!(scope, expires_in: 60)
        stub!({unquote(status), unquote(Macro.escape(body))})

        log = capture_log(fn -> send(self(), {:result, token(provider)}) end)
        assert_received {:result, {:error, :sign_in_needed}}
        assert log == ""

        cause = unquote(cause)

        assert %Login{state: "sign_in_needed", sign_in_cause: ^cause, failures: 1} =
                 login = row(provider)

        assert login.lease_id == nil and login.retry_at == nil
        assert DateTime.diff(login.last_failure, DateTime.utc_now()) in -5..5
        assert Login.causes() |> Enum.member?(cause)

        assert [{_conn, _body}] = requests()
        assert token(provider) == {:error, :sign_in_needed}
        assert token(provider, trigger: :schedule) == {:error, :sign_in_needed}
        assert requests() == []

        assert [%Entry{details: details}] = trail(provider)
        assert %{"outcome" => "sign_in_needed", "cause" => ^cause} = details

        assert stored(provider) == %{
                 access_token: tokens.access_token,
                 refresh_token: tokens.refresh_token
               }
      end
    end

    test "a new login pasted over a key that needs a sign-in starts it again", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      stub!({401, %{"error" => "refresh_token_reused"}})
      assert token(provider) == {:error, :sign_in_needed}

      pasted = login_tokens(tag: "again")

      {:ok, _} =
        Connections.update_provider_key(scope, plain(provider), "main", %{
          "value_id" => "main",
          "value" => login_paste(tokens: pasted)
        })

      assert %Login{state: "signed_in", sign_in_cause: nil, generation: 2} = row(provider)
      assert {:ok, access, _at} = token(provider)
      assert access == pasted.access_token
    end
  end

  # Waits until `fun` is true, 5 seconds at most: for what a task that no caller owns writes.
  defp eventually(fun, left \\ 250) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("the condition did not become true in 5 seconds")
      true -> Process.sleep(20) && eventually(fun, left - 1)
    end
  end

  describe "a refresh that its caller does not wait for" do
    test "a caller killed once the answer comes loses nothing: the token is stored, the next caller reads it",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      fresh = new_tokens("kept")
      test = self()

      stub!(fn conn, _body ->
        send(test, {:in_call, self()})

        receive do
          :go -> :ok
        after
          5_000 -> :ok
        end

        Req.Test.json(conn, fresh)
      end)

      log =
        capture_log(fn ->
          {:ok, caller} = Task.start(fn -> token(provider) end)
          assert_receive {:in_call, call}, 5_000
          monitor = Process.monitor(caller)
          Process.exit(caller, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
          send(call, :go)

          eventually(fn -> stored(provider).refresh_token == fresh["refresh_token"] end)
        end)

      assert stored(provider) == %{
               access_token: fresh["access_token"],
               refresh_token: fresh["refresh_token"]
             }

      assert %Login{lease_id: nil, failures: 0, refreshed_at: %DateTime{}} = row(provider)
      assert [%Entry{details: %{"outcome" => "refreshed"}}] = eventually_trail(provider)

      # The next caller gets the new token and makes no second call.
      assert {:ok, access, _at} = token(provider)
      assert access == fresh["access_token"]
      assert length(requests()) == 1

      for secret <- [fresh["access_token"], fresh["refresh_token"]], do: refute(log =~ secret)
    end

    test "a caller out of time gets the old token while it is valid, and the call still stores its result",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 200)
      fresh = new_tokens("late")

      stub!(fn conn, _body ->
        Process.sleep(300)
        Req.Test.json(conn, fresh)
      end)

      assert {:ok, access, _at} = token(provider, wait: 50)
      assert access == tokens.access_token

      eventually(fn -> stored(provider).refresh_token == fresh["refresh_token"] end)
      assert {:ok, access, _at} = token(provider)
      assert access == fresh["access_token"]
      assert length(requests()) == 1
    end

    test "a caller out of time with an expired token gets :unavailable", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -60)
      fresh = new_tokens("later")

      stub!(fn conn, _body ->
        Process.sleep(300)
        Req.Test.json(conn, fresh)
      end)

      assert token(provider, wait: 50) == {:error, :unavailable}
      eventually(fn -> stored(provider).refresh_token == fresh["refresh_token"] end)
    end
  end

  # The newest entries once the unowned task has written them.
  defp eventually_trail(provider) do
    eventually(fn -> trail(provider) != [] end)
    trail(provider)
  end

  describe "a refresh right after a refresh" do
    test "that answered a token already past its exp waits 60 seconds", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -60)
      past = new_tokens("past", expires_in: -30)
      stub!(past)

      assert {:ok, access, _at} = token(provider)
      assert access == past["access_token"]
      assert length(requests()) == 1

      refreshed_at = row(provider).refreshed_at

      # 59 seconds on, the call is held: the token has expired, so there is none to give.
      assert token(provider, now: DateTime.add(refreshed_at, 59)) == {:error, :unavailable}
      assert requests() == []

      assert {:ok, _access, _at} = token(provider, now: DateTime.add(refreshed_at, 61))
      assert length(requests()) == 1
    end

    test "that answered a token within the lead gives that token inside the gap", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -60)
      short = new_tokens("short", expires_in: 200)
      stub!(short)

      assert {:ok, access, _at} = token(provider)
      refreshed_at = row(provider).refreshed_at
      assert requests() |> length() == 1

      assert {:ok, ^access, _at} = token(provider, now: DateTime.add(refreshed_at, 59))
      assert requests() == []
      assert {:ok, _access, _at} = token(provider, now: DateTime.add(refreshed_at, 61))
      assert length(requests()) == 1
    end

    test "a login that was never refreshed is not held", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -60)
      stub!(new_tokens("first"))
      assert {:ok, _access, _at} = token(provider)
      assert length(requests()) == 1
    end
  end

  describe "a rotated refresh token that cannot be stored" do
    # A document past a value's size: the key refuses it.
    defp oversized(tag), do: %{new_tokens(tag) | "access_token" => String.duplicate("a", 17_000)}

    test "makes the login need a sign-in at once, and no call uses the spent token",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 60)
      big = oversized("big")
      stub!(big)

      log = capture_log(fn -> send(self(), {:result, token(provider)}) end)
      assert_received {:result, {:error, :sign_in_needed}}

      assert %Login{state: "sign_in_needed", sign_in_cause: "refresh_token_reused", lease_id: nil} =
               row(provider)

      assert stored(provider) == %{
               access_token: tokens.access_token,
               refresh_token: tokens.refresh_token
             }

      assert length(requests()) == 1

      assert [
               %Entry{
                 details: %{"outcome" => "sign_in_needed", "cause" => "refresh_token_reused"}
               }
             ] =
               trail(provider)

      assert token(provider) == {:error, :sign_in_needed}
      assert token(provider, trigger: :schedule) == {:error, :sign_in_needed}
      assert requests() == []

      for secret <- [big["refresh_token"], tokens.refresh_token], do: refute(log =~ secret)
    end

    test "is only a failure that may pass when the provider kept the refresh token",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 200)
      stub!(%{"access_token" => String.duplicate("a", 17_000)})

      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token

      assert %Login{state: "signed_in", failures: 1, lease_id: nil} = login = row(provider)
      assert DateTime.diff(login.retry_at, DateTime.utc_now()) in 25..30
      assert trail(provider) == []
    end
  end

  describe "the answer of the provider" do
    for {name, status, body, outcome} <- [
          {"an empty error with a named code", 400,
           %{"error" => "", "code" => "refresh_token_expired"},
           {:permanent, "refresh_token_expired"}},
          {"a blank error with an error.code", 400,
           %{"error" => "  ", "code" => "x", "details" => %{}}, {:transient, "http_400"}},
          {"an error object with a named code", 400,
           %{"error" => %{"code" => "refresh_token_invalidated"}},
           {:permanent, "refresh_token_invalidated"}},
          {"a named code at a 500", 500, %{"code" => "refresh_token_reused"},
           {:permanent, "refresh_token_reused"}},
          {"a named code at a 200 is no refresh", 200, %{"code" => "refresh_token_reused"},
           {:transient, "bad_response"}},
          {"an access token with a space", 200, %{"access_token" => "has space"},
           {:transient, "bad_response"}},
          {"an access token that is not ASCII", 200, %{"access_token" => "tökén"},
           {:transient, "bad_response"}},
          {"an access token with a line feed", 200, %{"access_token" => "abc\n"},
           {:transient, "bad_response"}}
        ] do
      test "#{name}", %{scope: scope} do
        {provider, _tokens} = subscription!(scope, expires_in: 60)
        stub!({unquote(status), unquote(Macro.escape(body))})
        token(provider)

        assert %Login{state: state, sign_in_cause: cause, last_failure: failed_at} = row(provider)

        case unquote(Macro.escape(outcome)) do
          {:permanent, code} ->
            assert {state, cause} == {"sign_in_needed", code}

          {:transient, code} ->
            assert state == "signed_in"
            assert failed_at != nil
            assert [%Entry{details: %{"cause" => ^code}}] = trail(provider)
        end
      end
    end
  end

  describe "a streak of failures" do
    # Each failing attempt is made after the wait of the one before.
    defp fail_again!(provider, status \\ 503, opts \\ []) do
      set_login!(provider, retry_at: -1)
      stub!({status, %{}})
      token(provider, opts)
    end

    defp outcomes(provider),
      do: Enum.map(trail(provider), &{&1.details["outcome"], &1.details["cause"]})

    test "the first failure leaves one entry, the failures after it leave none", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token

      assert %Login{failures: 1, failing_since: %DateTime{}, retry_at: first_retry} =
               row(provider)

      for _again <- 1..5, do: assert({:ok, _access, _at} = fail_again!(provider))

      assert %Login{failures: 6, failing_since: %DateTime{}} = login = row(provider)
      assert length(requests()) == 6
      assert login.retry_at != first_retry

      # The entry's retry time is the one scheduled at the first failure.
      assert [%Entry{details: %{"outcome" => "failed", "cause" => "http_503"} = details}] =
               trail(provider)

      assert details["retry_at"] == DateTime.to_iso8601(first_retry)
    end

    test "a refresh that works ends the streak with the entry of a refresh that works",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      token(provider)
      fail_again!(provider)

      set_login!(provider, retry_at: -1)
      stub!(new_tokens("recovered"))
      assert {:ok, _access, _at} = token(provider)

      assert %Login{failures: 0, failing_since: nil, retry_at: nil, last_failure: nil} =
               row(provider)

      assert outcomes(provider) == [{"failed", "http_503"}, {"refreshed", nil}]
    end

    test "a second streak leaves a new failure entry", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      token(provider)
      fail_again!(provider)
      set_login!(provider, retry_at: -1)
      stub!(new_tokens("between", expires_in: 100))
      assert {:ok, _access, _at} = token(provider)

      # The refreshed token is within the lead again, a minute on.
      set_login!(provider, refreshed_at: -120)
      fail_again!(provider, 500)
      fail_again!(provider, 500)

      assert outcomes(provider) == [
               {"failed", "http_503"},
               {"refreshed", nil},
               {"failed", "http_500"}
             ]
    end

    test "a login pasted over the key ends the streak with no entry", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      token(provider)
      assert %Login{failing_since: %DateTime{}} = row(provider)

      {:ok, _} =
        Connections.update_provider_key(scope, plain(provider), "main", %{
          "value_id" => "main",
          "value" => login_paste(tag: "pasted", expires_in: 100)
        })

      assert %Login{failing_since: nil, failures: 0, retry_at: nil} = row(provider)
      assert outcomes(provider) == [{"failed", "http_503"}]

      # A failure of the new login opens a streak of its own.
      stub!({503, %{}})
      token(provider)
      assert outcomes(provider) == [{"failed", "http_503"}, {"failed", "http_503"}]
    end

    test "the sweep's failures and a run's count in one streak", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})

      assert {:ok, _access, _at} = token(provider, trigger: :schedule)
      fail_again!(provider, 503, trigger: {:run, "run-1"})
      fail_again!(provider, 503, trigger: :schedule)

      assert [%Entry{details: %{"trigger" => "schedule", "outcome" => "failed"}}] =
               trail(provider)

      assert length(requests()) == 3
      set_login!(provider, retry_at: -1)
      stub!(new_tokens("sweep-recovered"))
      assert {:ok, _access, _at} = token(provider, trigger: {:run, "run-2"})

      assert [
               %Entry{details: %{"trigger" => "schedule", "outcome" => "failed"}},
               %Entry{details: %{"trigger" => "run", "outcome" => "refreshed"}}
             ] = trail(provider)
    end

    test "a refusal that stays leaves its entry even in a streak that may pass",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      token(provider)
      set_login!(provider, retry_at: -1)
      stub!({401, %{"error" => "refresh_token_expired"}})
      assert token(provider) == {:error, :sign_in_needed}

      assert outcomes(provider) == [
               {"failed", "http_503"},
               {"sign_in_needed", "refresh_token_expired"}
             ]

      assert %Login{state: "sign_in_needed", failing_since: %DateTime{}} = row(provider)

      # A paste of a new login ends it, and no call is made before.
      {:ok, _} =
        Connections.update_provider_key(scope, plain(provider), "main", %{
          "value_id" => "main",
          "value" => login_paste(tag: "again")
        })

      assert %Login{state: "signed_in", failing_since: nil} = row(provider)
      assert length(trail(provider)) == 2
    end

    test "no token is in the log, the row or an entry of a streak", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 100)
      fresh = new_tokens("quiet")

      log =
        capture_log(fn ->
          stub!(
            {503, %{"refresh_token" => "rt-in-an-answer", "access_token" => "at-in-an-answer"}}
          )

          token(provider)
          fail_again!(provider)
          set_login!(provider, retry_at: -1)
          stub!(fresh)
          token(provider)
        end)

      text =
        inspect(row(provider), limit: :infinity) <>
          inspect(trail(provider), limit: :infinity) <> log

      for secret <-
            secrets_of(tokens) ++
              [
                fresh["access_token"],
                fresh["refresh_token"],
                "rt-in-an-answer",
                "at-in-an-answer"
              ],
          do: refute(text =~ secret)
    end
  end

  describe "a failure that may pass" do
    for {name, status, body, cause} <- [
          {"a 500", 500, %{"error" => "server_error"}, "http_500"},
          {"a 503 with a refresh token in its text", 503, "refresh_token_reused rt-fixture",
           "http_503"},
          {"a 429", 429, %{"error" => "rate_limited"}, "http_429"},
          {"a 400 that is no invalid_grant", 400, %{"error" => "invalid_request"}, "http_400"},
          {"a 403", 403, "", "http_403"},
          {"an answer that is no JSON", 200, "<html>", "bad_response"},
          {"an answer with no access token", 200, %{"refresh_token" => "x"}, "bad_response"},
          {"an answer of 204", 204, "", "bad_response"}
        ] do
      test "#{name} sets retry_at and returns the old token while it is valid", %{scope: scope} do
        {provider, tokens} = subscription!(scope, expires_in: 120)

        stub!({unquote(status), unquote(Macro.escape(body))})

        log = capture_log(fn -> send(self(), {:result, token(provider)}) end)
        assert_received {:result, {:ok, access, _at}}
        assert access == tokens.access_token
        assert log == ""

        cause = unquote(cause)
        assert %Login{state: "signed_in", failures: 1, lease_id: nil} = login = row(provider)
        assert DateTime.diff(login.retry_at, DateTime.utc_now()) in 25..30
        assert login.last_failure != nil

        assert [%Entry{details: %{"outcome" => "failed", "cause" => ^cause}}] = trail(provider)
        assert length(requests()) == 1

        # Inside the wait no second call is made.
        assert {:ok, ^access, _at} = token(provider)
        assert requests() == []
      end
    end

    test "a redirect is not followed", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 120)

      stub!(fn conn, _body ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/oauth/token")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token
      assert [_one_request] = requests()
      assert [%Entry{details: %{"cause" => "http_302"}}] = trail(provider)
    end

    test "a failed refresh of an expired token is :unavailable", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: -5)
      stub!({503, %{}})

      assert token(provider) == {:error, :unavailable}
      assert %Login{failures: 1, state: "signed_in"} = row(provider)
      assert token(provider) == {:error, :unavailable}
      assert length(requests()) == 1
    end

    test "the wait doubles for each failure in a row, up to 10 minutes", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 120)
      stub!({503, %{}})

      for expected <- [30, 60, 120, 240, 480, 600, 600] do
        set_login!(provider, retry_at: -1)
        assert {:ok, _access, _at} = token(provider)
        login = row(provider)
        assert_in_delta DateTime.diff(login.retry_at, login.last_failure), expected, 1
      end

      assert %Login{failures: 7} = row(provider)
    end

    test "a success after failures clears them", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 120)
      stub!({503, %{}})
      assert {:ok, _access, _at} = token(provider)
      assert %Login{failures: 1} = row(provider)

      set_login!(provider, retry_at: -1)
      recovered = new_tokens("recovered")
      stub!(recovered)
      assert {:ok, access, _at} = token(provider)
      assert access == recovered["access_token"]
      assert %Login{failures: 0, retry_at: nil, last_failure: nil} = row(provider)
    end

    test "a transport error and a timeout of the client", %{scope: scope} do
      for reason <- [:econnrefused, :timeout] do
        {provider, tokens} = subscription!(scope, expires_in: 120)
        Req.Test.stub(LoginRefresh, &Req.Test.transport_error(&1, reason))

        log = capture_log(fn -> send(self(), {:result, token(provider)}) end)
        assert_received {:result, {:ok, access, _at}}
        assert access == tokens.access_token
        assert log == ""

        expected = if reason == :timeout, do: "timeout", else: "network"
        assert [%Entry{details: %{"cause" => ^expected}}] = trail(provider)
        Repo.delete_all(from e in Entry, where: e.action == "model_key.refresh")
      end
    end

    test "a call that outlasts its limit is stopped and is a timeout", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 120)
      previous = Application.get_env(:apiary, LoginRefresh)
      Application.put_env(:apiary, LoginRefresh, Keyword.put(previous, :total_timeout, 100))
      on_exit(fn -> Application.put_env(:apiary, LoginRefresh, previous) end)

      stub!(fn conn, _body ->
        Process.sleep(2_000)
        Req.Test.json(conn, new_tokens("late"))
      end)

      assert {:ok, access, _at} = token(provider)
      assert access == tokens.access_token
      assert [%Entry{details: %{"cause" => "timeout"}}] = trail(provider)
    end

    test "an answer over 64 KiB is a failure", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 120)
      stub!(fn conn, _body -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 70_000)) end)

      assert {:ok, _access, _at} = token(provider)
      assert [%Entry{details: %{"cause" => "bad_response"}}] = trail(provider)
    end

    test "a crash in the call is caught: no log line has a token", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 120)

      stub!(fn _conn, body ->
        raise "boom #{body["refresh_token"]}"
      end)

      log = capture_log(fn -> send(self(), {:result, token(provider)}) end)
      assert_received {:result, {:ok, _access, _at}}
      for secret <- secrets_of(tokens), do: refute(log =~ secret)
      assert log == ""
      assert [%Entry{details: %{"cause" => "network"}}] = trail(provider)
    end
  end

  describe "the entry of each call" do
    test "names the provider, the key, the trigger and the reason, never a token", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 60)
      fresh = new_tokens("audit")
      stub!(fresh)

      assert {:ok, _access, _at} = token(provider, trigger: {:run, "run-1234"})

      assert [%Entry{} = entry] = trail(provider)
      assert entry.actor_kind == :instance
      assert entry.subject_kind == "connection"
      assert entry.subject_id == provider.id
      assert entry.organisation_id == provider.organisation_id
      assert entry.workspace_id == nil
      assert entry.before == nil and entry.after == nil

      assert entry.details == %{
               "provider_id" => provider.public_id,
               "provider" => provider.name,
               "value_id" => "main",
               "trigger" => "run",
               "run_id" => "run-1234",
               "refresh_reason" => "proactive_expiry",
               "outcome" => "refreshed"
             }

      text = inspect(entry, limit: :infinity) <> Jason.encode!(entry.details)

      for secret <- secrets_of(tokens) ++ [fresh["access_token"], fresh["refresh_token"]],
          do: refute(text =~ secret)
    end

    test "a refresh by the sweep says so", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 3600)
      set_login!(provider, signed_in_at: -8 * @day)
      stub!(new_tokens("sweep"))

      assert {:ok, _access, _at} = token(provider, trigger: :schedule)

      assert [%Entry{details: details}] = trail(provider)

      assert details["trigger"] == "schedule"
      assert details["refresh_reason"] == "scheduled"
      refute Map.has_key?(details, "run_id")
    end

    test "each call leaves one entry, whatever its outcome", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 100)
      stub!({503, %{}})
      assert {:ok, _access, _at} = token(provider)
      set_login!(provider, retry_at: -1)
      stub!(new_tokens("second"))
      assert {:ok, _access, _at} = token(provider)
      set_login!(provider, access_expires_at: 10, refreshed_at: -120)
      stub!({401, %{"error" => "refresh_token_reused"}})
      assert token(provider) == {:error, :sign_in_needed}

      assert Enum.map(trail(provider), &{&1.details["outcome"], &1.details["cause"]}) == [
               {"failed", "http_503"},
               {"refreshed", nil},
               {"sign_in_needed", "refresh_token_reused"}
             ]
    end
  end

  describe "what the key shows after a call" do
    test "a refresh writes the state line, and no token is in the entry's page words",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      stub!(new_tokens("shown"))
      assert {:ok, _access, _at} = token(provider)

      assert {:signed_in, time} =
               ApiaryWeb.ModelKeyComponents.login(row(provider), plain(provider))

      assert is_binary(time)

      stub!({401, %{"error" => "refresh_token_expired"}})
      set_login!(provider, access_expires_at: 10, refreshed_at: -120)
      assert token(provider) == {:error, :sign_in_needed}

      assert {:sign_in_needed, rejected, help} =
               ApiaryWeb.ModelKeyComponents.login(row(provider), plain(provider))

      assert rejected =~ "OpenAI rejected it on"
      assert help == "Run codex login --device-auth and replace the key."
    end
  end

  describe "a key that is not a login of the provider" do
    test "is not found", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      %{scope: other_scope} = sign_up_fixture()
      {other, _tokens} = subscription!(other_scope, expires_in: 60)
      stub!(%{})

      assert Login.access_token(plain(provider), value(other).id, trigger: :schedule) ==
               {:error, :not_found}

      assert Login.access_token(plain(provider), Ecto.UUID.generate(), trigger: :schedule) ==
               {:error, :not_found}

      assert Login.access_token(plain(provider), "not-an-id", trigger: :schedule) ==
               {:error, :not_found}

      {:ok, api} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      assert Login.access_token(plain(api), value(api).id, trigger: :schedule) ==
               {:error, :not_found}

      assert requests() == []
    end

    test "the trigger is checked", %{scope: scope} do
      {provider, _tokens} = subscription!(scope)
      id = value(provider).id

      assert_raise ArgumentError, fn -> Login.access_token(plain(provider), id, trigger: :now) end
      assert_raise KeyError, fn -> Login.access_token(plain(provider), id, []) end
    end
  end

  describe "the call itself" do
    test "refuses an address that is not an https URL, and sends nothing" do
      stub!(%{})

      for url <- ["http://auth.openai.com/oauth/token", "https://127.0.0.1/oauth/token", nil] do
        assert LoginRefresh.call(%{"url" => url, "client_id" => "c"}, "rt", "scheduled") ==
                 {:transient, "bad_endpoint"}
      end

      assert LoginRefresh.call(nil, "rt", "scheduled") == {:transient, "bad_endpoint"}

      assert LoginRefresh.call(
               %{"url" => "https://auth.example/t", "client_id" => "c"},
               "rt",
               "forced"
             ) ==
               {:transient, "bad_endpoint"}

      assert requests() == []
    end
  end

  describe "the sweep" do
    defp aged!(provider, days, name \\ "main"),
      do: set_login!(provider, [signed_in_at: -days * @day, refreshed_at: nil], name)

    test "takes only the logins older than 7 days that are signed in and not waiting",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 3600)

      {:ok, provider} =
        Enum.reduce(~w(old young refreshed failing leased needed), {:ok, provider}, fn name,
                                                                                       {:ok, p} ->
          Connections.add_provider_key(scope, p, %{value_id: name, value: login_paste(tag: name)})
        end)

      aged!(provider, 3, "main")
      aged!(provider, 8, "old")
      aged!(provider, 6, "young")
      aged!(provider, 20, "refreshed")
      set_login!(provider, [refreshed_at: -2 * @day], "refreshed")
      aged!(provider, 9, "failing")
      set_login!(provider, [retry_at: 60], "failing")
      aged!(provider, 9, "leased")
      hold_lease!(provider, 30, "leased")

      aged!(provider, 9, "needed")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, "needed").id),
        set: [state: "sign_in_needed", sign_in_cause: "invalid_grant"]
      )

      assert [{swept, id}] = Login.sweep_due(10)
      assert swept.id == provider.id
      assert id == value(provider, "old").id
    end

    test "skips an organisation marked for deletion", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 3600)
      aged!(provider, 8)
      assert [_one] = Login.sweep_due(10)

      Repo.update_all(
        from(o in Apiary.Organisations.Organisation, where: o.id == ^provider.organisation_id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), 30 * @day),
          purge_trigger: "grace_period"
        ]
      )

      assert Login.sweep_due(10) == []
    end

    test "refreshes each old login with the reason scheduled, the oldest first, at most the batch",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 3600)

      {:ok, provider} =
        Connections.add_provider_key(scope, provider, %{
          value_id: "second",
          value: login_paste(tag: "second")
        })

      aged!(provider, 8, "main")
      aged!(provider, 10, "second")

      assert [{_p, first}, {_p2, second}] = Login.sweep_due(10)
      assert {first, second} == {value(provider, "second").id, value(provider).id}
      assert [{_p3, ^first}] = Login.sweep_due(1)

      stub!(fn conn, _body ->
        Req.Test.json(conn, new_tokens("s#{System.unique_integer([:positive])}"))
      end)

      assert :ok = perform_job(LoginSweep, %{})

      assert [
               {_c1, %{"refresh_reason" => "scheduled"}},
               {_c2, %{"refresh_reason" => "scheduled"}}
             ] =
               requests()

      assert Login.sweep_due(10) == []

      assert [%{details: %{"trigger" => "schedule"}}, %{details: %{"trigger" => "schedule"}}] =
               trail(provider)

      assert :ok = perform_job(LoginSweep, %{})
      assert requests() == []
    end

    test "a login a minute short of 7 days is left alone, and one a minute over is taken",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 3600)
      stub!(%{})
      set_login!(provider, signed_in_at: -7 * @day + 60, refreshed_at: nil)
      assert Login.sweep_due(10) == []
      assert :ok = perform_job(LoginSweep, %{})
      assert requests() == []

      set_login!(provider, signed_in_at: -7 * @day - 60)
      assert [_due] = Login.sweep_due(10)
    end

    test "is in the crontab, every 6 hours" do
      crontab = Application.get_env(:apiary, Oban)[:crontab]
      assert {"25 */6 * * *", LoginSweep} = List.keyfind(crontab, LoginSweep, 1)
    end
  end

  describe "the stored value after refreshes" do
    test "reveal_key_and_set_at/2 still refuses the key", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 60)
      stub!(new_tokens("sealed"))
      assert {:ok, _access, _at} = token(provider)

      assert Secrets.reveal_key_and_set_at(plain(provider), value(provider).id) ==
               {:error, :login}
    end
  end
end
