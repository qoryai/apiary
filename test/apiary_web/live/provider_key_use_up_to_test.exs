defmodule ApiaryWeb.ProviderKeyUseUpToTest do
  # A model key's Use up to on New model provider key, Edit key and the workspace's
  # Secrets › Add value and Change value, only for a provider with limit windows, with its
  # hint and its error; and a key's row on the list of model provider keys while a window
  # is at the key's percentage.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.ModelKeysFixtures

  alias Apiary.{Connections, ModelKeys, Repo}
  alias Apiary.ModelKeys.Setting
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-oat01-use-up-to-0123456789abcdef"
  @hint "Runs skip this key once its 5-hour or 7-day use reaches this percentage of the allowance, until that window resets, so the rest stays for your sessions outside Qory Apiary. Empty: runs use the key up to its limit."

  setup :register_and_log_in_user

  defp provider!(scope, kind, reach \\ :organisation) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        %{provider: kind, keys: [%{value: @key}]},
        reach
      )

    provider
  end

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: "#{list_path(scope)}/new"

  defp value!(provider, value_id) do
    Repo.one!(
      from v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
    )
  end

  # A Use up to percentage stored for `value`, written past the changeset, which has none
  # for a key of a provider without limit windows: as a key kept from before.
  defp stored!(value, percent) do
    Repo.insert!(%Setting{
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      use_up_to_percent: percent
    })
  end

  defp secrets_path(scope, rest),
    do: "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets#{rest}"

  # The Edit key page of the key `value_id`, at its row id.
  defp edit_path(scope, provider, value_id),
    do: "#{list_path(scope)}/#{provider.public_id}/keys/#{value!(provider, value_id).id}/edit"

  # The id of the key `value_id` in the page source: its row id.
  defp key_dom(provider, value_id), do: "key-#{value!(provider, value_id).id}"

  # The Change value page of the key `value_id` of `secret`, at its row id.
  defp change_path(scope, provider, secret, value_id),
    do: secrets_path(scope, "/#{secret.public_id}/values/#{value!(provider, value_id).id}/change")

  describe "New model provider key and Edit key" do
    test "show Use up to for a provider with limit windows, and save it", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form", provider: %{provider: "claude-subscription"})
      |> render_change()

      assert has_element?(lv, "#provider_use_up_to-use-up-to legend", "Use up to")
      assert has_element?(lv, ~s{#provider_use_up_to[type="number"][min="1"][max="99"]})
      refute has_element?(lv, ~s{#provider_use_up_to[value]:not([value=""])})
      assert has_element?(lv, "#provider_use_up_to-use-up-to-hint", @hint)

      lv
      |> form("#new-provider-form",
        provider: %{provider: "claude-subscription", key: @key, use_up_to: "90"}
      )
      |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert ModelKeys.setting(value!(provider, "key-1").id).use_up_to_percent == 90

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "key-1"))
      assert has_element?(lv, ~s{#key_use_up_to[value="90"]})

      lv |> form("#key-form", key: %{use_up_to: ""}) |> render_submit()
      assert ModelKeys.setting(value!(provider, "key-1").id).use_up_to_percent == nil
    end

    test "show the error of a percentage outside 1 to 99, and save nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "claude-subscription")

      for sent <- ["0", "100", "9.5", "abc"] do
        {:ok, lv, _html} = live(conn, edit_path(scope, provider, "key-1"))
        lv |> form("#key-form", key: %{use_up_to: sent}) |> render_submit()

        assert has_element?(
                 lv,
                 "#key_use_up_to-use-up-to-error",
                 "Enter a percentage from 1 to 99."
               ),
               sent

        assert has_element?(lv, "#key_use_up_to.input-error"), sent
        refute has_element?(lv, "#key_use_up_to-use-up-to-hint"), sent
      end

      assert ModelKeys.setting(value!(provider, "key-1").id) == nil
    end

    test "keep a stored percentage of a provider without limit windows", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "anthropic")
      value = value!(provider, "key-1")
      stored!(value, 40)

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "key-1"))

      lv
      |> form("#key-form", key: %{pause_number: "5", pause_unit: "minutes"})
      |> render_submit()

      assert %Setting{use_up_to_percent: 40, pause_seconds: 300} = ModelKeys.setting(value.id)
    end

    test "have no Use up to for a provider without limit windows", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "anthropic")

      {:ok, lv, html} = live(conn, new_path(scope))
      refute has_element?(lv, "#provider_use_up_to")
      refute html =~ "Use up to"

      {:ok, lv, html} = live(conn, edit_path(scope, provider, "key-1"))
      refute has_element?(lv, "#key_use_up_to")
      refute html =~ "Use up to"
    end
  end

  describe "a key's row" do
    test "shows a cooldown at the key's Use up to with the window and the percentage", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "claude-subscription")
      value = value!(provider, "key-1")
      {:ok, _} = put_key_setting(scope, value, %{"use_up_to_percent" => 90})
      reset = in_seconds(3600)

      ModelKeys.record(
        [
          %{
            name: "k",
            secret_value_id: value.id,
            organisation_id: value.organisation_id,
            copy_set_at: value.value_set_at,
            copy_kept: true
          }
        ],
        [
          %{
            credential: "k",
            window: "five_hour",
            status: "allowed",
            resets_at: reset,
            utilization: 93,
            cooldown_until: nil,
            source: "provider",
            observed_at: DateTime.utc_now()
          }
        ],
        DateTime.utc_now()
      )

      {:ok, lv, _html} = live(conn, list_path(scope))
      assert has_element?(lv, "##{key_dom(provider, "key-1")}-state", "In cooldown until")

      assert has_element?(
               lv,
               "##{key_dom(provider, "key-1")}-state",
               "5-hour at 90%, this key's Use up to"
             )

      # Above the window's use, the key is available, with its use.
      {:ok, _} = put_key_setting(scope, value, %{"use_up_to_percent" => 95})
      {:ok, lv, _html} = live(conn, list_path(scope))
      assert has_element?(lv, "##{key_dom(provider, "key-1")}-state", "Available")
      assert has_element?(lv, "##{key_dom(provider, "key-1")}-state", "5-hour 93%")
    end
  end

  describe "Secrets" do
    test "Change value of a provider's key shows and saves Use up to; Add value is not found",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "claude-subscription", :workspace)
      secret = Repo.get!(Secret, provider.secret_id)

      assert {:error, {:live_redirect, %{flash: %{"error" => _}}}} =
               live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

      {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @key <> "-2"})

      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "key-2"))
      assert has_element?(lv, "#secret_value_use_up_to-use-up-to-hint", @hint)

      lv
      |> form("#secret-form", secret_value: %{value: "", use_up_to: "0"})
      |> render_submit()

      assert has_element?(
               lv,
               "#secret_value_use_up_to-use-up-to-error",
               "Enter a percentage from 1 to 99."
             )

      lv |> form("#secret-form", secret_value: %{value: "", use_up_to: "85"}) |> render_submit()
      assert ModelKeys.setting(value!(provider, "key-2").id).use_up_to_percent == 85

      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "key-2"))
      assert has_element?(lv, ~s{#secret_value_use_up_to[value="85"]})
      lv |> form("#secret-form", secret_value: %{value: "", use_up_to: "70"}) |> render_submit()
      assert ModelKeys.setting(value!(provider, "key-2").id).use_up_to_percent == 70
    end

    test "Change value keeps a stored percentage of a provider without limit windows", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "anthropic", :workspace)
      secret = Repo.get!(Secret, provider.secret_id)
      value = value!(provider, "key-1")
      stored!(value, 40)

      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "key-1"))

      lv
      |> form("#secret-form",
        secret_value: %{value: "", pause_number: "2", pause_unit: "hours"}
      )
      |> render_submit()

      assert %Setting{use_up_to_percent: 40, pause_seconds: 7200} = ModelKeys.setting(value.id)
    end

    test "a provider without limit windows has no Use up to", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "anthropic", :workspace)
      secret = Repo.get!(Secret, provider.secret_id)

      {:ok, lv, _html} = live(conn, change_path(scope, provider, secret, "key-1"))
      assert has_element?(lv, "#secret_value_pause_number")
      refute has_element?(lv, "#secret_value_use_up_to")
    end
  end
end
