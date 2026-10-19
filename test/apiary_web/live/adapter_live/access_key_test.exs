defmodule ApiaryWeb.AdapterLive.AccessKeyTest do
  # An adapter's Access key tab in Instance settings › Adapters
  # (`ApiaryWeb.AdapterLive.AccessKey`), for an instance admin: Connect it with no key
  # yet, Get the command and the command's page, which holds the code once, hears the key
  # arrive and says when the code no longer works; each key as a node's key card and each
  # waiting code as a node's waiting command, both in their adapter mode; a waiting code's
  # cancelling and a key's revocation, each confirmed in place; the limit of two keys; a
  # stale sign-in; and a path that does not exist for anyone else, Add for every entry
  # included.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias ApiaryWeb.Format

  @moduletag needs: :factory

  setup do
    admin = instance_admin_scope()

    %{
      admin: admin,
      conn: log_in_user(build_conn(), admin.user),
      adapter: adapter_fixture(%{name: "Tracker #{System.unique_integer([:positive])}"})
    }
  end

  defp tab_path(adapter, rest \\ ""), do: "/instance/adapters/#{adapter.public_id}/keys" <> rest

  # The words of an element, its spaces made one.
  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r/<(p|div|h[1-6]|li|dt|dd|span)[\s>]/, " \\0")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Get the command on the tab: the command's page, and the code the page holds.
  defp get_command(lv, adapter) do
    lv |> element("#code-new-button") |> render_click()
    assert_patch(lv, tab_path(adapter, "/new-code"))
    %{issued: %{code: code}} = :sys.get_state(lv.pid).socket.assigns
    code.()
  end

  # What the adapter's machine posts to enrol with `code`: its new key, and the proof.
  defp enrol_request(code, pair \\ ed25519_key_pair()) do
    code = Enrolment.issued_code(code, SigningKey.fingerprint())
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, pair.encoded, "tracker-01", now)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => "tracker-01",
          "public_key" => pair.encoded,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    request
  end

  describe "with no key yet" do
    test "is a tab of the adapter's page that says how to connect it",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))

      assert has_element?(lv, "h1", adapter.name)
      assert words(lv, "#adapter-meta") =~ ~r/^Added by .+ · #{adapter.public_id}$/
      assert has_element?(lv, ~s{#adapter-tabs-keys[aria-current="page"]}, "Access key")
      assert page_title(lv) =~ "Access key · #{adapter.name} · Adapters · Instance settings"

      assert words(lv, "#adapter-connect-title") == "Connect #{adapter.name}"

      assert words(lv, "#adapter-connect-intro") ==
               "The adapter connects to Qory Apiary with a key that it makes on its machine. Until it has one, organisations can't install it."

      assert words(lv, "#adapter-way-title") == "Connect with a command"

      assert words(lv, "#adapter-way-happens") ==
               "You get one command to run on the machine that runs the adapter. It carries a one-time code, not a key, which works once within 15 minutes. The adapter makes the key there and sends Qory Apiary only its public half."

      assert has_element?(lv, "#code-new-button.btn-primary", "Get the command")
      refute has_element?(lv, "#adapter-keys")
      refute has_element?(lv, "#adapter-add")
    end

    test "with a command waiting, the button gets a new one",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, _row, _code} = Adapters.create_code(admin, adapter)
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      assert has_element?(lv, "#code-new-button", "Get a new command")
    end

    test "a command waiting says who got it, until when it works, and leads to its cancelling",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, row, code} = Adapters.create_code(admin, adapter)
      {:ok, lv, html} = live(conn, tab_path(adapter))

      assert has_element?(lv, "#adapter-way #code-#{row.id}")

      assert words(lv, "#code-#{row.id} > p:first-child") == "A command is waiting to be run."

      assert words(lv, "#code-#{row.id}") =~
               "I #{admin.user.email} (you) got it at #{Format.time(row.inserted_at)}. It works once, until #{Format.time(row.expires_at)}. It was shown once: if it's lost, cancel it and get a new one."

      assert has_element?(lv, ~s{#code-#{row.id} abbr[data-tip="#{admin.user.email} (you)"]})
      refute words(lv, "#code-#{row.id}") =~ adapter.name
      refute html =~ code

      cancel = tab_path(adapter, "/codes/#{row.id}/revoke")
      assert has_element?(lv, ~s{#code-#{row.id}-revoke[href="#{cancel}"]}, "Cancel the command…")

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      assert_patch(lv, cancel)
      assert has_element?(lv, "#code-#{row.id}-confirm")
      refute has_element?(lv, "#code-#{row.id}-revoke")
    end
  end

  describe "the command's page" do
    test "holds the code got once, and the page opened again holds none",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      code = get_command(lv, adapter)

      assert [%EnrolmentCode{} = row] = Adapters.list_codes(admin, adapter)
      assert row.code_sha256 == EnrolmentCode.hash(code)
      refute row.allow_secrets

      assert has_element?(lv, "h1", "Connect #{adapter.name} with a command")
      assert page_title(lv) =~ "Connect #{adapter.name} with a command · Adapters"

      assert words(lv, ".q-settings-head-sub") ==
               "The command connects #{adapter.name} by itself: it makes the adapter's key on its machine and sends Qory Apiary only the public half. The secret never leaves the machine."

      assert words(lv, "#code-issued-waiting") ==
               "Waiting for the command to run. This page shows when the adapter is connected."

      assert has_element?(lv, "#code-issued-done-button", "Done")
      refute render(lv) =~ code
      refute page_title(lv) =~ code

      # Back on the tab the code is gone, and its page opened again has none to hold.
      lv |> element("#code-issued-done-button") |> render_click()
      assert_patch(lv, tab_path(adapter))
      assert %{issued: nil} = :sys.get_state(lv.pid).socket.assigns

      # The tab draws the command waiting to be run, and never its code.
      assert has_element?(lv, "#code-#{row.id}")
      refute render(lv) =~ code
      refute page_title(lv) =~ code

      {:ok, lv, _html} =
        live(conn, tab_path(adapter, "/new-code"))
        |> follow_redirect(conn, tab_path(adapter))

      assert %{issued: nil} = :sys.get_state(lv.pid).socket.assigns
      assert has_element?(lv, "#code-new-button", "Get a new command")
    end

    test "hears the key the code brings arrive, and says the adapter is connected",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      code = get_command(lv, adapter)

      assert {:ok, %AccessKey{} = key} = AccessKeys.enrol(enrol_request(code))
      assert key.node_id == adapter.id

      assert words(lv, "#code-issued-connected") ==
               "#{adapter.name} is connected. Its key arrived at #{Format.time(key.received_at)} and is active."

      assert words(lv, "#code-issued-key") == "#{key.label} #{key.key_id}"
      assert words(lv, "#code-issued-fingerprint") == AccessKey.fingerprint(key)

      assert words(lv, "#code-issued-check") ==
               "The command printed a fingerprint when it ran. If it isn't this one, revoke the key on the Access key tab."

      assert words(lv, "#code-issued-install") == "Once it runs, organisations can install it."
      refute has_element?(lv, "#code-issued-waiting")

      # The code is let go of, spent.
      assert %{issued: %{code: nil}} = :sys.get_state(lv.pid).socket.assigns
    end

    test "says the code no longer works once it was cancelled elsewhere",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      _code = get_command(lv, adapter)
      [row] = Adapters.list_codes(admin, adapter)

      {:ok, _row} = Adapters.cancel_code(admin, row)

      assert words(lv, "#code-issued-spent") ==
               "That command no longer works: it was run, cancelled or expired."

      refute has_element?(lv, "#code-issued-waiting")
    end

    test "a stale sign-in is sent to log in again, and no code is made",
         %{admin: admin, adapter: adapter} do
      stale = DateTime.add(DateTime.utc_now(:second), -30, :minute)
      conn = log_in_user(build_conn(), admin.user, token_authenticated_at: stale)
      {:ok, lv, _html} = live(conn, tab_path(adapter))

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               lv |> element("#code-new-button") |> render_click()

      assert Adapters.list_codes(admin, adapter) == []
    end
  end

  describe "a waiting command" do
    test "is cancelled once confirmed in place; Keep it leaves it waiting",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, row, _code} = Adapters.create_code(admin, adapter)
      {:ok, lv, _html} = live(conn, tab_path(adapter, "/codes/#{row.id}/revoke"))

      assert words(lv, "#code-#{row.id}-confirm-question") ==
               "Cancel the command from #{Format.time(row.inserted_at)}?"

      assert words(lv, "#code-#{row.id}-confirm-sub") ==
               "It stops working at once. A machine that runs it after this is refused."

      assert has_element?(lv, "#code-#{row.id}-confirm-button", "Yes, cancel it")

      lv |> element("#code-#{row.id}-confirm-cancel", "Keep it") |> render_click()
      assert_patch(lv, tab_path(adapter))
      refute has_element?(lv, "#code-#{row.id}-confirm")
      assert [_row] = Adapters.list_codes(admin, adapter)

      lv |> render_patch(tab_path(adapter, "/codes/#{row.id}/revoke"))
      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      assert_patch(lv, tab_path(adapter))
      assert words(lv, "#flash-group") =~ "The command is cancelled. It no longer works."
      assert Adapters.list_codes(admin, adapter) == []
      assert Repo.get!(EnrolmentCode, row.id).cancelled_at
    end

    test "no longer waiting, its path says so", %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, row, _code} = Adapters.create_code(admin, adapter)
      {:ok, _row} = Adapters.cancel_code(admin, row)

      {:ok, lv, html} =
        live(conn, tab_path(adapter, "/codes/#{row.id}/revoke"))
        |> follow_redirect(conn, tab_path(adapter))

      assert html =~ "That command no longer works: it was run, cancelled or expired."
      refute has_element?(lv, "#code-#{row.id}-confirm")
    end

    test "cancelled on another page, its confirmation closes",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, row, _code} = Adapters.create_code(admin, adapter)
      {:ok, lv, _html} = live(conn, tab_path(adapter, "/codes/#{row.id}/revoke"))
      assert has_element?(lv, "#code-#{row.id}-confirm")

      {:ok, _row} = Adapters.cancel_code(admin, row)
      assert_patch(lv, tab_path(adapter))
      refute has_element?(lv, "#code-#{row.id}-confirm")
    end
  end

  describe "with a key" do
    setup %{admin: admin, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(admin, adapter, %{label: "tracker-01"})
      %{key: key}
    end

    test "lists the keys and offers a new command to move to a new key",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))

      refute has_element?(lv, "#adapter-connect")
      assert words(lv, "#adapter-keys-title") == "Keys 1"

      assert words(lv, "#adapter-keys-intro") ==
               "The adapter signs every request with its key. Qory Apiary keeps only the public half."

      assert words(lv, "#adapter-add-title") == "Add a key"

      assert words(lv, "#adapter-add-intro") ==
               "To move the adapter to a new key, get a new command and run it, then revoke the old key once the new one is in use. An adapter holds two keys at most."

      assert words(lv, "#adapter-way-happens") ==
               "You get one command to run on the machine that runs the adapter. It carries a one-time code, not a key, which works once within 15 minutes."

      assert has_element?(lv, "#code-new-button", "Get the command")
      refute has_element?(lv, "#code-new-button.btn-primary")
    end

    test "draws each key as its card, with where its secret is and none of Forager's rows",
         %{conn: conn, admin: admin, adapter: adapter, key: key} do
      {:ok, lv, html} = live(conn, tab_path(adapter))
      card = "#adapter-keys-list > li#key-#{key.key_id}"

      assert has_element?(lv, card)
      assert words(lv, "#key-#{key.key_id}-label") == "tracker-01"
      assert words(lv, "#key-#{key.key_id}-state") == "Active"
      assert words(lv, "#key-#{key.key_id}-id") == key.key_id

      assert has_element?(
               lv,
               ~s{#key-#{key.key_id}-id-copy[aria-label="Copy the key ID of tracker-01"]}
             )

      assert words(lv, "#key-#{key.key_id}-added") ==
               "Connected with a command by I #{admin.user.email} (you), #{Format.datetime(key.received_at)}"

      assert words(lv, "#key-#{key.key_id}-secret") ==
               "On the machine that ran the command; never shown"

      assert words(lv, "#key-#{key.key_id}-used") == "Not yet"
      assert words(lv, "#key-#{key.key_id}-fingerprint") == AccessKey.fingerprint(key)

      refute has_element?(lv, "#key-#{key.key_id}-stored-secrets")
      refute has_element?(lv, "#key-#{key.key_id}-forager-file")
      refute html =~ "Forager"
      refute has_element?(lv, "#key-#{key.key_id}-integrity")
    end

    test "a card's Revoke… opens its confirmation under it, in place of Revoke…",
         %{conn: conn, adapter: adapter, key: key} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      revoke = tab_path(adapter, "/#{key.key_id}/revoke")

      assert has_element?(lv, ~s{#key-#{key.key_id}-revoke[href="#{revoke}"]}, "Revoke…")
      lv |> element("#key-#{key.key_id}-revoke") |> render_click()
      assert_patch(lv, revoke)

      assert has_element?(lv, "#key-#{key.key_id} + li#key-#{key.key_id}-asked")
      assert has_element?(lv, "#key-#{key.key_id}-asked #key-#{key.key_id}-confirm")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")

      lv |> element("#key-#{key.key_id}-confirm-cancel") |> render_click()
      assert_patch(lv, tab_path(adapter))
      assert has_element?(lv, "#key-#{key.key_id}-revoke")
    end

    test "draws two keys as two cards, and a revoked one says who revoked it",
         %{conn: conn, admin: admin, adapter: adapter, key: key} do
      %{access_key: second} = enrolled_key_fixture(admin, adapter, %{label: "tracker-02"})
      {:ok, revoked} = Adapters.revoke_key(admin, key)
      {:ok, lv, _html} = live(conn, tab_path(adapter))

      assert has_element?(lv, "#adapter-keys-list > li#key-#{second.key_id}")
      assert has_element?(lv, "#adapter-keys-list > li#key-#{key.key_id}")
      assert words(lv, "#key-#{second.key_id}-state") == "Active"
      assert words(lv, "#key-#{key.key_id}-state") == "Revoked"

      assert words(lv, "#key-#{key.key_id}") =~
               "Revoked by I #{admin.user.email} (you), #{Format.datetime(revoked.revoked_at)}"

      assert has_element?(
               lv,
               ~s{#key-#{key.key_id} dd abbr[data-tip="#{admin.user.email} (you)"]}
             )

      assert has_element?(lv, "#key-#{second.key_id}-revoke")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")
    end

    test "its last active key is revoked once confirmed, with what that means",
         %{conn: conn, admin: admin, adapter: adapter, key: key} do
      {:ok, lv, _html} = live(conn, tab_path(adapter, "/#{key.key_id}/revoke"))

      assert words(lv, "#key-#{key.key_id}-confirm-question") == "Revoke tracker-01?"

      assert words(lv, "#key-#{key.key_id}-confirm-sub") ==
               "It is revoked at once, and its public key can never be used again. This cannot be undone. It is the adapter's only key: until it gets a new one, nothing it sends reaches any organisation."

      assert has_element?(lv, "#key-#{key.key_id}-confirm-button", "Yes, revoke")

      lv |> element("#key-#{key.key_id}-confirm-cancel") |> render_click()
      assert_patch(lv, tab_path(adapter))
      refute has_element?(lv, "#key-#{key.key_id}-confirm")

      lv |> render_patch(tab_path(adapter, "/#{key.key_id}/revoke"))
      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_patch(lv, tab_path(adapter))
      assert words(lv, "#flash-group") =~ "tracker-01 is revoked."
      assert [%AccessKey{revoked_at: %DateTime{}}] = Adapters.list_keys(admin, adapter)

      # No key in use: the tab says how to connect it again.
      assert has_element?(lv, "#adapter-connect")
      assert words(lv, "#adapter-keys-title") == "Keys 1"
    end

    test "one of two keys is revoked without that line, and at two the way is not offered",
         %{conn: conn, admin: admin, adapter: adapter, key: key} do
      enrolled_key_fixture(admin, adapter, %{label: "tracker-02"})
      {:ok, lv, _html} = live(conn, tab_path(adapter, "/#{key.key_id}/revoke"))

      assert has_element?(lv, "#key-#{key.key_id}-confirm")
      refute has_element?(lv, "#key-#{key.key_id}-last")
      assert words(lv, "#adapter-keys-title") == "Keys 2"
      assert has_element?(lv, "#adapter-way")
      refute has_element?(lv, "#code-new-button")

      # Asked anyway, no code is made.
      render_click(lv, "create_code", %{})
      assert Adapters.list_codes(admin, adapter) == []

      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_patch(lv, tab_path(adapter))
      assert words(lv, "#flash-group") =~ "tracker-01 is revoked."

      assert [%AccessKey{label: "tracker-02", revoked_at: nil}] =
               Enum.filter(Adapters.list_keys(admin, adapter), &is_nil(&1.revoked_at))
    end

    test "a revoked key's path says so, and an unknown one leads back to the tab",
         %{conn: conn, admin: admin, adapter: adapter, key: key} do
      {:ok, _key} = Adapters.revoke_key(admin, key)

      {:ok, _lv, html} =
        live(conn, tab_path(adapter, "/#{key.key_id}/revoke"))
        |> follow_redirect(conn, tab_path(adapter))

      assert html =~ "tracker-01 is revoked."

      {:ok, lv, _html} =
        live(conn, tab_path(adapter, "/ak_none/revoke"))
        |> follow_redirect(conn, tab_path(adapter))

      refute has_element?(lv, ".q-confirm")
    end

    test "an act with no confirmation open does nothing",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(adapter))
      render_click(lv, "revoke", %{})
      render_click(lv, "revoke_code", %{})
      assert [%AccessKey{revoked_at: nil}] = Adapters.list_keys(admin, adapter)
    end
  end

  test "an adapter removed meanwhile leaves for the list",
       %{conn: conn, admin: admin, adapter: adapter} do
    {:ok, lv, _html} = live(conn, tab_path(adapter))
    {:ok, _adapter} = Adapters.delete_adapter(admin, adapter)

    assert {:error, {:live_redirect, %{to: "/instance/adapters"}}} =
             lv |> element("#code-new-button") |> render_click()
  end

  test "Add answers as a path that does not exist, for every entry", %{conn: conn} do
    for entry <- ~w(github x1) do
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, "/instance/adapters/new/#{entry}") end
    end
  end

  test "anyone but an instance admin is answered as a path that does not exist",
       %{admin: admin, adapter: adapter} do
    %{user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)
    {:ok, row, _code} = Adapters.create_code(admin, adapter)
    %{access_key: key} = enrolled_key_fixture(admin, adapter)

    for path <- [
          tab_path(adapter),
          tab_path(adapter, "/new-code"),
          tab_path(adapter, "/#{key.key_id}/revoke"),
          tab_path(adapter, "/codes/#{row.id}/revoke"),
          "/instance/adapters/new/x1"
        ] do
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
    end

    assert_raise ApiaryWeb.NotFound, fn ->
      live(log_in_user(build_conn(), admin.user), "/instance/adapters/na_none/keys")
    end
  end
end
