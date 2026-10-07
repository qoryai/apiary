defmodule ApiaryWeb.NodeLive.AccessKeyTest do
  @moduledoc """
  A node's Access key tab (`ApiaryWeb.NodeLive.AccessKey`): the plain line that runners
  can't use a node's keys yet, the keys and their acts confirmed in place, adding a key by
  its public key, an enrolment code made and shown once, the outstanding codes and their
  revocation, and what a member, another organisation and a stale page are refused.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Repo
  alias ApiaryWeb.{Format, NodeComponents}

  setup :register_and_log_in_user

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

  # Not one line says a node enrols, posts or connects with these, nor names a command.
  defp refute_untrue(html) do
    refute html =~ "access-key enrol"
    refute html =~ "qory access-key"
    refute html =~ "post runs"
    refute html =~ "can post"
    refute html =~ "enrol with this code"
  end

  describe "the tab" do
    test "is a tab of the node's page, and says once that runners can't use these keys yet",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, html} = live(conn, tab_path(scope, node))

      assert has_element?(lv, "h1#node-header-title", "build-01")
      assert has_element?(lv, ~s{#node-tabs-access_key[aria-current="page"]}, "Access key")

      assert has_element?(
               lv,
               ~s{#node-tabs-overview[href="#{~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}"}"]}
             )

      assert has_element?(
               lv,
               "#not-on-runs",
               "Runners can't use these keys or enrolment codes yet."
             )

      assert has_element?(lv, "#not-on-runs", "Runs still use the workspace's access keys, in")
      assert has_element?(lv, "#not-on-runs-keys", "Settings › Access keys")

      assert has_element?(
               lv,
               ~s{#not-on-runs-keys[href="#{~p"/#{scope.organisation}/#{scope.workspace}/settings/keys"}"]}
             )

      assert lv
             |> element("#node-access-key")
             |> render()
             |> String.split("not-on-runs\"")
             |> length() == 2

      assert has_element?(lv, "#node-keys-none", "No key yet.")
      assert has_element?(lv, "#node-codes-none", "No enrolment code is outstanding.")
      assert has_element?(lv, "#key-add-button", "Add a public key")
      assert has_element?(lv, "#code-new-button", "New enrolment code")
      assert page_title(lv) =~ "Access key · build-01"
      refute_untrue(html)
    end

    test "lists each key with its state, fingerprint and arrival", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: pasted} = node_key_fixture(scope, node, %{label: "current"})
      %{access_key: pending} = pending_key_fixture(scope, node, %{label: "replacement"})

      {:ok, lv, html} = live(conn, tab_path(scope, node))

      # Each card's line is its heading, which takes the focus where an act took its button.
      assert has_element?(lv, ~s{h3#key-#{pasted.key_id}-title[tabindex="-1"]}, "current")
      assert has_element?(lv, "#key-#{pasted.key_id}-state", "Approved")
      assert has_element?(lv, "#key-#{pasted.key_id}-fingerprint", AccessKey.fingerprint(pasted))
      assert has_element?(lv, "#key-#{pasted.key_id}-arrived", "Pasted by #{scope.user.email}")
      assert has_element?(lv, "#key-#{pasted.key_id}-revoke", "Revoke…")
      # Each Revoke… is named for the key it revokes.
      assert has_element?(lv, "#key-#{pasted.key_id}-revoke .sr-only", "Revoke current")
      assert has_element?(lv, ~s{#key-#{pasted.key_id}-revoke [aria-hidden="true"]}, "Revoke…")
      refute has_element?(lv, "#key-#{pasted.key_id}-approve")

      assert has_element?(lv, "#key-#{pending.key_id}-state", "Awaiting approval")

      assert has_element?(
               lv,
               "#key-#{pending.key_id}-arrived",
               "With an enrolment code #{scope.user.email} made"
             )

      assert has_element?(lv, "#key-#{pending.key_id}-guidance", "Approve it only if")
      assert has_element?(lv, "#key-#{pending.key_id}-approve", "Approve…")
      assert has_element?(lv, "#key-#{pending.key_id}-reject", "Reject…")
      refute has_element?(lv, "#key-#{pending.key_id}-revoke")
      refute_untrue(html)
    end
  end

  describe "a key's acts, each confirmed in place" do
    test "approve a key that awaits approval", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node, %{label: "build-01"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#key-#{key.key_id}-approve") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/approve"))
      assert has_element?(lv, "#key-#{key.key_id}-confirm", "Approve build-01?")
      assert has_element?(lv, "#key-#{key.key_id}-confirm", AccessKey.fingerprint(key))

      # Cancel folds it, changes nothing, and gives the focus back to Approve….
      lv |> element("#key-#{key.key_id}-confirm-cancel") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      refute has_element?(lv, "#key-#{key.key_id}-confirm")
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "key-#{key.key_id}-approve"
      assert has_element?(lv, ~s{##{id}[phx-hook="FocusOn"]})

      lv |> element("#key-#{key.key_id}-approve") |> render_click()
      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert render(lv) =~ "build-01 is approved."
      assert has_element?(lv, "#key-#{key.key_id}-state", "Approved")
      assert Repo.get!(AccessKey, key.id).approved_at

      # Approve… is gone with the approval: the focus goes to the key's heading.
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "key-#{key.key_id}-title"
      assert has_element?(lv, ~s{##{id}[phx-hook="FocusOn"]})
    end

    test "reject a key that awaits approval", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node, %{label: "build-01"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/reject"))

      assert has_element?(lv, "#key-#{key.key_id}-confirm", "Reject build-01?")
      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert render(lv) =~ "build-01 is rejected."
      assert has_element?(lv, "#key-#{key.key_id}-state", "Rejected")

      rejected = Repo.get!(AccessKey, key.id)
      assert rejected.revoked_at && is_nil(rejected.approved_at)
    end

    test "revoke an approved key", %{conn: conn, scope: scope} do
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

    test "an act on a key it does not fit, or no key of the node's, is said and not taken", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      other = node_fixture(scope)
      %{access_key: approved} = node_key_fixture(scope, node, %{label: "build-01"})
      %{access_key: elsewhere} = pending_key_fixture(scope, other)

      {:ok, lv, html} =
        live(conn, tab_path(scope, node, "/keys/#{approved.key_id}/approve"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "build-01 no longer awaits approval."
      refute has_element?(lv, "#key-#{approved.key_id}-confirm")

      {:ok, _lv, html} =
        live(conn, tab_path(scope, node, "/keys/#{elsewhere.key_id}/approve"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~ "This node has no such key."
      assert is_nil(Repo.get!(AccessKey, elsewhere.id).approved_at)
    end

    test "an approval whose confirmation is not open acts on nothing", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      render_hook(lv, "approve", %{"key_id" => key.key_id})
      assert is_nil(Repo.get!(AccessKey, key.id).approved_at)
    end
  end

  describe "a key whose record was changed outside the application" do
    test "says so in its card, not as an alert, and offers no approval; its path refuses", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node, %{label: "build-01"})
      tamper(key)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      assert has_element?(lv, "#key-#{key.key_id}-integrity", "doesn't match its integrity code")
      refute has_element?(lv, "#key-#{key.key_id}-integrity[role=alert]")
      refute has_element?(lv, "#key-#{key.key_id}-integrity [role=alert]")
      refute has_element?(lv, "#key-#{key.key_id}-approve")
      refute has_element?(lv, "#key-#{key.key_id}-guidance")
      assert has_element?(lv, "#key-#{key.key_id}-reject")

      {:ok, lv, html} =
        live(conn, tab_path(scope, node, "/keys/#{key.key_id}/approve"))
        |> follow_redirect(conn, tab_path(scope, node))

      assert html =~
               "build-01 can&#39;t be approved: its record was changed outside the application."

      refute has_element?(lv, "#key-#{key.key_id}-confirm-button")
      render_hook(lv, "approve", %{})
      assert is_nil(Repo.get!(AccessKey, key.id).approved_at)
    end

    test "one changed after its confirmation opened is not approved", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node, %{label: "build-01"})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/approve"))
      tamper(key)

      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert render(lv) =~ "build-01 can&#39;t be approved: its record was changed outside"
      assert is_nil(Repo.get!(AccessKey, key.id).approved_at)
    end
  end

  test "a key gone since its confirmation opened is said plainly", %{conn: conn, scope: scope} do
    node = node_fixture(scope)
    %{access_key: key} = pending_key_fixture(scope, node)
    {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/reject"))
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
      assert has_element?(lv, "#key-add", "approved as you add it")
      assert has_element?(lv, "#not-on-runs", "Runners can't use these keys")
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

      assert_patch(lv, tab_path(scope, node))
      assert render(lv) =~ "build-01 is added, and approved."
      assert_push_event(lv, "run:focus", %{id: "key-add-button"})

      assert [%AccessKey{label: "build-01", approved_at: %DateTime{}}] =
               AccessKeys.list_for_node(scope, node)
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
      assert_patch(lv, tab_path(scope, node))

      assert [%AccessKey{label: "build-01", public_key: public_key}] =
               AccessKeys.list_for_node(scope, node)

      assert public_key == pair.public_key
    end

    test "a third key is refused with what to do, revoke or reject one", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      pending_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/add"))

      lv
      |> form("#key-add-form",
        key: %{label: "third", allow_secrets: "false", public_key: ed25519_key_pair().encoded}
      )
      |> render_submit()

      flash = lv |> element("#flash-group") |> render()
      assert flash =~ "build-01 holds two keys already."
      assert flash =~ "Revoke or reject one before you add another."

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

      assert has_element?(
               lv,
               "#not-on-runs",
               "Runners can't use these keys or enrolment codes yet"
             )

      html =
        lv
        |> form("#code-new-form", code: %{allow_secrets: "true", label_hint: "build-01"})
        |> render_submit()

      refute_untrue(html)
      [code] = Regex.run(~r/qec_[0-9A-Z]{26}/, lv |> element("#code-issued-value") |> render())
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

  describe "a member" do
    test "reads the keys and the codes, with no act", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = pending_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      conn = member_conn(scope)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(
               lv,
               "#node-keys-members",
               "Only owners and admins manage a node's keys."
             )

      assert has_element?(lv, "#key-#{key.key_id}-state", "Awaiting approval")
      assert has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#key-add-button")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-#{key.key_id}-approve")
      refute has_element?(lv, "#key-#{key.key_id}-guidance")
      refute has_element?(lv, "#code-#{row.id}-revoke")
    end

    test "is refused every act's path and event, and nothing changes", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: pending} = pending_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      conn = member_conn(scope)

      for {rest, words} <- [
            {"/add", "Only owners and admins add a node's keys."},
            {"/new-code", "Only owners and admins make enrolment codes."},
            {"/keys/#{pending.key_id}/approve", "Only owners and admins manage a node's keys."},
            {"/keys/#{pending.key_id}/reject", "Only owners and admins manage a node's keys."},
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
            {"approve", %{}},
            {"reject", %{}},
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

      assert is_nil(Repo.get!(AccessKey, pending.id).approved_at)
      assert is_nil(Repo.get!(AccessKey, pending.id).revoked_at)
      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
      assert length(AccessKeys.list_enrolment_codes(scope, node)) == 1
      assert length(AccessKeys.list_for_node(scope, node)) == 1
    end
  end

  test "an admin made a member since the page opened is refused by the context", %{scope: scope} do
    node = node_fixture(scope)
    %{access_key: key} = pending_key_fixture(scope, node)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, tab_path(scope, node, "/keys/#{key.key_id}/approve"))
    Repo.update!(Ecto.Changeset.change(membership, level: :member))

    lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
    assert render(lv) =~ "Only owners and admins manage a node&#39;s keys."
    assert is_nil(Repo.get!(AccessKey, key.id).approved_at)
  end

  test "a node of another workspace or organisation is not found", %{conn: conn, scope: scope} do
    other_workspace = node_fixture(%{scope | workspace: workspace_fixture(scope.organisation)})
    other_organisation = node_fixture(sign_up_fixture().scope)

    for node <- [other_workspace, other_organisation] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, tab_path(scope, node)) end
    end
  end
end
