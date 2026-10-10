defmodule ApiaryWeb.AttemptLimitsTest do
  # The limits come from the application environment, which every test shares: here the
  # numbers the module gives, not the test configuration's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.UserToken
  alias Apiary.Repo
  alias ApiaryWeb.AttemptLimits

  @message "Too many attempts. Try again in a few minutes."
  @table Apiary.Runs.RateLimit

  setup do
    config = Application.get_env(:apiary, AttemptLimits)
    Application.delete_env(:apiary, AttemptLimits)
    on_exit(fn -> Application.put_env(:apiary, AttemptLimits, config) end)
  end

  defp address_key(bucket, email),
    do: {AttemptLimits, bucket, :crypto.hash(:sha256, String.downcase(email))}

  # The flash shows the message's first sentence as its title and the second under it.
  defp shows_message?(html),
    do: html =~ "Too many attempts." and html =~ "Try again in a few minutes."

  # Moves the bucket's last spending `ms` into the past, as if that much time went by.
  defp rewind(key, ms) do
    [{^key, _tokens, at}] = :ets.lookup(@table, key)
    true = :ets.update_element(@table, key, {3, at - ms})
  end

  describe "the buckets" do
    test "a password log-in: 5 per address, in whatever case, then 1 a minute; another address is not counted" do
      email = unique_user_email()

      for n <- 1..5,
          do: assert(AttemptLimits.password_log_in(email, "198.51.100.#{n}") == :ok)

      assert AttemptLimits.password_log_in(String.upcase(email), "198.51.100.6") == :limited
      assert AttemptLimits.password_log_in(unique_user_email(), "198.51.100.6") == :ok

      key = address_key(:password_address, email)
      rewind(key, 59_000)
      assert AttemptLimits.password_log_in(email, "198.51.100.7") == :limited
      rewind(key, 1_000)
      assert AttemptLimits.password_log_in(email, "198.51.100.7") == :ok
      assert AttemptLimits.password_log_in(email, "198.51.100.7") == :limited
    end

    test "a password log-in: 20 per client address, whatever the addresses tried, then 1 every 3 seconds" do
      client = "198.51.100.20"

      for _ <- 1..20,
          do: assert(AttemptLimits.password_log_in(unique_user_email(), client) == :ok)

      assert AttemptLimits.password_log_in(unique_user_email(), client) == :limited
      assert AttemptLimits.password_log_in(unique_user_email(), "198.51.100.21") == :ok

      key = {AttemptLimits, :password_client, client}
      rewind(key, 2_900)
      assert AttemptLimits.password_log_in(unique_user_email(), client) == :limited
      rewind(key, 100)
      assert AttemptLimits.password_log_in(unique_user_email(), client) == :ok
      assert AttemptLimits.password_log_in(unique_user_email(), client) == :limited
    end

    test "a log-in link: 3 per address, then 1 every 5 minutes" do
      email = unique_user_email()

      for _ <- 1..3, do: assert(AttemptLimits.link_request(email) == :ok)
      assert AttemptLimits.link_request(String.upcase(email)) == :limited
      assert AttemptLimits.link_request(unique_user_email()) == :ok

      key = address_key(:link_address, email)
      rewind(key, 299_000)
      assert AttemptLimits.link_request(email) == :limited
      rewind(key, 1_000)
      assert AttemptLimits.link_request(email) == :ok
      assert AttemptLimits.link_request(email) == :limited
    end

    test "the pages a link opens: 20 per client address, then 1 every 3 seconds" do
      client = "198.51.100.22"

      for _ <- 1..20, do: assert(AttemptLimits.link_page(client) == :ok)
      assert AttemptLimits.link_page(client) == :limited
      assert AttemptLimits.link_page("198.51.100.23") == :ok

      key = {AttemptLimits, :link_page_client, client}
      rewind(key, 2_900)
      assert AttemptLimits.link_page(client) == :limited
      rewind(key, 100)
      assert AttemptLimits.link_page(client) == :ok
    end

    test "each bucket is its own: a password log-in does not spend a link's" do
      email = unique_user_email()

      for _ <- 1..5,
          do: assert(AttemptLimits.password_log_in(email, "198.51.100.24") == :ok)

      assert AttemptLimits.link_request(email) == :ok
      assert AttemptLimits.link_page("198.51.100.24") == :ok
    end
  end

  describe "log-in with a password" do
    defp log_in(client, email, password, headers \\ []) do
      conn = Map.put(build_conn(), :remote_ip, client)

      headers
      |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
      |> post(~p"/users/log-in", %{"user" => %{"email" => email, "password" => password}})
    end

    defp refused?(conn) do
      redirected_to(conn) == ~p"/users/log-in" and is_nil(get_session(conn, :user_token)) and
        Phoenix.Flash.get(conn.assigns.flash, :error) == @message
    end

    test "past an address's 5, its right password and an unknown address's get the same answer, and nobody is logged in" do
      %{user: user} = sign_up_fixture()
      user = set_password(user)
      unknown = unique_user_email()

      for email <- [user.email, unknown] do
        for n <- 1..5 do
          conn = log_in({192, 0, 2, n}, email, "not the password")

          assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                   "That email and password do not match."
        end
      end

      known = log_in({192, 0, 2, 6}, user.email, valid_user_password())
      other = log_in({192, 0, 2, 6}, unknown, valid_user_password())

      assert refused?(known)
      assert refused?(other)
      assert Phoenix.Flash.get(known.assigns.flash, :email) == user.email
      assert Phoenix.Flash.get(other.assigns.flash, :email) == unknown

      {:ok, _lv, html} = live(recycle(known), ~p"/users/log-in")
      assert shows_message?(html)
    end

    test "past a client's 20, over any addresses, a right password is refused too" do
      %{user: user} = sign_up_fixture()
      user = set_password(user)
      client = {192, 0, 2, 30}

      for _ <- 1..20 do
        conn = log_in(client, unique_user_email(), "not the password")
        refute Phoenix.Flash.get(conn.assigns.flash, :error) == @message
      end

      assert refused?(log_in(client, user.email, valid_user_password()))

      conn = log_in({192, 0, 2, 31}, user.email, valid_user_password())
      assert get_session(conn, :user_token)
    end

    test "a client does not choose its bucket by writing X-Forwarded-For from a proxy nobody trusts" do
      client = {192, 0, 2, 32}

      for n <- 1..20 do
        log_in(client, unique_user_email(), "not the password", [
          {"x-forwarded-for", "203.0.113.#{n}"}
        ])
      end

      assert refused?(
               log_in(client, unique_user_email(), "not the password", [
                 {"x-forwarded-for", "203.0.113.99"}
               ])
             )
    end

    test "behind a proxy TRUSTED_PROXIES names, each client has its own bucket" do
      trusted = Application.get_env(:apiary, :trusted_proxies)
      Application.put_env(:apiary, :trusted_proxies, [{{10, 0, 0, 0}, 8}])
      on_exit(fn -> Application.put_env(:apiary, :trusted_proxies, trusted) end)

      proxy = {10, 0, 0, 7}
      behind = [{"x-forwarded-for", "203.0.113.40"}]

      for _ <- 1..20, do: log_in(proxy, unique_user_email(), "not the password", behind)
      assert refused?(log_in(proxy, unique_user_email(), "not the password", behind))

      refute refused?(
               log_in(proxy, unique_user_email(), "not the password", [
                 {"x-forwarded-for", "203.0.113.41"}
               ])
             )
    end
  end

  describe "a log-in link" do
    defp ask_link(email) do
      {:ok, lv, _html} = live(build_conn(), ~p"/users/log-in")
      html = lv |> form("#login_form", user: %{email: email}) |> render_submit()
      {lv, html}
    end

    test "past an address's 3, an address with an account and one without get the same answer, and nothing is sent" do
      user = user_fixture()
      unknown = unique_user_email()
      sent = Repo.aggregate(UserToken, :count)

      for email <- [user.email, unknown], _ <- 1..3 do
        {_lv, html} = ask_link(email)
        assert html =~ "a log-in link is on its way"
      end

      assert Repo.aggregate(UserToken, :count) == sent + 3

      for email <- [user.email, unknown] do
        {lv, html} = ask_link(email)
        assert shows_message?(html)
        refute html =~ "a log-in link is on its way"
        assert has_element?(lv, "#login_form")
      end

      assert Repo.aggregate(UserToken, :count) == sent + 3
    end
  end

  describe "the pages a link opens" do
    setup do
      owner = sign_up_fixture()
      %{token: token} = invitation_fixture(owner.scope)
      %{owner: owner, token: token}
    end

    defp from(text) do
      {:ok, address} = :inet.parse_address(String.to_charlist(text))
      Plug.Test.put_peer_data(build_conn(), %{address: address, port: 4711, ssl_cert: nil})
    end

    # Spends what is left of the client's bucket.
    defp spend_page(client) do
      if AttemptLimits.link_page(client) == :ok, do: spend_page(client)
    end

    test "an invitation: past a client's 20, a real token and an unknown one get the same answer",
         %{token: token} do
      client = "198.51.100.40"
      {:ok, _lv, html} = live(from(client), ~p"/invitations/#{token}")
      assert html =~ "Create an account"

      spend_page(client)

      for path <- [~p"/invitations/#{token}", ~p"/invitations/not-a-token"] do
        assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
                 live(from(client), path)
      end

      {:ok, _lv, html} = live(from("198.51.100.41"), ~p"/invitations/#{token}")
      assert html =~ "Create an account"
    end

    test "an invitation, signed in: past the limit, to the person's home", %{token: token} do
      client = "198.51.100.42"
      spend_page(client)
      %{user: user} = sign_up_fixture()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => @message}}}} =
               client |> from() |> log_in_user(user) |> live(~p"/invitations/#{token}")
    end

    test "the invited sign-up: past a client's 20, a real token and an unknown one get the same answer; without a token it is not counted",
         %{token: token} do
      client = "198.51.100.43"
      spend_page(client)

      for path <- [
            ~p"/users/register?invitation=#{token}",
            ~p"/users/register?invitation=not-a-token"
          ] do
        assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
                 live(from(client), path)
      end

      assert {:ok, _lv, _html} = live(from(client), ~p"/users/register")
    end
  end
end
