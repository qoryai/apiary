defmodule ApiaryWeb.AccessKeyLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey

  @secret ~r/secret: ([A-Za-z0-9_-]{43})/

  describe "/hive/keys" do
    setup :register_and_log_in_user

    test "starts empty", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/hive/keys")
      assert html =~ "No access keys yet"
      assert html =~ "New access key"
    end

    test "creates a key and reveals the secret once", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/keys")

      lv |> element("a", "New access key") |> render_click()
      assert_patch(lv, ~p"/hive/keys/new")

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

      lv |> element("a", "Done") |> render_click()
      assert_patch(lv, ~p"/hive/keys")

      html = render(lv)
      assert html =~ "build-server-1"
      assert html =~ key.key_id
      assert html =~ "Active"
      assert html =~ "never posted"
      refute html =~ secret

      # the secret never appears again
      {:ok, _lv, html} = live(conn, ~p"/hive/keys")
      refute html =~ secret
    end

    test "rotates a key, shows the new secret, then retires the previous one", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key, secret: secret} = access_key_fixture(scope, label: "runner-a")

      {:ok, lv, _html} = live(conn, ~p"/hive/keys")

      lv |> element("#key-#{key.id} a", "Rotate") |> render_click()
      assert_patch(lv, ~p"/hive/keys/#{key.id}/rotate")
      assert render(lv) =~ "keeps working"

      html = lv |> element("#rotate-key button", "Rotate key") |> render_click()
      assert html =~ "New secret for runner-a"
      assert [_, new_secret] = Regex.run(@secret, html)
      assert new_secret != secret

      lv |> element("a", "Done") |> render_click()
      assert_patch(lv, ~p"/hive/keys")

      html = render(lv)
      assert html =~ "Rotating"
      assert html =~ "Retire previous secret"
      refute html =~ new_secret
      assert AccessKey.status(AccessKeys.get_access_key!(scope, key.id)) == :rotating

      lv |> element("#key-#{key.id} button", "Retire previous secret") |> render_click()
      assert render(lv) =~ "Only the secret issued at the last rotation keeps working"

      html = lv |> element("#retire-secret button", "Retire previous secret") |> render_click()
      assert html =~ "is retired"
      refute html =~ "Rotating"
      assert AccessKey.status(AccessKeys.get_access_key!(scope, key.id)) == :active
    end

    test "revokes a key", %{conn: conn, scope: scope} do
      %{access_key: key} = access_key_fixture(scope, label: "runner-b")

      {:ok, lv, _html} = live(conn, ~p"/hive/keys")

      lv |> element("#key-#{key.id} a", "Revoke") |> render_click()
      assert_patch(lv, ~p"/hive/keys/#{key.id}/revoke")
      assert render(lv) =~ "stops verifying at once"

      lv |> element("#revoke-key button", "Revoke key") |> render_click()
      assert_patch(lv, ~p"/hive/keys")

      html = render(lv)
      assert html =~ "runner-b is revoked"
      assert html =~ "Revoked"
      refute has_element?(lv, "#key-#{key.id} a", "Rotate")
      refute has_element?(lv, "#key-#{key.id} a", "Revoke")
      assert AccessKeys.get_access_key!(scope, key.id).revoked_at

      # a revoked key cannot be rotated
      assert {:error, {_, %{to: "/hive/keys"}}} = live(conn, ~p"/hive/keys/#{key.id}/rotate")
    end

    test "M1: a page whose membership is gone is refused and sent to /hive", %{
      conn: conn,
      scope: scope
    } do
      %{access_key: key} = access_key_fixture(scope, label: "runner-c")
      {:ok, lv, _html} = live(conn, ~p"/hive/keys/#{key.id}/revoke")

      # Removed behind the page's back: no announcement reaches it.
      Apiary.Repo.delete!(scope.membership)

      lv |> element("#revoke-key button", "Revoke key") |> render_click()
      {path, flash} = assert_redirect(lv)
      assert path == ~p"/hive"
      assert flash["error"] =~ "no longer a member"
      assert {:ok, _active} = AccessKeys.fetch_for_verification(key.key_id)
    end

    test "M1: a page whose membership is gone cannot create a key", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/keys/new")
      Apiary.Repo.delete!(scope.membership)

      lv |> form("#access-key-form", access_key: %{label: "after"}) |> render_submit()
      assert_redirect(lv, ~p"/hive")
      assert Apiary.Repo.all(AccessKey) == []
    end

    test "H2: the page holds no secret of a listed key", %{conn: conn, scope: scope} do
      %{access_key: key, secret: secret} = access_key_fixture(scope, label: "runner-d")
      {:ok, _, second_secret} = AccessKeys.rotate_access_key(scope, key)

      {:ok, lv, html} = live(conn, ~p"/hive/keys")
      assert html =~ "Rotating"

      state = :sys.get_state(lv.pid)
      dump = inspect(state, limit: :infinity, printable_limit: :infinity, structs: false)
      refute dump =~ secret
      refute dump =~ second_secret
    end

    test "cannot reach a key of another hive", %{conn: conn} do
      other = Apiary.OrganisationsFixtures.scope_fixture()
      %{access_key: key} = access_key_fixture(other, label: "elsewhere")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/hive/keys/#{key.id}/revoke")
      end
    end
  end
end
