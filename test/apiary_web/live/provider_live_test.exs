defmodule ApiaryWeb.ProviderLiveTest do
  # Organisation settings › Model provider keys (`ApiaryWeb.ProviderLive.Index` and
  # `ApiaryWeb.ProviderLive.Key`): the state of each key on the list, never a key; New model
  # provider key with its key, its settings and, for LiteLLM, its address; Edit key with a
  # key's settings under its identity line; who sees what. The rows, Workspaces and Remove
  # are in `ApiaryWeb.ModelProviderKeysTest`.
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
        keys: [%{value: @key}]
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

  # The Edit key page of the key `value_id`, at its row id.
  defp edit_path(scope, provider, value_id),
    do: key_path(scope, provider, "#{values(provider)[value_id].id}/edit")

  # The identity line of a key of `provider` whose value ends in `tail`, as the pages show it.
  defp line(provider, tail \\ "cdef"), do: "#{provider.name} · …#{tail}"

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

  # The id of the key `value_id` in the page source: its row id.
  defp key_dom(provider, value_id), do: "key-#{values(provider)[value_id].id}"

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

  # The key `value_id` of `provider`, as a run's sealing reads it.
  defp key_value(provider, value_id),
    do:
      Apiary.ModelKeysFixtures.revealed_key(
        Repo.get!(Connection, provider.id),
        values(provider)[value_id].id
      )

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

  # The form of New model provider key in `html` is sent with POST, and its key's field has
  # no value.
  defp assert_posts_without_key(html) do
    form = LazyHTML.query(html, "#new-provider-form")
    assert LazyHTML.attribute(form, "method") == ["post"]

    key = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(key, "name") == ["provider[key]"]
    assert LazyHTML.attribute(key, "value") == []
  end

  describe "the list" do
    test "a member reads the state of each key, never a key", %{scope: scope} do
      provider = provider!(scope)
      conn = member_conn(scope, :member)

      {:ok, lv, html} = live(conn, list_path(scope))
      assert has_element?(lv, "##{key_dom(provider, "key-1")}-state", "Available")
      refute html =~ @key
    end

    test "an admin adds one", %{scope: scope} do
      {:ok, lv, _html} = live(member_conn(scope, :admin), list_path(scope))
      assert has_element?(lv, "#new-model-provider")
    end
  end

  describe "New model provider key" do
    test "adds a key, never rendering it", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      refute has_element?(lv, "#new-provider-address")

      {:ok, list, html} =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert html =~ "key-1 is added."
      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert provider.provider_kind == "anthropic"
      assert text(list, "##{key_dom(provider, "key-1")}-provider") == title("anthropic")
      refute html =~ @key
      refute html =~ String.slice(@key, -8, 8)
    end

    test "with one workspace, adds the key as a secret of the workspace, on its Secrets page",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
      |> render_submit()

      assert {:ok, [provider]} = Connections.list_providers(scope)
      secret = Repo.get!(Secret, provider.secret_id)

      {:ok, secrets, html} =
        live(conn, "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets")

      assert has_element?(secrets, "#secret-#{secret.public_id}-provider", provider.name)
      refute html =~ @key
    end

    test "a key for every workspace is a secret of the organisation", ctx do
      %{conn: conn, scope: scope} = ctx
      workspace_fixture(scope.organisation, "Storefront")
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key, reach: "all"})
      |> render_submit()

      assert {:ok, [every]} = Connections.list_providers(scope)
      assert every.applies_to == "all"
      assert Repo.get!(Secret, every.secret_id).workspace_id == nil
    end

    test "with no workspace yet, says to set one up first, with no form", %{conn: conn} do
      %{user: user, organisation: organisation} = without_workspace()
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/#{organisation}/settings/model-providers/new")

      assert has_element?(
               lv,
               "#new-provider-needs-workspace",
               "Set up a workspace first, then add a model provider key in its Model step."
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
               "Set up a workspace first, then add a model provider key in its Model step."
             )

      assert has_element?(
               lv,
               ~s{#new-provider-needs-workspace a[href="/#{organisation.slug}"]},
               "Set up a workspace"
             )

      refute has_element?(lv, "#new-provider-form")

      render_hook(lv, "create", %{
        "provider" => %{"provider" => "anthropic", "key" => @key, "reach" => "all"}
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

    # LiteLLM is offered with model_proxies alone.
    @tag needs: [:factory, :secrets, :model_proxies]
    test "About model provider keys has what a key is for, and where to get the chosen one",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(
               lv,
               "aside#page-context > h2#page-context-h",
               ~r/\AAbout model provider keys\z/
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

    test "OpenAI is a choice with its title, its subtitle and where to get its key", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      for {name, title} <- [
            {"openai", "OpenAI API key"},
            {"openai-subscription", "OpenAI subscription"}
          ] do
        index = Enum.find_index(Providers.list(), &(&1.name == name))
        assert has_element?(lv, "label[for=provider_provider-#{index}]", title)
        assert has_element?(lv, ~s{#provider_provider-#{index}[value="#{name}"]})
      end

      lv |> form("#new-provider-form", provider: %{provider: "openai"}) |> render_change()

      assert text(lv, "#new-provider-get-key") ==
               "Get the key from the provider first: create an API key in the OpenAI Platform."

      # Its description's address on About model provider keys is the subscription's alone.
      assert {:ok, openai} = Providers.fetch("openai")
      assert Index.terms_url(openai) == nil
      assert {:ok, subscription} = Providers.fetch("openai-subscription")
      assert Index.terms_url(subscription) == "https://openai.com/policies/terms-of-use/"

      lv
      |> form("#new-provider-form", provider: %{provider: "openai-subscription"})
      |> render_change()

      refute has_element?(lv, "#new-provider-get-key")
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

    # LiteLLM is offered with model_proxies alone.
    @tag needs: [:factory, :secrets, :model_proxies]
    test "Provider is a choice: each provider's title and its description's text", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "button#provider_provider", "Anthropic API key")
      refute has_element?(lv, "select#provider_provider")

      for {provider, index} <- Enum.with_index(Providers.offered()) do
        assert has_element?(
                 lv,
                 ~s{#provider_provider-#{index}[type=radio][name="provider[provider]"][value="#{provider.name}"]}
               )

        assert has_element?(lv, "label[for=provider_provider-#{index}]", provider.title)
      end

      # A subtitle is plain text: no backticks, and the terms' address is on About model
      # provider keys.
      subscription = Enum.find_index(Providers.offered(), &(&1.name == "claude-subscription"))
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
      [first | _rest] = providers = Providers.offered()
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

      html = rendered_to_string(Index.terms(%{href: nil, vendor: "Anthropic"}))
      refute html =~ "<a"
      assert html =~ "Anthropic&#39;s terms"

      html = rendered_to_string(Index.terms(%{href: nil, vendor: "your LiteLLM proxy"}))
      assert html =~ "Your LiteLLM proxy&#39;s terms"

      html = rendered_to_string(Index.terms(%{href: "https://terms.example.com", vendor: "Acme"}))
      assert html =~ ~s(href="https://terms.example.com")
      assert html =~ "Acme&#39;s terms"
    end

    test "a refused key leaves the field empty and shows its error; only spaces are an empty Key",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      html =
        lv
        |> form("#new-provider-form", provider: %{provider: "anthropic", key: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      empty = text(lv, "#new-provider-key-1-error")

      lv
      |> form("#new-provider-form", provider: %{provider: "anthropic", key: " \n\t\u00A0\r\n"})
      |> render_submit()

      assert text(lv, "#new-provider-key-2-error") == empty
      assert {:ok, []} = Connections.list_providers(scope)
    end

    # LiteLLM is offered with model_proxies alone.
    @tag needs: [:factory, :secrets, :model_proxies]
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

    # LiteLLM is offered with model_proxies alone.
    @tag needs: [:factory, :secrets, :model_proxies]
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

  describe "the state of a key on the list" do
    test "is in words, in the reader's time zone", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))
      now = DateTime.utc_now()

      provider = keys!(scope, "anthropic", ~w(zeta beta alpha gamma delta omega))
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

      {:ok, lv, html} = live(conn, list_path(scope))

      until = "In cooldown until #{berlin(in_two_days, now)}"

      assert text(lv, "##{key_dom(provider, "alpha")}-state") ==
               "#{until} · from the provider's response"

      assert text(lv, "##{key_dom(provider, "zeta")}-state") == "Available"

      assert text(lv, "##{key_dom(provider, "beta")}-state") ==
               "Available · 5-hour 89%, resets #{berlin(soon, now)} · 7-day 40%, resets #{berlin(in_three_days, now)}"

      assert text(lv, "##{key_dom(provider, "gamma")}-state") ==
               "#{until} · from this key's schedule"

      assert text(lv, "##{key_dom(provider, "delta")}-state") ==
               "#{until} · no reset time given; paused for 2 hours"

      assert text(lv, "##{key_dom(provider, "omega")}-state") ==
               "#{until} · no reset time given; paused for 1 minute"

      refute html =~ @key
    end

    test "a member reads it without Edit, and Edit key is not found for them", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      edit = edit_path(scope, provider, "spare")

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(
               lv,
               ~s{a##{key_dom(provider, "spare")}-edit[href="#{edit}"][aria-label="Edit spare"]},
               "Edit"
             )

      member = member_conn(scope, :member)
      {:ok, lv, _html} = live(member, list_path(scope))
      assert has_element?(lv, "##{key_dom(provider, "spare")}-state", "Available")
      refute has_element?(lv, "##{key_dom(provider, "spare")}-edit")
      assert_raise ApiaryWeb.NotFound, fn -> live(member, edit) end
    end

    test "shows each window of the contract in words, and another by its code", ctx do
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

      {:ok, lv, _html} = live(conn, list_path(scope))
      segments = lv |> text("##{key_dom(provider, "main")}-state") |> String.split(" · ")
      assert hd(segments) == "Available"

      expected =
        for {{window, word}, n} <- Enum.sort(Enum.with_index(words, 1)),
            do: {window, "#{word} #{n}%"}

      assert tl(segments) == Enum.map(expected, &elem(&1, 1))

      # A reset follows the use.
      now = DateTime.utc_now()
      soon = DateTime.add(now, 60)
      record!(value, %{window: "requests", utilization: 12, resets_at: soon})
      {:ok, lv, _html} = live(conn, list_path(scope))

      assert text(lv, "##{key_dom(provider, "main")}-state") =~
               "Requests per minute 12%, resets #{berlin(soon, now)}"
    end
  end

  describe "New model provider key, a key's settings" do
    test "adds a key with its settings, never rendering it", ctx do
      %{conn: conn, scope: scope, user: user} = ctx
      Repo.update!(Ecto.Changeset.change(user, time_zone: "Europe/Berlin"))

      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(
               lv,
               "#provider_reset_day-resets-hint",
               "The weekly time when this key's allowance resets. Set it if the provider sends no reset time."
             )

      assert has_element?(
               lv,
               "#provider_pause_number-pause-hint",
               "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 minute."
             )

      assert has_element?(lv, ~s{#provider_reset_zone option[value="Europe/Berlin"][selected]})
      assert has_element?(lv, ~s{#provider_pause_unit option[value="minutes"][selected]})
      assert has_element?(lv, ~s{#provider_reset_day option[value="1"]}, "Monday")

      {:ok, list, html} =
        lv
        |> form("#new-provider-form",
          provider: %{
            provider: "anthropic",
            key: @key,
            reset_day: "1",
            reset_time: "09:00",
            reset_zone: "Europe/Berlin",
            pause_number: "2",
            pause_unit: "hours"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert html =~ "key-1 is added."
      assert {:ok, [provider]} = Connections.list_providers(scope)
      assert has_element?(list, "##{key_dom(provider, "key-1")}-state", "Available")
      refute html =~ @key

      value = values(provider)["key-1"]
      setting = ModelKeys.setting(value.id)
      assert {setting.reset_weekday, setting.reset_time} == {1, ~T[09:00:00]}
      assert {setting.reset_time_zone, setting.pause_seconds} == {"Europe/Berlin", 7200}
      assert key_value(provider, "key-1") == {:ok, @key}
    end

    test "for a subscription, pauses for an hour", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))

      lv
      |> form("#new-provider-form", provider: %{provider: "claude-subscription"})
      |> render_change()

      assert has_element?(
               lv,
               "#provider_pause_number-pause-hint",
               "How long runs skip this key after the provider returns a limit error, when no reset time is known. Empty: 1 hour."
             )

      assert has_element?(lv, ~s{#provider_pause_unit option[value="hours"][selected]})
    end

    test "says what is wrong under each field, and adds nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, lv, _html} = live(conn, new_path(scope))

      html =
        lv
        |> form("#new-provider-form",
          provider: %{provider: "anthropic", key: @key, reset_day: "1", pause_number: "0"}
        )
        |> render_submit()

      refute html =~ @key
      assert has_element?(lv, ~s{#new-provider-form input[type=password]:not([value])})

      assert has_element?(
               lv,
               "#provider_reset_day-resets-error",
               "Set the day, the time and the time zone, or leave all three empty."
             )

      assert has_element?(
               lv,
               "#provider_pause_number-pause-error",
               "Enter a time from 1 minute to 7 days."
             )

      refute has_element?(lv, "#provider_pause_number-pause-hint")

      lv
      |> form("#new-provider-form",
        provider: %{
          provider: "anthropic",
          key: @key,
          reset_day: "",
          pause_number: "8",
          pause_unit: "days"
        }
      )
      |> render_submit()

      assert has_element?(
               lv,
               "#provider_pause_number-pause-error",
               "Enter a time from 1 minute to 7 days."
             )

      assert {:ok, []} = Connections.list_providers(scope)
    end

    test "a person who can no longer write keys adds nothing", %{scope: scope} do
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, new_path(scope))
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

      lv
      |> form("#new-provider-form", provider: %{provider: "anthropic", key: @key})
      |> render_submit()

      assert has_element?(lv, "#new-provider-refusal")
      assert {:ok, []} = Connections.list_providers(scope)
    end
  end

  describe "Edit key, Name" do
    test "has the key's name, and a new name renames it; the default key stays the default",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      assert provider.default_value_id == "main"

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))
      assert has_element?(lv, ~s{#key-form label[for="key-name"]}, "Name")
      assert has_element?(lv, ~s{#key-name[value="main"]})

      {:ok, _list, html} =
        lv
        |> form("#key-form", key: %{name: "primary"})
        |> render_submit()
        |> follow_redirect(conn, list_path(scope))

      assert html =~ "#{line(provider)} is saved."
      assert values(provider) |> Map.keys() |> Enum.sort() == ["primary", "spare"]
      assert Repo.get!(Connections.Connection, provider.id).default_value_id == "primary"
    end

    test "two providers' keys both named key-1 keep their names, and one can be renamed",
         ctx do
      %{conn: conn, scope: scope} = ctx
      storefront = workspace_fixture(scope.organisation, "Storefront")

      create = fn reach ->
        {:ok, provider} =
          Connections.create_provider(
            scope,
            Map.merge(%{provider: "anthropic", keys: [%{value: @key}]}, reach)
          )

        provider
      end

      every = create.(%{applies_to: "all"})
      only = create.(%{applies_to: "selected", workspace_ids: [storefront.id]})

      # Both providers have a key-1; one is renamed storefront.
      {:ok, lv, _html} = live(conn, edit_path(scope, only, "key-1"))
      assert has_element?(lv, ~s{#key-name[value="key-1"]})

      lv |> form("#key-form", key: %{name: "storefront"}) |> render_submit()
      {:ok, lv, _html} = live(conn, edit_path(scope, every, "key-1"))

      # Another key of the kind has storefront now: the name is refused, under Name.
      lv |> form("#key-form", key: %{name: "storefront"}) |> render_submit()
      assert has_element?(lv, "#key-form", "is already the name of another key")

      # A name key-<n> is refused too, under Name.
      lv |> form("#key-form", key: %{name: "key-7"}) |> render_submit()

      assert has_element?(
               lv,
               "#key-form",
               "Choose another name: Qory Apiary gives names like key-3 to new keys."
             )

      assert Map.keys(values(every)) == ["key-1"]
      assert Map.keys(values(only)) == ["storefront"]
    end

    test "an empty Name is refused, and saves nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main))
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "main"))

      lv |> form("#key-form", key: %{name: " ", pause_number: "5"}) |> render_submit()

      assert has_element?(lv, "#key-form", "can't be blank")
      assert Map.keys(values(provider)) == ["main"]
      assert ModelKeys.setting(values(provider)["main"].id) == nil
    end
  end

  describe "Edit key" do
    test "shows the key's settings under its identity line, and saves them, its state kept",
         ctx do
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

      {:ok, lv, html} = live(conn, edit_path(scope, provider, "spare"))
      assert has_element?(lv, "h1", line(provider))
      assert has_element?(lv, "#breadcrumb", "Edit key")
      refute has_element?(lv, "#key_value_id")
      refute has_element?(lv, ~s{[name="key[value_id]"]})
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
      assert text(lv, "#key-workspaces-names") == "Every workspace"
      refute html =~ @key

      result =
        lv
        |> form("#key-form",
          key: %{
            reset_day: "",
            reset_time: "",
            pause_number: "30",
            pause_unit: "minutes"
          }
        )
        |> render_submit()

      {:ok, list, html} = follow_redirect(result, conn, list_path(scope))
      assert html =~ "#{line(provider)} is saved."
      assert text(list, "##{key_dom(provider, "spare")}-state") =~ "Available · 5-hour 30%"
      assert values(provider)["spare"].id == value.id
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

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      # A New value of spaces keeps the value and the cooldown; the settings still save.
      result =
        lv
        |> form("#key-form", key: %{key: "   ", pause_number: "5"})
        |> render_submit()

      {:ok, list, html} = follow_redirect(result, conn, list_path(scope))
      assert html =~ "#{line(provider)} is saved."
      assert text(list, "##{key_dom(provider, "spare")}-state") =~ "In cooldown until"
      assert ModelKeys.setting(value.id).pause_seconds == 300
      assert values(provider)["spare"].value_set_at == value.value_set_at

      assert Apiary.ModelKeysFixtures.revealed_key(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, @key}

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      result =
        lv
        |> form("#key-form", key: %{key: new_value, pause_number: "5"})
        |> render_submit()

      {:ok, list, html} = follow_redirect(result, conn, list_path(scope))
      assert html =~ "#{line(provider)} is saved."
      refute html =~ new_value
      refute html =~ String.slice(new_value, -8, 8)
      assert text(list, "##{key_dom(provider, "spare")}-state") == "Available"

      saved = values(provider)["spare"]
      assert DateTime.compare(saved.value_set_at, value.value_set_at) == :gt

      assert Apiary.ModelKeysFixtures.revealed_key(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, new_value}

      assert Apiary.ModelKeysFixtures.revealed_key(
               Repo.get!(Connection, provider.id),
               values(provider)["main"].id
             ) == {:ok, @key}
    end

    test "trims the spaces and newlines around a New value, and keeps the spaces inside",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      value = values(provider)["spare"]
      key_state!(provider, "spare", until: in_seconds(3_600))

      # Only whitespace, a newline and a no-break space among it, keeps the value.
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      result =
        lv
        |> form("#key-form", key: %{key: "\n\t\u00A0\r\n"})
        |> render_submit()

      {:ok, list, _html} = follow_redirect(result, conn, list_path(scope))
      assert text(list, "##{key_dom(provider, "spare")}-state") =~ "In cooldown until"
      assert values(provider)["spare"].value_set_at == value.value_set_at
      assert key_value(provider, "spare") == {:ok, @key}

      # The value it has, with spaces around it, is a new value: set, its cooldown ended.
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      result =
        lv
        |> form("#key-form", key: %{key: " #{@key}\n"})
        |> render_submit()

      {:ok, list, html} = follow_redirect(result, conn, list_path(scope))
      assert html =~ "#{line(provider)} is saved."
      refute html =~ @key
      assert text(list, "##{key_dom(provider, "spare")}-state") == "Available"
      assert DateTime.compare(values(provider)["spare"].value_set_at, value.value_set_at) == :gt
      assert key_value(provider, "spare") == {:ok, @key}

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      result =
        lv
        |> form("#key-form", key: %{key: "\r\n sk-ant rotated key \n"})
        |> render_submit()

      {:ok, _list, html} = follow_redirect(result, conn, list_path(scope))
      refute html =~ "rotated"
      assert key_value(provider, "spare") == {:ok, "sk-ant rotated key"}
    end

    test "a New value that fails its checks shows its error under it, and changes nothing",
         ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      value = values(provider)["spare"]
      bad = "sk-ant-rotated-0123456789abcdef" <> <<0>>
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      html =
        lv
        |> form("#key-form", key: %{key: bad, pause_number: "5"})
        |> render_submit()

      assert has_element?(lv, "#key-value-1-error", "must not contain a NUL byte")
      assert has_element?(lv, ~s{#key-form input#key-value-1[type=password]:not([value])})
      refute html =~ "sk-ant-rotated"
      state = inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity)
      refute state =~ "sk-ant-rotated"

      # With settings that cannot be saved, the errors of every field show at once.
      html =
        lv
        |> form("#key-form", key: %{key: bad, reset_time: "09:00"})
        |> render_submit()

      assert has_element?(lv, "#key-value-2-error", "must not contain a NUL byte")
      assert has_element?(lv, "#key_reset_day-resets-error")
      refute html =~ "sk-ant-rotated"

      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      assert values(provider)["spare"].value_set_at == value.value_set_at
      refute ModelKeys.setting(value.id)

      assert Apiary.ModelKeysFixtures.revealed_key(Repo.get!(Connection, provider.id), value.id) ==
               {:ok, @key}
    end

    test "says what is wrong under each field, and changes nothing", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))

      lv |> form("#key-form", key: %{reset_time: "09:00"}) |> render_submit()

      assert has_element?(
               lv,
               "#key_reset_day-resets-error",
               "Set the day, the time and the time zone, or leave all three empty."
             )

      refute has_element?(lv, "#key_value_id")

      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      refute ModelKeys.setting(values(provider)["spare"].id)
    end

    test "a key deleted while the page is open: Save says it is no longer there", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))
      {:ok, _provider} = Connections.delete_provider_key(scope, provider, "spare")

      lv
      |> form("#key-form", key: %{pause_number: "5"})
      |> render_submit()

      assert text(lv, "#key-refusal") == "It is no longer there."
      assert Map.keys(values(provider)) == ["main"]
    end

    test "a person who can no longer write keys changes nothing", ctx do
      %{scope: scope} = ctx
      provider = keys!(scope, "anthropic", ~w(main spare))
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "spare"))
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

      lv
      |> form("#key-form", key: %{key: "sk-ant-other", pause_number: "5"})
      |> render_submit()

      assert has_element?(lv, "#key-refusal")
      assert Map.keys(values(provider)) |> Enum.sort() == ["main", "spare"]
      refute ModelKeys.setting(values(provider)["spare"].id)

      assert Apiary.ModelKeysFixtures.revealed_key(
               Repo.get!(Connection, provider.id),
               values(provider)["spare"].id
             ) == {:ok, @key}
    end

    test "a key of another organisation is not found", %{conn: conn, scope: scope} do
      %{scope: other} = sign_up_fixture()
      theirs = keys!(other, "anthropic", ~w(main theirs))
      ours = provider!(scope)

      for path <- [
            key_path(scope, theirs, "#{values(theirs)["theirs"].id}/edit"),
            key_path(scope, ours, "#{values(theirs)["theirs"].id}/edit")
          ] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end
      end
    end
  end

  describe "a key's identity line, the title of Edit key" do
    # A provider of `name` with a key for each value, added in their order, a second apart.
    defp provider_with!(scope, name, values) do
      [first | rest] = values

      {:ok, provider} =
        Connections.create_provider(scope, %{provider: name, keys: [%{value: first}]})

      provider =
        Enum.reduce(rest, provider, fn value, provider ->
          {:ok, provider} = Connections.add_provider_key(scope, provider, %{value: value})
          provider
        end)

      base = ~U[2026-01-01 00:00:00.000000Z]

      for {key, n} <- Enum.with_index(Enum.sort_by(values(provider), &elem(&1, 0))) do
        Repo.update_all(from(v in Value, where: v.id == ^elem(key, 1).id),
          set: [inserted_at: DateTime.add(base, n)]
        )
      end

      provider
    end

    test "a value of fewer than 12 characters, or a key with no hint, is the name alone",
         ctx do
      %{conn: conn, scope: scope} = ctx

      provider =
        provider_with!(scope, "anthropic", [
          "sk-ant-build-0123456789-9c2e",
          "sk-short-1",
          "sk-ant-docs-0123456789-4h7k"
        ])

      values = values(provider)
      assert values["key-1"].hint == "9c2e"
      assert values["key-2"].hint == nil

      # An API key saved before the hint existed has none.
      Repo.update_all(from(v in Value, where: v.id == ^values["key-3"].id), set: [hint: nil])

      for value_id <- ~w(key-2 key-3) do
        {:ok, lv, _html} = live(conn, edit_path(scope, provider, value_id))
        assert text(lv, "h1") == provider.name
      end
    end

    test "a provider named differently from its kind shows its name in the line", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)

      Repo.update_all(from(c in Connection, where: c.id == ^provider.id),
        set: [name: "Web shop API"]
      )

      {:ok, edit, _html} = live(conn, edit_path(scope, provider, "key-1"))
      assert has_element?(edit, "h1", "Web shop API · …cdef")
    end

    test "is at the key's row id, and no other address is found", ctx do
      %{conn: conn, scope: scope} = ctx
      provider = provider!(scope)
      other = keys!(scope, "openrouter", ~w(main))
      row_id = values(provider)["key-1"].id

      {:ok, lv, _html} = live(conn, key_path(scope, provider, "#{row_id}/edit"))
      assert has_element?(lv, "h1", line(provider))
      refute has_element?(lv, "#key_value_id")

      {:ok, list, _html} = live(conn, list_path(scope))

      assert has_element?(
               list,
               ~s{##{key_dom(provider, "key-1")}-edit[href="#{key_path(scope, provider, "#{row_id}/edit")}"]}
             )

      for rest <- [
            "key-1/edit",
            "#{Ecto.UUID.generate()}/edit",
            "#{values(other)["main"].id}/edit"
          ] do
        assert_raise ApiaryWeb.NotFound, fn -> live(conn, key_path(scope, provider, rest)) end
      end
    end

    test "is the provider's name and the last 4 characters of the value, shown on save",
         ctx do
      %{conn: conn, scope: scope} = ctx

      provider =
        provider_with!(scope, "anthropic", [
          "sk-ant-build-0123456789-9c2e",
          "sk-ant-docs-0123456789-4h7k"
        ])

      {:ok, lv, _html} = live(conn, edit_path(scope, provider, "key-2"))
      assert has_element?(lv, "h1", line(provider, "4h7k"))

      result = lv |> form("#key-form", key: %{pause_number: "5"}) |> render_submit()
      {:ok, _list, html} = follow_redirect(result, conn, list_path(scope))
      assert html =~ "#{line(provider, "4h7k")} is saved."
    end
  end
end
