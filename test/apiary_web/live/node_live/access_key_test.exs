defmodule ApiaryWeb.NodeLive.AccessKeyTest do
  @moduledoc """
  A node's Access key tab (`ApiaryWeb.NodeLive.AccessKey`): its intro and the way a
  machine gets a key, the keys and their acts confirmed in place, adding a key by its
  public key and the runner file it leads to, an enrolment code made and shown once with
  the command that enrols the machine (redeemed as shown), the outstanding codes and their
  revocation, and what a member, another organisation and a stale page are refused.
  """
  use ApiaryWeb.ConnCase, async: true

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

      assert has_element?(
               lv,
               "#node-keys-none",
               "No key yet. Make an enrolment code and run the command it shows on the machine, or add the public key qory access-key create printed there."
             )

      assert has_element?(lv, "#node-keys-none .font-mono", "qory access-key create")

      # Two keys at a time, never two approved and a third awaiting approval.
      assert render(lv) =~
               "A node holds at most 2 keys at a time, at most 1 of them awaiting approval."

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
      # An approved key's card leads to its runner file, named for the key.
      assert has_element?(
               lv,
               ~s{#key-#{pasted.key_id}-runner-file[href="#{tab_path(scope, node, "/keys/#{pasted.key_id}/runner-file")}"]}
             )

      assert has_element?(
               lv,
               "#key-#{pasted.key_id}-runner-file .sr-only",
               "Runner file lines for current"
             )

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
      refute has_element?(lv, "#key-#{pending.key_id}-runner-file")
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

      assert [%AccessKey{label: "build-01", approved_at: %DateTime{}} = key] =
               AccessKeys.list_for_node(scope, node)

      # On to what the machine is given: the key's runner file.
      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))
      assert render(lv) =~ "build-01 is added, and approved."
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

    test "is an approved key's alone", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      %{access_key: pending} = pending_key_fixture(scope, node, %{label: "replacement"})
      %{access_key: revoked} = node_key_fixture(scope, node, %{label: "old"})
      {:ok, _revoked} = AccessKeys.revoke_access_key(scope, revoked)

      for {rest, words} <- [
            {"/keys/#{pending.key_id}/runner-file", "replacement is not an approved key."},
            {"/keys/#{revoked.key_id}/runner-file", "old is not an approved key."},
            {"/keys/ak_0000000000000000/runner-file", "This node has no such key."}
          ] do
        {:ok, lv, html} =
          live(conn, tab_path(scope, node, rest)) |> follow_redirect(conn, tab_path(scope, node))

        assert html =~ words
        refute has_element?(lv, "#key-runner-file")
      end

      # From the tab, the same.
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      render_patch(lv, tab_path(scope, node, "/keys/#{pending.key_id}/runner-file"))
      assert_patch(lv, tab_path(scope, node))
      assert render(lv) =~ "replacement is not an approved key."
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
               "#code-issued-approve",
               "The key it brings arrives here awaiting approval. Compare the fingerprint qory prints with the key's before you approve it."
             )

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
      assert AccessKey.status(key) == :pending
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

  describe "a member" do
    test "with no key, reads that there is none, not how to make one; an admin reads how",
         %{scope: scope} do
      node = node_fixture(scope, name: "build-01")

      {:ok, lv, _html} = live(member_conn(scope), tab_path(scope, node))

      assert lv |> element("#node-keys-none") |> render() |> text() |> String.trim() ==
               "No key yet."

      refute has_element?(lv, "#node-keys-none", "enrolment code")
      refute has_element?(lv, "#node-keys-none .font-mono")

      {:ok, lv, _html} = live(member_conn(scope, :admin), tab_path(scope, node))

      assert has_element?(
               lv,
               "#node-keys-none",
               "No key yet. Make an enrolment code and run the command it shows on the machine, or add the public key qory access-key create printed there."
             )
    end

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
