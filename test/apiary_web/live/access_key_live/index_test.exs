defmodule ApiaryWeb.AccessKeyLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [where: 2]
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey

  @secret ~r/secret: ([A-Za-z0-9_-]{43})/

  describe "/:org/:workspace/settings/keys" do
    setup :register_and_log_in_user

    test "starts empty", %{conn: conn, scope: scope} do
      {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")
      assert html =~ "No access keys yet"
      assert html =~ "New access key"
    end

    test "shows each key's last use, and a key never used says so", %{conn: conn, scope: scope} do
      %{access_key: used} = access_key_fixture(scope, label: "build-01")
      %{access_key: silent} = access_key_fixture(scope, label: "build-02")

      Apiary.Repo.update_all(
        where(AccessKey, id: ^used.id),
        set: [last_used_at: DateTime.add(DateTime.utc_now(), -300, :second)]
      )

      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      assert html =~ ~r/Last used.*Runner/s
      assert lv |> element("#key-#{used.id}") |> render() =~ "5 minutes ago"

      row = lv |> element("#key-#{silent.id}") |> render()
      assert row =~ "Never used; created"
      refute row =~ "minutes ago"
    end

    test "an active key says no state, and its acts are in its menu", %{conn: conn, scope: scope} do
      %{access_key: key} = access_key_fixture(scope, label: "build-03")

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      refute has_element?(lv, "#key-#{key.id}-state")
      assert has_element?(lv, "#key-#{key.id}-menu #key-#{key.id}-rotate", "Rotate")
      assert has_element?(lv, "#key-#{key.id}-menu #key-#{key.id}-revoke", "Revoke")
      refute has_element?(lv, "#key-#{key.id} .badge")
    end

    test "New access key is a page of the section, not a dialog", %{conn: conn, scope: scope} do
      keys = workspace_path(scope, "/settings/keys")
      {:ok, lv, _html} = live(conn, keys)

      lv |> element("#main a", "New access key") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      # Its title and sentence, the breadcrumb ending with the section and the page, the
      # form with its button, and Cancel back to the list.
      refute has_element?(lv, "#new-key")
      assert has_element?(lv, "#settings-tab-keys[aria-current=page]")
      assert has_element?(lv, "#settings-section-title", "New access key")
      assert render(lv) =~ "Its secret is shown once"
      assert has_element?(lv, "#breadcrumb a[href='#{keys}']", "Access keys")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New access key")
      assert page_title(lv) =~ "New access key"

      assert has_element?(
               lv,
               "#access-key-form #access-key-save button[type=submit]",
               "Create key"
             )

      assert has_element?(lv, "#access-key-save-cancel[href='#{keys}']", "Cancel")

      # The form opens without errors.
      refute render(lv) =~ "can&#39;t be blank"

      lv |> element("#access-key-save-cancel") |> render_click()
      assert_patch(lv, keys)
      refute has_element?(lv, "#access-key-form")
      assert has_element?(lv, "#settings-section-title", "Access keys")
      assert AccessKeys.list_access_keys(scope) == []
    end

    test "a refused label stays on the page, its error under the field", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      html = lv |> form("#access-key-form", access_key: %{label: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"
      assert has_element?(lv, "#access-key-form")
      refute has_element?(lv, "#key-secret")
      assert AccessKeys.list_access_keys(scope) == []
    end

    test "creates a key and reveals the secret once", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      lv |> element("#main a", "New access key") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      assert lv
             |> form("#access-key-form", access_key: %{label: ""})
             |> render_change() =~ "can&#39;t be blank"

      html =
        lv
        |> form("#access-key-form", access_key: %{label: "build-server-1"})
        |> render_submit()

      [key] = AccessKeys.list_access_keys(scope)
      assert key.label == "build-server-1"

      assert html =~ "This secret is shown once"
      assert html =~ key.key_id
      assert html =~ "apiVersion: qory.dev/v1alpha1"
      assert html =~ "url: #{ApiaryWeb.Endpoint.url()}"
      assert html =~ "access_key: #{key.key_id}"
      assert [_, secret] = Regex.run(@secret, html)

      # The page of the form is now the secret's, on the page itself: no dialog.
      refute has_element?(lv, "#reveal-key")
      refute has_element?(lv, "#access-key-form")
      assert has_element?(lv, "#settings-section-title", "Your new access key")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "New access key")
      assert page_title(lv) =~ "Your new access key"
      assert has_element?(lv, "#key-secret #copy-reveal-secret")
      assert has_element?(lv, "#key-secret #copy-reveal-key-id")

      lv |> element("#key-secret-done", "Done") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")
      refute has_element?(lv, "#key-secret")

      refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~
               secret

      html = render(lv)
      assert html =~ "build-server-1"
      assert html =~ key.key_id
      assert html =~ "Active"
      assert html =~ "Never used"
      refute html =~ secret

      # the secret never appears again, on the list nor on the page that showed it
      {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")
      refute html =~ secret

      {:ok, lv, html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      refute html =~ secret
      assert has_element?(lv, "#access-key-form")
    end

    test "a secret shown is gone once the page is left by another way", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      html =
        lv
        |> form("#access-key-form", access_key: %{label: "build-server-2"})
        |> render_submit()

      assert [_, secret] = Regex.run(@secret, html)

      # The breadcrumb's section, and opening the page again: neither shows the secret.
      render_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")
      refute render(lv) =~ secret
      assert has_element?(lv, "#access-key-form")

      {:ok, _lv, html} =
        lv
        |> element("#breadcrumb a", "Access keys")
        |> render_click()
        |> follow_redirect(conn)

      refute html =~ secret
    end

    test "rotates a key, shows the new secret, then retires the previous one", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key, secret: secret} = access_key_fixture(scope, label: "runner-a")

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      lv |> element("#key-#{key.id} a", "Rotate") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/#{key.id}/rotate"
      )

      assert render(lv) =~ "keeps working"

      # The rotation is a confirmation over the list: a small dialog.
      assert has_element?(lv, "dialog#rotate-key")

      html = lv |> element("#rotate-key button", "Rotate key") |> render_click()
      assert [_, new_secret] = Regex.run(@secret, html)
      assert new_secret != secret

      # The new secret is shown on the page, as a new key's is: no dialog.
      refute has_element?(lv, "#rotate-key")
      refute has_element?(lv, "#reveal-key")
      assert has_element?(lv, "#settings-section-title", "New secret for runner-a")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Rotate key")
      assert render(lv) =~ "The previous one keeps working until you retire it"

      lv |> element("#key-secret-done", "Done") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      html = render(lv)
      assert has_element?(lv, "#key-#{key.id}-state", "Rotated")
      assert html =~ "Retire previous secret"
      refute html =~ new_secret
      assert AccessKey.status(AccessKeys.get_access_key!(scope, key.id)) == :rotating

      lv |> element("#key-#{key.id} button", "Retire previous secret") |> render_click()
      assert has_element?(lv, "dialog#retire-secret")
      assert render(lv) =~ "Only the secret issued at the last rotation keeps working"

      html = lv |> element("#retire-secret button", "Retire previous secret") |> render_click()
      assert html =~ "is retired"
      refute has_element?(lv, "#key-#{key.id}-state")
      assert AccessKey.status(AccessKeys.get_access_key!(scope, key.id)) == :active
    end

    test "revokes a key", %{conn: conn, scope: scope} do
      %{access_key: key} = access_key_fixture(scope, label: "runner-b")

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      lv |> element("#key-#{key.id} a", "Revoke") |> render_click()

      assert_patch(
        lv,
        ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/#{key.id}/revoke"
      )

      assert has_element?(lv, "dialog#revoke-key")
      assert render(lv) =~ "stops verifying at once"

      lv |> element("#revoke-key button", "Revoke key") |> render_click()
      assert_patch(lv, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      html = render(lv)
      assert html =~ "runner-b is revoked"
      assert has_element?(lv, "#key-#{key.id}-state", "Revoked")
      refute has_element?(lv, "#key-#{key.id} a", "Rotate")
      refute has_element?(lv, "#key-#{key.id} a", "Revoke")
      assert AccessKeys.get_access_key!(scope, key.id).revoked_at

      # a revoked key cannot be rotated
      keys = workspace_path(scope, "/settings/keys")

      assert {:error, {_, %{to: ^keys}}} =
               live(
                 conn,
                 ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/#{key.id}/rotate"
               )
    end

    test "a page whose membership is gone is refused and sent to /", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "runner-c")

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/#{key.id}/revoke")

      # Removed behind the page's back: no announcement reaches it.
      Apiary.Repo.delete!(scope.membership)

      lv |> element("#revoke-key button", "Revoke key") |> render_click()
      {path, flash} = assert_redirect(lv)
      assert path == ~p"/"
      assert flash["error"] =~ "no longer a member"
      assert {:ok, _active} = AccessKeys.fetch_for_verification(key.key_id)
    end

    test "a page whose membership is gone cannot create a key", %{conn: conn, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/new")

      Apiary.Repo.delete!(scope.membership)

      lv |> form("#access-key-form", access_key: %{label: "after"}) |> render_submit()
      assert_redirect(lv, ~p"/")
      assert Apiary.Repo.all(AccessKey) == []
    end

    test "the page holds no secret of a listed key", %{conn: conn, scope: scope} do
      %{access_key: key, secret: secret} = access_key_fixture(scope, label: "runner-d")
      {:ok, _, second_secret} = AccessKeys.rotate_access_key(scope, key)

      {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")
      assert html =~ "Rotated"

      state = :sys.get_state(lv.pid)
      dump = inspect(state, limit: :infinity, printable_limit: :infinity, structs: false)
      refute dump =~ secret
      refute dump =~ second_secret
    end

    test "cannot reach a key of another workspace", %{conn: conn, scope: scope} do
      other = Apiary.OrganisationsFixtures.scope_fixture()
      %{access_key: key} = access_key_fixture(other, label: "elsewhere")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys/#{key.id}/revoke")
      end
    end
  end

  describe "a member removed from the organisation while the page is open" do
    test "is sent to / when the removal is announced", %{conn: conn} do
      owner = Apiary.OrganisationsFixtures.sign_up_fixture()

      %{user: user, membership: membership, scope: scope} =
        Apiary.OrganisationsFixtures.member_fixture(owner.scope, :member)

      {:ok, lv, _html} =
        live(log_in_user(conn, user), ~p"/#{scope.organisation}/#{scope.workspace}/settings/keys")

      {:ok, _} = Apiary.Organisations.remove_member(owner.scope, membership.id)

      assert_redirect(lv, ~p"/")
    end
  end
end
