defmodule ApiaryWeb.NodeLive.AccessKeyTest do
  @moduledoc """
  A node's Access key tab (`ApiaryWeb.NodeLive.AccessKey`): the two ways to connect a
  node, ordered by its kind, the keys and their acts confirmed in place, Add a key,
  generating a key in the browser and the key's page it leads to, an active key's runner
  file as the key came, the command got in one click and shown once (redeemed as shown,
  the page turning to "connected" as the key arrives), a command waiting and its
  cancelling, and what a member, another organisation and a stale page are refused.
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
  alias ApiaryWeb.Format

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

  # The words of an element, its spaces made one.
  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r/<(p|div|h[1-6]|li|dt|dd)[\s>]/, " \\0")
    |> text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Get the command on the tab: the command's page, and the code in its command.
  defp get_command(lv, scope, node) do
    lv |> element("#code-new-button") |> render_click()
    assert_patch(lv, tab_path(scope, node, "/new-code"))
    command = lv |> element("#code-issued-command") |> render() |> text() |> String.trim()
    ["qory", "access-key", "enrol" | rest] = String.split(command, " ")
    [_server, code] = rest -- ["--replace"]
    code
  end

  # What a machine posts as `qory access-key enrol` with `code`: its new key, and the proof.
  defp enrol_request(code, pair \\ ed25519_key_pair()) do
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

    request
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

      # With no key, the question and the two ways (the ways' own tests are below); no
      # list of codes, no Keys part.
      assert has_element?(lv, "#node-connect-title", "How do you want to connect build-01?")

      assert words(lv, "#node-connect-intro") ==
               "build-01 needs a key before it can start runs. Choose one of two ways to give it one."

      refute has_element?(lv, "#node-keys")
      refute has_element?(lv, "#node-codes")
      refute render(lv) =~ "Enrolment code"
      refute render(lv) =~ ~r/approv/i

      assert has_element?(lv, "#code-new-button", "Get the command")
      assert has_element?(lv, "#key-generate-button", "Generate a key")
      assert page_title(lv) =~ "Access key · build-01"
      refute_untrue(html)
    end

    test "lists each key with its state, fingerprint and arrival", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: made} = node_key_fixture(scope, node, %{label: "current"})
      %{access_key: enrolled} = enrolled_key_fixture(scope, node, %{label: "replacement"})

      {:ok, lv, html} = live(conn, tab_path(scope, node))

      # Each card's line is its heading, which takes the focus where an act took its button:
      # its label and its state; the key's ID is its first row, with Copy.
      assert has_element?(lv, ~s{h3#key-#{made.key_id}-title[tabindex="-1"]}, "current")
      refute has_element?(lv, "h3#key-#{made.key_id}-title", made.key_id)
      assert has_element?(lv, "#key-#{made.key_id}-state", "Active")
      assert has_element?(lv, "#key-#{made.key_id}-id", made.key_id)

      assert has_element?(
               lv,
               ~s{#key-#{made.key_id}-id-copy[aria-label="Copy the key ID of current"][data-copy="#{made.key_id}"]}
             )

      assert has_element?(lv, "#key-#{made.key_id}-fingerprint", AccessKey.fingerprint(made))

      assert has_element?(
               lv,
               "#key-#{made.key_id}-added",
               "Generated in a browser by #{scope.user.email}, #{Format.datetime(made.received_at)}"
             )

      assert has_element?(
               lv,
               "#key-#{made.key_id}-secret",
               "Shown once when it was generated; kept where you put it, such as your CI's secret store"
             )

      assert has_element?(lv, "#key-#{made.key_id}-used", "Not yet")
      assert has_element?(lv, "#node-keys-title", "Keys")
      assert has_element?(lv, "#node-keys-title .q-part-n", "2")

      assert words(lv, "#node-keys-intro") ==
               "build-01 signs every request with its key. Qory Apiary keeps only the public half."

      assert has_element?(lv, "#key-#{made.key_id}-revoke", "Revoke…")
      # Each Revoke… is named for the key it revokes.
      assert has_element?(lv, "#key-#{made.key_id}-revoke .sr-only", "Revoke current")
      assert has_element?(lv, ~s{#key-#{made.key_id}-revoke [aria-hidden="true"]}, "Revoke…")
      # An active key's card leads to its runner file, named for the key.
      assert has_element?(
               lv,
               ~s{#key-#{made.key_id}-runner-file[href="#{tab_path(scope, node, "/keys/#{made.key_id}/runner-file")}"]}
             )

      assert has_element?(
               lv,
               "#key-#{made.key_id}-runner-file .sr-only",
               "Runner file for current"
             )

      assert has_element?(
               lv,
               ~s{#key-#{made.key_id}-runner-file [aria-hidden="true"]},
               "Runner file"
             )

      # A key a command brought is active as it arrives: the same state, and the same acts.
      assert has_element?(lv, "#key-#{enrolled.key_id}-state", "Active")

      assert has_element?(
               lv,
               "#key-#{enrolled.key_id}-added",
               "Connected with a command by #{scope.user.email}"
             )

      assert has_element?(
               lv,
               "#key-#{enrolled.key_id}-secret",
               "On build-01, saved there by the command"
             )

      assert has_element?(lv, "#key-#{enrolled.key_id}-revoke", "Revoke…")
      assert has_element?(lv, "#key-#{enrolled.key_id}-runner-file")

      # Nothing awaits approval, and no card offers one.
      for key <- [made, enrolled], act <- ~w(approve reject guidance) do
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

    test "revoke a key a code brought, as a browser key", %{conn: conn, scope: scope} do
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

  describe "the pages a way opens" do
    test "Cancel and Done lead back to the tab, the focus on the button that opened the page",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#key-generate-button") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/generate"))
      lv |> element("#key-generate-save-cancel") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: "key-generate-button"})

      _code = get_command(lv, scope, node)
      lv |> element("#code-issued-done-button") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: "code-new-button"})
    end

    test "the breadcrumb leads back to the tab from the form; the form has no Back link",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      tab = tab_path(scope, node)

      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
      refute has_element?(lv, "#key-generate-back")

      assert {:error, {:live_redirect, %{to: ^tab}}} =
               lv |> element("#breadcrumb a[href='#{tab}']", "Access key") |> render_click()
    end

    test "a form's crafted parameters are an empty form, and nothing is made", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)

      for {event, params} <- [
            {"validate_generate", %{"key" => "x"}},
            {"validate_generate", %{"key" => %{"label" => %{"a" => 1}}}},
            {"validate_generate", %{"key" => %{"label" => "ci", "allow_secrets" => "true"}}}
          ] do
        {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
        render_hook(lv, event, params)
        assert Process.alive?(lv.pid), "#{event} #{inspect(params)}"
        assert has_element?(lv, "#key-generate-form")
        refute has_element?(lv, "#key-generate-form [name='key[allow_secrets]']")
      end

      assert AccessKeys.list_for_node(scope, node) == []
    end
  end

  describe "a key's public key pasted" do
    test "is no way to give a node or a pool its key: no page, no button, no event", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      %{access_key: key} = node_key_fixture(scope, node)

      # The old page's address is no page: not found.
      for target <- [node, pool] do
        assert conn |> get(tab_path(scope, target, "/add")) |> html_response(404)
      end

      # No page of the tab offers it, nor says a key may be pasted.
      for path <- [
            tab_path(scope, node),
            tab_path(scope, pool),
            tab_path(scope, node, "/generate"),
            tab_path(scope, pool, "/generate"),
            tab_path(scope, node, "/keys/#{key.key_id}/runner-file")
          ] do
        {:ok, lv, html} = live(conn, path)
        refute has_element?(lv, "#key-add-button")
        refute html =~ "Add a public key"
        refute html =~ ~r/past(e|ed)\b/i
        refute html =~ "access-key create"
      end

      # Nor does the first-run overview.
      {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
      refute html =~ "Add a public key"
    end
  end

  describe "a key's runner file" do
    test "a key connected with a command: the lines the command wrote, each marked whose",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = enrolled_key_fixture(scope, node, %{label: "current"})
      {yaml_pin, _env_pin} = pin_lines()

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      lv |> element("#key-#{key.key_id}-runner-file") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/keys/#{key.key_id}/runner-file"))

      assert has_element?(lv, "#key-runner-file-header-title", "Runner file for current")
      assert page_title(lv) =~ "Runner file for current · build-01"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "current")

      assert words(lv, "#key-runner-file-header-description") ==
               "The runner file's lines for this key. Nothing here is secret."

      assert has_element?(
               lv,
               "#key-runner-file",
               "The command wrote these lines to ~/.config/qory/runner.yaml on build-01 when it connected. They are here to check, or to write the file again:"
             )

      yaml =
        (lv |> element("#key-runner-file-yaml") |> render() |> text() |> String.trim_trailing()) <>
          "\n"

      url = "  url: #{ApiaryWeb.Endpoint.url()}"
      key_line = "  access_key_id: #{key.key_id}"
      width = Enum.max(Enum.map([url, key_line, "  apiary_public_key:"], &String.length/1)) + 2

      assert yaml ==
               """
               server:
               #{String.pad_trailing(url, width)}# Qory Apiary
               #{String.pad_trailing(key_line, width)}# this key
               #{String.pad_trailing("  apiary_public_key:", width)}# Qory Apiary's public key
               #{yaml_pin}
               """

      assert has_element?(lv, "#key-runner-file-yaml-copy", "Copy lines")

      assert words(lv, "#key-runner-file-parts") ==
               "Only the key ID is this key's. The address and the public key are Qory Apiary's, the same for every machine connected to it."

      assert words(lv, "#key-runner-file-secret") ==
               "The key's secret is on build-01, in ~/.config/qory/access-key-secret, where the command saved it. It has never been on a screen."

      refute has_element?(lv, "#key-runner-file-key")
      refute has_element?(lv, "#key-runner-file-server")
      refute render(lv) =~ "access-key create"
      refute_untrue(render(lv))

      # Done: back to the tab, the focus on the link that opened the page.
      lv |> element("#key-runner-file-done-button", "Done") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "key-#{key.key_id}-runner-file"
    end

    test "a generated key: four steps, the secret, its ID, Qory Apiary's public key and address",
         %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      %{access_key: key} = browser_key_fixture(scope, pool, %{label: "spot-runners"})
      {_yaml_pin, env_pin} = pin_lines()

      {:ok, lv, _html} = live(conn, tab_path(scope, pool, "/keys/#{key.key_id}/runner-file"))

      assert words(lv, "#key-runner-file-header-description") ==
               "What spot-runners needs, besides the secret. Nothing here is secret."

      assert words(lv, "#key-runner-file-steps-1") ==
               "1 Keep the secret in a secret store. It was shown once, when the key was generated, and belongs in QORY_ACCESS_KEY_SECRET in the secret store of the system that runs qory. If it is lost, generate a new key and revoke this one."

      assert words(lv, "#key-runner-file-steps-2") =~ "2 Set the key's ID. As a plain setting."

      assert lv |> element("#key-runner-file-key-env") |> render() |> text() |> String.trim() ==
               "QORY_ACCESS_KEY_ID=#{key.key_id}"

      assert has_element?(lv, "#key-runner-file-key-env-copy", "Copy variable")

      assert words(lv, "#key-runner-file-steps-3") =~
               "3 Set Qory Apiary's public key. As a plain setting."

      assert lv |> element("#key-runner-file-server-env") |> render() |> text() |> String.trim() ==
               env_pin

      assert words(lv, "#key-runner-file-belongs") ==
               "The same for every machine connected to this Qory Apiary."

      assert words(lv, "#key-runner-file-steps-4") =~ "4 Point qory at Qory Apiary."

      assert lv |> element("#key-runner-file-url") |> render() |> text() |> String.trim() ==
               "server:\n  url: #{ApiaryWeb.Endpoint.url()}"

      # The key's id is in its own step alone: the server's steps name no key.
      for n <- [3, 4], do: refute(words(lv, "#key-runner-file-steps-#{n}") =~ key.key_id)
      refute has_element?(lv, "#key-runner-file-yaml")
      refute render(lv) =~ "where the command saved it"
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
      assert has_element?(lv, "#key-runner-file-key-env", key.key_id)
    end
  end

  describe "a command" do
    test "Get the command makes it in one click and shows it once, in no address, flash, title or log",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      server = ApiaryWeb.Endpoint.url()
      fingerprint = SigningKey.fingerprint()

      {code, log} = ExUnit.CaptureLog.with_log(fn -> get_command(lv, scope, node) end)

      # The code as the machine sends it, the server key's fingerprint after it, inside
      # the command alone.
      assert code =~ ~r/\Aqec_[0-9A-Z]{26}\.#{Regex.escape(fingerprint)}\z/

      assert lv |> element("#code-issued-command") |> render() |> text() |> String.trim() ==
               "qory access-key enrol #{server} #{code}"

      refute has_element?(lv, "#code-issued-value")
      refute render(lv) =~ "Enrolment code"
      refute render(lv) =~ "This code is shown once."

      assert has_element?(lv, "#code-issued-header-title", "Connect build-01 with a command")
      assert page_title(lv) == "Connect build-01 with a command"
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Command")

      assert words(lv, "#code-issued-header-description") ==
               "The command connects build-01 by itself: it makes the machine's key there, saves it, and writes Qory Apiary's address and public key into the runner file. The secret never leaves the machine."

      assert words(lv, "#code-issued-run") == "On build-01, run:"
      assert has_element?(lv, "#code-issued-command-copy", "Copy command")
      # The command wraps, whole, instead of running off its box.
      assert has_element?(lv, "#code-issued-command.whitespace-pre-wrap.break-all")

      [row] = AccessKeys.list_enrolment_codes(scope, node)

      assert words(lv, "#code-issued-waiting") ==
               "Waiting for build-01 to run it. This page shows when it is connected."

      assert words(lv, "#code-issued-works") ==
               "It works once, until #{Format.time(row.expires_at)}, 15 minutes from when you got it. This is the only time it is shown."

      assert words(lv, "#code-issued-done") ==
               "Done Once you leave this page, the command is not shown again. Cancel it from the Access key tab if you won't run it."

      refute has_element?(lv, "#code-issued-done-cancel")

      # The defaults, no question asked: stored secrets not allowed, no label hint.
      assert row.code_sha256 == EnrolmentCode.hash(hd(String.split(code, ".")))
      refute row.allow_secrets
      assert is_nil(row.label_hint)

      # No address, flash, title or log line holds it, nor the page's state as inspected.
      refute tab_path(scope, node, "/new-code") =~ code
      refute lv |> element("#flash-group") |> render() =~ code
      refute page_title(lv) =~ code
      refute log =~ code
      deep = &inspect(&1, limit: :infinity, printable_limit: :infinity)
      refute deep.(:sys.get_state(lv.pid)) =~ code
      refute deep.(:sys.get_status(lv.pid)) =~ code

      # Done: back to the tab, where the command is not shown, nor ever again; it waits.
      lv |> element("#code-issued-done-button") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      refute render(lv) =~ code
      assert has_element?(lv, "#code-#{row.id}", "A command is waiting to be run on build-01.")
      assert has_element?(lv, "#code-new-button", "Get a new command")

      {:ok, lv, html} =
        live(conn, tab_path(scope, node, "/new-code"))
        |> follow_redirect(conn, tab_path(scope, node))

      refute html =~ code
      refute has_element?(lv, "#code-issued")
    end

    test "carries --replace for a node or a pool that has or had a key, and says what it does",
         %{conn: conn, scope: scope} do
      server = ApiaryWeb.Endpoint.url()

      # The command shown and copied, and the line under it, if any.
      shown = fn node ->
        {:ok, lv, _html} = live(conn, tab_path(scope, node))
        code = get_command(lv, scope, node)
        command = lv |> element("#code-issued-command") |> render() |> text() |> String.trim()
        assert has_element?(lv, ~s{#code-issued-command-copy[data-copy="#{command}"]})
        line = if has_element?(lv, "#code-issued-replace"), do: words(lv, "#code-issued-replace")
        {command, code, line}
      end

      for {kind, name} <- [{"node", "build-02"}, {"pool", "spot-runners"}] do
        node = node_fixture(scope, name: name, kind: kind)

        # Never a key: the plain command, no line; a code waiting unused changes nothing.
        for _ <- 1..2 do
          {command, code, line} = shown.(node)
          assert command == "qory access-key enrol #{server} #{code}"
          assert line == nil
        end

        %{access_key: key} = access_key_fixture(scope, node: node)
        {command, code, line} = shown.(node)
        assert command == "qory access-key enrol --replace #{server} #{code}"

        assert line ==
                 "It moves #{name} to a new key. The old key keeps working until you revoke it on the Access key tab."

        {:ok, _revoked} = AccessKeys.revoke_access_key(scope, key)
        {command, code, line} = shown.(node)
        assert command == "qory access-key enrol --replace #{server} #{code}"
        assert line == "It moves #{name} to a new key."
      end
    end

    test "a crafted Get the command asks nothing: stored secrets stay not allowed", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      render_hook(lv, "create_code", %{
        "code" => %{"allow_secrets" => "true", "label_hint" => "build-01"},
        "allow_secrets" => "true"
      })

      assert_patch(lv, tab_path(scope, node, "/new-code"))
      assert [row] = AccessKeys.list_enrolment_codes(scope, node)
      refute row.allow_secrets
      assert is_nil(row.label_hint)
    end

    test "the command shown is the one an enrolment redeems, and the page says it connected",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      code = get_command(lv, scope, node)

      request = enrol_request(code)
      assert Enrolment.issued_under?(request, SigningKey.fingerprint())
      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(request)
      assert key.node_id == node.id
      assert is_nil(key.revoked_at)
      refute key.allow_secrets

      # The page heard the key arrive.
      assert words(lv, "#code-issued-connected") ==
               "build-01 is connected. Its key arrived at #{Format.time(key.received_at)} and is active."

      assert has_element?(lv, "#code-issued-connected .bg-success-soft")
      assert words(lv, "#code-issued-key") == "#{key.label} #{key.key_id}"
      assert has_element?(lv, "#code-issued-fingerprint", AccessKey.fingerprint(key))

      assert words(lv, "#code-issued-check") ==
               "qory printed a fingerprint on build-01 when it ran the command. If it isn't this one, revoke the key on the Access key tab."

      # The command is spent: no longer shown, nor held, and Done stands alone.
      refute has_element?(lv, "#code-issued-command")
      refute has_element?(lv, "#code-issued-waiting")
      refute render(lv) =~ code
      assert is_nil(:sys.get_state(lv.pid).socket.assigns.issued.code)
      assert words(lv, "#code-issued-done") == "Done"

      lv |> element("#code-issued-done-button") |> render_click()
      assert has_element?(lv, "#key-#{key.key_id}-state", "Active")
      assert has_element?(lv, "#key-#{key.key_id}-added", "Connected with a command by")
    end

    test "a key another command brings, or another node's, leaves the page waiting", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      _code = get_command(lv, scope, node)

      enrolled_key_fixture(scope, node)
      send(lv.pid, {:key_enrolled, %{key_id: "ak_x", node_id: node.id}})
      other = node_fixture(scope)
      send(lv.pid, {:key_enrolled, %{key_id: "ak_y", node_id: other.id}})

      assert has_element?(lv, "#code-issued-waiting")
      refute has_element?(lv, "#code-issued-connected")
    end

    test "a command that expires on its page says it no longer works", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      code = get_command(lv, scope, node)
      [row] = AccessKeys.list_enrolment_codes(scope, node)
      expire_in(row, -1_000)

      send(lv.pid, :codes_expire)

      assert words(lv, "#code-issued-spent") ==
               "That command no longer works: it was run, cancelled or expired."

      refute has_element?(lv, "#code-issued-command")
      refute render(lv) =~ code
      assert words(lv, "#code-issued-done") == "Done"
    end

    test "a server address only this computer reaches is said, with PUBLIC_URL", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      _code = get_command(lv, scope, node)
      server = ApiaryWeb.Endpoint.url()

      # The test endpoint is localhost.
      assert ApiaryWeb.NodeComponents.loopback?(server)

      assert words(lv, "#code-issued-unreachable") ==
               "Machines can't reach this address. #{server} works only on the computer Qory Apiary runs on. Set PUBLIC_URL to the address machines use, and the command will carry it."
    end

    test "loopback?/1 is localhost and the loopback addresses alone" do
      for url <- ~w(http://localhost:4200 http://LOCALHOST http://app.localhost:4000
                    http://127.0.0.1:4000 http://127.8.9.1 http://[::1]:4000
                    http://[::ffff:127.0.0.1]:4000 http://localhost.) do
        assert ApiaryWeb.NodeComponents.loopback?(url), url
      end

      for url <- ~w(https://apiary.example.com http://10.0.0.5:4000 http://[::2]
                    http://localhost.example.com http://128.0.0.1 not-a-url) do
        refute ApiaryWeb.NodeComponents.loopback?(url), url
      end
    end

    test "a command waiting is shown in the command's card, and cancelled in place", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      got = Format.time(row.inserted_at)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(lv, "#way-new_code #code-#{row.id}")
      refute has_element?(lv, "#node-codes")

      assert words(lv, "#code-#{row.id}") =~
               "A command is waiting to be run on build-01. #{scope.user.email} got it at #{got}. It works once, until #{Format.time(row.expires_at)}. It was shown once: if it's lost, cancel it and get a new one."

      assert has_element?(lv, "#code-new-button", "Get a new command")

      # Cancel the command… names the command it cancels, and so does its confirmation.
      assert has_element?(
               lv,
               "#code-#{row.id}-revoke .sr-only",
               "Cancel the command from #{got}"
             )

      assert has_element?(
               lv,
               ~s{#code-#{row.id}-revoke [aria-hidden="true"]},
               "Cancel the command…"
             )

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/codes/#{row.id}/revoke"))

      assert has_element?(
               lv,
               "#code-#{row.id}-confirm-question",
               "Cancel the command from #{got}?"
             )

      assert has_element?(
               lv,
               "#code-#{row.id}-confirm-sub",
               "It stops working at once. A machine that runs it after this is refused."
             )

      assert has_element?(lv, "#code-#{row.id}-confirm-button", "Yes, cancel it")
      assert has_element?(lv, "#code-#{row.id}-confirm-cancel", "Keep it")
      refute has_element?(lv, "#code-#{row.id}-confirm-cancel", "Cancel")

      # Keep it gives the focus back to its Cancel the command….
      lv |> element("#code-#{row.id}-confirm-cancel") |> render_click()
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "code-#{row.id}-revoke"
      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      assert words(lv, "#flash-group") =~ "The command is cancelled. It no longer works."
      assert Repo.get!(EnrolmentCode, row.id).cancelled_at
      refute has_element?(lv, "#code-#{row.id}")
      assert has_element?(lv, "#code-new-button", "Get the command")
      # Its Cancel the command… is gone with it: the focus goes to Get the command.
      assert_push_event(lv, "run:focus", %{id: "code-new-button"})
    end

    test "with a key, a command waiting is shown in Add a key's command row", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert has_element?(lv, "#node-add #way-new_code #code-#{row.id}")
      assert has_element?(lv, "#node-add #code-new-button", "Get a new command")
    end

    test "a command cancelled elsewhere takes its page back to the tab, said to no longer work",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      code = get_command(lv, scope, node)
      [row] = AccessKeys.list_enrolment_codes(scope, node)

      # Another page, or another person, cancels it.
      {:ok, _} = AccessKeys.cancel_code(scope, row)

      assert_patch(lv, tab_path(scope, node))

      assert words(lv, "#flash-group") =~
               "That command no longer works: it was run, cancelled or expired."

      refute has_element?(lv, "#code-issued")
      refute has_element?(lv, "#code-#{row.id}")
      refute render(lv) =~ code
      assert has_element?(lv, "#code-new-button", "Get the command")
    end

    test "a command cancelled elsewhere leaves the tab, and closes its confirmation", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, other, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      {:ok, _} = AccessKeys.cancel_code(scope, row)
      _ = render(lv)
      refute has_element?(lv, "#code-#{row.id}")
      assert has_element?(lv, "#code-#{other.id}")

      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{other.id}/revoke"))
      {:ok, _} = AccessKeys.cancel_code(scope, other)
      assert_patch(lv, tab_path(scope, node))
      refute has_element?(lv, "#code-#{other.id}")

      assert words(lv, "#flash-group") =~
               "That command no longer works: it was run, cancelled or expired."
    end

    test "a machine running the command while its cancelling is asked closes the confirmation",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, row, code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      assert has_element?(lv, "#code-#{row.id}-confirm-button")

      {:ok, key} =
        AccessKeys.enrol(enrol_request(Enrolment.issued_code(code, SigningKey.fingerprint())))

      assert_patch(lv, tab_path(scope, node))
      refute has_element?(lv, "#code-#{row.id}")
      assert has_element?(lv, "#key-#{key.key_id}-state", "Active")

      assert words(lv, "#flash-group") =~
               "That command no longer works: it was run, cancelled or expired."

      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
    end

    test "at two keys, a command still waiting is shown and can be cancelled, with no way offered",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      # A second key, generated meanwhile: the node is at its limit.
      browser_key_fixture(scope, node)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert words(lv, "#node-add-full") ==
               "build-01 holds two keys, the most a node can. Revoke the one it no longer uses to add another."

      assert has_element?(
               lv,
               "#node-add #code-#{row.id}",
               "A command is waiting to be run on build-01."
             )

      refute has_element?(lv, "#node-ways")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-generate-button")

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      assert has_element?(lv, "#code-#{row.id}-confirm-question")
      lv |> element("#code-#{row.id}-confirm-button") |> render_click()

      assert words(lv, "#flash-group") =~ "The command is cancelled. It no longer works."
      assert Repo.get!(EnrolmentCode, row.id).cancelled_at
      refute has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#code-new-button")
    end

    test "a used command, cancelled, is said to have run", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{row.id}/revoke"))

      # Used meanwhile, before the page heard of it.
      row
      |> Ecto.Changeset.change(
        used_at: DateTime.utc_now(),
        used_by_key_id: AccessKey.generate_key_id(),
        public_key: ed25519_key_pair().public_key
      )
      |> EnrolmentCode.put_integrity()
      |> Repo.update!()

      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      assert lv |> element("#flash-group") |> render() =~ "That command was run already."
    end

    test "a command that expires while the tab is open leaves it, and its confirmation closes",
         %{conn: conn, scope: scope} do
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
               "That command no longer works: it was run, cancelled or expired."

      assert is_nil(Repo.get!(EnrolmentCode, row.id).cancelled_at)
    end

    test "a command that expired before its cancelling reached it is said to no longer work",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/codes/#{row.id}/revoke"))
      expire_in(row, -60_000)

      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      flash = lv |> element("#flash-group") |> render()
      assert flash =~ "That command no longer works: it was run, cancelled or expired."
      refute flash =~ "is cancelled"
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

    test "Get the command once the command is shown, or off the tab, makes none", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      code = get_command(lv, scope, node)
      render_hook(lv, "create_code", %{})
      assert render(lv) =~ code
      assert length(AccessKeys.list_enrolment_codes(scope, node)) == 1

      for rest <- ["/generate", "/keys/#{key.key_id}/runner-file"] do
        {:ok, lv, _html} = live(conn, tab_path(scope, node, rest))
        render_hook(lv, "create_code", %{})
      end

      assert length(AccessKeys.list_enrolment_codes(scope, node)) == 1
    end

    test "at two keys, Get the command is refused with what to do", %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      node_key_fixture(scope, node)
      node_key_fixture(scope, node)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      render_hook(lv, "create_code", %{})
      assert lv |> element("#flash-group") |> render() =~ "build-01 holds two keys already."
      assert AccessKeys.list_enrolment_codes(scope, node) == []
    end
  end

  describe "the two ways" do
    # The ids of the ways' buttons, in their order, and those shown as primary.
    defp ways(lv, within) do
      doc = lv |> element(within) |> render() |> LazyHTML.from_fragment()

      {doc |> LazyHTML.query("[id$=-button]") |> LazyHTML.attribute("id"),
       doc |> LazyHTML.query(".btn-primary") |> LazyHTML.attribute("id")}
    end

    test "a node with no active key asks how, the command first and primary", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert ways(lv, "#node-ways") ==
               {~w(code-new-button key-generate-button), ["code-new-button"]}

      assert has_element?(lv, "#way-new_code-title", "Connect with a command")

      # Two equal options: when to choose it, what happens, the same four facts in the same
      # rows, and one button at the foot. No steps, no code, no variable and nothing to copy.
      assert words(lv, "#way-new_code") ==
               "Connect with a command Choose it when you can open a terminal on build-01: a laptop, or a server of your own. You get one command to run on build-01. It carries a one-time code, not a key, which works once within 15 minutes. qory makes the key on build-01, sends Qory Apiary only its public half, and saves everything else there itself. Key made On build-01, by qory Secret Stays on build-01; it is never shown By hand Nothing Needs A terminal on build-01 Get the command"

      assert has_element?(lv, "#way-generate-title", "Generate a key in the browser")

      assert words(lv, "#way-generate") ==
               "Generate a key in the browser Choose it when build-01 runs in a CI job, or on a machine you can't open a terminal on. This browser makes the key, and Qory Apiary receives only its public half. The next page shows the secret once, with everything else the machine needs, for you to set where build-01 runs. Key made In this browser Secret Shown to you once, for the machine's or the CI's secret store By hand The key's ID, its secret, Qory Apiary's public key and address Needs This page open over HTTPS Generate a key"

      labels = fn way ->
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#way-#{way}-facts > dt")
        |> Enum.map(&LazyHTML.text/1)
      end

      assert labels.(:new_code) == ["Key made", "Secret", "By hand", "Needs"]
      assert labels.(:generate) == labels.(:new_code)

      for way <- [:new_code, :generate] do
        refute has_element?(lv, "#way-#{way} pre")
        refute has_element?(lv, "#way-#{way} code")
        refute has_element?(lv, "#way-#{way} .copy-btn")
        refute has_element?(lv, "#way-#{way} ol")
        refute render(lv |> element("#way-#{way}")) =~ "QORY_"
      end

      assert has_element?(lv, "#node-ways.items-stretch.md\\:grid-cols-2")
      assert has_element?(lv, "#way-new_code > div.mt-auto #code-new-button")
      assert has_element?(lv, "#way-generate > div.mt-auto #key-generate-button")
      refute has_element?(lv, "#node-configure")

      assert has_element?(
               lv,
               ~s{#key-generate-button[href="#{tab_path(scope, node, "/generate")}"]}
             )

      assert has_element?(lv, ~s{#code-new-button[phx-click="create_code"]})
      refute has_element?(lv, "#node-add")
    end

    test "a pool with no active key leads with generating a key", %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      {:ok, lv, _html} = live(conn, tab_path(scope, pool))

      assert has_element?(lv, "#node-connect-title", "How do you want to connect spot-runners?")

      assert words(lv, "#node-connect-intro") ==
               "spot-runners needs a key before it can start runs; its instances share one. Choose one of two ways to give it one."

      assert ways(lv, "#node-ways") ==
               {~w(key-generate-button code-new-button), ["key-generate-button"]}
    end

    test "once a key is active, Add a key offers the two as rows, plain, the kind's way first; a revoked one asks again",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      %{access_key: key} = node_key_fixture(scope, node)
      node_key_fixture(scope, pool)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      refute has_element?(lv, "#node-connect")
      assert has_element?(lv, "#node-add-title", "Add a key")

      assert words(lv, "#node-add-intro") ==
               "To move build-01 to a new key, add it the same way as the first, or the other way, then revoke the old one once the new one is in use. A node holds two keys at most."

      assert ways(lv, "#node-ways") == {~w(code-new-button key-generate-button), []}

      assert words(lv, "#way-new_code") ==
               "Connect with a command Choose it when you can open a terminal on build-01: a laptop, or a server of your own. Get the command"

      assert words(lv, "#way-generate") ==
               "Generate a key in the browser Choose it when build-01 runs in a CI job, or on a machine you can't open a terminal on. Generate a key"

      {:ok, lv, _html} = live(conn, tab_path(scope, pool))
      assert ways(lv, "#node-ways") == {~w(key-generate-button code-new-button), []}

      assert words(lv, "#node-add-intro") =~ "A node pool holds two keys at most."

      assert words(lv, "#node-keys-intro") ==
               "The instances of spot-runners sign every request with the pool's key. Qory Apiary keeps only the public half."

      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      assert has_element?(lv, "#node-connect-title", "How do you want to connect build-01?")
      refute has_element?(lv, "#node-add")
      # The revoked key is still listed, under Keys.
      assert has_element?(lv, "#key-#{key.key_id}-state", "Revoked")
    end

    test "once a key is active, Configure a machine at the foot gives four steps, to everyone, at the limit too",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope, name: "build-01")
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      %{access_key: key} = node_key_fixture(scope, node)
      %{access_key: first} = node_key_fixture(scope, pool)
      %{access_key: second} = node_key_fixture(scope, pool)
      {_yaml_pin, env_pin} = pin_lines()
      pin = String.replace_prefix(env_pin, "QORY_APIARY_PUBLIC_KEY=", "") |> String.trim()

      for {target, conn} <- [{node, conn}, {pool, conn}, {node, member_conn(scope)}] do
        {:ok, lv, _html} = live(conn, tab_path(scope, target))

        assert has_element?(lv, "#node-configure-title", "Configure a machine")

        assert words(lv, "#node-configure-lead") ==
                 "A machine connected with the command needs nothing more: qory saved all of this on it. Don't set these again there; qory refuses a key ID or a public key set twice. With a generated key, set these where the machine runs qory."

        assert words(lv, "#node-configure-steps-1") =~
                 "1 Point qory at Qory Apiary. In the runner file. It is required: without it, qory ignores the three variables below."

        assert lv |> element("#node-configure-yaml") |> render() |> text() |> String.trim() ==
                 "server:\n  url: #{ApiaryWeb.Endpoint.url()}"

        assert has_element?(lv, "#node-configure-yaml-copy", "Copy lines")

        assert words(lv, "#node-configure-steps-2") ==
                 "2 Set Qory Apiary's public key. QORY_APIARY_PUBLIC_KEY, a plain setting. The same for every machine connected to this Qory Apiary. #{pin}"

        assert lv |> element("#node-configure-pin") |> render() |> text() |> String.trim() == pin

        assert has_element?(
                 lv,
                 ~s{#node-configure-pin-copy[aria-label="Copy QORY_APIARY_PUBLIC_KEY"]}
               )

        assert words(lv, "#node-configure-steps-4") ==
                 "4 Keep the key's secret in a secret store. QORY_ACCESS_KEY_SECRET. It was shown once, when the key was generated, and is never shown here. If it is lost, generate a new key and revoke the old one."

        # The secret: text alone, never a value and never a Copy.
        refute has_element?(lv, "#node-configure-steps-4 code")
        refute has_element?(lv, "#node-configure-steps-4 .copy-btn")
        refute lv |> element("#node-configure") |> render() =~ ~r/qak_/i
        refute has_element?(lv, "#node-server")
      end

      # One active key: its ID, with Copy.
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert words(lv, "#node-configure-steps-3") ==
               "3 Set the key's ID. QORY_ACCESS_KEY_ID, a plain setting. #{key.key_id}"

      assert has_element?(lv, "#node-configure-key-id", key.key_id)

      assert has_element?(
               lv,
               ~s{#node-configure-key-id-copy[aria-label="Copy QORY_ACCESS_KEY_ID"]}
             )

      refute has_element?(lv, "#node-configure-key-id-pointer")

      # Two active keys: the pointer to the key's card, and no ID.
      {:ok, lv, _html} = live(conn, tab_path(scope, pool))

      assert words(lv, "#node-configure-steps-3") ==
               "3 Set the key's ID. QORY_ACCESS_KEY_ID, a plain setting: the ID of the key the machine uses, on its card above."

      refute has_element?(lv, "#node-configure-key-id")
      refute lv |> element("#node-configure") |> render() =~ first.key_id
      refute lv |> element("#node-configure") |> render() =~ second.key_id

      # At the foot: after Keys, and after Add a key where it shows.
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#node-keys, #node-add, #node-configure")
        |> LazyHTML.attribute("id")

      assert ids == ["node-keys", "node-add", "node-configure"]

      # A revoked key alone is no key: the ways ask again, and the part goes.
      {:ok, _} = AccessKeys.revoke_access_key(scope, key)
      {:ok, lv, _html} = live(conn, tab_path(scope, node))
      refute has_element?(lv, "#node-configure")
    end

    test "at two keys, Add a key says to revoke one first, and offers no button", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")

      for target <- [node, pool], _ <- 1..2, do: node_key_fixture(scope, target)

      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      assert words(lv, "#node-add-full") ==
               "build-01 holds two keys, the most a node can. Revoke the one it no longer uses to add another."

      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-generate-button")

      {:ok, lv, _html} = live(conn, tab_path(scope, pool))

      assert words(lv, "#node-add-full") ==
               "spot-runners holds two keys, the most a node pool can. Revoke the one it no longer uses to add another."
    end
  end

  describe "generating a key in the browser" do
    defp generated_path(scope, node, key_id),
      do: tab_path(scope, node, "/keys/#{key_id}/generated")

    # A key's page as the server renders it, the same whether the page made the key, was
    # opened again or joined again: what says the secret is shown once (the notice, the
    # secret's Copy, the note beside Done) hidden, for the hook to show while the slot
    # shows the secret; the "Not shown" line hidden inside the slot, for the hook to show
    # while it holds nothing for the key; the slot empty. Nothing of it shows without the
    # hook, and the server never says the secret is gone beside it.
    defp assert_server_render(lv, key) do
      slot = "#key-generated-secret-#{key.key_id}"

      assert has_element?(lv, "#key-generated-once[data-secret-shown].hidden")

      assert has_element?(
               lv,
               "#key-generated-secret-copy-shown[data-secret-shown].hidden #key-generated-secret-copy[data-copy-target=\"#{slot}-value\"]"
             )

      assert has_element?(
               lv,
               "#key-generated-done #key-generated-done-note[data-secret-shown].hidden",
               "Once you leave this page, the secret is not shown again."
             )

      shown =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-secret-shown]")
        |> LazyHTML.attribute("id")

      assert shown ==
               [
                 "key-generated-once",
                 "key-generated-secret-copy-shown",
                 "key-generated-done-note"
               ]

      assert has_element?(lv, ~s{#{slot}[data-secret-slot][phx-update="ignore"]})
      assert has_element?(lv, "#{slot} #{slot}-gone[data-secret-gone].hidden.text-muted")
      assert lv |> element("#{slot}-value") |> render() =~ ~r{>\s*</code>}

      assert words(lv, "#{slot}-gone") ==
               "Not shown: only the page that made the key held its secret, and this one was opened again. If you didn't copy it, revoke #{key.label} and generate another key."
    end

    # A key's page opened again: the server's render, as on the page that made it.
    defp assert_reopened(lv, key) do
      assert_server_render(lv, key)

      # The rest stays: the key's ID and Qory Apiary's values.
      assert has_element?(lv, "#key-generated-id-copy")
      assert has_element?(lv, "#key-generated-pin-copy")
      assert has_element?(lv, "#key-generated-yaml-copy")
    end

    defp push_key(lv, key) do
      render_hook(lv, "generate_key", %{"key" => key})
    end

    defp browser_key(attrs \\ %{}) do
      Map.merge(
        %{"label" => "spot-runners", "public_key" => ed25519_key_pair().encoded},
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

    test "is a form page whose form holds the key's name alone, and no submit event", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      {:ok, lv, _html} = live(conn, tab_path(scope, node))

      lv |> element("#key-generate-button") |> render_click()
      assert_patch(lv, tab_path(scope, node, "/generate"))

      assert has_element?(lv, ~s{section#key-generate[phx-hook="GenerateKey"]})
      assert has_element?(lv, "h1#key-generate-header-title", "Generate a key for build-01")

      assert words(lv, "#key-generate-header-description") ==
               "This browser makes a key for build-01. You see its secret once, to copy into your CI's secret store, or the settings of the system that runs it; Qory Apiary receives only the public half. The key's ID stays on the Access key tab."

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

      # The name alone: no stored-secrets question.
      assert names == ["_csrf_token", "key[label]"]
      refute form =~ "stored secrets"
      refute has_element?(lv, "#key-generate-form textarea")
      refute has_element?(lv, "#key-generate-form [name*=public_key]")

      # Prefilled with the node's name, labelled as the key's name.
      assert has_element?(lv, ~s{#key-generate-form input[name="key[label]"][value="build-01"]})
      assert has_element?(lv, "#key-generate-form label", "Name of the key")

      assert has_element?(
               lv,
               "#key-generate-form",
               "Shown on the Access key tab, so you can tell its keys apart."
             )

      assert has_element?(lv, ~s{#key-generate-submit[type="submit"]}, "Generate key")
      assert has_element?(lv, "#key-generate-submit .btn-busy", "Generating")

      # The notices are the server's words, hidden by the class, never by the attribute.
      assert has_element?(lv, ~s{#key-generate-notices[phx-update="ignore"]})

      for {id, words} <- [
            {"key-generate-insecure",
             "This browser makes keys only on a page served over HTTPS. Open Qory Apiary over HTTPS, or connect the machine with a command."},
            {"key-generate-unsupported",
             "This browser can't make an Ed25519 key. Use a current Chrome, Edge, Firefox or Safari, or connect the machine with a command."},
            {"key-generate-lost",
             "The connection to Qory Apiary dropped before the key was confirmed, and its secret is gone. If a new key shows on the Access key tab, revoke it, then generate another."}
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

    test "for a pool, says where its instances run; a second key's name is the next free one",
         %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      browser_key_fixture(scope, pool, %{label: "spot-runners"})
      {:ok, lv, _html} = live(conn, tab_path(scope, pool, "/generate"))

      assert words(lv, "#key-generate-header-description") ==
               "This browser makes a key for spot-runners. You see its secret once, to copy into your CI's secret store, or the settings of whatever runs the instances; Qory Apiary receives only the public half. The key's ID stays on the Access key tab."

      assert has_element?(
               lv,
               ~s{#key-generate-form input[name="key[label]"][value="spot-runners-2"]}
             )
    end

    test "Cancel leads back to the tab, the focus on Generate a key", %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))

      lv |> element("#key-generate-save a", "Cancel") |> render_click()
      assert_patch(lv, tab_path(scope, node))
      assert_push_event(lv, "run:focus", %{id: "key-generate-button"})
    end

    test "the key the browser made is added by its public half, and its page is four steps, with no flash",
         %{conn: conn, scope: scope} do
      pool = node_fixture(scope, name: "spot-runners", kind: "pool")
      {:ok, lv, _html} = live(conn, tab_path(scope, pool, "/generate"))
      key = browser_key()

      push_key(lv, key)

      assert [%AccessKey{} = added] = AccessKeys.list_for_node(scope, pool)
      assert_reply(lv, %{key_id: key_id})
      assert key_id == added.key_id
      assert_patch(lv, generated_path(scope, pool, added.key_id))

      assert added.arrived_by == :browser
      assert AccessKey.status(added) == :active
      # No question, and stored secrets not allowed.
      refute added.allow_secrets
      assert added.created_by_id == scope.user.id
      assert Base.url_encode64(added.public_key, padding: false) == key["public_key"]
      assert [entry] = add_entries(pool)
      assert entry.after["arrived_by"] == "browser"

      html = render(lv)
      # No flash: the page itself says what is next.
      refute lv |> element("#flash-group") |> render() =~ "is added"

      # The same section, now the values.
      assert has_element?(lv, ~s{section#key-generate[phx-hook="GenerateKey"]})
      refute has_element?(lv, "#key-generate-form")
      assert has_element?(lv, "h1#key-generated-header-title", "Key for spot-runners")
      assert page_title(lv) == "Key for spot-runners"

      assert words(lv, "#key-generated-header-description") ==
               "Do these where spot-runners runs. Only the secret can't be seen again."

      assert words(lv, "#key-generated-once") ==
               "The secret is shown once. Copy QORY_ACCESS_KEY_SECRET now: it was made in this browser, Qory Apiary never received it, and it can't be shown again."

      assert has_element?(lv, "#key-generated-once strong", "The secret is shown once.")

      # Four numbered steps, the secret first, since it is shown once.
      {_yaml, env_pin} = pin_lines()

      assert words(lv, "#key-generated-steps-1") =~
               "1 Store the secret. In the secret store of the system that runs spot-runners, such as your CI's. QORY_ACCESS_KEY_SECRET secret · shown once"

      assert words(lv, "#key-generated-steps-2") ==
               "2 Set the key's ID. As a plain setting. It stays on the Access key tab. QORY_ACCESS_KEY_ID plain setting #{added.key_id}"

      assert words(lv, "#key-generated-steps-3") ==
               "3 Set Qory Apiary's public key. As a plain setting. The same for every machine connected to this Qory Apiary. It stays on the Access key tab. QORY_APIARY_PUBLIC_KEY plain setting " <>
                 String.replace_prefix(env_pin, "QORY_APIARY_PUBLIC_KEY=", "")

      assert words(lv, "#key-generated-steps-4") =~
               "4 Point qory at Qory Apiary. In the runner file. It is required: without it, qory ignores the three variables."

      assert lv |> element("#key-generated-yaml") |> render() |> text() =~
               "server:\n  url: #{ApiaryWeb.Endpoint.url()}"

      assert has_element?(lv, "#key-generated-id", added.key_id)

      assert "QORY_APIARY_PUBLIC_KEY=" <>
               (lv |> element("#key-generated-pin") |> render() |> text()) ==
               env_pin

      refute has_element?(lv, "#key-generated-key")
      refute has_element?(lv, "#key-generated-server")

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

      # The page that made the key renders as one opened again: the hook, which holds the
      # secret, shows what says it is shown once.
      assert_server_render(lv, added)

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
               "#key-#{added.key_id}-added",
               "Generated in a browser by #{scope.user.email}, #{Format.datetime(added.received_at)}"
             )

      # Back to the key's page: opened again, nothing says the secret is shown, or offers
      # it to copy; the gone line is where it was.
      render_patch(lv, generated_path(scope, pool, added.key_id))
      assert_reopened(lv, added)
    end

    test "opened again, the page shows the id and the pin, and holds no secret", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope, name: "build-01")
      %{access_key: key} = browser_key_fixture(scope, node, %{label: "ci"})

      {:ok, lv, html} = live(conn, generated_path(scope, node, key.key_id))

      assert has_element?(lv, "h1#key-generated-header-title", "Key for build-01")
      assert has_element?(lv, "#key-generated-id", key.key_id)
      assert has_element?(lv, "#key-generated-pin")
      assert_reopened(lv, key)
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

      # A's page renders as any: what says the secret is shown once hidden, and the gone
      # line hidden in A's slot, for the hook to choose between.
      assert_server_render(lv, a)
    end

    test "a crafted event is refused before anything is stored", %{conn: conn, scope: scope} do
      node = node_fixture(scope)

      for key <- [
            Map.put(browser_key(), "secret", "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"),
            Map.put(browser_key(), "other", "x"),
            browser_key(%{"label" => "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}),
            browser_key(%{"label" => "ci QAK_x"}),
            # Stored secrets are no choice: the flag is refused, whatever it says.
            browser_key(%{"allow_secrets" => "true"}),
            browser_key(%{"allow_secrets" => "false"}),
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

    test "an event the page has no clause for crashes it, and its crash report holds no secret",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
      Process.flag(:trap_exit, true)
      ref = Process.monitor(lv.pid)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          catch_exit(
            render_hook(lv, "bogus", %{
              "value" => "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
            })
          )

          assert_receive {:DOWN, ^ref, :process, _pid, _reason}
        end)

      assert log =~ "FunctionClauseError"
      assert log =~ ~s{"value" => "[FILTERED]"}
      refute log =~ ~r/qak_/i
      assert AccessKeys.list_for_node(scope, node) == []
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

      for rest <- ["", "/keys/#{key.key_id}/runner-file", "/keys/#{key.key_id}/generated"] do
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

    test "the key's page is for an active key the reader made in a browser alone", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)
      %{scope: admin} = member_fixture(scope, :admin)
      %{access_key: others} = browser_key_fixture(admin, node, %{label: "others"})
      %{access_key: enrolled} = enrolled_key_fixture(scope, node, %{label: "enrolled"})

      # Another person's browser key, and one a code brought: their runner file, no flash.
      for key <- [others, enrolled] do
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
    test "with no key, reads that an owner or admin connects it, and no way; an admin is asked",
         %{scope: scope} do
      node = node_fixture(scope, name: "build-01")
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      {:ok, lv, _html} = live(member_conn(scope), tab_path(scope, node))

      assert has_element?(lv, "#node-connect-title", "Connect build-01")

      assert words(lv, "#node-keys-members") ==
               "build-01 has no key yet, so it can't start runs. An owner or admin connects it."

      refute has_element?(lv, "#node-ways")
      refute has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-generate-button")

      {:ok, lv, _html} = live(member_conn(scope, :admin), tab_path(scope, node))
      assert has_element?(lv, "#node-connect-title", "How do you want to connect build-01?")
      assert has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#node-keys-members")
    end

    test "reads the keys, with no act", %{scope: scope} do
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
      refute has_element?(lv, "#node-add")
      refute has_element?(lv, "#code-#{row.id}")
      refute has_element?(lv, "#code-new-button")
      refute has_element?(lv, "#key-generate-button")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")
      assert has_element?(lv, "#key-#{key.key_id}-runner-file")
    end

    test "is refused every act's path and event, and nothing changes", %{scope: scope} do
      node = node_fixture(scope)
      %{access_key: key} = node_key_fixture(scope, node)
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})
      conn = member_conn(scope)

      for {rest, words} <- [
            {"/generate", "Only owners and admins add a node's keys."},
            {"/new-code", "Only owners and admins connect a node."},
            {"/keys/#{key.key_id}/revoke", "Only owners and admins manage a node's keys."},
            {"/codes/#{row.id}/revoke", "Only owners and admins manage a node's keys."}
          ] do
        {:ok, _lv, html} =
          live(conn, tab_path(scope, node, rest)) |> follow_redirect(conn, tab_path(scope, node))

        assert html =~ String.replace(words, "'", "&#39;")
      end

      for {event, params} <- [
            {"create_code", %{}},
            {"generate_key",
             %{"key" => %{"label" => "x", "public_key" => ed25519_key_pair().encoded}}},
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

  test "an admin made a member since Generate a key opened is refused by the context", %{
    scope: scope
  } do
    node = node_fixture(scope)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, tab_path(scope, node, "/generate"))
    Repo.update!(Ecto.Changeset.change(membership, level: :member))

    render_hook(lv, "generate_key", %{"key" => browser_key()})
    assert render(lv) =~ "Only owners and admins add a node&#39;s keys."
    assert AccessKeys.list_for_node(scope, node) == []

    assert Repo.all(
             from e in Apiary.Audit.Entry,
               where: e.action == "access_key.add" and e.organisation_id == ^scope.organisation.id
           ) == []
  end

  test "a node of another workspace or organisation is not found", %{conn: conn, scope: scope} do
    other_workspace = node_fixture(%{scope | workspace: workspace_fixture(scope.organisation)})
    other_organisation = node_fixture(sign_up_fixture().scope)

    for node <- [other_workspace, other_organisation] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, tab_path(scope, node)) end
    end
  end
end
