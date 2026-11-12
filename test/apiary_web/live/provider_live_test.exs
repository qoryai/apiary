defmodule ApiaryWeb.ProviderLiveTest do
  # Organisation settings › Model providers (`ApiaryWeb.ProviderLive.Index`,
  # `ApiaryWeb.ProviderLive.Show` and `ApiaryWeb.ProviderLive.Key`): the list, New model
  # provider with its key and, for LiteLLM, its address, a provider's page with its keys
  # and their states, never a key, Add key and Edit key with a key's settings; who sees
  # what.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, ModelKeys, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Provider, Providers}
  alias Apiary.Secrets.{Secret, Value}
  alias ApiaryWeb.ProviderLive.Index

  @moduletag needs: [:factory, :secrets]

  @key "sk-ant-page-test-0123456789abcdef"

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers/new"

  defp provider!(scope, name \\ "anthropic", settings \\ %{}) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: name,
        settings: settings,
        keys: [%{value_id: "key-1", value: @key}]
      })

    provider
  end

  # A person and the organisation they signed up, which has no workspace yet.
  defp without_workspace do
    {:ok, %{user: user, organisation: organisation}} =
      Apiary.Organisations.sign_up_user(
        %{email: Apiary.AccountsFixtures.unique_user_email(), organisation_name: "Acme"},
        nil,
        open: true,
        workspace: false
      )

    %{user: user, organisation: organisation}
  end

  defp key_path(scope, provider, rest),
    do: "#{list_path(scope)}/#{provider.public_id}/keys/#{rest}"

  # A provider of `name` with a key for each value id, added in their order, a second
  # apart.
  defp keys!(scope, name, [first | rest]) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: name,
        keys: [%{value_id: first, value: @key}]
      })

    provider =
      Enum.reduce(rest, provider, fn value_id, provider ->
        {:ok, provider} =
          Connections.add_provider_key(scope, provider, %{value_id: value_id, value: @key})

        provider
      end)

    base = ~U[2026-01-01 00:00:00.000000Z]

    for {value_id, n} <- Enum.with_index([first | rest]) do
      Repo.update_all(
        from(v in Value, where: v.secret_id == ^provider.secret_id and v.value_id == ^value_id),
        set: [inserted_at: DateTime.add(base, n)]
      )
    end

    provider
  end

  defp values(provider),
    do:
      Repo.all(from v in Value, where: v.secret_id == ^provider.secret_id)
      |> Map.new(&{&1.value_id, &1})

  # A state of the key `value`, as a run's gateway reports it.
  defp record!(value, attrs) do
    key = %{
      name: "model-1",
      secret_value_id: value.id,
      organisation_id: value.organisation_id,
      copy_set_at: value.value_set_at,
      copy_kept: true
    }

    item =
      Map.merge(
        %{
          credential: "model-1",
          status: "allowed",
          source: "provider",
          observed_at: DateTime.utc_now()
        },
        attrs
      )

    :ok = ModelKeys.record([key], [item], DateTime.utc_now())
  end

  # A time as a reader in Berlin reads it at `now`: the clock on the day of `now`, the
  # weekday and the clock on another.
  defp berlin(at, now) do
    local = DateTime.shift_zone!(at, "Europe/Berlin")
    today = now |> DateTime.shift_zone!("Europe/Berlin") |> DateTime.to_date()

    if DateTime.to_date(local) == today,
      do: Calendar.strftime(local, "%H:%M"),
      else: Calendar.strftime(local, "%a %H:%M")
  end

  defp member_conn(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp title(name), do: (Providers.fetch(name) |> elem(1)).title

  # The text of the element `selector` selects, its whitespace collapsed.
  defp text(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # New model provider's form in `html` is sent with POST, and its key's field has no value.
  defp assert_posts_without_key(html) do
    form = LazyHTML.query(html, "#new-provider-form")
    assert LazyHTML.attribute(form, "method") == ["post"]

    key = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(key, "name") == ["provider[key]"]
    assert LazyHTML.attribute(key, "value") == []
  end

  describe "the list" do
    test "lists each provider with its keys, and New model provider for an owner", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "h1", "Model providers")
      assert page_title(lv) =~ "Model providers · Organisation settings"
      assert has_element?(lv, ~s{#settings-tab-model_providers[aria-current="page"]})
      assert has_element?(lv, "#provider-#{provider.public_id}-name", title("anthropic"))
      assert has_element?(lv, "#provider-#{provider.public_id}-keys", "1")
      assert has_element?(lv, ~s{a#new-model-provider[href="#{new_path(scope)}"]})
      refute has_element?(lv, "#providers-who")
      refute render(lv) =~ @key
    end

    test "a member reads the list without New, and its form's path is not there", ctx do
      %{scope: scope} = ctx
      provider!(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "#providers")
      refute has_element?(lv, "#new-model-provider")
      assert has_element?(lv, "#providers-who", "Only owners and admins add model providers.")
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, new_path(scope)) end
    end

    test "an admin adds one", %{scope: scope} do
      {:ok, lv, _html} = live(member_conn(scope, :admin), list_path(scope))
      assert has_element?(lv, "#new-model-provider")
    end

    test "with none, says how to start", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, list_path(scope))
      assert has_element?(lv, "#providers-none", "Add a model key, so agents can run.")
    end
  end

  describe "New model provider" do
    test "adds a provider with its key, never rendering it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      refute has_element?(lv, "#new-provider-address")

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
        |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert provider.provider_kind == "anthropic"
      assert to == "#{list_path(scope)}/#{provider.public_id}"

      {:ok, show, html} = live(conn, to)
      assert has_element?(show, "h1", title("anthropic"))
      assert has_element?(show, "#provider-key-key-1", "key-1")
      refute html =~ @key
      refute html =~ String.slice(@key, -4, 4)
    end

    test "in the core, adds it for the workspace alone, its key a secret of the workspace",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))
      refute has_element?(lv, "#new-provider-form input[name='provider[everywhere]']")

      lv
      |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
      |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert provider.applies_to == "selected"
      assert Connections.workspace_ids_of(provider) == [scope.workspace.id]

      secret = Repo.get!(Secret, provider.secret_id)
      assert secret.workspace_id == scope.workspace.id

      # The key is on the workspace's Secrets and variables, with its provider.
      {:ok, secrets, html} =
        live(conn, "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets")

      assert has_element?(secrets, "#secret-#{secret.public_id}-provider", provider.name)
      refute html =~ @key
    end

    test "where the edition shows the setting: on, for every workspace; off, for this one",
         ctx do
      %{conn: conn, scope: scope} = ctx
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(
               lv,
               "#new-provider-form label",
               "Available to every workspace in #{scope.organisation.name}"
             )

      refute has_element?(
               lv,
               "#new-provider-form input[type=checkbox][name='provider[everywhere]'][checked]"
             )

      lv
      |> form("#new-provider-form",
        provider: %{provider: "anthropic", key: @key, everywhere: "true"}
      )
      |> render_submit()

      assert {:ok, [every]} = Connections.list_providers(scope)
      assert every.applies_to == "all"
      assert Repo.get!(Secret, every.secret_id).workspace_id == nil

      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form",
        provider: %{provider: "openrouter", key: @key, everywhere: "false"}
      )
      |> render_submit()

      assert {:ok, providers} = Connections.list_providers(scope)
      one = Enum.find(providers, &(&1.provider_kind == "openrouter"))
      assert one.applies_to == "selected"
      assert Connections.workspace_ids_of(one) == [scope.workspace.id]
      assert Repo.get!(Secret, one.secret_id).workspace_id == scope.workspace.id
    end

    test "with no workspace yet, says to set one up first, with no form", %{conn: conn} do
      %{user: user, organisation: organisation} = without_workspace()
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/#{organisation}/settings/model-providers/new")

      assert has_element?(
               lv,
               "#new-provider-needs-workspace",
               "Set up a workspace first, then add a model provider in its Model step."
             )

      assert has_element?(
               lv,
               ~s{#new-provider-needs-workspace a[href="/#{organisation.slug}"]},
               "Set up a workspace"
             )

      refute has_element?(lv, "#new-provider-form")
      refute html =~ "new-provider-form"
    end

    test "with no workspace yet and the setting shown, the same: no form, and nothing added",
         %{conn: conn} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      %{user: user, organisation: organisation} = without_workspace()
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/model-providers/new")

      assert has_element?(
               lv,
               "#new-provider-needs-workspace",
               "Set up a workspace first, then add a model provider in its Model step."
             )

      assert has_element?(
               lv,
               ~s{#new-provider-needs-workspace a[href="/#{organisation.slug}"]},
               "Set up a workspace"
             )

      refute has_element?(lv, "#new-provider-form")

      render_hook(lv, "create", %{
        "provider" => %{"provider" => "anthropic", "key" => @key, "everywhere" => "true"}
      })

      assert has_element?(lv, "#new-provider-needs-workspace")

      for schema <- [Apiary.Connections.Connection, Secret] do
        refute Repo.get_by(schema, organisation_id: organisation.id)
      end
    end

    test "with no workspace yet, a submit adds nothing", %{conn: conn} do
      %{user: user, organisation: organisation} = without_workspace()
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/model-providers/new")

      render_hook(lv, "create", %{"provider" => %{"provider" => "anthropic", "key" => @key}})

      assert has_element?(lv, "#new-provider-needs-workspace")

      for schema <- [Apiary.Connections.Connection, Secret] do
        refute Repo.get_by(schema, organisation_id: organisation.id)
      end
    end

    test "About model providers has what a key is for, and where to get the chosen one", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(
               lv,
               "aside#page-context > h2#page-context-h",
               ~r/\AAbout model providers\z/
             )

      assert has_element?(
               lv,
               "#page-context #new-provider-what",
               "A model provider's key lets runs in #{scope.organisation.name} call a model."
             )

      assert has_element?(
               lv,
               "#new-provider-get-key",
               "Get the key from the provider first: create an API key in the Claude Console."
             )

      assert has_element?(
               lv,
               "#new-provider-next",
               "After you save, choose the model for #{scope.workspace.name} in Workspace settings › Model."
             )

      # The help that repeated the form is gone.
      refute has_element?(lv, "#new-provider-help")
      refute render(lv) =~ "Press"

      lv
      |> form("#new-provider-form", provider: %{provider: "claude-subscription"})
      |> render_change()

      assert text(lv, "#page-context #new-provider-get-key-run") ==
               "Get the key from the provider first. In a terminal where Claude Code is installed, run:"

      assert text(lv, "#new-provider-get-key-command-text") == "claude setup-token"

      assert has_element?(
               lv,
               ~s{#new-provider-get-key-command-copy[data-copy="claude setup-token"]}
             )

      assert text(lv, "#new-provider-get-key-copy-token") ==
               "Then copy the token it prints. Anthropic's terms (opens in a new tab) allow this for personal use only."

      assert has_element?(
               lv,
               ~s{#new-provider-get-key-copy-token a[href="https://code.claude.com/docs/en/legal-and-compliance"][target="_blank"]},
               "Anthropic's terms"
             )

      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()

      assert has_element?(
               lv,
               "#new-provider-get-key",
               "First get a key that your LiteLLM proxy accepts, and the proxy's https address " <>
                 "without /v1, such as https://litellm.example.com."
             )

      assert has_element?(
               lv,
               "#new-provider-address-hint",
               "The proxy's https address without /v1."
             )
    end

    test "the Key field's hint says the key is stored encrypted and never shown again", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert text(lv, ~s{#new-provider-form [id^="new-provider-key-"][id$="-hint"]}) ==
               "Qory Apiary stores the key encrypted, and nobody can view it again."

      assert has_element?(
               lv,
               ~s{#new-provider-form input[type=password][aria-describedby$="-hint"]}
             )
    end

    test "Provider is a choice: each provider's title and its description's text", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "button#provider_provider", "Anthropic API key")
      refute has_element?(lv, "select#provider_provider")

      for {provider, index} <- Enum.with_index(Providers.list()) do
        assert has_element?(
                 lv,
                 ~s{#provider_provider-#{index}[type=radio][name="provider[provider]"][value="#{provider.name}"]}
               )

        assert has_element?(lv, "label[for=provider_provider-#{index}]", provider.title)
      end

      # A subtitle is plain text: no backticks, and the terms' address is on About model providers.
      subscription = Enum.find_index(Providers.list(), &(&1.name == "claude-subscription"))
      subtitle = lv |> element("#provider_provider-#{subscription}-s") |> render()
      assert subtitle =~ "an access token that claude setup-token creates."
      assert subtitle =~ "on behalf of other users."
      refute subtitle =~ "`"
      refute subtitle =~ "https://"

      # The form sends the radio as it sent the select.
      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()
      assert has_element?(lv, "button#provider_provider", "LiteLLM")
      assert has_element?(lv, "#new-provider-address")
    end

    test "a provider chosen is checked and shown on the button", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))
      radio = ~s{#new-provider-form input[type=radio][name="provider[provider]"]}
      [first | _rest] = providers = Providers.list()
      provider = List.last(providers)
      refute provider.name == first.name

      lv |> form("#new-provider-form", provider: %{provider: provider.name}) |> render_change()

      assert has_element?(lv, ~s{#{radio}[value="#{provider.name}"][checked]})
      refute has_element?(lv, ~s{#{radio}[checked]:not([value="#{provider.name}"])})
      assert has_element?(lv, "button#provider_provider .q-pick-t", provider.title)
    end

    test "Anthropic's terms are plain words where the description has no address" do
      provider = %Provider{
        name: "claude-subscription",
        title: "Claude subscription token",
        description: %{document: %{"description" => "Runs use your Claude subscription."}}
      }

      assert Index.terms_url(provider) == nil

      html = rendered_to_string(Index.terms(%{href: nil}))
      refute html =~ "<a"
      assert html =~ "Anthropic&#39;s terms"

      html = rendered_to_string(Index.terms(%{href: "https://terms.example.com"}))
      assert html =~ ~s(href="https://terms.example.com")
    end

    test "a refused key leaves the field empty and says why", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))

      html =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "posts its form, and the key's field has no value", %{conn: conn, scope: scope} do
      # The page before it connects: a submit there is the browser's, with the form's method.
      html = conn |> get(new_path(scope)) |> html_response(200)
      assert_posts_without_key(LazyHTML.from_document(html))

      {:ok, lv, _html} = live(conn, new_path(scope))
      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()

      html =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "http://litellm.example.com"}
        )
        |> render_submit()

      assert html =~ "https://"
      assert_posts_without_key(LazyHTML.from_fragment(html))
    end

    test "LiteLLM asks its address, and the endpoint rule checks it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv |> form("#new-provider-form", provider: %{provider: "litellm"}) |> render_change()
      assert has_element?(lv, "#new-provider-address")
      assert has_element?(lv, ~s{label[for="new-provider-address"]}, "Address")

      html =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "http://litellm.example.com"}
        )
        |> render_submit()

      assert html =~ "https://"
      refute html =~ @key
      assert {:ok, []} = Connections.list_providers(scope)

      {:error, {:live_redirect, _}} =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "litellm", key: @key, address: "https://litellm.example.com"}
        )
        |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)

      assert Connections.Connection.settings_map(provider) == %{
               "address" => "https://litellm.example.com"
             }
    end
  end

  describe "a provider's page" do
    test "a member reads its keys, never a key", %{scope: scope} do
      provider = provider!(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, html} = live(conn, "#{list_path(scope)}/#{provider.public_id}")
      assert has_element?(lv, "#provider-keys", "Keys")
      assert has_element?(lv, "#provider-key-key-1")
      refute html =~ @key
    end

    test "one of another organisation is not found", %{conn: conn, scope: scope} do
      %{scope: other} = sign_up_fixture()
      provider = provider!(other)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, "#{list_path(scope)}/#{provider.public_id}")
      end
    end
  end

  describe "a provider's keys" do
    test "are in the provider's order, each with its state, in the reader's time zone", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))
      now = DateTime.utc_now()

      provider = keys!(scope, "anthropic", ~w(zeta beta alpha gamma delta omega))
      {:ok, provider} = Connections.put_default_key(scope, provider, "alpha")
      values = values(provider)

      soon = DateTime.add(now, 60)
      in_two_days = DateTime.add(now, 2, :day)
      in_three_days = DateTime.add(now, 3, :day)

      record!(values["zeta"], %{
        window: "five_hour",
        status: "rejected",
        cooldown_until: DateTime.add(now, -3600)
      })

      record!(values["beta"], %{window: "five_hour", utilization: 89, resets_at: soon})
      record!(values["beta"], %{window: "seven_day", utilization: 40, resets_at: in_three_days})

      record!(values["alpha"], %{
        window: "seven_day",
        status: "rejected",
        cooldown_until: in_two_days
      })

      # A Pause for shows the cooldown that applied, from the answer to its end: delta's
      # 2 hours, though its setting is 10 minutes now, and omega's 1 minute.
      for {name, source, observed_at} <- [
            {"gamma", "schedule", now},
            {"delta", "pause_for", DateTime.add(in_two_days, -7200)},
            {"omega", "pause_for", DateTime.add(in_two_days, -60)}
          ] do
        record!(values[name], %{
          window: "five_hour",
          status: "rejected",
          cooldown_until: in_two_days,
          source: source,
          observed_at: observed_at
        })
      end

      {:ok, _setting} = put_key_setting(scope, values["delta"], %{"pause_seconds" => 600})

      {:ok, lv, html} = live(conn, "#{list_path(scope)}/#{provider.public_id}")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#provider-keys li")
             |> LazyHTML.attribute("id") ==
               Enum.map(~w(alpha zeta beta gamma delta omega), &"provider-key-#{&1}")

      until = "In cooldown until #{berlin(in_two_days, now)}"

      assert text(lv, "#provider-key-alpha-state") == "#{until} · from the provider's answer"
      assert text(lv, "#provider-key-zeta-state") == "Available"

      assert text(lv, "#provider-key-beta-state") ==
               "Available · 5-hour 89%, resets #{berlin(soon, now)} · 7-day 40%, resets #{berlin(in_three_days, now)}"

      assert text(lv, "#provider-key-gamma-state") == "#{until} · from this key's schedule"

      assert text(lv, "#provider-key-delta-state") ==
               "#{until} · no reset time given; paused for 2 hours"

      assert text(lv, "#provider-key-omega-state") ==
               "#{until} · no reset time given; paused for 1 minute"

      assert text(lv, "#provider-key-alpha-name") == "alpha"
      refute html =~ @key
    end

    test "an owner has Add key and Edit on each row; a member has neither", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      page = "#{list_path(scope)}/#{provider.public_id}"

      {:ok, lv, _html} = live(conn, page)
      assert has_element?(lv, ~s{a#provider-add-key[href="#{page}/keys/new"]}, "Add key")

      assert has_element?(
               lv,
               ~s{a#provider-key-spare-edit[href="#{page}/keys/spare/edit"][aria-label="Edit key spare"]},
               "Edit"
             )

      member = member_conn(scope, :member)
      {:ok, lv, _html} = live(member, page)
      assert has_element?(lv, "#provider-key-spare-state", "Available")
      refute has_element?(lv, "#provider-add-key")
      refute has_element?(lv, "#provider-key-spare-edit")

      for path <- ["#{page}/keys/new", "#{page}/keys/spare/edit"] do
        assert_raise ApiaryWeb.NotFound, fn -> live(member, path) end
      end
    end

    test "the list counts each provider's keys and those in cooldown", ctx do
      %{conn: conn, scope: scope} = ctx
      three = keys!(scope, "anthropic", ~w(main spare backup))
      one = keys!(scope, "openrouter", ~w(main))
      now = DateTime.utc_now()

      record!(values(three)["spare"], %{
        window: "five_hour",
        status: "rejected",
        cooldown_until: DateTime.add(now, 3600)
      })

      # A key with two windows in cooldown counts once.
      record!(values(three)["spare"], %{
        window: "seven_day",
        status: "rejected",
        cooldown_until: DateTime.add(now, 7200)
      })

      record!(values(three)["backup"], %{
        window: "five_hour",
        status: "rejected",
        cooldown_until: DateTime.add(now, -3600)
      })

      two = keys!(scope, "deepseek", ~w(main spare))

      for {_id, value} <- values(two) do
        record!(value, %{
          window: "requests",
          status: "rejected",
          cooldown_until: DateTime.add(now, 60)
        })
      end

      {:ok, lv, _html} = live(conn, list_path(scope))
      assert text(lv, "#provider-#{three.public_id}-keys") == "3 keys, 1 in cooldown"
      assert text(lv, "#provider-#{two.public_id}-keys") == "2 keys, 2 in cooldown"
      assert text(lv, "#provider-#{one.public_id}-keys") == "1 key"
    end

    test "name each window of the contract in words, and another by its code", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))
      provider = keys!(scope, "anthropic", ~w(main))
      value = values(provider)["main"]

      words = [
        {"five_hour", "5-hour"},
        {"seven_day", "7-day"},
        {"seven_day_opus", "7-day Opus"},
        {"seven_day_sonnet", "7-day Sonnet"},
        {"overage", "Extra usage"},
        {"requests", "Requests per minute"},
        {"tokens", "Tokens per minute"},
        {"input_tokens", "Input tokens per minute"},
        {"output_tokens", "Output tokens per minute"},
        {"spend_limit", "Spend limit"},
        {"key", "Limit"},
        {"daily_cap", "daily_cap"}
      ]

      for {{window, _word}, n} <- Enum.with_index(words, 1),
          window != "daily_cap",
          do: record!(value, %{window: window, utilization: n})

      # A report keeps no window outside the contract's list (`Apiary.ModelKeys.record/3`),
      # so a row of another window, one stored before, is written as it is.
      Repo.insert!(%Apiary.ModelKeys.State{
        secret_value_id: value.id,
        organisation_id: value.organisation_id,
        window: "daily_cap",
        status: "allowed",
        utilization: 12,
        source: "provider",
        observed_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      {:ok, lv, _html} = live(conn, "#{list_path(scope)}/#{provider.public_id}")
      segments = lv |> text("#provider-key-main-state") |> String.split(" · ")
      assert hd(segments) == "Available"

      expected =
        for {{window, word}, n} <- Enum.sort(Enum.with_index(words, 1)),
            do: {window, "#{word} #{n}%"}

      assert tl(segments) == Enum.map(expected, &elem(&1, 1))

      # A reset follows the use.
      now = DateTime.utc_now()
      soon = DateTime.add(now, 60)
      record!(value, %{window: "requests", utilization: 12, resets_at: soon})
      {:ok, lv, _html} = live(conn, "#{list_path(scope)}/#{provider.public_id}")

      assert text(lv, "#provider-key-main-state") =~
               "Requests per minute 12%, resets #{berlin(soon, now)}"
    end
  end

  describe "Add key" do
    test "adds a key with its settings, never rendering it", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))
      provider = provider!(scope)

      {:ok, lv, html} = live(conn, key_path(scope, provider, "new"))
      assert has_element?(lv, "h1", "Add key")
      assert page_title(lv) =~ "Add key · #{provider.name} · Model providers"
      assert has_element?(lv, "#key_value_id-hint", "Lowercase letters, digits, ., _ and -.")

      assert html =~
               "Qory Apiary stores the key encrypted, and nobody can view it again."

      assert has_element?(
               lv,
               "#key_reset_day-resets-hint",
               "The weekly time when this key's allowance resets. Set it if the provider sends no reset time."
             )

      assert has_element?(
               lv,
               "#key_pause_number-pause-hint",
               "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 minute."
             )

      assert has_element?(lv, ~s{#key_reset_zone option[value="Europe/Berlin"][selected]})
      assert has_element?(lv, ~s{#key_pause_unit option[value="minutes"][selected]})
      assert has_element?(lv, ~s{#key_reset_day option[value="1"]}, "Monday")
      refute has_element?(lv, "#key-get-key")
      assert has_element?(lv, "#key-submit", "Add key")

      result =
        lv
        |> form("#key-form",
          key: %{
            value_id: "spare",
            key: @key <> "-2",
            reset_day: "1",
            reset_time: "09:00",
            reset_zone: "Europe/Berlin",
            pause_number: "2",
            pause_unit: "hours"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == "#{list_path(scope)}/#{provider.public_id}"
      {:ok, show, html} = follow_redirect(result, conn)
      assert html =~ "spare is added."
      assert has_element?(show, "#provider-key-spare-state", "Available")
      refute html =~ @key

      value = values(provider)["spare"]
      setting = ModelKeys.setting(value.id)
      assert {setting.reset_weekday, setting.reset_time} == {1, ~T[09:00:00]}
      assert {setting.reset_time_zone, setting.pause_seconds} == {"Europe/Berlin", 7200}

      assert Apiary.Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, @key <> "-2"}
    end

    test "for a subscription, says where to get the key and the terms, and pauses for an hour",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope, "claude-subscription")

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      assert has_element?(
               lv,
               "#key_pause_number-pause-hint",
               "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 hour."
             )

      assert has_element?(lv, ~s{#key_pause_unit option[value="hours"][selected]})
      assert has_element?(lv, "#key-get-key-command", "claude setup-token")

      assert text(lv, "#key-get-key-copy-token") ==
               "Then copy the token it prints. Anthropic's terms (opens in a new tab) allow this for personal use only."
    end

    test "says what is wrong under each field, and adds nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      html =
        lv
        |> form("#key-form",
          key: %{value_id: "Bad Name", key: @key, reset_day: "1", pause_number: "0"}
        )
        |> render_submit()

      refute html =~ @key
      assert has_element?(lv, "#key_value_id-error")
      assert has_element?(lv, ~s{#key-form input[type=password]:not([value])})

      assert has_element?(
               lv,
               "#key_reset_day-resets-error",
               "Set the day, the time and the time zone, or leave all three empty."
             )

      assert has_element?(
               lv,
               "#key_pause_number-pause-error",
               "Enter a time from 1 minute to 7 days."
             )

      refute has_element?(lv, "#key_pause_number-pause-hint")

      lv
      |> form("#key-form",
        key: %{value_id: "key-1", key: @key, reset_day: "", pause_number: "8", pause_unit: "days"}
      )
      |> render_submit()

      assert has_element?(
               lv,
               "#key_pause_number-pause-error",
               "Enter a time from 1 minute to 7 days."
             )

      lv
      |> form("#key-form", key: %{value_id: "key-1", key: @key, pause_number: ""})
      |> render_submit()

      assert has_element?(
               lv,
               "#key_value_id-error",
               "Another key of #{provider.name} has this name."
             )

      assert Map.keys(values(provider)) == ["key-1"]
    end

    test "at the most keys a provider has, says so under Key", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", for(n <- 1..32, do: "key-#{n}"))
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))

      lv |> form("#key-form", key: %{value_id: "one-more", key: @key}) |> render_submit()

      assert has_element?(
               lv,
               ~s{#key-form [id$="-error"]},
               "#{provider.name} has 32 keys, the most it can have. Delete a key to add another."
             )

      assert map_size(values(provider)) == 32
    end

    test "a person who can no longer write keys adds nothing", ctx do
      %{scope: scope} = ctx
      provider = provider!(scope)
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "new"))
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

      lv |> form("#key-form", key: %{value_id: "spare", key: @key}) |> render_submit()

      assert has_element?(lv, "#key-refusal")
      assert Map.keys(values(provider)) == ["key-1"]
    end

    test "a provider or a key of another organisation is not found", ctx do
      %{conn: conn, scope: scope} = ctx
      %{scope: other} = sign_up_fixture()
      theirs = keys!(other, "anthropic", ~w(key-1 theirs))
      ours = provider!(scope)

      for path <- [
            key_path(scope, theirs, "new"),
            key_path(scope, theirs, "theirs/edit"),
            key_path(scope, ours, "theirs/edit")
          ] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
      end
    end
  end

  describe "Edit key" do
    test "shows the key's settings, and renames it, its settings and state kept", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      value = values(provider)["spare"]
      now = DateTime.utc_now()

      {:ok, _setting} =
        put_key_setting(scope, value, %{
          "reset_weekday" => 5,
          "reset_time" => "14:00",
          "reset_time_zone" => "Europe/Berlin",
          "pause_seconds" => 7200
        })

      record!(value, %{window: "five_hour", utilization: 30, resets_at: DateTime.add(now, 3600)})

      {:ok, lv, html} = live(conn, key_path(scope, provider, "spare/edit"))
      assert has_element?(lv, "h1", "Edit key")
      assert has_element?(lv, ~s{#key_value_id[value="spare"]})
      assert has_element?(lv, ~s{#key-form label[for="key-value-0"]}, "New value")
      assert has_element?(lv, ~s{#key-form input#key-value-0[type=password]:not([value])})
      refute has_element?(lv, ~s{#key-value-0[required]})
      assert has_element?(lv, "#key-value-0-hint", "Leave it empty to keep the value.")
      assert has_element?(lv, ~s{#key_reset_day option[value="5"][selected]})
      assert has_element?(lv, ~s{#key_reset_time[value="14:00"]})
      assert has_element?(lv, ~s{#key_reset_zone option[value="Europe/Berlin"][selected]})
      assert has_element?(lv, ~s{#key_pause_number[value="2"]})
      assert has_element?(lv, ~s{#key_pause_unit option[value="hours"][selected]})
      assert has_element?(lv, "#key-submit", "Save")
      refute html =~ @key

      result =
        lv
        |> form("#key-form",
          key: %{
            value_id: "backup",
            reset_day: "",
            reset_time: "",
            pause_number: "30",
            pause_unit: "minutes"
          }
        )
        |> render_submit()

      {:ok, show, html} = follow_redirect(result, conn)
      assert html =~ "backup is saved."
      assert text(show, "#provider-key-backup-state") =~ "Available · 5-hour 30%"
      assert values(provider)["backup"].id == value.id
      setting = ModelKeys.setting(value.id)
      assert {setting.reset_weekday, setting.pause_seconds} == {nil, 1800}
    end

    test "a New value replaces the key's value and ends its cooldown, never rendering it",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      value = values(provider)["spare"]
      new_value = "sk-ant-rotated-0123456789abcdef"
      key_state!(provider, "spare", until: in_seconds(3_600))

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))

      # A New value of spaces keeps the value and the cooldown; the settings still save.
      result =
        lv
        |> form("#key-form", key: %{value_id: "spare", key: "   ", pause_number: "5"})
        |> render_submit()

      {:ok, show, html} = follow_redirect(result, conn)
      assert html =~ "spare is saved."
      assert text(show, "#provider-key-spare-state") =~ "In cooldown until"
      assert ModelKeys.setting(value.id).pause_seconds == 300
      assert values(provider)["spare"].value_set_at == value.value_set_at

      assert Apiary.Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, @key}

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))

      result =
        lv
        |> form("#key-form", key: %{value_id: "spare", key: new_value, pause_number: "5"})
        |> render_submit()

      {:ok, show, html} = follow_redirect(result, conn)
      assert html =~ "spare is saved."
      refute html =~ new_value
      refute html =~ String.slice(new_value, -4, 4)
      assert text(show, "#provider-key-spare-state") == "Available"

      saved = values(provider)["spare"]
      assert DateTime.compare(saved.value_set_at, value.value_set_at) == :gt

      assert Apiary.Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, new_value}

      assert Apiary.Secrets.reveal_key_for_sealing(
               Repo.get!(Connection, provider.id),
               values(provider)["main"].id
             ) == {:ok, @key}
    end

    test "a New value that fails its checks says so under it, and changes nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      value = values(provider)["spare"]
      bad = "sk-ant-rotated-0123456789abcdef" <> <<0>>
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))

      html =
        lv
        |> form("#key-form", key: %{value_id: "renamed", key: bad, pause_number: "5"})
        |> render_submit()

      assert has_element?(lv, "#key-value-1-error", "must not contain a NUL byte")
      assert has_element?(lv, ~s{#key-form input#key-value-1[type=password]:not([value])})
      refute html =~ "sk-ant-rotated"
      state = inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
      refute state =~ "sk-ant-rotated"

      # With settings that cannot be saved, the errors of every field show at once.
      html =
        lv
        |> form("#key-form", key: %{value_id: "Bad Name", key: bad, reset_time: "09:00"})
        |> render_submit()

      assert has_element?(lv, "#key-value-2-error", "must not contain a NUL byte")
      assert has_element?(lv, "#key_value_id-error")
      assert has_element?(lv, "#key_reset_day-resets-error")
      refute html =~ "sk-ant-rotated"

      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      assert values(provider)["spare"].value_set_at == value.value_set_at
      refute ModelKeys.setting(value.id)

      assert Apiary.Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, @key}
    end

    test "says what is wrong under each field, and changes nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))

      lv
      |> form("#key-form", key: %{value_id: "spare", reset_time: "09:00"})
      |> render_submit()

      assert has_element?(
               lv,
               "#key_reset_day-resets-error",
               "Set the day, the time and the time zone, or leave all three empty."
             )

      lv |> form("#key-form", key: %{value_id: "main", reset_time: ""}) |> render_submit()

      assert has_element?(
               lv,
               "#key_value_id-error",
               "Another key of #{provider.name} has this name."
             )

      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      refute ModelKeys.setting(values(provider)["spare"].id)
    end

    test "a key deleted while the page is open: Save says it is no longer there", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))
      {:ok, _provider} = Connections.delete_provider_key(scope, provider, "spare")

      lv
      |> form("#key-form", key: %{value_id: "renamed", pause_number: "5"})
      |> render_submit()

      assert text(lv, "#key-refusal") == "It is no longer there."
      assert has_element?(lv, ~s{#key_value_id[value="renamed"]})
      assert Map.keys(values(provider)) == ["main"]
    end

    test "a person who can no longer write keys changes nothing", ctx do
      %{scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "spare/edit"))
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

      lv
      |> form("#key-form", key: %{value_id: "renamed", key: "sk-ant-other", pause_number: "5"})
      |> render_submit()

      assert has_element?(lv, "#key-refusal")
      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      refute ModelKeys.setting(values(provider)["spare"].id)

      assert Apiary.Secrets.reveal_key_for_sealing(
               Repo.get!(Connection, provider.id),
               values(provider)["spare"].id
             ) == {:ok, @key}
    end
  end
end
