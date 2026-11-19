defmodule Apiary.ModelKeys.LoginStatusTest do
  # What a claim reads of a sign-in without calling the provider
  # (`Apiary.ModelKeys.Login.status/2`, `statuses/3`, `account?/2`, `rejectable?/2`), and the
  # two refreshes a run causes: the one in the background for a sign-in that expires before
  # the end of the run's time limit (`expires_before:`), and the one after a 401
  # (`recover: true`, at most one in 5 minutes).
  # Every call goes to the `Req.Test` stub of `LoginRefresh`; no token reaches a log line.
  use Apiary.DataCase, async: true

  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.{Login, LoginRefresh}

  @moduletag needs: [:factory, :secrets]

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp subscription!(scope, opts \\ []) do
    tokens = login_tokens(opts)

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openai-subscription",
        keys: [%{value_id: "main", value: device_login(tokens: tokens)}]
      })

    {provider, tokens}
  end

  defp plain(provider), do: Repo.get!(Connection, provider.id)
  defp value(provider, name \\ "main"), do: key_value!(provider, name)
  defp row(provider, name \\ "main"), do: Repo.get!(Login, value(provider, name).id)

  defp set_login!(provider, changes, name \\ "main") do
    changes =
      for {field, seconds} <- changes,
          do: {field, seconds && DateTime.add(DateTime.utc_now(), seconds)}

    Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, name).id),
      set: changes
    )
  end

  # The key's stored document, with the access token `access_token`, written as a refresh
  # writes it.
  defp store!(provider, access_token, refresh_token) do
    id = value(provider).id
    {:ok, _plaintext, snapshot} = Apiary.Secrets.reveal_login_snapshot(plain(provider), id)

    document =
      Jason.encode!(%{
        "version" => 1,
        "access_token" => access_token,
        "refresh_token" => refresh_token
      })

    :ok = Apiary.Secrets.write_refreshed_key(plain(provider), id, document, snapshot)
  end

  defp stub!(answer) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})

      case answer do
        %{} = body -> Req.Test.json(conn, body)
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
      {:request, body} -> requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp token(provider, opts) do
    opts = Keyword.put_new(opts, :trigger, {:run, "run-1"})
    Login.access_token(plain(provider), value(provider).id, opts)
  end

  describe "status/2" do
    test "is :sign_in_needed for a sign-in that needs a new one, whatever the expiry", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope)

      Repo.update_all(from(l in Login),
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      assert Login.status(row(provider)) == :sign_in_needed

      assert Login.status(row(provider), expires_before: DateTime.add(DateTime.utc_now(), 60)) ==
               :sign_in_needed
    end

    test "is :ready while the expiry is at or after expires_before, and with no expires_before",
         %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      login = row(provider)
      now = DateTime.utc_now()

      assert Login.status(login) == :ready
      assert Login.status(login, expires_before: DateTime.add(now, 3600)) == :ready
      assert Login.status(login, expires_before: login.access_expires_at) == :ready
    end

    test "is :due when the expiry is before expires_before and no refresh runs or waits", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      assert Login.status(row(provider), expires_before: before) == :due
    end

    test "is :refreshing while a lease holds, and {:retry, at} while a retry waits", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      Repo.update_all(from(l in Login),
        set: [lease_id: Ecto.UUID.generate(), lease_until: DateTime.add(DateTime.utc_now(), 30)]
      )

      assert Login.status(row(provider), expires_before: before) == :refreshing

      Repo.update_all(from(l in Login), set: [lease_id: nil, lease_until: nil])
      set_login!(provider, retry_at: 90)
      retry_at = row(provider).retry_at
      assert Login.status(row(provider), expires_before: before) == {:retry, retry_at}
    end

    test "is :ready for a sign-in made or refreshed less than 60 seconds ago", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 600)
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      assert Login.status(row(provider), expires_before: before) == :ready
    end

    test "reads the clock it is given", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      login = row(provider)
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      assert Login.status(login,
               expires_before: before,
               now: DateTime.add(DateTime.utc_now(), -3600)
             ) == :ready

      assert Login.status(login, expires_before: before, now: DateTime.utc_now()) == :due
    end
  end

  describe "statuses/3" do
    test "reads the expiry and the account from the access token, with no call", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      stub!(%{})
      id = value(provider).id
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      assert Login.statuses(plain(provider), [id], expires_before: before) == %{id => :due}
      assert Login.statuses(plain(provider), [id]) == %{id => :ready}
      assert requests() == []
    end

    test "a token with no account id needs a new sign-in", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, account: false)
      stub!(%{})
      id = value(provider).id

      assert Login.statuses(plain(provider), [id]) == %{id => :sign_in_needed}
      assert requests() == []
    end

    test "a stored token that is readable but is no JWT needs a new sign-in", %{scope: scope} do
      {provider, tokens} = subscription!(scope)
      store!(provider, "opaque-access-token", tokens.refresh_token)
      stub!(%{})
      id = value(provider).id

      assert %Login{state: "signed_in"} = row(provider)
      assert Login.statuses(plain(provider), [id]) == %{id => :sign_in_needed}
      assert Login.statuses(plain(provider), [id], decrypt: false) == %{id => :ready}
      assert requests() == []
    end

    test "a value that cannot be read has the status its row gives", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      id = value(provider).id
      before = DateTime.add(DateTime.utc_now(), 3 * 3600)

      Repo.update_all(from(v in Apiary.Secrets.Value, where: v.id == ^id),
        set: [ciphertext: :binary.copy(<<7>>, 64)]
      )

      assert {:error, _reason} = Login.tokens(plain(provider), id)
      assert Login.statuses(plain(provider), [id]) == %{id => :ready}
      assert Login.statuses(plain(provider), [id], expires_before: before) == %{id => :due}

      set_login!(provider, signed_in_at: -3600)

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^id),
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )

      assert Login.statuses(plain(provider), [id]) == %{id => :sign_in_needed}
    end

    test "has nothing for a provider with no sign-ins, for no ids and for an unknown id",
         %{scope: scope} do
      {:ok, api} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-ant-fixture-main-0123456789"}]
        })

      assert Login.statuses(plain(api), [value(api).id]) == %{}
      {provider, _tokens} = subscription!(scope)
      assert Login.statuses(plain(provider), []) == %{}
      assert Login.statuses(plain(provider), [Ecto.UUID.generate()]) == %{}
    end

    test "puts no token in the log", %{scope: scope} do
      {provider, tokens} = subscription!(scope)
      id = value(provider).id

      log =
        capture_log(fn ->
          Login.statuses(plain(provider), [id], expires_before: DateTime.utc_now())
        end)

      refute log =~ tokens.access_token
      refute log =~ tokens.refresh_token
    end
  end

  describe "account?/2" do
    test "is true for a token with the account claim of the catalogue entry", %{scope: scope} do
      {provider, tokens} = subscription!(scope)
      assert Login.account?(plain(provider), tokens.access_token)
    end

    test "is false for a token without it, with a blank one, or that is no JWT", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope)
      none = login_tokens(account: false).access_token

      blank =
        jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "  "}, "exp" => 1})

      other = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => 7}, "exp" => 1})

      for token <- [none, blank, other, "not-a-jwt", nil] do
        refute Login.account?(plain(provider), token)
      end
    end
  end

  describe "rejectable?/2" do
    test "is true only when no refresh can fix the 401: the token is under 5 minutes old", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope)
      login = row(provider)

      assert Login.rejectable?(login, DateTime.add(login.signed_in_at, 60))
      refute Login.rejectable?(login, DateTime.add(login.signed_in_at, 300))
      refute Login.rejectable?(login, DateTime.add(login.signed_in_at, -1))
    end
  end

  describe "a refresh before the end of a run's time limit" do
    test "refreshes a sign-in whose token expires before expires_before, and no other", %{
      scope: scope
    } do
      {provider, tokens} = subscription!(scope, expires_in: 7200)
      set_login!(provider, signed_in_at: -3600)
      stub!(new_tokens("later"))

      assert {:ok, access, _at} =
               token(provider,
                 trigger: :schedule,
                 expires_before: DateTime.add(DateTime.utc_now(), 3600)
               )

      assert access == tokens.access_token
      assert requests() == []

      assert {:ok, access, _at} =
               token(provider,
                 trigger: :schedule,
                 expires_before: DateTime.add(DateTime.utc_now(), 3 * 3600)
               )

      refute access == tokens.access_token
      assert [%{"refresh_reason" => "proactive_expiry"}] = requests()
    end
  end

  describe "a renewal after a 401 (recover: true)" do
    test "refreshes a token that is far from its expiry, with the reason unauthorized_recovery",
         %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 864_000)
      set_login!(provider, signed_in_at: -600)
      stub!(new_tokens("recovered"))

      assert {:ok, access, _at} = token(provider, recover: true)
      refute access == tokens.access_token

      assert [%{"refresh_reason" => "unauthorized_recovery", "grant_type" => "refresh_token"}] =
               requests()
    end

    test "refreshes at most once in 5 minutes per sign-in", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 864_000)
      set_login!(provider, signed_in_at: -600)
      stub!(new_tokens("recovered"))

      assert {:ok, _access, _at} = token(provider, recover: true)
      assert {:error, :unavailable} = token(provider, recover: true)
      assert length(requests()) == 1

      set_login!(provider, refreshed_at: -301)
      stub!(new_tokens("again"))
      assert {:ok, _access, _at} = token(provider, recover: true)
      assert [%{"refresh_reason" => "unauthorized_recovery"}] = requests()
    end

    test "gets no refresh for a token made less than 5 minutes ago, and serves none", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope, expires_in: 864_000)
      stub!(new_tokens("never"))

      assert {:error, :unavailable} = token(provider, recover: true)
      assert requests() == []
    end

    test "a failed refresh counts as the last one", %{scope: scope} do
      {provider, _tokens} = subscription!(scope, expires_in: 864_000)
      set_login!(provider, signed_in_at: -600)
      stub!({500, %{}})

      assert {:error, :unavailable} = token(provider, recover: true)
      assert {:error, :unavailable} = token(provider, recover: true)
      assert length(requests()) == 1
    end

    test "a login the provider rejects for good is a sign-in that needs a new one", %{
      scope: scope
    } do
      {provider, _tokens} = subscription!(scope, expires_in: 864_000)
      set_login!(provider, signed_in_at: -600)
      stub!({400, %{"error" => "invalid_grant"}})

      assert {:error, :sign_in_needed} = token(provider, recover: true)
      assert Login.status(row(provider)) == :sign_in_needed
    end

    test "puts no token in the log", %{scope: scope} do
      {provider, tokens} = subscription!(scope, expires_in: 864_000)
      set_login!(provider, signed_in_at: -600)
      stub!(new_tokens("recovered"))

      log = capture_log(fn -> token(provider, recover: true) end)

      refute log =~ tokens.access_token
      refute log =~ tokens.refresh_token
    end
  end
end
