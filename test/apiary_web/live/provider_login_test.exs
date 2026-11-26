defmodule ApiaryWeb.ProviderLoginTest do
  # The sign-in of an OpenAI subscription's key (`Apiary.ModelKeys.Login`) on Organisation
  # settings › Model provider keys: New model provider key and Edit key have the button
  # Sign in with ChatGPT, which starts a device sign-in (`Apiary.ModelKeys.DeviceSignIn`)
  # against a stub of the provider, and never show a token; the list shows each key's
  # sign-in, Signed in or Needs a new sign-in, and starts none; Edit key has the sign-in's
  # identity line as its title; the workspace's Secrets page has the same button for a
  # workspace's key.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.ModelKeysFixtures
  import Apiary.DeviceSignInStub, only: [eventually: 1, assert_ended: 1]

  alias Apiary.{Connections, Repo}
  alias Apiary.DeviceSignInStub, as: Stub
  alias Apiary.ModelKeys.Login

  @moduletag needs: [:factory, :secrets]

  @hint "Qory Apiary signs in to ChatGPT for this key. You enter a code on OpenAI's page, and you paste nothing."
  @stored "Qory Apiary stores the sign-in encrypted, and no page shows it."
  @key_hint "Qory Apiary stores the key encrypted, and nobody can view it again."

  setup :register_and_log_in_user

  defp base(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: "#{base(scope)}/new"
  defp key_path(scope, provider, rest), do: "#{base(scope)}/#{provider.public_id}/keys/#{rest}"

  # The Edit key page of the key `value_id`, at its row id.
  defp edit_path(scope, provider, value_id),
    do: key_path(scope, provider, "#{key_value!(provider, value_id).id}/edit")

  # The identity line of a sign-in of `provider` with the email `email`.
  defp line(provider, email \\ "dana@example.com"), do: "#{provider.name} · #{email}"

  defp subscription!(scope, tokens \\ login_tokens(), place \\ :organisation) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{
          provider: "openai-subscription",
          keys: [%{value_id: "main", value: device_login(tokens: tokens)}]
        },
        place
      )

    provider
  end

  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # No token of `tokens`, nor any code of the device sign-in, in `html`.
  defp refute_tokens(html, tokens) do
    for secret <- [
          tokens.access_token,
          tokens.refresh_token,
          tokens.id_token,
          "device-auth-fixture",
          "authorization-code-fixture",
          "verifier-fixture"
        ],
        do: refute(html =~ secret)
  end

  defp device_of(lv), do: :sys.get_state(lv.pid).socket.assigns.device

  # Clicks the button and waits for the code, then for the sign-in.
  defp sign_in!(lv, id) do
    lv |> element("##{id}-start") |> render_click()
    eventually(fn -> assert has_element?(lv, "##{id}-code") end)
  end

  defp signed_in!(lv, id), do: eventually(fn -> assert has_element?(lv, "##{id}-state") end)

  defp refute_in_assigns(lv, tokens) do
    state = inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
    refute_tokens(state, tokens)
  end

  defp login_of(provider, value_id) do
    value = key_value!(provider, value_id)
    Repo.get!(Login, value.id)
  end

  # The id of the key `value_id` in the page source: its row id.
  defp key_dom(provider, value_id), do: "key-#{key_value!(provider, value_id).id}"

  # Opens New model provider key with the provider `kind` chosen.
  defp new_key!(conn, scope, kind \\ "openai-subscription") do
    {:ok, lv, _html} = live(conn, new_path(scope))
    choose(lv, kind)
    lv
  end

  defp choose(lv, provider),
    do: lv |> form("#new-provider-form", provider: %{provider: provider}) |> render_change()

  describe "New model provider key, the sign-in" do
    test "saves nothing before the sign-in, and shows the errors of the settings", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      lv = new_key!(conn, scope)

      lv
      |> form("#new-provider-form", provider: %{reset_time: "09:00"})
      |> render_submit()

      assert has_element?(lv, "#provider_reset_day-resets-error")

      assert text(lv, "#new-provider-sign-in-error-1") ==
               "Click Sign in with ChatGPT, then save. This key has no sign-in yet."

      assert has_element?(lv, "#new-provider-sign-in-start")
      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "shows the code, waits, then Signed in", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(hold: true)
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")

      assert text(lv, "#new-provider-sign-in-open") ==
               "Open auth.example.test/device and enter this code."

      assert has_element?(
               lv,
               ~s{#new-provider-sign-in-open a[href="https://auth.example.test/device"][target=_blank]}
             )

      assert text(lv, "#new-provider-sign-in-code") == "7QKD-M4TPX"
      assert has_element?(lv, "#new-provider-sign-in-copy", "Copy")

      assert text(lv, "#new-provider-sign-in-until") =~
               ~r/\AThe code works until \d{1,2}:\d{2}.*\.\z/

      assert text(lv, "#new-provider-sign-in-only-yours") ==
               "Approve only a code you started yourself."

      assert text(lv, "#new-provider-sign-in-waiting") ==
               "Waiting for you to approve the sign-in on OpenAI's page."

      assert has_element?(lv, "#new-provider-sign-in-cancel", "Cancel")
      # The page's Cancel leaves the form: two Cancel buttons while the code shows.
      assert has_element?(lv, "#new-provider-save a", "Cancel")
      refute has_element?(lv, "#new-provider-sign-in-start")

      Stub.approve()
      signed_in!(lv, "new-provider-sign-in")
      assert text(lv, "#new-provider-sign-in-state") == "Signed in."
      assert render(lv) =~ @stored
      refute has_element?(lv, "#new-provider-sign-in-code")
      refute has_element?(lv, "#new-provider-sign-in-start")
    end

    test "keeps no token, code or device id in the page or its assigns", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = Stub.put()
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      signed_in!(lv, "new-provider-sign-in")

      refute_tokens(render(lv), tokens)
      refute_in_assigns(lv, tokens)

      # A refused save (a reset time with no day) draws the page again.
      html =
        lv
        |> form("#new-provider-form", provider: %{reset_time: "09:00"})
        |> render_submit()

      assert has_element?(lv, "#provider_reset_day-resets-error")
      assert has_element?(lv, "#new-provider-sign-in-state")
      refute_tokens(html, tokens)
      refute_in_assigns(lv, tokens)

      # The device assign has the user code and nothing else of the sign-in.
      assert Map.keys(device_of(lv)) |> Enum.sort() ==
               ~w(cause expires_at kind pid ref state user_code verification_url)a
    end

    test "Cancel beside the code stops the sign-in and shows the button again", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(pending: :never)
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      pid = device_of(lv).pid
      lv |> element("#new-provider-sign-in-cancel") |> render_click()

      assert has_element?(lv, "#new-provider-sign-in-start")
      refute has_element?(lv, "#new-provider-sign-in-code")
      assert_ended(pid)
    end

    test "leaving the form stops the polling", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(pending: :never)
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      pid = device_of(lv).pid
      GenServer.stop(lv.pid)

      assert_ended(pid)
    end

    test "shows an expired code with the fix first, and a new code on the next click", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(pending: :never, expires_at: DateTime.add(DateTime.utc_now(), 1))
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      eventually(fn -> assert has_element?(lv, "#new-provider-sign-in-fix") end)

      assert text(lv, "#new-provider-sign-in-fix") == "Click Sign in with ChatGPT for a new code."

      assert text(lv, "#new-provider-sign-in-cause") ==
               "The code expired before the sign-in was approved."

      refute has_element?(lv, "#new-provider-sign-in-hint")

      Stub.put(pending: :never)
      sign_in!(lv, "new-provider-sign-in")
      assert text(lv, "#new-provider-sign-in-code") == "7QKD-M4TPX"
    end

    test "says device code sign-in is off, with the retry button", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(usercode: 404)
      lv = new_key!(conn, scope)

      lv |> element("#new-provider-sign-in-start") |> render_click()
      eventually(fn -> assert has_element?(lv, "#new-provider-sign-in-fix") end)

      assert text(lv, "#new-provider-sign-in-fix") ==
               "Turn on Enable device code sign-in for Codex in ChatGPT's security settings, or ask your ChatGPT workspace admin to turn it on."

      assert has_element?(
               lv,
               "#new-provider-sign-in-fix b",
               "Enable device code sign-in for Codex"
             )

      assert text(lv, "#new-provider-sign-in-cause") ==
               "OpenAI returned no code, because device code sign-in for Codex is off for this ChatGPT account."

      assert has_element?(lv, "#new-provider-sign-in-start", "Sign in with ChatGPT")
    end

    test "shows the fix and the status of the response that failed the sign-in", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(usercode: 500)
      lv = new_key!(conn, scope)

      lv |> element("#new-provider-sign-in-start") |> render_click()
      eventually(fn -> assert has_element?(lv, "#new-provider-sign-in-fix") end)

      assert text(lv, "#new-provider-sign-in-fix") == "Click Sign in with ChatGPT for a new code."

      assert text(lv, "#new-provider-sign-in-cause") ==
               "Qory Apiary could not complete the sign-in with OpenAI (HTTP 500)."

      assert has_element?(lv, "#new-provider-sign-in-start")
    end

    test "leaves the status out of the cause when the failure has none", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(code: "")
      lv = new_key!(conn, scope)

      lv |> element("#new-provider-sign-in-start") |> render_click()
      eventually(fn -> assert has_element?(lv, "#new-provider-sign-in-fix") end)

      assert text(lv, "#new-provider-sign-in-cause") ==
               "Qory Apiary could not complete the sign-in with OpenAI."
    end

    test "shows the fix and the cause for tokens with no account id", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(tokens: %{login_tokens(tag: "x") | access_token: "not.a.jwt"})
      lv = new_key!(conn, scope)

      lv |> element("#new-provider-sign-in-start") |> render_click()
      eventually(fn -> assert has_element?(lv, "#new-provider-sign-in-fix") end)

      assert text(lv, "#new-provider-sign-in-fix") == "Click Sign in with ChatGPT for a new code."

      assert text(lv, "#new-provider-sign-in-cause") ==
               "OpenAI returned no account id for this sign-in."
    end

    test "copies the code as text, with no white space around it", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(hold: true)
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      assert lv |> element("#new-provider-sign-in-code") |> render() =~ ~r/>7QKD-M4TPX<\/code>\z/
      assert lv |> element("#new-provider-sign-in-copy") |> render() =~ ~s{data-copy="7QKD-M4TPX"}
      refute lv |> element("#new-provider-sign-in-copy") |> render() =~ "data-copy-target"
    end
  end

  describe "Edit key" do
    test "has the button and its hint, and no Sign-in field", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      provider = subscription!(scope)
      {:ok, lv, html} = live(conn, edit_path(scope, provider, "main"))

      assert text(lv, "#key-sign-in-start") == "Sign in with ChatGPT"
      assert text(lv, "#key-sign-in-hint") == @hint
      refute has_element?(lv, "#key-form input[type=password]")
      refute html =~ "Leave it empty to keep the value."
      refute has_element?(lv, "#key-sign-in-needed")
    end

    test "shows a sign-in that needs renewing above the button", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      provider = subscription!(scope)
      value = key_value!(provider, "main")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          last_failure: ~U[2026-11-18 10:04:00.000000Z]
        ]
      )

      {:ok, lv, html} = live(conn, edit_path(scope, provider, "main"))

      assert text(lv, "#key-sign-in-needed") =~
               ~r/\ANeeds a new sign-inOpenAI rejected it on .*2026.*\.\z/

      assert has_element?(lv, "#key-sign-in-start", "Sign in with ChatGPT")
      assert text(lv, "#key-sign-in-hint") == @hint
      refute html =~ "codex login"

      sign_in!(lv, "key-sign-in")
      signed_in!(lv, "key-sign-in")
      refute has_element?(lv, "#key-sign-in-needed")

      lv |> form("#key-form") |> render_submit()
      assert_redirect(lv, base(scope))

      assert %Login{state: "signed_in", generation: 2, sign_in_cause: nil} =
               login_of(provider, "main")
    end

    test "keeps the reason of a key that needs a new sign-in after a failed attempt", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      value = key_value!(provider, "main")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          last_failure: ~U[2026-11-18 10:04:00.000000Z]
        ]
      )

      for {script, fix} <- [
            {[usercode: 404], "Turn on"},
            {[usercode: 500], "Click Sign in with ChatGPT for a new code."},
            {[pending: :never, expires_at: DateTime.add(DateTime.utc_now(), 1)],
             "Click Sign in with ChatGPT for a new code."}
          ] do
        Stub.put(script)
        {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))
        lv |> element("#key-sign-in-start") |> render_click()
        eventually(fn -> assert has_element?(lv, "#key-sign-in-fix") end)

        assert text(lv, "#key-sign-in-fix") =~ fix

        assert text(lv, "#key-sign-in-needed") =~
                 ~r/\ANeeds a new sign-inOpenAI rejected it on .*2026.*\.\z/

        assert has_element?(lv, "#key-sign-in-start")
      end
    end

    test "stores a new sign-in over the key's, and keeps the key when none is made", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = Stub.put(tokens: login_tokens(tag: "edit"))
      provider = subscription!(scope)

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))
      lv |> form("#key-form") |> render_submit()
      assert_redirect(lv, base(scope))
      assert %Login{generation: 1, account_id: "acct-fixture-a"} = login_of(provider, "main")

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))
      sign_in!(lv, "key-sign-in")
      signed_in!(lv, "key-sign-in")
      lv |> form("#key-form") |> render_submit()
      assert_redirect(lv, base(scope))

      assert %Login{generation: 2, account_id: account} = login_of(provider, "main")
      assert account == tokens.account_id
    end

    test "keeps New value and its hint for a key that is no login", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))

      assert has_element?(lv, ~s{#key-form label[for="key-value-0"]}, "New value")
      assert text(lv, "#key-value-0-hint") == "Leave it empty to keep the value."
      refute has_element?(lv, "#key-sign-in")
    end
  end

  describe "New model provider key" do
    test "has the button for a subscription and the Key field for an API key", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      lv = new_key!(conn, scope)

      assert text(lv, "#new-provider-sign-in-start") == "Sign in with ChatGPT"
      assert text(lv, "#new-provider-sign-in-hint") == @hint
      refute has_element?(lv, "#new-provider-form input[type=password]")
      refute has_element?(lv, "#new-provider-form label", "Name")
      refute render(lv) =~ "Sign-in"
      refute render(lv) =~ "auth.json"

      choose(lv, "openai")
      refute has_element?(lv, "#new-provider-sign-in")
      assert has_element?(lv, ~s{#new-provider-form label[for="new-provider-key-0"]}, "Key")
      assert text(lv, "#new-provider-key-0-hint") == @key_hint
    end

    test "adds a subscription with the sign-in, and shows no token", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = Stub.put(tokens: login_tokens(tag: "new"))
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      signed_in!(lv, "new-provider-sign-in")
      refute_tokens(render(lv), tokens)
      refute_in_assigns(lv, tokens)

      log =
        capture_log(fn ->
          lv |> form("#new-provider-form") |> render_submit()
          flash = assert_redirect(lv, base(scope))
          assert flash["info"] == "key-1 is added."
        end)

      refute_tokens(log, tokens)
      provider = Repo.get_by!(Apiary.Connections.Connection, provider_kind: "openai-subscription")
      assert %Login{account_id: account} = login_of(provider, "key-1")
      assert account == tokens.account_id
    end

    # The button is there without a stub: the vendored description has the device sign-in.
    test "refuses a save before the sign-in, and adds nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      lv = new_key!(conn, scope)

      lv |> form("#new-provider-form") |> render_submit()

      assert text(lv, "#new-provider-sign-in-error-1") ==
               "Click Sign in with ChatGPT, then save. This key has no sign-in yet."

      assert has_element?(lv, "#new-provider-sign-in-error-1 b", "Sign in with ChatGPT")

      assert Repo.all(Apiary.Connections.Connection) == []
    end

    test "stops the sign-in when another provider is chosen", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(pending: :never)
      lv = new_key!(conn, scope)

      sign_in!(lv, "new-provider-sign-in")
      pid = device_of(lv).pid
      choose(lv, "openai")

      assert_ended(pid)
      choose(lv, "openai-subscription")
      assert has_element?(lv, "#new-provider-sign-in-start")
      refute has_element?(lv, "#new-provider-sign-in-code")
    end
  end

  describe "the list" do
    test "shows a signed-in key as Signed in, with the last refresh once there is one", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = login_tokens()
      provider = subscription!(scope, tokens)
      path = base(scope)

      {:ok, lv, html} = live(conn, path)
      refute_tokens(html, tokens)

      assert text(lv, "##{key_dom(provider, "main")}-login") == "Signed in." <> @stored
      assert has_element?(lv, "##{key_dom(provider, "main")}-state", "Available")

      value = key_value!(provider, "main")
      refreshed_at = ~U[2026-11-12 10:04:00.000000Z]

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [refreshed_at: refreshed_at]
      )

      {:ok, lv, html} = live(conn, path)
      refute_tokens(html, tokens)

      assert text(lv, "##{key_dom(provider, "main")}-login") =~
               ~r/\ASigned in\. Last refresh .*2026.*\.\z/

      refute_in_assigns(lv, tokens)
    end

    test "shows the state a refresh leaves, and no token", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = login_tokens(expires_in: 60)
      fresh = login_tokens(tag: "page")
      provider = subscription!(scope, tokens)
      value = key_value!(provider, "main")
      path = base(scope)
      plain = Repo.get!(Apiary.Connections.Connection, provider.id)

      Req.Test.stub(Apiary.ModelKeys.LoginRefresh, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => fresh.access_token,
          "refresh_token" => fresh.refresh_token
        })
      end)

      log =
        capture_log(fn ->
          assert {:ok, _access, _at} =
                   Login.access_token(plain, value.id, trigger: {:run, "run-1"})
        end)

      {:ok, lv, html} = live(conn, path)

      assert text(lv, "##{key_dom(provider, "main")}-login") =~
               ~r/\ASigned in\. Last refresh .*\.\z/

      for text <- [html, log],
          token <- [
            tokens.access_token,
            tokens.refresh_token,
            fresh.access_token,
            fresh.refresh_token
          ],
          do: refute(text =~ token)

      refute_in_assigns(lv, tokens)
      refute_in_assigns(lv, fresh)

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          access_expires_at: DateTime.add(DateTime.utc_now(), 60),
          refreshed_at: DateTime.add(DateTime.utc_now(), -120)
        ]
      )

      Req.Test.stub(Apiary.ModelKeys.LoginRefresh, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "refresh_token_reused"})
      end)

      assert Login.access_token(plain, value.id, trigger: {:run, "run-2"}) ==
               {:error, :sign_in_needed}

      {:ok, lv, html} = live(conn, path)

      assert text(lv, "##{key_dom(provider, "main")}-login") =~
               ~r/\ANeeds a new sign-inOpenAI rejected it on .*\.\z/

      refute html =~ "refresh_token_reused"
      refute_tokens(html, fresh)
    end

    test "shows a key that needs a new sign-in, in place of its state", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)
      value = key_value!(provider, "main")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          last_failure: ~U[2026-11-12 10:04:00.000000Z]
        ]
      )

      {:ok, lv, html} = live(conn, base(scope))

      assert has_element?(lv, "##{key_dom(provider, "main")}-login", "Needs a new sign-in")

      assert text(lv, "##{key_dom(provider, "main")}-login") =~
               ~r/\ANeeds a new sign-inOpenAI rejected it on .*2026.*\.\z/

      refute html =~ "codex login"

      refute has_element?(lv, "##{key_dom(provider, "main")}-state")
      refute html =~ "refresh_token_reused"
    end

    test "says what failed for token_not_stored and no_account, and OpenAI rejected it otherwise",
         ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = login_tokens()
      provider = subscription!(scope, tokens)
      value = key_value!(provider, "main")
      assert length(Login.causes()) == 7

      for cause <- Login.causes() do
        Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
          set: [
            state: "sign_in_needed",
            sign_in_cause: cause,
            last_failure: ~U[2026-11-12 10:04:00.000000Z]
          ]
        )

        {:ok, lv, html} = live(conn, base(scope))
        line = text(lv, "##{key_dom(provider, "main")}-login")

        cond do
          cause == "token_not_stored" ->
            assert line =~
                     ~r/\ANeeds a new sign-inQory Apiary could not save the new sign-in on [^.]*2026[^.]*\.\z/

            refute line =~ "rejected it"

          cause == "no_account" ->
            assert line =~
                     ~r/\ANeeds a new sign-inOpenAI returned no account id on [^.]*2026[^.]*\.\z/

            refute line =~ "rejected it"
            refute line =~ "Qory Apiary could not save"

          true ->
            assert line =~ ~r/\ANeeds a new sign-inOpenAI rejected it on .*2026.*\.\z/
            refute line =~ "Qory Apiary could not save"
        end

        refute_tokens(html, tokens)
        refute_in_assigns(lv, tokens)
        refute html =~ cause
      end
    end

    test "shows no sign-in for a key of another provider", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, provider} =
        Connections.create_provider(scope, %{
          provider: "openai",
          keys: [%{value_id: "main", value: "sk-proj-an-api-key"}]
        })

      {:ok, lv, _html} = live(conn, base(scope))

      refute has_element?(lv, "##{key_dom(provider, "main")}-login")
      assert has_element?(lv, "##{key_dom(provider, "main")}-state")
    end
  end

  describe "the identity line of a sign-in, the title of Edit key" do
    defp set_login!(provider, value_id, attrs) do
      value = key_value!(provider, value_id)
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id), set: attrs)
    end

    # A provider with a sign-in for each tag, the first with the key `main`.
    defp subscription_with!(scope, [first | rest]) do
      provider = subscription!(scope, login_tokens(tag: first))

      Enum.reduce(rest, provider, fn tag, provider ->
        {:ok, provider} =
          Connections.add_provider_key(scope, provider, %{value: device_login(tag: tag)})

        provider
      end)
    end

    defp title(conn, scope, provider, value_id) do
      {:ok, lv, html} = live(conn, edit_path(scope, provider, value_id))
      refute html =~ "account …"
      text(lv, "h1")
    end

    test "is the email of its sign-in, the keys of four accounts apart", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription_with!(scope, ~w(a b c d))
      ids = ~w(main key-1 key-2 key-3)
      emails = ~w(sam@example.com kim@example.com lee@example.com jo@example.com)

      for {id, email} <- Enum.zip(ids, emails), do: set_login!(provider, id, email: email)

      for {id, email} <- Enum.zip(ids, emails),
          do: assert(title(conn, scope, provider, id) == line(provider, email))
    end

    test "a sign-in with no email has the last 4 characters of its account", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription_with!(scope, ~w(a b))
      set_login!(provider, "main", email: nil)

      # "acct-fixture-a" ends in "re-a".
      {:ok, edit, _html} = live(conn, edit_path(scope, provider, "main"))
      assert has_element?(edit, "h1", "#{provider.name} · account …re-a")
    end

    test "a sign-in saved before the email was kept has its account", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope, login_tokens(tag: "x"))
      set_login!(provider, "main", email: nil, account_id: "acct-9d81c27e7c1d")

      {:ok, edit, _html} = live(conn, edit_path(scope, provider, "main"))
      assert text(edit, "h1") == "#{provider.name} · account …7c1d"
    end

    test "a provider named differently from its kind has its name in the line", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = subscription!(scope)

      Repo.update_all(from(c in Apiary.Connections.Connection, where: c.id == ^provider.id),
        set: [name: "Web shop key"]
      )

      assert title(conn, scope, provider, "main") == "Web shop key · dana@example.com"
    end
  end

  describe "the list, a key that needs a new sign-in" do
    test "has no button, and a sign-in sent to the list starts none", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      provider = subscription!(scope)
      value = key_value!(provider, "main")

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value.id),
        set: [
          state: "sign_in_needed",
          sign_in_cause: "refresh_token_reused",
          last_failure: ~U[2026-11-18 10:04:00.000000Z]
        ]
      )

      before = login_of(provider, "main")
      {:ok, lv, _html} = live(conn, base(scope))

      assert has_element?(lv, "##{key_dom(provider, "main")}-login", "Needs a new sign-in")
      refute has_element?(lv, "[phx-click=device_sign_in]")

      render_click(lv, "device_sign_in", %{"key" => value.id})
      assert device_of(lv) == nil
      assert login_of(provider, "main") == before
    end
  end

  describe "the workspace's Secrets page" do
    defp secrets_path(scope, rest),
      do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets#{rest}"

    # The Change value page of the key `value_id` of the secret `secret`, at its row id.
    defp change_path(scope, provider, secret, value_id),
      do:
        secrets_path(
          scope,
          "/#{secret.public_id}/values/#{key_value!(provider, value_id).id}/change"
        )

    test "has no Add value for a login key: that path and Rename are not found", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      provider = subscription!(scope, login_tokens(), :workspace)
      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)

      for rest <- ["/add-value", "/values/main/rename"] do
        assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
                 live(conn, secrets_path(scope, "/#{secret.public_id}#{rest}"))

        assert error == "That secret is no longer in this workspace."
      end

      {:ok, lv, _html} = live(conn, secrets_path(scope, ""))
      row = "#secret-#{secret.public_id}"
      row_id = key_value!(provider, "main").id
      assert has_element?(lv, "#{row}-#{row_id}-value-id", line(provider))
      refute has_element?(lv, "#{row}-add")
      refute has_element?(lv, "#{row}-#{row_id}-rename")
    end

    test "has the button on Change value of a login key, and Save stores the sign-in", ctx do
      %{conn: conn, scope: scope} = ctx
      tokens = Stub.put(tokens: login_tokens(tag: "change"), hold: true)
      provider = subscription!(scope, login_tokens(), :workspace)
      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)

      {:ok, lv, html} = live(conn, change_path(scope, provider, secret, "main"))

      assert text(lv, "#secret-sign-in-start") == "Sign in with ChatGPT"
      assert text(lv, "#secret-sign-in-hint") == @hint
      refute has_element?(lv, "#secret-form textarea")
      refute html =~ "Sign-in"
      assert has_element?(lv, "h1", "Change #{line(provider)} of #{secret.name}")

      sign_in!(lv, "secret-sign-in")
      assert text(lv, "#secret-sign-in-code") == "7QKD-M4TPX"
      assert has_element?(lv, "#secret-save a", "Cancel")
      Stub.approve()
      signed_in!(lv, "secret-sign-in")

      html = lv |> form("#secret-form") |> render_submit()

      refute_tokens(html, tokens)
      assert %Login{generation: 2, account_id: account} = login_of(provider, "main")
      assert account == tokens.account_id
      refute_in_assigns(lv, tokens)
    end

    test "keeps the sign-in when Change value is saved without a new one", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      provider = subscription!(scope, login_tokens(), :workspace)
      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)

      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "main"))

      lv |> form("#secret-form") |> render_submit()

      assert %Login{generation: 1} = login_of(provider, "main")
    end

    test "stops the sign-in when the person leaves the form", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put(pending: :never)
      provider = subscription!(scope, login_tokens(), :workspace)
      secret = Repo.get!(Apiary.Secrets.Secret, provider.secret_id)
      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "main"))

      sign_in!(lv, "secret-sign-in")
      pid = device_of(lv).pid
      lv |> element("#secret-save a", "Cancel") |> render_click()

      assert_ended(pid)
    end

    test "keeps Value on Add value for a secret that is no model provider's", ctx do
      %{conn: conn, scope: scope} = ctx
      Stub.put()
      {:ok, secret} = Apiary.Secrets.create_secret(scope, %{name: "DEPLOY_TOKEN", value: "prod"})
      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      assert has_element?(lv, ~s{#secret-form label[for="secret_value_value"]}, "Value")
      refute has_element?(lv, "#secret-sign-in")
    end
  end
end
