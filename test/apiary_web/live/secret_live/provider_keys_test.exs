defmodule ApiaryWeb.SecretLive.ProviderKeysTest do
  # The keys of a model provider added for the workspace alone, on the workspace's Secrets
  # and variables: listed with the provider's name and "Model provider key", each by its
  # identity line (`Apiary.ModelKeys.Identity`), never its value id; changed and deleted
  # as the provider's keys, under `provider.write`, at the key's row id, changed with their
  # settings; no Add value and no Rename for a key, whose paths are not found; the
  # search matches the identity line; the secret's deletion refused while the provider
  # links it; never a key in the page.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys, Repo, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.{Secret, Value}

  @moduletag needs: :factory

  @key "sk-ant-workspace-page-key-0123456789"
  @second "second-key-0123456789ab"

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

  # The key `value_id` of `provider`, as the secrets endpoint reveals it, by its row id;
  # `{:error, :not_found}` once no key has that value id.
  defp reveal(provider, value_id) do
    provider = Repo.get!(Connection, provider.id)

    case Repo.one(
           from v in Apiary.Secrets.Value,
             where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id
         ) do
      nil -> {:error, :not_found}
      value -> Apiary.ModelKeysFixtures.revealed_key(provider, value.id)
    end
  end

  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp refute_key(html) do
    refute html =~ @key
    refute html =~ "second-key"
  end

  # The row id of the key `value_id` of the provider's secret `secret`.
  defp row_id!(secret, value_id),
    do: Repo.get_by!(Value, secret_id: secret.id, value_id: value_id).id

  # The Change value page of the key `value_id` of `secret`, at its row id.
  defp change_path(scope, secret, value_id),
    do: secrets_path(scope, "/#{secret.public_id}/values/#{row_id!(secret, value_id)}/change")

  # The identity line of a key of "Claude keys" whose value ends in `tail`.
  defp line(tail \\ "6789"), do: "Claude keys · …#{tail}"

  test "lists the key with its provider and its identity line, among the workspace's secrets",
       ctx do
    %{conn: conn, scope: scope, secret: secret} = ctx
    {:ok, plain} = Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "plain-value"})

    {:ok, lv, html} = live(conn, secrets_path(scope))
    refute_key(html)

    row = "#secret-#{secret.public_id}"
    assert has_element?(lv, "#{row} .q-title", secret.name)
    assert has_element?(lv, "#{row}-provider", "Claude keys")
    assert has_element?(lv, row, "Model provider key · 1 value")
    assert text(lv, "#{row}-main-value-id") == line()
    refute html =~ "••••"
    assert has_element?(lv, "#{row}-used-by", "Claude keys")
    assert has_element?(lv, "#secrets-tabs-secrets .q-tabs-n", "2")

    # Its name stays: no Edit name and note, and its path is not this secret's. A model
    # key has no Add value and no Rename, which an ordinary secret keeps.
    assert has_element?(lv, "#{row}-delete")
    refute has_element?(lv, "#{row}-edit")
    refute has_element?(lv, "#{row}-add")
    assert has_element?(lv, "#{row}-main-change")
    refute has_element?(lv, "#{row}-main-rename")

    plain_row = "#secret-#{plain.public_id}"
    assert has_element?(lv, "#{plain_row}-add")
    assert has_element?(lv, "#{plain_row}-delete")

    assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
             live(conn, secrets_path(scope, "/#{secret.public_id}/edit"))

    assert error == "That secret is no longer in this workspace."
  end

  test "labels a key's menu and its items by its identity line", ctx do
    %{conn: conn, scope: scope, secret: secret} = ctx
    row = "#secret-#{secret.public_id}"
    {:ok, lv, _html} = live(conn, secrets_path(scope))

    assert has_element?(lv, ~s{[aria-label="Actions for #{line()} of #{secret.name}"]})

    assert has_element?(
             lv,
             ~s{#{row}-main-change[aria-label="Change value #{line()} of #{secret.name}"]}
           )
  end

  test "Change value is at the key's row id, and the other addresses are not found", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    row = "#secret-#{secret.public_id}"
    {:ok, lv, _html} = live(conn, secrets_path(scope))

    lv |> element("#{row}-main-change") |> render_click()
    assert_patch(lv, change_path(scope, secret, "main"))
    assert has_element?(lv, "h1", "Change #{line()} of #{secret.name}")

    row_id = row_id!(secret, "main")
    {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @second})

    for rest <- [
          "/values/main/change",
          "/values/main/delete",
          "/values/key-1/change",
          "/values/#{Ecto.UUID.generate()}/change",
          "/values/#{Ecto.UUID.generate()}/delete",
          "/values/#{row_id}/rename",
          "/values/main/rename",
          "/add-value"
        ] do
      assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
               live(conn, secrets_path(scope, "/#{secret.public_id}#{rest}")),
             rest

      assert error =~ "no longer", rest
    end
  end

  test "changes and deletes a key as the provider's, never showing one", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    row = "#secret-#{secret.public_id}"

    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{value: "backup-0123456789cdef"})

    {:ok, lv, _html} = live(conn, secrets_path(scope))

    lv |> element("#{row}-main-change") |> render_click()
    assert_patch(lv, change_path(scope, secret, "main"))

    html =
      lv |> form("#secret-form", secret_value: %{value: "changed-#{@key}"}) |> render_submit()

    refute_key(html)
    assert_patch(lv, secrets_path(scope))
    assert render(lv) =~ "#{line()} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, "changed-#{@key}"}
    assert has_element?(lv, row, "Model provider key · 2 values")
    assert text(lv, "#{row}-key-1-value-id") == line("cdef")

    lv |> element("#{row}-key-1-delete") |> render_click()
    assert has_element?(lv, "#{row}-key-1-confirm", "Delete #{line("cdef")} of #{secret.name}?")
    html = lv |> element("#{row}-key-1-confirm button", "Yes, delete") |> render_click()
    refute_key(html)
    assert render(lv) =~ "#{line("cdef")} is deleted from #{secret.name}."
    assert reveal(provider, "key-1") == {:error, :not_found}

    # Each change is the provider's: its `provider.write` entries, no `secret.write`.
    changes =
      Repo.all(
        from e in Apiary.Audit.Entry,
          where: e.subject_id == ^provider.id,
          select: e.details["change"]
      )

    assert Enum.count(changes, &(&1 == "provider_keys_changed")) == 3
    refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "secret.write")
  end

  test "the default key stays, with why on its confirmation", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    row = "#secret-#{secret.public_id}"
    {:ok, _provider} = Connections.add_provider_key(scope, provider, %{value: @second})
    {:ok, lv, _html} = live(conn, secrets_path(scope))

    lv |> element("#{row}-main-delete") |> render_click()

    assert_patch(
      lv,
      secrets_path(scope, "/#{secret.public_id}/values/#{row_id!(secret, "main")}/delete")
    )

    assert has_element?(lv, "#{row}-main-confirm", "Delete #{line()} of #{secret.name}?")
    lv |> element("#{row}-main-confirm button", "Yes, delete") |> render_click()

    assert has_element?(
             lv,
             "#secret-refused",
             "Choose another default key for Claude keys first: #{line()} is its default key."
           )

    assert reveal(provider, "main") == {:ok, @key}
  end

  test "changes a key with its settings, Resets and Pause for, and has no Add value", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    value = Repo.get_by!(Value, secret_id: secret.id, value_id: "main")
    {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))

    assert has_element?(
             lv,
             "#secret_value_reset_day-resets-hint",
             "The weekly time when this key's allowance resets. Set it if the provider sends no reset time."
           )

    assert has_element?(
             lv,
             "#secret_value_pause_number-pause-hint",
             "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 minute."
           )

    html =
      lv
      |> form("#secret-form",
        secret_value: %{value: @second, reset_day: "1", reset_time: "", pause_number: "0"}
      )
      |> render_submit()

    refute_key(html)

    assert has_element?(
             lv,
             "#secret_value_reset_day-resets-error",
             "Set the day, the time and the time zone, or leave all three empty."
           )

    assert has_element?(
             lv,
             "#secret_value_pause_number-pause-error",
             "Enter a time from 1 minute to 7 days."
           )

    assert reveal(provider, "main") == {:ok, @key}

    lv
    |> form("#secret-form",
      secret_value: %{
        value: @second,
        reset_day: "2",
        reset_time: "10:30",
        reset_zone: "Europe/Berlin",
        pause_number: "3",
        pause_unit: "days"
      }
    )
    |> render_submit()

    assert render(lv) =~ "#{line("89ab")} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, @second}
    setting = ModelKeys.setting(value.id)
    assert {setting.reset_weekday, setting.reset_time} == {2, ~T[10:30:00]}
    assert {setting.reset_time_zone, setting.pause_seconds} == {"Europe/Berlin", 259_200}

    {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))

    assert has_element?(lv, ~s{#secret_value_reset_day option[value="2"][selected]})
    assert has_element?(lv, ~s{#secret_value_pause_number[value="3"]})
    assert has_element?(lv, ~s{#secret_value_pause_unit option[value="days"][selected]})

    lv
    |> form("#secret-form",
      secret_value: %{
        value: "third-key-0123456789",
        reset_day: "",
        reset_time: "",
        pause_number: "45",
        pause_unit: "minutes"
      }
    )
    |> render_submit()

    assert render(lv) =~ "#{line("6789")} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, "third-key-0123456789"}
    setting = ModelKeys.setting(value.id)
    assert {setting.reset_weekday, setting.pause_seconds} == {nil, 2700}

    # A key has no Add value: its settings are saved with the key's page or Change value.
    assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
             live(conn, secrets_path(scope, "/#{secret.public_id}/add-value"))

    assert error == "That secret is no longer in this workspace."
  end

  test "Change value with New value empty saves a key's settings and keeps its value", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    value = Repo.get_by!(Value, secret_id: secret.id, value_id: "main")
    key_state!(provider, "main", until: in_seconds(3_600))

    {:ok, lv, _html} =
      live(conn, change_path(scope, secret, "main"))

    lv
    |> form("#secret-form",
      secret_value: %{
        value: "",
        reset_day: "5",
        reset_time: "14:00",
        reset_zone: "Europe/Berlin",
        pause_number: "2",
        pause_unit: "hours"
      }
    )
    |> render_submit()

    assert render(lv) =~ "#{line()} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, @key}
    setting = ModelKeys.setting(value.id)
    assert {setting.reset_weekday, setting.reset_time} == {5, ~T[14:00:00]}
    assert {setting.reset_time_zone, setting.pause_seconds} == {"Europe/Berlin", 7200}

    # The value stays, and so does its cooldown.
    assert [%{status: "rejected"}] =
             ModelKeys.provider_states(provider, DateTime.utc_now())[value.id]
  end

  test "Change value with New value empty and settings that fail shows only theirs", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    path = change_path(scope, secret, "main")

    for empty <- ["", " \n\t"] do
      {:ok, lv, _html} = live(conn, path)

      html =
        lv
        |> form("#secret-form",
          secret_value: %{value: empty, reset_day: "1", reset_time: "", pause_number: "0"}
        )
        |> render_submit()

      assert has_element?(lv, "#secret_value_reset_day-resets-error")
      assert has_element?(lv, "#secret_value_pause_number-pause-error")
      refute html =~ "can&#39;t be blank"
    end

    assert reveal(provider, "main") == {:ok, @key}
  end

  test "Change value with a new value clears the key's cooldown", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    value = Repo.get_by!(Value, secret_id: secret.id, value_id: "main")
    key_state!(provider, "main", until: in_seconds(3_600))

    {:ok, lv, _html} =
      live(conn, change_path(scope, secret, "main"))

    lv
    |> form("#secret-form", secret_value: %{value: "second-key"})
    |> render_submit()

    # A value of fewer than 12 characters has no hint: the key shows by the name alone.
    assert render(lv) =~ "Claude keys of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, "second-key"}
    refute ModelKeys.provider_states(provider, DateTime.utc_now())[value.id]
  end

  test "Change value trims the spaces and newlines around a key's value", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    value = Repo.get_by!(Value, secret_id: secret.id, value_id: "main")
    key_state!(provider, "main", until: in_seconds(3_600))
    path = change_path(scope, secret, "main")

    # Only whitespace, a newline and a no-break space among it, is a New value left empty:
    # the value and its cooldown stay.
    {:ok, lv, _html} = live(conn, path)

    lv
    |> form("#secret-form", secret_value: %{value: " \n\t\u00A0\r\n"})
    |> render_submit()

    assert render(lv) =~ "#{line()} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, @key}
    assert Repo.reload!(value).value_set_at == value.value_set_at

    assert [%{status: "rejected"}] =
             ModelKeys.provider_states(provider, DateTime.utc_now())[value.id]

    # The value it has, with spaces around it, is a new value: set, its cooldown ended.
    {:ok, lv, _html} = live(conn, path)

    lv
    |> form("#secret-form", secret_value: %{value: "\u00A0#{@key} \r\n"})
    |> render_submit()

    assert reveal(provider, "main") == {:ok, @key}
    assert DateTime.compare(Repo.reload!(value).value_set_at, value.value_set_at) == :gt
    refute ModelKeys.provider_states(provider, DateTime.utc_now())[value.id]

    # The spaces inside stay.
    {:ok, lv, _html} = live(conn, path)

    html =
      lv
      |> form("#secret-form", secret_value: %{value: "\n second-key with spaces \n"})
      |> render_submit()

    refute_key(html)
    assert reveal(provider, "main") == {:ok, "second-key with spaces"}
  end

  test "Change value of another secret keeps the value as typed, its last newline too", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, plain} = Secrets.create_secret(scope, %{name: "DEPLOY_KEY", value: "plain-value"})
    pem = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"

    {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/change-value"))
    lv |> form("#secret-form", secret_value: %{value: pem}) |> render_submit()

    assert render(lv) =~ "The value of DEPLOY_KEY is saved."
    assert Secrets.reveal_for_sealing(scope.workspace, plain.public_id, nil) == {:ok, pem}
  end

  test "settings that fail show the key's errors as the save checks it, trimmed", ctx do
    %{conn: conn, scope: scope, secret: secret, provider: provider} = ctx
    longest = String.duplicate("k", Value.value_max())
    bad_settings = %{reset_day: "1", reset_time: "", pause_number: "0"}

    # Change value: the longest key with a newline after it fits.
    {:ok, lv, _html} =
      live(conn, change_path(scope, secret, "main"))

    html =
      lv
      |> form("#secret-form",
        secret_value: Map.merge(bad_settings, %{value: "#{longest}\n"})
      )
      |> render_submit()

    assert has_element?(lv, "#secret_value_reset_day-resets-error")
    refute html =~ "must be at most"
    refute html =~ longest
    assert reveal(provider, "main") == {:ok, @key}

    # And it is saved, trimmed, once the settings are right.
    lv
    |> form("#secret-form",
      secret_value: %{value: "#{longest}\n", reset_day: "", reset_time: "", pause_number: ""}
    )
    |> render_submit()

    assert render(lv) =~ "#{line("kkkk")} of #{secret.name} is saved."
    assert reveal(provider, "main") == {:ok, longest}
  end

  test "Add value of another secret keeps the value as typed, last newline too", ctx do
    %{conn: conn, scope: scope} = ctx
    pem = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"

    {:ok, plain} =
      Secrets.create_secret(scope, %{
        name: "DEPLOY_KEYS",
        values: [%{value_id: "first", value: "plain-value"}]
      })

    {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/add-value"))

    lv
    |> form("#secret-form", secret_value: %{value_id: "second", value: pem})
    |> render_submit()

    assert render(lv) =~ "second is added to DEPLOY_KEYS."
    second = Secrets.reveal_for_sealing(scope.workspace, plain.public_id, "second")
    assert second == {:ok, pem}
  end

  test "another secret's value has no settings", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, plain} = Secrets.create_secret(scope, %{name: "FORGE_TOKEN", value: "plain-value"})

    {:ok, lv, _html} =
      live(conn, secrets_path(scope, "/#{plain.public_id}/change-value"))

    assert has_element?(lv, "#secret-form")
    refute has_element?(lv, "#secret_value_reset_day")
    refute has_element?(lv, "#secret_value_pause_number")
  end

  describe "the search" do
    setup ctx do
      %{scope: scope, provider: provider} = ctx

      {:ok, _provider} =
        Connections.add_provider_key(scope, provider, %{value: "zeta-key-0123456789-9c2e"})

      {:ok, plain} =
        Secrets.create_secret(scope, %{
          name: "DEPLOY_TOKEN",
          values: [%{value_id: "prod", value: "p"}, %{value_id: "staging", value: "s"}]
        })

      %{plain: plain}
    end

    defp found?(conn, scope, secret, q) do
      {:ok, lv, _html} = live(conn, secrets_path(scope, "?q=#{URI.encode_www_form(q)}"))
      has_element?(lv, "#secret-#{secret.public_id}")
    end

    test "matches the identity line of a key, not its value id", ctx do
      %{conn: conn, scope: scope, secret: secret} = ctx

      # The value ids "main" and "key-1" are in no page.
      for q <- ["main", "key-1", "y-1"], do: refute(found?(conn, scope, secret, q), q)

      # The provider's name, the hint, a part of the hint and the line as shown.
      for q <- ["claude", "Claude keys", "6789", "…6789", "9c2e", "…9c2e", "Claude keys · …9c2e"],
          do: assert(found?(conn, scope, secret, q), q)

      refute found?(conn, scope, secret, "0123456789")
    end

    test "matches the value ids of an ordinary secret as before", ctx do
      %{conn: conn, scope: scope, plain: plain} = ctx

      for q <- ["staging", "prod", "deploy"], do: assert(found?(conn, scope, plain, q), q)
    end
  end

  describe "an ordinary secret beside a model key" do
    setup %{scope: scope} do
      {:ok, plain} =
        Secrets.create_secret(scope, %{
          name: "DEPLOY_TOKEN",
          values: [%{value_id: "prod", value: "p"}, %{value_id: "staging", value: "s"}]
        })

      %{plain: plain}
    end

    test "keeps its value ids, Add value, Rename, Change value and Delete value", ctx do
      %{conn: conn, scope: scope, plain: plain} = ctx
      row = "#secret-#{plain.public_id}"
      {:ok, lv, _html} = live(conn, secrets_path(scope))

      assert text(lv, "#{row}-prod-value-id") == "prod"
      assert has_element?(lv, "#{row}-add")

      for id <- ~w(prod staging) do
        assert has_element?(lv, "#{row}-#{id}-change")
        assert has_element?(lv, "#{row}-#{id}-rename")
        assert has_element?(lv, "#{row}-#{id}-delete")
      end

      assert has_element?(
               lv,
               ~s{#{row}-prod-rename[aria-label="Rename value prod of DEPLOY_TOKEN"]}
             )

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/add-value"))
      assert has_element?(lv, ~s{#secret-form label}, "Value ID of the new value")

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/values/prod/rename"))
      assert has_element?(lv, "h1", "Rename prod of DEPLOY_TOKEN")

      {:ok, lv, _html} = live(conn, secrets_path(scope, "/#{plain.public_id}/values/prod/change"))
      assert has_element?(lv, "h1", "Change prod of DEPLOY_TOKEN")

      {:ok, lv, _html} = live(conn, secrets_path(scope))
      lv |> element("#{row}-prod-delete") |> render_click()
      assert has_element?(lv, "#{row}-prod-confirm", "Delete prod of DEPLOY_TOKEN?")
    end
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
             live(conn, change_path(scope, secret, "main"))
  end

  test "an admin changes the key", ctx do
    %{scope: scope, secret: secret, provider: provider} = ctx
    %{user: user} = member_fixture(scope, :admin)
    conn = log_in_user(build_conn(), user)

    {:ok, lv, _html} = live(conn, change_path(scope, secret, "main"))
    lv |> form("#secret-form", secret_value: %{value: "admin-value"}) |> render_submit()
    assert reveal(provider, "main") == {:ok, "admin-value"}
  end
end
