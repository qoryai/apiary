defmodule ApiaryWeb.SecretLive.ProviderKeysTest do
  # The keys of a model provider added for the workspace alone, on the workspace's Secrets
  # and variables: listed with the provider's name and "Model provider key", masked;
  # changed, added, renamed and deleted as the provider's keys, under `provider.write`;
  # the secret's deletion refused while the provider links it; never a key in the page.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.Secret

  @moduletag needs: :factory

  @key "sk-ant-workspace-page-key-0123456789"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{provider: "anthropic", name: "Claude keys", keys: [%{value_id: "main", value: @key}]},
        :workspace
      )

    %{provider: provider, secret: Repo.get!(Secret, provider.secret_id)}
  end

  defp secrets_path(scope, rest \\ ""),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets#{rest}"

  defp reveal(provider, value_id),
    do: Secrets.reveal_for_sealing(Repo.get!(Connection, provider.id), value_id)

  defp refute_key(html) do
    refute html =~ @key
    refute html =~ "second-key"
  end

  test "lists the key with its provider, masked, among the workspace's secrets", ctx do
    %{conn: conn, scope: scope, secret: secret} = ctx
    {:ok, _plain} = Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "plain-value"})

    {:ok, lv, html} = live(conn, secrets_path(scope))
    refute_key(html)

    row = "#secret-#{secret.public_id}"
    assert has_element?(lv, "#{row} .q-title", secret.name)
    assert has_element?(lv, "#{row}-provider", "Claude keys")
    assert has_element?(lv, row, "Model provider key · 1 value")
    assert has_element?(lv, "#{row}-main-value-id", "main")
    assert has_element?(lv, "#{row}-main [aria-hidden=true]", "••••••••••••")
    assert has_element?(lv, "#{row}-used-by", "Claude keys")
    assert has_element?(lv, "#secrets-tabs-secrets .q-tabs-n", "2")

    # Its name stays: no Edit name and note, and its path is not this secret's.
    assert has_element?(lv, "#{row}-add")
    assert has_element?(lv, "#{row}-delete")
    refute has_element?(lv, "#{row}-edit")
    assert has_element?(lv, "#{row}-main-change")
    assert has_element?(lv, "#{row}-main-rename")

    assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
             live(conn, secrets_path(scope, "/#{secret.public_id}/edit"))

    assert error == "That secret is no longer in this workspace."
  end

  test "changes, adds, renames and deletes a key as the provider's, never showing one", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    row = "#secret-#{secret.public_id}"
    {:ok, lv, _html} = live(conn, secrets_path(scope))

    lv |> element("#{row}-main-change") |> render_click()
    assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/values/main/change"))

    html =
      lv |> form("#secret-form", secret_value: %{value: "changed-#{@key}"}) |> render_submit()

    refute_key(html)
    assert_patch(lv, secrets_path(scope))
    assert render(lv) =~ "main of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, "changed-#{@key}"}

    lv |> element("#{row}-add") |> render_click()
    assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/add-value"))
    refute has_element?(lv, "#secret_value_first_value_id")

    html =
      lv
      |> form("#secret-form", secret_value: %{value_id: "spare", value: "second-key"})
      |> render_submit()

    refute_key(html)
    assert render(lv) =~ "spare is added to #{secret.name}."
    assert reveal(provider, "spare") == {:ok, "second-key"}
    assert has_element?(lv, row, "Model provider key · 2 values")

    lv |> element("#{row}-spare-rename") |> render_click()
    lv |> form("#secret-form", secret_value: %{value_id: "backup"}) |> render_submit()
    assert render(lv) =~ "spare of #{secret.name} is now backup."
    assert reveal(provider, "backup") == {:ok, "second-key"}

    # The default key stays, with why on its confirmation.
    lv |> element("#{row}-main-delete") |> render_click()
    lv |> element("#{row}-main-confirm button", "Yes, delete") |> render_click()

    assert has_element?(
             lv,
             "#secret-refused",
             "Choose another default key for Claude keys first: main is its default key."
           )

    lv |> element("#{row}-backup-delete") |> render_click()
    html = lv |> element("#{row}-backup-confirm button", "Yes, delete") |> render_click()
    refute_key(html)
    assert render(lv) =~ "backup is deleted from #{secret.name}."
    assert reveal(provider, "backup") == {:error, :not_found}

    # Each change is the provider's: its `provider.write` entries, no `secret.write`.
    changes =
      Repo.all(
        from e in Apiary.Audit.Entry,
          where: e.subject_id == ^provider.id,
          select: e.details["change"]
      )

    assert Enum.count(changes, &(&1 == "provider_keys_changed")) == 4
    refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "secret.write")
  end

  test "refuses to delete the secret while the provider links it", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    row = "#secret-#{secret.public_id}"
    {:ok, lv, _html} = live(conn, secrets_path(scope))

    lv |> element("#{row}-delete") |> render_click()
    assert_patch(lv, secrets_path(scope, "/#{secret.public_id}/delete"))
    lv |> element("#{row}-confirm button", "Yes, delete") |> render_click()

    assert has_element?(
             lv,
             "#secret-refused",
             "Change or add a value instead. Model provider Claude keys uses this secret, so it cannot be deleted."
           )

    assert Repo.get(Secret, secret.id)
    assert reveal(provider, "main") == {:ok, @key}
  end

  test "a member reads the key's row, and changes nothing", ctx do
    %{scope: scope, secret: secret} = ctx
    %{user: user} = member_fixture(scope, :member)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, html} = live(conn, secrets_path(scope))
    refute_key(html)
    assert has_element?(lv, "#secret-#{secret.public_id}", "Model provider key · 1 value")
    refute has_element?(lv, "#secret-#{secret.public_id}-menu")

    assert {:error, {:live_redirect, %{flash: %{"error" => _why}}}} =
             live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))
  end

  test "an admin changes the key", ctx do
    %{scope: scope, secret: secret, provider: provider} = ctx
    %{user: user} = member_fixture(scope, :admin)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{secret.public_id}/values/main/change"))
    lv |> form("#secret-form", secret_value: %{value: "admin-value"}) |> render_submit()
    assert reveal(provider, "main") == {:ok, "admin-value"}
  end
end
