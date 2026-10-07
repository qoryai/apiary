defmodule ApiaryWeb.NodeLive.AccessKeyTest do
  @moduledoc """
  A node's Access key tab (`ApiaryWeb.NodeLive.AccessKey`): its intro and the way a
  machine gets a key, the keys and their acts confirmed in place, adding a key by its
  public key and the runner file it leads to, an enrolment code made and shown once with
  the command that enrols the machine (redeemed as shown), the outstanding codes and their
  revocation, and what a member, another organisation and a stale page are refused.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Repo
  alias ApiaryWeb.{Format, NodeComponents}

  setup :register_and_log_in_user

  # The runner contract's fixture access key (keys.json): refused everywhere.
  @fixture_public_key "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"

  defp tab_path(scope, node, rest \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key" <> rest

  # A key's row changed behind the application's back: its integrity code no longer fits.
  defp tamper(%AccessKey{id: id}),
    do:
      Repo.query!("UPDATE access_keys SET rate = 7, burst = 7 WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  # The code's row expires `ms` from now: a code made by the context expires in minutes.
  defp expire_in(%EnrolmentCode{id: id}, ms) do
    at = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    Repo.query!("UPDATE access_key_enrolment_codes SET expires_at = $2 WHERE id = $1", [
      Ecto.UUID.dump!(id),
      at
    ])
  end

  # The timer of the next expiry the page holds (`schedule_expiry/1`).
  defp expiry_timer(lv), do: :sys.get_state(lv.pid).socket.assigns.expiry_timer

  # Not one line says runners can't use a node's keys yet, nor names a workspace's keys
  # or their secrets in the runner file.
  defp refute_untrue(html) do
    refute html =~ "keys yet"
    refute html =~ "Once runners use"
    refute html =~ "workspace access key"
    refute html =~ "QORY_SERVER_SECRET"
    refute html =~ ~r/^\s*(access_key|secret):/m
  end

  # The text of an element as rendered, its marks gone and its spaces kept.
  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  # The pin as the page shows it: K2's list, in YAML's flow form and as JSON.
  defp pin_lines do
    [%{"alg" => "ed25519", "public_key" => public_key}] = SigningKey.apiary_public_key()

    {"    - {alg: ed25519, public_key: #{public_key}}",
     ~s(QORY_APIARY_PUBLIC_KEY=[{"alg":"ed25519","public_key":"#{public_key}"}])}
  end

  describe "the tab" do
    test "is a tab of the node's page, with no line about a workspace's access keys",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, html} = live(conn, tab_path(scope, node))

      assert has_element?(lv, "h1#node-header-title", "build-01")
      assert has_element?(lv, ~s{#node-tabs-access_key[aria-current="page"]}, "Access key")

      assert has_element?(
               lv,
               ~s{#node-tabs-overview[href="#{~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}"}"]}
             )

      refute has_element?(lv, "#not-on-runs")
      refute render(lv) =~ "workspace access key"

      assert has_element?(
               lv,
               "#node-keys-intro",
               "A machine signs every request with its own key. Qory keeps only the public half."
             )

      # With no key, the way that suits a node leads (the ways' own tests are below).
      assert has_element?(lv, "#node-keys-lead-title", "Enrol this machine with qory")
      refute has_element?(lv, "#node-keys-none")

      # Two keys at a time; none awaits anything.
      assert render(lv) =~ "A node holds at most 2 keys at a time."
      refute render(lv) =~ ~r/approv/i

      assert has_element?(lv, "#node-codes-none", "No enrolment code is outstanding.")
      assert has_element?(lv, "#key-add-button", "Add a public key")
      assert has_element?(lv, "#code-new-button", "New enrolment code")
      assert has_element?(lv, "#key-generate-button", "Generate a key")
      assert page_title(lv) =~ "Access key · build-01"
      refute_untrue(html)
    end

    test "lists each key with its state, fingerprint and arrival", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: pasted} = node_key_fixture(scope, node, %{label: "current"})
      %{access_key: enrolled} = enrolled_key_fixture(scope, node, %{label: "replacement"})

      {:ok, lv, html} = live(conn, tab_path(scope, node))

      # Each card's line is its heading, which takes the focus where an act took its button.
      assert has_element?(lv, ~s{h3#key-#{pasted.key_id}-title[tabindex="-1"]}, "current")
      assert has_element?(lv, "#key-#{pasted.key_id}-state", "Active")
      assert has_element?(lv, "#key-#{pasted.key_id}-fingerprint", AccessKey.fingerprint(pasted))
      assert has_element?(lv, "#key-#{pasted.key_id}-arrived", "Pasted by #{scope.user.email}")
      assert has_element?(lv, "#key-#{pasted.key_id}-revoke", "Revoke…")
      # Each Revoke… is named for the key it revokes.
      assert has_element?(lv, "#key-#{pasted.key_id}-revoke .sr-only", "Revoke current")
      assert has_element?(lv, ~s{#key-#{pasted.key_id}-revoke [aria-hidden="true"]}, "Revoke…")
      # An active key's card leads to its runner file, named for the key.
      assert has_element?(
               lv,
               ~s{#key-#{pasted.key_id}-runner-file[href="#{tab_path(scope, node, "/keys/#{pasted.key_id}/runner-file")}"]}
             )

      assert has_element?(
               lv,
               "#key-#{pasted.key_id}-runner-file .sr-only",
               "Runner file lines for current"
             )

      # A key a code brought is active as it arrives: the same state, and the same acts.
      assert has_element?(lv, "#key-#{enrolled.key_id}-state", "Active")

      assert has_element?(
               lv,
               "#key-#{enrolled.key_id}-arrived",
               "With an enrolment code #{scope.user.email} made"
             )

      assert has_element?(lv, "#key-#{enrolled.key_id}-revoke", "Revoke…")
      assert has_element?(lv, "#key-#{enrolled.key_id}-runner-file")

      # Nothing awaits approval, and no card offers one.
      for key <- [pasted, enrolled], act <- ~w(approve reject guidance) do
        refute has_element?(lv, "#key-#{key.key_id}-#{act}")
      end

      refute html =~ ~r/approv|reject/i
      refute_untrue(html)
    end

    test "a revoked key says so, by whom and when, and offers no act", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node, %{label: "old"})
      {:ok, _revoked} = AccessKeys.revoke_access_key(scope, key)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      assert has_element?(lv, "#key-#{key.key_id}-state", "Revoked")
      assert has_element?(lv, "#key-#{key.key_id}", "by #{scope.user.email}")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")
      refute has_element?(lv, "#key-#{key.key_id}-runner-file")
    end
  end

  describe "a key's acts, each confirmed in place" do
    test "a key is never approved or rejected: those addresses are not found", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node, %{label: "build-01"})

      for act <- ~w(approve reject) do
        assert conn
               |> get(tab_path(scope, node, "/keys/#{key.key_id}/#{act}"))
               |> html_response(404)
      end

      assert is_nil(Repo.get!(AccessKey, key.id).revoked_at)
    end

    test "revoke an active key", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node, %{label: "build-01"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/revoke"))

      assert has_element?(lv, "#key-#{key.key_id}-confirm", "Revoke build-01?")
      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert render(lv) =~ "build-01 is revoked."
      assert has_element?(lv, "#key-#{key.key_id}-state", "Revoked")
      assert Repo.get!(AccessKey, key.id).revoked_at
      assert_push_event(lv, "run:focus", %{id: "key-" <> _ = id})
      assert id == "key-#{key.key_id}-title"
    end

    test "revoke a key a code brought, as a pasted one", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = enrolled_key_fixture(scope, node, %{label: "build-01"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/revoke"))

      assert has_element?(lv, "#key-#{key.key_id}-confirm", "Revoke build-01?")
      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert render(lv) =~ "build-01 is revoked."
      assert has_element?(lv, "#key-#{key.key_id}-state", "Revoked")
      assert Repo.get!(AccessKey, key.id).revoked_at
    end

    test "an act on a key it does not fit, or no key of the node's, is said and not taken", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      other = node_fixture(scope)
      %{access_key: revoked} = node_key_fixture(scope, node, %{label: "build-01"})
      {:ok, _revoked} = AccessKeys.revoke_access_key(scope, revoked)
      %{access_key: elsewhere} = node_key_fixture(scope, other)

      {:ok, lv, html} =
        live(conn, tab_path(scope, node, "/keys/#{revoked.key_id}/revoke"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "build-01 is revoked."
      refute has_element?(lv, "#key-#{revoked.key_id}-confirm")

      {:ok, _lv, html} =
        live(conn, tab_path(scope, node, "/keys/#{elsewhere.key_id}/revoke"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "This node has no such key."
      assert is_nil(Repo.get!(AccessKey, elsewhere.id).revoked_at)
    end

    test "a revocation whose confirmation is not open acts on nothing", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      render_hook(lv, "revoke", %{"key_id" => key.key_id})
      assert is_nil(Repo.get!(AccessKey, key.id).revoked_at)
    end
  end

  describe "a key whose record was changed outside the application" do
    test "says so in its card, not as an alert: it can't be used", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node, %{label: "build-01"})
      tamper(key)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(
               lv,
               "#key-#{key.key_id}-integrity",
               "This key's record doesn't match its integrity code: it was changed outside the application. It can't be used."
             )

      refute has_element?(lv, "#key-#{key.key_id}-integrity[role=alert]")
      refute has_element?(lv, "#key-#{key.key_id}-integrity [role=alert]")
      refute render(lv) =~ ~r/approv/i
      # Revoking it stays open: it ends what can't be used anyway.
      assert has_element?(lv, "#key-#{key.key_id}-revoke")
    end
  end

  test "a key gone since its confirmation opened is said plainly", %{conn: conn, scope: scope} do
    node = node_fixture(scope)
    %{access_key: key} = node_key_fixture(scope, node)
    {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/revoke"))
    Repo.delete!(key)

    lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
    assert_patch(lv, tab_path(scope, node))

    assert lv |> element("#flash-group") |> render() =~
             "That key or code is gone: this node&#39;s keys changed meanwhile."
  end

  describe "adding a key by its public key" do
    test "is a page of its own; the fingerprint shows before it is added", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      pair = ed25519_key_pair()
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#key-add-button") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/add"))
      assert has_element?(lv, "#key-add-title", "Add a public key")

      assert has_element?(
               lv,
               "#key-add",
               "A key for build-01. It is active as soon as you add it."
             )

      assert has_element?(
               lv,
               "#key_public_key-hint",
               "without padding. qory access-key create prints it on the machine."
             )

      refute has_element?(lv, "#not-on-runs")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Add a public key")
      assert has_element?(lv, ~s{#key-add-save-cancel[href="#{tab_path(scope, node)}"]})
      refute_untrue(render(lv))

      # The fingerprint's place is there before any key is typed, read out as it fills, and
      # describes Add key.
      assert has_element?(lv, ~s{#key-add-fingerprint[aria-live="polite"]})
      refute has_element?(lv, "#key-add-fingerprint p")
      assert has_element?(lv, ~s{#key-add-submit[aria-describedby="key-add-fingerprint"]})

      lv
      |> form("#key-add-form", key: %{label: "build-01", public_key: pair.encoded})
      |> render_change()

      assert has_element?(
               lv,
               "#key-add-fingerprint",
               Apiary.Contract.Ed25519.fingerprint(pair.public_key)
             )

      lv
      |> form("#key-add-form",
        key: %{label: "build-01", allow_secrets: "false", public_key: pair.encoded}
      )
      |> render_submit()

      assert [%AccessKey{label: "build-01", revoked_at: nil} = key] =
               AccessKeys.list_for_node(scope, node)

      # On to what the machine is given: the key's runner file.
      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))
      assert render(lv) =~ "build-01 is added."
      assert has_element?(lv, "#key-runner-file-header-title", "Runner file for build-01")
    end

    test "Cancel leads back to the tab, the focus on the button that opened the page",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      for {open, leave, page} <- [
            {"#key-add-button", "#key-add-save-cancel", "/add"},
            {"#code-new-button", "#code-new-save-cancel", "/new-code"}
          ] do
        lv |> element(open) |> render_click()
        assert_patch(lv, tab_path(scope, node, page))
        lv |> element(leave) |> render_click()
        assert_patch(lv, tab_path(scope, node))
        assert_push_event(lv, "run:focus", %{id: id})
        assert "#" <> id == open
      end
    end

    test "the breadcrumb leads back to the tab from each form; the form has no Back link",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      tab = tab_path(scope, node)

      for {page, form} <- [{"/add", "#key-add"}, {"/new-code", "#code-new"}] do
        {:ok, lv, _html} = live(conn, tab_path(scope, node, page))
        refute has_element?(lv, form <> "-back")

        assert {:error, {:live_redirect, %{to: ^tab}}} =
                 lv |> element("#breadcrumb a[href='#{tab}']", "Access key") |> render_click()
      end
    end

    test "a key pasted with a line end around it is the key its fingerprint showed", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      pair = ed25519_key_pair()
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/add"))

      params = %{
        label: "build-01",
        allow_secrets: "false",
        public_key: " " <> pair.encoded <> "\n"
      }

      lv |> form("#key-add-form", key: params) |> render_change()

      assert has_element?(
               lv,
               "#key-add-fingerprint",
               Apiary.Contract.Ed25519.fingerprint(pair.public_key)
             )

      lv |> form("#key-add-form", key: params) |> render_submit()

      assert [%AccessKey{label: "build-01", public_key: public_key} = key] =
               AccessKeys.list_for_node(scope, node)

      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))

      assert public_key == pair.public_key
    end

    test "a third key is refused with what to do, revoke one", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      node_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/add"))

      lv
      |> form("#key-add-form",
        key: %{label: "third", allow_secrets: "false", public_key: ed25519_key_pair().encoded}
      )
      |> render_submit()

      flash = lv |> element("#flash-group") |> render()
      assert flash =~ "build-01 holds two keys already."
      assert flash =~ "Revoke one before you add another."

      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "a form's crafted parameters are an empty form, and nothing is added", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)

      for {event, params} <- [
            {"validate_key", %{"key" => %{"public_key" => %{"a" => 1}, "label" => "x"}}},
            {"validate_key", %{"key" => "x"}},
            {"add_key",
             %{"key" => %{"public_key" => ["x"], "label" => "x", "allow_secrets" => "false"}}},
            {"add_key",
             %{"key" => %{"public_key" => 1, "label" => "x", "allow_secrets" => "false"}}},
            {"add_key", %{"key" => "x"}},
            {"validate_code", %{"code" => "x"}},
            {"validate_code", %{"code" => %{"label_hint" => %{"a" => 1}}}},
            {"create_code", %{"code" => "x"}}
          ] do
        page = if event in ~w(validate_code create_code), do: "/new-code", else: "/add"
        {:ok, lv, _html} = live(conn, tab_path(scope, node, page))
        render_hook(lv, event, params)
        assert Process.alive?(lv.pid), "#{event} #{inspect(params)}"
        assert render(lv) =~ "id=\"#{if page == "/add", do: "key-add", else: "code"}"
      end

      assert AccessKeys.list_for_node(scope, node) == []
    end

    test "a key that can't be used is refused on the form", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/add"))

      html =
        lv
        |> form("#key-add-form", key: %{label: "build-01", public_key: "not-a-key"})
        |> render_submit()

      assert html =~ "this key cannot be used"
      assert AccessKeys.list_for_node(scope, node) == []
    end
  end

  describe "a key's runner file" do
    test "is what the machine is given: the server section and, for CI, the variables",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = node_key_fixture(scope, node, %{label: "current"})
      {yaml_pin, env_pin} = pin_lines()

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      lv |> element("#key-#{key.key_id}-runner-file") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))

      assert has_element?(lv, "#key-runner-file-header-title", "Runner file for current")
      assert page_title(lv) =~ "Runner file for current · build-01"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "current")

      assert has_element?(
               lv,
               "#key-runner-file",
               "For build-01. Nothing here is secret: the key's secret stays on the machine."
             )

      assert has_element?(
               lv,
               "#key-runner-file",
               "Put these lines in ~/.config/qory/runner.yaml on the machine:"
             )

      yaml = lv |> element("#key-runner-file-yaml") |> render() |> text()

      assert yaml ==
               """
               server:
                 url: #{ApiaryWeb.Endpoint.url()}
                 access_key_id: #{key.key_id}
                 apiary_public_key:
               #{yaml_pin}\
               """

      assert has_element?(lv, "#key-runner-file-yaml-copy", "Copy lines")

      assert has_element?(
               lv,
               "#key-runner-file",
               "For CI, keep url in the file and set these instead of the other two lines:"
             )

      env = lv |> element("#key-runner-file-env") |> render() |> text()
      assert env == "QORY_ACCESS_KEY_ID=#{key.key_id}\n#{env_pin}"
      assert has_element?(lv, "#key-runner-file-env-copy", "Copy variables")

      assert has_element?(
               lv,
               "#key-runner-file-secret",
               "The key's secret is where qory access-key create put it: ~/.config/qory/access-key-secret, or QORY_ACCESS_KEY_SECRET in CI."
             )

      refute_untrue(render(lv))

      # Done: back to the tab, the focus on the link that opened the page.
      lv |> element("#key-runner-file-done-button", "Done") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "key-#{key.key_id}-runner-file"
    end

    test "is an active key's alone", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: revoked} = node_key_fixture(scope, node, %{label: "old"})
      {:ok, _revoked} = AccessKeys.revoke_access_key(scope, revoked)

      for {rest, words} <- [
            {"/keys/#{revoked.key_id}/runner-file", "old is revoked."},
            {"/keys/ak_0000000000000000/runner-file", "This node has no such key."}
          ] do
        {:ok, lv, html} =
          live(conn, tab_path(scope, node, rest)) |> follow_redirect(conn, tab_path(scope, node))

        assert html =~ words
        refute has_element?(lv, "#key-runner-file")
      end

      # From the tab, the same.
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      render_patch(lv, tab_path(scope, node, "/keys/#{revoked.key_id}/runner-file"))
      assert_patch(lv, tab_path(scope, node))
      assert render(lv) =~ "old is revoked."
      refute has_element?(lv, "#key-runner-file")
    end

    test "a member reads it too: nothing on it is secret", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node, %{label: "current"})
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      assert has_element?(lv, "#key-#{key.key_id}-runner-file")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")

      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))
      assert has_element?(lv, "#key-runner-file-yaml", key.key_id)
    end
  end

  describe "an enrolment code" do
    test "is made on a page of its own and shown once, never in an address or a flash", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#code-new-button") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/new-code"))
      assert has_element?(lv, "#code-new-title", "New enrolment code")
      assert has_element?(lv, "#code-new", "expires 15 minutes later")
      # The page's heading takes the focus as it opens.
      assert lv |> element("#code-new-form") |> render() =~ ~r/phx-mounted="[^"]*code-new-title/

      refute has_element?(lv, "#not-on-runs")

      html =
        lv
        |> form("#code-new-form", code: %{allow_secrets: "true", label_hint: "build-01"})
        |> render_submit()

      refute_untrue(html)
      fingerprint = SigningKey.fingerprint()

      # The code as the machine sends it: the server key's fingerprint after it.
      [code] =
        Regex.run(
          ~r/qec_[0-9A-Z]{26}(?=\.#{Regex.escape(fingerprint)}<)/,
          lv |> element("#code-issued-value") |> render()
        )

      # The command that enrols the machine, with the address of this server and that code.
      assert has_element?(lv, "#code-issued", "On the machine, run:")

      assert lv |> element("#code-issued-command") |> render() |> text() ==
               "qory access-key enrol #{ApiaryWeb.Endpoint.url()} #{code}.#{fingerprint}"

      assert has_element?(lv, "#code-issued-command-copy", "Copy command")
      assert has_element?(lv, "#code-issued-works", "It works once, for 15 minutes.")

      assert has_element?(
               lv,
               "#code-issued-key",
               "The key it brings is active as soon as it arrives here. If its fingerprint is not the one qory prints, revoke it."
             )

      refute render(lv) =~ ~r/approv/i

      assert has_element?(lv, "#code-issued", "This code is shown once.")
      assert has_element?(lv, "#code-issued-secrets", "Allowed")
      assert has_element?(lv, "#code-issued-expires-label", "Expires")
      assert has_element?(lv, "#code-issued-expires", "15 minutes after it was made")

      # The page is named by its heading; the code is a group named "Enrolment code",
      # described by its expiry and by the notice that it is shown once, and takes the
      # focus as it shows.
      assert has_element?(lv, ~s{#code-issued[aria-labelledby="code-issued-header-title"]})
      assert has_element?(lv, "#code-issued-header-title", "New enrolment code")

      assert has_element?(
               lv,
               ~s{#code-issued-code[role="group"][aria-labelledby="code-issued-label"]}
             )

      assert has_element?(lv, "#code-issued-label", "Enrolment code")

      [described] =
        Regex.run(~r/aria-describedby="([^"]+)"/, render(element(lv, "#code-issued-code")),
          capture: :all_but_first
        )

      for id <- String.split(described) do
        assert has_element?(lv, "##{id}")
      end

      assert has_element?(lv, "#code-issued-once", "This code is shown once.")
      assert has_element?(lv, ~s{#code-issued-value[tabindex="-1"][phx-mounted]})

      # Done alone: leaving the page cancels nothing.
      assert has_element?(lv, "#code-issued-done-button", "Done")
      refute has_element?(lv, "#code-issued-done-cancel")
      refute lv |> element("#code-issued-done") |> render() =~ "Cancel"

      # No flash holds the code, nor the page's title.
      refute lv |> element("#flash-group") |> render() =~ code
      refute page_title(lv) =~ code

      [row] = AccessKeys.list_enrolment_codes(scope, node)
      assert row.code_sha256 == EnrolmentCode.hash(code)
      assert row.allow_secrets and row.label_hint == "build-01"

      # Done: back to the tab, where the code is not shown, nor ever again, and the focus
      # on New enrolment code.
      lv |> element("#code-issued-done-button") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      refute render(lv) =~ code
      assert has_element?(lv, "#code-#{row.id}", "Allowed")
      assert_push_event(lv, "run:focus", %{id: "code-new-button"})

      {:ok, lv, html} = live(conn, tab_path(scope, node, "/new-code"))
      refute html =~ code
      refute has_element?(lv, "#code-issued")
    end

    test "the code shown, as the command has it, is the one an enrolment redeems", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/new-code"))
      lv |> form("#code-new-form", code: %{allow_secrets: "false"}) |> render_submit()

      server = ApiaryWeb.Endpoint.url()

      ["qory", "access-key", "enrol", ^server, code] =
        lv |> element("#code-issued-command") |> render() |> text() |> String.split(" ")

      assert lv |> element("#code-issued-value") |> render() |> text() == code

      # A machine posts it as `qory access-key enrol` would: its new key, and the proof.
      pair = ed25519_key_pair()
      now = System.os_time(:second)
      message = SignedMessage.enrolment(code, pair.encoded, "build-01", now)
      proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

      {:ok, request} =
        Enrolment.decode(
          Jason.encode!(%{
            "version" => 1,
            "code" => code,
            "name" => "build-01",
            "public_key" => pair.encoded,
            "timestamp" => now,
            "proof" => Ed25519.encode(proof)
          })
        )

      assert Enrolment.issued_under?(request, SigningKey.fingerprint())
      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(request)
      assert key.node_id == node.id
      assert key.public_key == pair.public_key
      assert is_nil(key.revoked_at)
    end

    test "an outstanding code is listed with its expiry, and revoked in place", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      made = Format.time(row.inserted_at)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(
               lv,
               "#node-codes",
               "Listed here: the codes neither used, revoked nor expired."
             )

      # When it expires, as the reader's clock writes it.
      assert has_element?(lv, "#code-#{row.id}-expires-label", "Expires")
      assert has_element?(lv, "#code-#{row.id}-expires", Format.datetime(row.expires_at))
      refute has_element?(lv, "#code-#{row.id}-expires", "Just now")

      # Revoke… names the code it revokes, and so does its confirmation.
      assert has_element?(lv, "#code-#{row.id}-revoke .sr-only", "Revoke the code made #{made}")
      lv |> element("#code-#{row.id}-revoke") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      assert has_element?(lv, "#code-#{row.id}-confirm", "Revoke the code made #{made}?")
      assert has_element?(lv, "#code-#{row.id}-confirm", "It is revoked at once.")

      # Cancel gives the focus back to its Revoke….
      lv |> element("#code-#{row.id}-confirm-cancel") |> render_click()
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "code-#{row.id}-revoke"

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      assert render(lv) =~ "The enrolment code is revoked."
      assert Repo.get!(EnrolmentCode, row.id).cancelled_at
      assert has_element?(lv, "#node-codes-none")
      # Its Revoke… is gone with it: the focus goes to New enrolment code.
      assert_push_event(lv, "run:focus", %{id: "code-new-button"})
    end

    test "a code that expires while the tab is open leaves it, and its confirmation closes", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, other, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      expire_in(row, 1_500)

      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      assert has_element?(lv, "#code-#{row.id}-confirm-button")

      # The page reads the codes again as the first expires, without a word from elsewhere.
      Process.sleep(1_800)
      assert_patch(lv, tab_path(scope, node))
      refute has_element?(lv, "#code-#{row.id}")
      assert has_element?(lv, "#code-#{other.id}")

      assert lv |> element("#flash-group") |> render() =~
               "This enrolment code is no longer outstanding."

      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
    end

    test "a code that expired before its revocation reached it is said to be no longer outstanding",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      expire_in(row, -60_000)

      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      flash = lv |> element("#flash-group") |> render()
      assert flash =~ "This enrolment code is no longer outstanding."
      refute flash =~ "revoked"
      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
      refute has_element?(lv, "#code-#{row.id}")
    end

    test "a code's expiry read again leaves one timer, the one the page holds",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, _row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      held = expiry_timer(lv)
      assert is_integer(Process.read_timer(held))

      # An expiry whose message waited while a read set the timer the page holds: that
      # timer is cancelled, not left running beside the new one.
      send(lv.pid, :codes_expire)
      _ = render(lv)

      refute Process.read_timer(held)
      assert is_integer(Process.read_timer(expiry_timer(lv)))
    end

    test "its expiry says Expired once it is past" do
      now = DateTime.utc_now()

      for {at, word} <- [{DateTime.add(now, 60), "Expires"}, {DateTime.add(now, -1), "Expired"}] do
        html = render_component(&NodeComponents.code_expiry/1, id: "c", at: at, now: now)
        assert html =~ ~r{<dt[^>]* id="c-label"[^>]*>\s*#{word}\s*</dt>}
        assert html =~ Format.datetime(at)
      end
    end

    test "a second Make code once the code is shown makes none", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/new-code"))

      lv |> form("#code-new-form", code: %{}) |> render_submit()
      render_hook(lv, "create_code", %{"code" => %{}})
      assert length(AccessKeys.list_enrolment_codes(scope, node)) == 1
    end
  end

  describe "the ways to give a node its key" do
    # The ids of the row's buttons, in their order, and those shown as primary.
    defp ways(lv) do
      doc = lv |> element("#node-keys-ways") |> render() |> LazyHTML.from_fragment()

      {doc |> LazyHTML.query("[id$=-button]") |> LazyHTML.attribute("id"),
       doc |> LazyHTML.query(".btn-primary") |> LazyHTML.attribute("id")}
    end

    test "a node with no active key leads with enrolling the machine with qory", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(lv, "h3#node-keys-lead-title", "Enrol this machine with qory")

      assert lv |> element("#node-keys-lead p") |> render() |> text() |> String.trim() ==
               "Make a code, then run qory access-key enrol with it on the machine. The machine makes its own key, and the secret never shows on a screen."

      assert has_element?(lv, "#node-keys-lead p .font-mono", "qory access-key enrol")

      assert ways(lv) ==
               {~w(code-new-button key-generate-button key-add-button), ["code-new-button"]}

      assert has_element?(
               lv,
               ~s{#key-generate-button[href="#{tab_path(scope, node, "/generate")}"]}
             )

      refute has_element?(lv, "#node-keys-none")
    end

    test "a pool with no active key leads with generating a key", %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      {:ok, lv, _html} = live(conn, tab_path(scope, pool))

      assert has_element?(lv, "h3#node-keys-lead-title", "Generate a key for this pool")

      assert lv |> element("#node-keys-lead p") |> render() |> text() |> String.trim() ==
               "The pool's instances share one key. This browser makes it and shows you the secret once, for your CI's secret store; Qory receives only the public half."

      assert ways(lv) ==
               {~w(key-generate-button code-new-button key-add-button), ["key-generate-button"]}
    end

    test "once a key is active, the three stay, plain, the kind's way first; a revoked one leads again",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      %{access_key: key} = node_key_fixture(scope, node)
      node_key_fixture(scope, pool)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      refute has_element?(lv, "#node-keys-lead")
      assert ways(lv) == {~w(code-new-button key-generate-button key-add-button), []}

      {:ok, lv, _html} = live(conn, tab_path(scope, pool))
      refute has_element?(lv, "#node-keys-lead")
      assert ways(lv) == {~w(key-generate-button code-new-button key-add-button), []}

      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      assert has_element?(lv, "#node-keys-lead-title", "Enrol this machine with qory")
      refute has_element?(lv, "#node-keys-none")
    end
  end

  describe "generating a key in the browser" do
    defp generated_path(scope, node, key_id),
      do: tab_path(scope, node, "/keys/#{key_id}/generated")

    defp push_key(lv, key) do
      render_hook(lv, "generate_key", %{"key" => key})
    end

    defp browser_key(attrs \\ %{}) do
      Map.merge(
        %{
          "label" => "spot-runners",
          "allow_secrets" => "false",
          "public_key" => ed25519_key_pair().encoded
        },
        attrs
      )
    end

    defp add_entries(node) do
      Repo.all(
        from e in Apiary.Audit.Entry,
          where:
            e.action == "access_key.add" and
              fragment("?->>'node_id'", e.details) == ^node.public_id
      )
    end

    test "is a form page whose form holds the label and the flag alone, and no submit event", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#key-generate-button") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/generate"))

      assert has_element?(lv, ~s{section#key-generate[phx-hook="GenerateKey"]})
      assert has_element?(lv, "h1#key-generate-header-title", "Generate a key")

      assert lv
             |> element("#key-generate-header-description")
             |> render()
             |> text()
             |> String.trim() ==
               "A key for build-01, made in this browser. Only its public half is sent to Qory, and you see the secret once, as soon as it is made. For a machine of your own, enrolling it with qory keeps the secret off every screen."

      assert page_title(lv) =~ "Generate a key · build-01"

      # No phx-submit: the hook takes the submit. A same-origin action, posting.
      form = lv |> element("#key-generate-form") |> render()
      refute form =~ "phx-submit"
      assert form =~ ~s(action="#{tab_path(scope, node, "/generate")}")
      assert form =~ ~s(phx-change="validate_generate")

      names =
        form
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[name]")
        |> LazyHTML.attribute("name")
        |> Enum.uniq()
        |> Enum.sort()

      assert names == ["_csrf_token", "key[allow_secrets]", "key[label]"]

      refute has_element?(
               lv,
               "#key-generate-form [name*=secret]:not([name='key[allow_secrets]'])"
             )

      refute has_element?(lv, "#key-generate-form textarea")
      refute has_element?(lv, "#key-generate-form [name*=public_key]")

      assert has_element?(
               lv,
               ~s{#key-generate-form input[name="key[label]"][placeholder="build-01"]}
             )

      assert has_element?(lv, ~s{#key-generate-submit[type="submit"]}, "Generate key")
      assert has_element?(lv, "#key-generate-submit .btn-busy", "Generating")

      # The notices are the server's words, hidden by the class, never by the attribute.
      assert has_element?(lv, ~s{#key-generate-notices[phx-update="ignore"]})

      for {id, words} <- [
            {"key-generate-insecure",
             "This browser makes keys only on a page served over HTTPS. Open Qory over HTTPS, or enrol the machine with qory."},
            {"key-generate-unsupported",
             "This browser can't make an Ed25519 key. Use a current Chrome, Edge, Firefox or Safari, or enrol the machine with qory."},
            {"key-generate-lost",
             "The connection to Qory dropped before the key was confirmed, and its secret is gone. If a new key shows on the Access key tab, revoke it, then generate another."}
          ] do
        assert has_element?(lv, "##{id}.hidden")
        refute has_element?(lv, "##{id}[hidden]")
        assert lv |> element("##{id}") |> render() |> text() |> String.trim() == words
      end

      # Changing the form validates it, with no key yet.
      html = lv |> form("#key-generate-form", key: %{label: ""}) |> render_change()
      assert html =~ "can&#39;t be blank"
      assert AccessKeys.list_for_node(scope, node) == []
    end

    test "for a pool, says so without the line for a machine", %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      {:ok, lv, _html} = live(conn, tab_path(scope, pool, "/generate"))

      assert lv
             |> element("#key-generate-header-description")
             |> render()
             |> text()
             |> String.trim() ==
               "A key for spot-runners, made in this browser. Only its public half is sent to Qory, and you see the secret once, as soon as it is made."

      assert has_element?(
               lv,
               ~s{#key-generate-form input[name="key[label]"][placeholder="spot-runners"]}
             )
    end

    test "Cancel leads back to the tab, the focus on Generate a key", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))

      lv |> element("#key-generate-save a", "Cancel") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: "key-generate-button"})
    end

    test "the key the browser made is added by its public half, and its variables shown with an empty slot",
         %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      {:ok, lv, _html} = live(conn, tab_path(scope, pool, "/generate"))
      key = browser_key(%{"allow_secrets" => "true"})

      push_key(lv, key)

      assert [%AccessKey{} = added] = AccessKeys.list_for_node(scope, pool)
      assert_reply(lv, %{key_id: key_id})
      assert key_id == added.key_id
      assert_patch(lv, generated_path(scope, pool, added.key_id))

      assert added.arrived_by == :browser
      assert AccessKey.status(added) == :active
      assert added.allow_secrets
      assert added.created_by_id == scope.user.id
      assert Base.url_encode64(added.public_key, padding: false) == key["public_key"]
      assert [entry] = add_entries(pool)
      assert entry.after["arrived_by"] == "browser"

      html = render(lv)
      assert lv |> element("#flash-group") |> render() =~ "spot-runners is added."

      # The same section, now the variables.
      assert has_element?(lv, ~s{section#key-generate[phx-hook="GenerateKey"]})
      refute has_element?(lv, "#key-generate-form")
      assert has_element?(lv, "h1#key-generated-header-title", "Variables for spot-runners")
      assert page_title(lv) =~ "Variables for spot-runners · spot-runners"

      assert lv
             |> element("#key-generated-header-description")
             |> render()
             |> text()
             |> String.trim() ==
               "For spot-runners. Set these three variables where the runner starts."

      assert lv
             |> element("#key-generated-once")
             |> render()
             |> text()
             |> String.split()
             |> Enum.join(" ") ==
               "The secret is shown once. Copy it now: it was made in this browser, Qory never received it, and it can't be shown again."

      assert has_element?(lv, "#key-generated-once strong", "The secret is shown once.")

      [{"QORY_ACCESS_KEY_ID", id}, {"QORY_APIARY_PUBLIC_KEY", pin}] = AccessKeys.variables(added)
      assert has_element?(lv, "#key-generated-id", id)
      assert lv |> element("#key-generated-pin") |> render() |> text() == pin
      {_yaml, env_pin} = pin_lines()
      assert "QORY_APIARY_PUBLIC_KEY=" <> pin == env_pin

      # The slot: the key's own, ignored by LiveView, the stored public key on it, its
      # value empty.
      slot = "#key-generated-secret-#{added.key_id}"

      assert has_element?(
               lv,
               ~s{#{slot}[data-secret-slot][phx-update="ignore"][data-public-key="#{key["public_key"]}"]}
             )

      assert lv |> element("#{slot}-value") |> render() =~
               ~r{<code[^>]*id="key-generated-secret-#{added.key_id}-value"[^>]*>\s*</code>}

      assert has_element?(lv, ~s{#{slot} #{slot}-value[data-secret-value][tabindex="-1"]})
      assert has_element?(lv, "#{slot} #{slot}-gone[data-secret-gone].hidden")

      assert lv |> element("#{slot}-gone") |> render() |> text() |> String.trim() ==
               "Not shown: only the page that made the key held its secret, and this one was opened again. If you didn't copy it, revoke spot-runners and generate another key."

      for {copy, target, name} <- [
            {"key-generated-id-copy", "#key-generated-id", "QORY_ACCESS_KEY_ID"},
            {"key-generated-secret-copy", "#key-generated-secret-#{added.key_id}-value",
             "QORY_ACCESS_KEY_SECRET"},
            {"key-generated-pin-copy", "#key-generated-pin", "QORY_APIARY_PUBLIC_KEY"}
          ] do
        assert has_element?(
                 lv,
                 ~s{##{copy}[data-copy-target="#{target}"][aria-label="Copy #{name}"]}
               )
      end

      assert lv |> element("#key-generated-where") |> render() |> text() |> String.trim() ==
               "Only QORY_ACCESS_KEY_SECRET belongs in your CI's secret store; the other two are plain settings. The runner file then needs only url."

      assert has_element?(
               lv,
               "#key-generated-done",
               "Once you leave this page, the secret is not shown again."
             )

      # Nothing secret anywhere, and no form at all.
      refute html =~ ~r/qak_/i
      refute has_element?(lv, "#key-generate form")
      refute has_element?(lv, "#key-generate input")
      refute has_element?(lv, "#key-generate textarea")

      # Done: the tab, the focus on the key's heading, its card saying how it came.
      lv |> element("#key-generated-done-button") |> render_click()
      assert_patch(lv, tab_path(scope, pool))
      assert_push_event(lv, "run:focus", %{id: "key-" <> _})

      assert has_element?(
               lv,
               "#key-#{added.key_id}-arrived",
               "Made in a browser by #{scope.user.email}, #{Format.datetime(added.received_at)}"
             )
    end

    test "opened again, the page shows the id and the pin, and holds no secret", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = browser_key_fixture(scope, node, %{label: "ci"})

      {:ok, lv, html} = live(conn, generated_path(scope, node, key.key_id))

      assert has_element?(lv, "h1#key-generated-header-title", "Variables for ci")
      assert has_element?(lv, "#key-generated-id", key.key_id)
      assert has_element?(lv, "#key-generated-secret-#{key.key_id}-gone.hidden")
      refute html =~ ~r/qak_/i
    end

    test "a patch from one key's page to another's replaces the secret's slot", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      %{access_key: a} = browser_key_fixture(scope, node, %{label: "ci"})
      %{access_key: b} = browser_key_fixture(scope, node, %{label: "spot-runners"})
      encoded = &Base.url_encode64(&1.public_key, padding: false)

      {:ok, lv, _html} = live(conn, generated_path(scope, node, b.key_id))

      assert has_element?(
               lv,
               ~s{#key-generated-secret-#{b.key_id}[data-public-key="#{encoded.(b)}"]}
             )

      # A history jump to A's page patches the same LiveView: B's slot, the one the hook
      # filled with B's secret, leaves the page, and A's comes in, its value empty and
      # its gone line naming A.
      render_patch(lv, generated_path(scope, node, a.key_id))

      assert has_element?(lv, "#key-generated-id", a.key_id)
      refute has_element?(lv, "#key-generated-secret-#{b.key_id}")

      assert [_slot] =
               lv
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("[data-secret-slot]")
               |> Enum.to_list()

      assert has_element?(
               lv,
               ~s{#key-generated-secret-#{a.key_id}[phx-update="ignore"][data-public-key="#{encoded.(a)}"]}
             )

      assert lv |> element("#key-generated-secret-#{a.key_id}-value") |> render() =~
               ~r{>\s*</code>}

      assert lv
             |> element("#key-generated-secret-#{a.key_id}-gone")
             |> render()
             |> text()
             |> String.trim() =~ "revoke ci and generate another key."

      assert has_element?(
               lv,
               ~s{#key-generated-secret-copy[data-copy-target="#key-generated-secret-#{a.key_id}-value"]}
             )
    end

    test "a crafted event is refused before anything is stored", %{conn: conn, scope: scope} do
      node = node_fixture(scope)

      for key <- [
            Map.put(browser_key(), "secret", "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"),
            Map.put(browser_key(), "other", "x"),
            browser_key(%{"label" => "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}),
            browser_key(%{"label" => "ci QAK_x"}),
            browser_key(%{"allow_secrets" => "Qak_"}),
            browser_key(%{"public_key" => "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}),
            browser_key(%{"public_key" => "not-a-key"}),
            browser_key(%{"public_key" => @fixture_public_key}),
            browser_key(%{"label" => 1}),
            browser_key(%{"public_key" => ["x"]}),
            Map.delete(browser_key(), "public_key"),
            "x"
          ] do
        {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
        push_key(lv, key)
        assert_reply(lv, reply)
        refute Map.has_key?(reply, :key_id), inspect(key)
        assert_patch(lv, tab_path(scope, node))
        flash = lv |> element("#flash-group") |> render()
        assert flash =~ "The key wasn&#39;t added."
        assert flash =~ "Try again."
      end

      # A field beside the key, too.
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
      render_hook(lv, "generate_key", %{"key" => browser_key(), "secret" => "x"})
      assert_reply(lv, %{} = reply)
      refute Map.has_key?(reply, :key_id)

      assert AccessKeys.list_for_node(scope, node) == []
      assert add_entries(node) == []
    end

    # A valid public key whose base64url holds `prefix` at its start: hashes, the first
    # three bytes of each made `prefix`'s (four characters, 24 bits, so the encoding stays
    # canonical), until one decodes and passes the key checks. Deterministic.
    defp public_key_holding(prefix) do
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(fn i ->
        <<_::binary-size(3), rest::binary>> = :crypto.hash(:sha256, "spot-runners #{i}")
        Base.url_encode64(Base.url_decode64!(prefix) <> rest, padding: false)
      end)
      |> Enum.find(&match?({:ok, _}, Ed25519.decode_public_key(&1)))
    end

    test "a public key that happens to hold qak_ is added like any other", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)

      for prefix <- ["qak_", "QAK_"] do
        public_key = public_key_holding(prefix)
        assert String.starts_with?(public_key, prefix)
        assert String.length(public_key) == 43

        {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))

        push_key(
          lv,
          browser_key(%{"label" => "ci #{:erlang.phash2(prefix)}", "public_key" => public_key})
        )

        assert_reply(lv, %{key_id: key_id})
        assert_patch(lv, generated_path(scope, node, key_id))

        assert has_element?(
                 lv,
                 ~s{#key-generated-secret-#{key_id}[data-public-key="#{public_key}"]}
               )
      end

      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "a secret sent as the public key is refused by its decoding", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)

      for secret <- [
            "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
            "qak_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          ] do
        assert String.length(secret) == 47
        assert {:error, :length} = Ed25519.decode_public_key(secret)

        {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
        push_key(lv, browser_key(%{"public_key" => secret}))
        assert_reply(lv, reply)
        refute Map.has_key?(reply, :key_id)
        assert_patch(lv, tab_path(scope, node))
        assert lv |> element("#flash-group") |> render() =~ "The key wasn&#39;t added."
      end

      assert AccessKeys.list_for_node(scope, node) == []
      assert add_entries(node) == []
    end

    test "the event acts only on its page, with the form open", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = browser_key_fixture(scope, node)

      for rest <- ["", "/add", "/new-code", "/keys/#{key.key_id}/generated"] do
        {:ok, lv, _html} = live(conn, tab_path(scope, node, rest))
        push_key(lv, browser_key())
        assert_reply(lv, reply)
        refute Map.has_key?(reply, :key_id)
      end

      assert [_only] = AccessKeys.list_for_node(scope, node)
    end

    test "a label already taken is said on the form, and nothing is added", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      node_key_fixture(scope, node, %{label: "ci"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))

      html = push_key(lv, browser_key(%{"label" => "ci"}))
      assert_reply(lv, reply)
      refute Map.has_key?(reply, :key_id)
      assert html =~ "is already the label of a key of this node"
      assert has_element?(lv, "#key-generate-form")
      assert length(AccessKeys.list_for_node(scope, node)) == 1
    end

    test "at the limit, the page and the event go back to the tab with what to do", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)

      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
      # A second key arrives meanwhile.
      node_key_fixture(scope, node)
      push_key(lv, browser_key())
      assert_reply(lv, reply)
      refute Map.has_key?(reply, :key_id)
      assert_patch(lv, tab_path(scope, node))

      flash = lv |> element("#flash-group") |> render()
      assert flash =~ "build-01 holds two keys already."
      assert flash =~ "Revoke one before you add another."

      {:ok, _lv, html} =
        live(conn, tab_path(scope, node, "/generate"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "build-01 holds two keys already."
      assert length(AccessKeys.list_for_node(scope, node)) == 2
    end

    test "the variables' address is for an active key the reader made in a browser alone", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{scope: admin} = member_fixture(scope, :admin)
      %{access_key: others} = browser_key_fixture(admin, node, %{label: "others"})
      %{access_key: pasted} = node_key_fixture(scope, node, %{label: "pasted"})

      # Another person's browser key, and a pasted one: their runner file, no flash.
      for key <- [others, pasted] do
        {:ok, lv, _html} =
          live(conn, generated_path(scope, node, key.key_id))
          |> follow_redirect(conn, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))

        assert has_element?(lv, "#key-runner-file")
        refute has_element?(lv, "[data-secret-slot]")
      end

      # A revoked one, and none of the node's: back to the tab, said.
      {:ok, _} = AccessKeys.revoke_access_key(scope, others)
      %{access_key: elsewhere} = browser_key_fixture(scope, node_fixture(scope))

      for {key, words} <- [
            {others, "others is revoked."},
            {elsewhere, "This node has no such key."}
          ] do
        {:ok, _lv, html} =
          live(conn, generated_path(scope, node, key.key_id))
          |> follow_redirect(conn, tab_path(scope, node))

        assert html =~ words
      end
    end

    test "a member is refused the page and the event", %{scope: scope} do
      node = node_fixture(scope)
      conn = member_conn(scope)

      {:ok, _lv, html} =
        live(conn, tab_path(scope, node, "/generate"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "Only owners and admins add a node&#39;s keys."

      # The event, pushed from the tab they may read: refused, no key, nothing written.
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      push_key(lv, browser_key())
      assert_reply(lv, reply)
      refute Map.has_key?(reply, :key_id)
      assert render(lv) =~ "Only owners and admins manage a node&#39;s keys."

      assert AccessKeys.list_for_node(scope, node) == []
      assert add_entries(node) == []
    end

    test "an admin's own key goes to its runner file once they are a member", %{scope: scope} do
      node = node_fixture(scope)
      %{scope: admin, user: user, membership: membership} = member_fixture(scope, :admin)
      %{access_key: key} = browser_key_fixture(admin, node)
      Repo.update!(Ecto.Changeset.change(membership, level: :member))
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} =
        live(conn, generated_path(scope, node, key.key_id))
        |> follow_redirect(conn, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))

      assert has_element?(lv, "#key-runner-file")
    end
  end

  describe "a member" do
    test "with no key, reads that there is none, not how to make one; an admin is led",
         %{scope: scope} do
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(member_conn(scope), tab_path(scope, node))

      assert lv |> element("#node-keys-none") |> render() |> text() |> String.trim() ==
               "No key yet."

      refute has_element?(lv, "#node-keys-none", "enrolment code")
      refute has_element?(lv, "#node-keys-none .font-mono")

      refute has_element?(lv, "#node-keys-lead")
      refute has_element?(lv, "#node-keys-ways")

      {:ok, lv, _html} = live(member_conn(scope, :admin), tab_path(scope, node))

      assert has_element?(lv, "#node-keys-lead-title", "Enrol this machine with qory")
      refute has_element?(lv, "#node-keys-none")
    end

    test "reads the keys and the codes, with no act", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(
               lv,
               "#node-keys-members",
               "Only owners and admins manage a node's keys."
             )

      assert has_element?(lv, "#key-#{key.key_id}-state", "Active")
      assert has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#key-add-button")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-generate-button")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")
      refute has_element?(lv, "#code-#{row.id}-revoke")
    end

    test "is refused every act's path and event, and nothing changes", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      conn = member_conn(scope)

      for {rest, words} <- [
            {"/add", "Only owners and admins add a node's keys."},
            {"/generate", "Only owners and admins add a node's keys."},
            {"/new-code", "Only owners and admins make enrolment codes."},
            {"/keys/#{key.key_id}/revoke", "Only owners and admins manage a node's keys."},
            {"/codes/#{row.id}/revoke", "Only owners and admins manage a node's keys."}
          ] do
        {:ok, _lv, html} =
          live(conn, tab_path(scope, node, rest)) |> follow_redirect(conn, tab_path(scope, node))

        assert html =~ String.replace(words, "'", "&#39;")
      end

      for {event, params} <- [
            {"add_key",
             %{"key" => %{"label" => "x", "public_key" => ed25519_key_pair().encoded}}},
            {"create_code", %{"code" => %{}}},
            {"generate_key",
             %{
               "key" => %{
                 "label" => "x",
                 "allow_secrets" => "false",
                 "public_key" => ed25519_key_pair().encoded
               }
             }},
            {"revoke", %{}},
            {"revoke_code", %{}}
          ] do
        # A page of its own for each, so each refusal is its own flash.
        {:ok, lv, _html} = live(conn, tab_path(scope, node))
        refute lv |> element("#flash-group") |> render() =~ "Only owners and admins"
        render_hook(lv, event, params)

        assert lv |> element("#flash-group") |> render() =~
                 "Only owners and admins manage a node&#39;s keys."
      end

      assert is_nil(Repo.get!(AccessKey, key.id).revoked_at)
      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
      assert length(AccessKeys.list_enrolment_codes(scope, node)) == 1
      assert length(AccessKeys.list_for_node(scope, node)) == 1
    end
  end

  test "an admin made a member since the page opened is refused by the context", %{scope: scope} do
    node = node_fixture(scope)
    %{access_key: key} = node_key_fixture(scope, node)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/revoke"))
    Repo.update!(Ecto.Changeset.change(membership, level: :member))

    lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
    assert render(lv) =~ "Only owners and admins manage a node&#39;s keys."
    assert is_nil(Repo.get!(AccessKey, key.id).revoked_at)
  end

  test "a node of another workspace or organisation is not found", %{conn: conn, scope: scope} do
    other_workspace = node_fixture(%{scope | workspace: workspace_fixture(scope.organisation)})
    other_organisation = node_fixture(sign_up_fixture().scope)

    for node <- [other_workspace, other_organisation] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, tab_path(scope, node)) end
    end
  end
end
