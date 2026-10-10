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

  defp address_key(bucket, email), do: {AttemptLimits, bucket, AttemptLimits.address_key(email)}

  # The flash shows the message's first sentence as its title and the second under it.
  defp shows_message?(html),
    do: html =~ "Too many attempts." and html =~ "Try again in a few minutes."

  # Moves the bucket's last spending `ms` into the past, as if that much time went by.
  defp rewind(key, ms) do
    [{^key, _tokens, at, drop_after}] = :ets.lookup(@table, key)
    true = :ets.update_element(@table, key, [{3, at - ms}, {4, drop_after - ms}])
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

    test "a client past its own 20 spends no address's bucket: the address is still allowed from another client" do
      client = "203.0.113.60"
      victim = unique_user_email()

      for _ <- 1..20,
          do: assert(AttemptLimits.password_log_in(unique_user_email(), client) == :ok)

      for _ <- 1..5, do: assert(AttemptLimits.password_log_in(victim, client) == :limited)

      assert AttemptLimits.password_log_in(victim, "203.0.113.61") == :ok
    end

    test "an IPv6 client counts with the rest of its /64; another /64 is another bucket" do
      for _ <- 1..10,
          do: assert(AttemptLimits.password_log_in(unique_user_email(), "2001:db8::1") == :ok)

      for _ <- 1..10,
          do:
            assert(AttemptLimits.password_log_in(unique_user_email(), "2001:db8::ffff:2") == :ok)

      assert AttemptLimits.password_log_in(unique_user_email(), "2001:db8:0:0:1:2:3:4") ==
               :limited

      assert AttemptLimits.password_log_in(unique_user_email(), "2001:db8:0:1::1") == :ok

      for _ <- 1..20, do: assert(AttemptLimits.link_page("2001:db8:0:2::1") == :ok)
      assert AttemptLimits.link_page("2001:db8:0:2:ffff::1") == :limited
      assert AttemptLimits.link_page("2001:db8:0:3::1") == :ok

      # IPv4 is as before: an address is its own bucket.
      assert AttemptLimits.client_key("203.0.113.62") == "203.0.113.62"
      assert AttemptLimits.client_key("2001:db8:0:2:ffff::1") == "2001:db8:0:2::/64"
    end

    test "an address in another case or with a dotted capital I is the same bucket, as citext may take it for the same account" do
      n = System.unique_integer([:positive])
      email = "alice#{n}@example.com"

      for variant <- ["alİce#{n}@example.com", "ALİCE#{n}@EXAMPLE.COM"] do
        assert AttemptLimits.address_key(variant) == AttemptLimits.address_key(email), variant
      end

      for _ <- 1..5, do: assert(AttemptLimits.password_log_in(email, "198.51.100.25") == :ok)
      assert AttemptLimits.password_log_in("alİce#{n}@example.com", "198.51.100.26") == :limited

      for _ <- 1..3, do: assert(AttemptLimits.link_request("alİce#{n}@example.com") == :ok)
      assert AttemptLimits.link_request(email) == :limited

      refute AttemptLimits.address_key("bob#{n}@example.com") == AttemptLimits.address_key(email)
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

    test "a log-in link: the bucket is not dropped, full, while it refills" do
      email = unique_user_email()
      for _ <- 1..3, do: assert(AttemptLimits.link_request(email) == :ok)

      # Ten minutes and a second idle, then the table's sweep: two of the three are back.
      rewind(address_key(:link_address, email), 601_000)
      send(@table, :sweep)
      :sys.get_state(@table)

      assert AttemptLimits.link_request(email) == :ok
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

    test "a post of any other shape counts against the client's 20 too, and keeps its answer" do
      client = {192, 0, 2, 34}
      conn = Map.put(build_conn(), :remote_ip, client)

      shapes = [
        %{"user" => %{"email" => unique_user_email()}},
        %{"user" => %{"password" => "not the password"}},
        %{"user" => %{"email" => ["a list"], "password" => "not the password"}},
        %{"user" => "not a map"},
        %{}
      ]

      for shape <- shapes do
        answer = post(conn, ~p"/users/log-in", shape)
        assert redirected_to(answer) == ~p"/users/log-in"

        assert Phoenix.Flash.get(answer.assigns.flash, :error) ==
                 "That email and password do not match."
      end

      for _ <- 1..15, do: post(conn, ~p"/users/log-in", %{"user" => %{"password" => "p"}})

      for shape <- shapes do
        answer = post(conn, ~p"/users/log-in", shape)
        assert refused?(answer)
      end

      assert refused?(log_in(client, unique_user_email(), "not the password"))
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

    test "a password change logs in its own account, whatever email it posts" do
      %{user: victim} = sign_up_fixture()
      victim = set_password(victim)
      %{user: user} = sign_up_fixture()

      # The victim's bucket spent, so a log-in in their name is refused.
      for _ <- 1..5, do: log_in({192, 0, 2, 33}, victim.email, "not the password")
      assert refused?(log_in({192, 0, 2, 33}, victim.email, valid_user_password()))

      conn =
        build_conn()
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => victim.email,
            "password" => valid_user_password(),
            "password_confirmation" => valid_user_password()
          }
        })

      token = get_session(conn, :user_token)
      assert token
      assert {%{id: id}, _at} = Apiary.Accounts.get_user_by_session_token(token)
      assert id == user.id
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

    test "the password form's \"Email me a link\" counts against the same 3" do
      user = user_fixture()
      for _ <- 1..3, do: assert(AttemptLimits.link_request(user.email) == :ok)
      sent = Repo.aggregate(UserToken, :count)

      {:ok, lv, _html} = live(build_conn(), ~p"/users/log-in")
      lv |> element("button[phx-click=toggle_mode]") |> render_click()
      lv |> form("#login_form", user: %{email: user.email}) |> render_change()
      html = lv |> element("#login_forgot button") |> render_click()

      assert shows_message?(html)
      refute html =~ "a log-in link is on its way"
      assert Repo.aggregate(UserToken, :count) == sent
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

    test "a password link: past a client's 20, a real token and an unknown one get the same answer, and nothing is set" do
      user = user_fixture()
      {token, user_token} = UserToken.build_password_link_token(user, "password")
      Repo.insert!(user_token)

      client = "198.51.100.44"
      {:ok, _lv, html} = live(from(client), ~p"/users/password/#{token}")
      assert html =~ "Set your password"

      spend_page(client)

      for path <- [~p"/users/password/#{token}", ~p"/users/password/not-a-token"] do
        assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
                 live(from(client), path)
      end

      # The link still works, from another client.
      assert Apiary.Accounts.get_user_by_password_link(token)
      {:ok, _lv, html} = live(from("198.51.100.45"), ~p"/users/password/#{token}")
      assert html =~ "Set your password"
    end
  end

  describe "the set-up page" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      %{code: Apiary.Setup.code!()}
    end

    test "past a client's 20, the code and a wrong one get the same answer, before set-up and after",
         %{code: code} do
      client = "198.51.100.46"
      {:ok, _lv, html} = live(from(client), ~p"/setup/#{code}")
      assert html =~ "Set up Qory Apiary"

      spend_page(client)

      for path <- [~p"/setup/#{code}", ~p"/setup/not-the-code"] do
        assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
                 live(from(client), path)
      end

      {:ok, _lv, html} = live(from("198.51.100.47"), ~p"/setup/#{code}")
      assert html =~ "Set up Qory Apiary"

      sign_up_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in", flash: %{"error" => @message}}}} =
               live(from(client), ~p"/setup/#{code}")
    end
  end
end
