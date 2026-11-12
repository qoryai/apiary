defmodule ApiaryWeb.ProviderKeyFieldsTest do
  # The field of a model provider's key on each page that takes one: Add key and Edit key
  # (`ApiaryWeb.ProviderLive.Key`), New model provider (`ApiaryWeb.ProviderLive.Index`)
  # and the set-up's Model step (`ApiaryWeb.WorkspaceSetupLive`). Each is a password
  # field that a password manager does not fill with a sign-in password
  # (`autocomplete="new-password"`), and each page stores the key without the whitespace
  # at its ends (`Apiary.Connections.trim_key/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-field-test-0123456789abcdef"

  setup :register_and_log_in_user

  defp providers_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"

  defp key_path(scope, provider, rest),
    do: "#{providers_path(scope)}/#{provider.public_id}/keys/#{rest}"

  defp provider!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "key-1", value: @key}]
      })

    provider
  end

  # The value of the key `value_id` of the provider, as a run's sealing reads it.
  defp key_value(provider, value_id) do
    provider = Repo.get!(Connection, provider.id)
    value = Repo.get_by!(Value, secret_id: provider.secret_id, value_id: value_id)
    Secrets.reveal_key_for_sealing(provider, value.id)
  end

  defp new_password?(lv, selector),
    do: has_element?(lv, ~s{#{selector}[type=password][autocomplete="new-password"]})

  test "each key field is a new password, not a field for the sign-in password", ctx do
    %{conn: conn, scope: scope} = ctx
    provider = provider!(scope)

    {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))
    assert new_password?(lv, "#key-form input[name='key[key]']")

    {:ok, lv, _html} = live(conn, key_path(scope, provider, "key-1/edit"))
    assert new_password?(lv, "#key-form input[name='key[key]']")

    {:ok, lv, _html} = live(conn, "#{providers_path(scope)}/new")
    assert new_password?(lv, "#new-provider-form input[name='provider[key]']")

    %{user: user, organisation: organisation} = sign_up_fixture()

    {:ok, lv, _html} =
      build_conn() |> log_in_user(user) |> live(~p"/#{organisation}/main/set-up/model")

    assert new_password?(lv, "#set-up-model-form input[name='model[key]']")
  end

  test "Add key with settings that fail checks the Key as the save does, trimmed", ctx do
    %{conn: conn, scope: scope} = ctx
    provider = provider!(scope)
    longest = String.duplicate("k", Value.value_max())
    {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

    # The longest key with a newline after it fits; only the settings' error shows.
    html =
      lv
      |> form("#key-form",
        key: %{value_id: "spare", key: "#{longest}\n", reset_day: "1", reset_time: ""}
      )
      |> render_submit()

    assert has_element?(lv, "#key_reset_day-resets-error")
    refute has_element?(lv, "#key-value-1-error")
    refute html =~ "must be at most"
    refute html =~ longest

    # A Key of only whitespace has the error of an empty Key.
    lv
    |> form("#key-form",
      key: %{value_id: "spare", key: " \n\t", reset_day: "1", reset_time: ""}
    )
    |> render_submit()

    assert has_element?(lv, "#key-value-2-error", "can't be blank")
    refute Repo.get_by(Value, secret_id: provider.secret_id, value_id: "spare")
  end

  test "New model provider stores its key trimmed, the spaces inside kept", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, lv, _html} = live(conn, "#{providers_path(scope)}/new")

    lv
    |> form("#new-provider-form",
      provider: %{provider: "anthropic", key: " \n#{@key} two\r\n "}
    )
    |> render_submit()

    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert key_value(provider, provider.default_value_id) == {:ok, @key <> " two"}
  end

  test "the set-up's Model step stores its key trimmed, the spaces inside kept" do
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()

    {:ok, lv, _html} =
      build_conn() |> log_in_user(user) |> live(~p"/#{organisation}/main/set-up/model")

    lv
    |> form("#set-up-model-form",
      model: %{provider: "anthropic", key: "\t#{@key} two \n"}
    )
    |> render_submit()

    refute render(lv) =~ @key
    assert {:ok, [provider]} = Connections.list_providers(scope)
    assert key_value(provider, provider.default_value_id) == {:ok, @key <> " two"}
  end
end
