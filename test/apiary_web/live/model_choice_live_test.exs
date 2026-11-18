defmodule ApiaryWeb.ModelChoiceLiveTest do
  # Workspace settings › Model (`ApiaryWeb.ModelChoiceLive`): Key, the tiers of the key's
  # provider (`ApiaryWeb.ModelTiers`), Runtime, Save once every tier has a model, each refusal
  # under its field, who may save, the fallbacks, and a saved choice that a run's settings
  # then use.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Kinds.Runtimes
  alias Apiary.ModelChoices.ModelChoice

  @moduletag needs: [:factory, :secrets]

  # The tiers a test sets: each tier's model and effort, of the Anthropic description.
  @tiers %{
    "thinking" => %{"model" => "claude-opus-5-5", "effort" => "high"},
    "balanced" => %{"model" => "claude-sonnet-5-5", "effort" => "medium"},
    "light" => %{"model" => "claude-haiku-5-5", "effort" => "low"}
  }

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "key-1", value: "sk-ant-model-page-0123456789"}]
      })

    %{provider: provider}
  end

  defp path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/model"

  defp choice(scope) do
    Repo.one(
      from c in ModelChoice,
        where: c.workspace_id == ^scope.workspace.id and is_nil(c.target_id)
    )
  end

  defp option(provider, model), do: "#{provider.public_id}/#{model}"

  defp key(provider, value_id \\ "key-1"), do: "#{provider.public_id}/#{value_id}"

  # Sets each tier of `tiers` through the form: the models first, then the efforts, as
  # an Effort is disabled until its tier has a model.
  defp set_tiers(lv, tiers) do
    models = Map.new(tiers, fn {tier, set} -> {tier, %{model: set["model"]}} end)
    lv |> form("#model-form", model_choice: %{tiers: models}) |> render_change()

    efforts =
      for {tier, %{"effort" => effort}} <- tiers, effort not in ["", nil], into: %{} do
        {tier, %{effort: effort}}
      end

    if efforts != %{},
      do: lv |> form("#model-form", model_choice: %{tiers: efforts}) |> render_change()

    lv
  end

  defp saved_tiers(scope), do: choice(scope).tiers

  test "has Default models: Key, each key as provider · key, and the tiers", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(lv, "h1", "Model")
    assert has_element?(lv, ~s{#settings-tab-model[aria-current="page"]})
    assert has_element?(lv, "#model-default-title", "Default models")

    assert has_element?(
             lv,
             "#model-default-line",
             "Runs use this key and these models when their workflow sets none."
           )

    assert has_element?(lv, "aside#page-context > h2#page-context-h", ~r/\AAbout models\z/)
    refute has_element?(lv, ".q-settings-head-sub")

    assert has_element?(
             lv,
             "#page-context #model-line",
             "The models runs in #{scope.workspace.name} use: one key, and a model and an effort for each tier. A workflow can choose another key and models in its settings on the Workflows page. If #{scope.workspace.name} sets none, its runs use the models of #{scope.organisation.name}."
           )

    # Key is a choice with no search, its one key chosen.
    assert has_element?(lv, "button#model_choice_key", "#{provider.name} · key-1")
    refute has_element?(lv, "#model_choice_key-search")

    assert has_element?(
             lv,
             ~s{#model_choice_key-options input[value="#{key(provider)}"][checked]}
           )

    assert has_element?(lv, "#model-tiers-h", "Model and effort per tier")
    refute has_element?(lv, "#model_choice_model")
    refute has_element?(lv, "#model_choice_other")
  end

  test "each tier is a group with its name and line, and Model lists the suggestions", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, html} = live(conn, path(scope))
    suggestions = ModelChoices.suggestions(provider, ModelChoices.default_runtime())

    names =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#model-tiers fieldset > legend > span > span:first-child")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert names == ["Thinking", "Balanced", "Light"]

    for {tier, line} <- [
          {"thinking", "Plans and reviews: the most capable model."},
          {"balanced", "Writes and runs most steps."},
          {"light", "Simple, scripted steps: the cheapest model."}
        ] do
      assert has_element?(
               lv,
               ~s{fieldset#model-tiers-#{tier}[aria-describedby="model-tiers-#{tier}-line"]}
             )

      assert has_element?(lv, "#model-tiers-#{tier}-line", line)

      # Each field has its label, tied to it.
      assert has_element?(lv, ~s{label[for="model_choice_tiers_#{tier}_model"]}, "Model")
      assert has_element?(lv, ~s{label[for="model_choice_tiers_#{tier}_effort"]}, "Effort")

      assert has_element?(
               lv,
               ~s{select#model_choice_tiers_#{tier}_model[name="model_choice[tiers][#{tier}][model]"]}
             )

      # No choice saved: no model, and Effort disabled until the tier has one.
      assert has_element?(
               lv,
               ~s{#model_choice_tiers_#{tier}_model option[value=""][selected]},
               "Choose a model"
             )

      assert has_element?(lv, "#model_choice_tiers_#{tier}_effort[disabled]")
    end

    options =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#model_choice_tiers_thinking_model option")
      |> Enum.map(&LazyHTML.text/1)

    assert options == ["Choose a model" | Enum.map(suggestions, & &1.title)]
  end

  test "a tier's model offers its effort values", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    set_tiers(lv, %{"thinking" => %{"model" => "claude-sonnet-5-5"}})
    refute has_element?(lv, "#model_choice_tiers_thinking_effort[disabled]")

    for effort <- ~w(low medium high xhigh max) do
      assert has_element?(lv, ~s{#model_choice_tiers_thinking_effort option[value="#{effort}"]})
    end

    assert has_element?(lv, "#model_choice_tiers_balanced_effort[disabled]")
  end

  test "Save stays disabled until every tier has a model", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(lv, "#model-submit[disabled]")

    set_tiers(lv, Map.take(@tiers, ["thinking", "balanced"]))
    assert has_element?(lv, "#model-submit[disabled]")

    set_tiers(lv, Map.take(@tiers, ["light"]))
    refute has_element?(lv, "#model-submit[disabled]")
    assert has_element?(lv, "#model-submit")

    # A save sent all the same, with a tier left out, is refused under that tier.
    render_hook(lv, "save", %{
      "model_choice" => %{
        "key" => key(ctx.provider),
        "tiers" => %{@tiers | "light" => %{"model" => "", "effort" => ""}}
      }
    })

    assert has_element?(
             lv,
             "#model_choice_tiers_light_model-error",
             "Choose a model for each tier: Light has none."
           )

    assert choice(scope) == nil
  end

  test "a save writes the key, each tier, and the Thinking tier as the choice's model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

    assert render(lv) =~ "Model saved."

    assert %ModelChoice{value_id: "key-1", model_id: "claude-opus-5-5", effort: "high"} =
             saved = choice(scope)

    assert saved.connection_id == provider.id
    assert saved_tiers(scope) == @tiers
  end

  test "opened again, the page shows the saved key and tiers", ctx do
    %{conn: conn, scope: scope} = ctx
    {:ok, lv, _html} = live(conn, path(scope))
    lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

    {:ok, again, _html} = live(conn, path(scope))

    for {tier, %{"model" => model, "effort" => effort}} <- @tiers do
      assert has_element?(
               again,
               ~s{#model_choice_tiers_#{tier}_model option[value="#{model}"][selected]}
             )

      assert has_element?(
               again,
               ~s{#model_choice_tiers_#{tier}_effort option[value="#{effort}"][selected]}
             )
    end

    refute has_element?(again, "#model-submit[disabled]")
  end

  test "a key chosen is checked and shown on the button; another key keeps the tiers", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{
        value_id: "key-2",
        value: "sk-ant-model-page-second-0123456789"
      })

    {:ok, lv, _html} = live(conn, path(scope))
    set_tiers(lv, @tiers)

    lv |> form("#model-form", model_choice: %{key: key(provider, "key-2")}) |> render_change()

    assert has_element?(
             lv,
             ~s{#model_choice_key-options input[value="#{key(provider, "key-2")}"][checked]}
           )

    assert has_element?(lv, "button#model_choice_key .q-pick-t", "#{provider.name} · key-2")

    assert has_element?(
             lv,
             ~s{#model_choice_tiers_light_model option[value="claude-haiku-5-5"][selected]}
           )

    lv |> form("#model-form") |> render_submit()
    assert %ModelChoice{value_id: "key-2"} = choice(scope)
  end

  test "with two providers, Key lists each provider's keys; another provider empties the tiers",
       ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, second} =
      Connections.create_provider(scope, %{
        provider: "deepseek",
        keys: [%{value_id: "key-1", value: "sk-deepseek-model-page-0123456789"}]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    titles =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#model_choice_key-options .q-pick-t")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert Enum.sort(titles) ==
             Enum.sort(["#{provider.name} · key-1", "#{second.name} · key-1"])

    set_tiers(lv, @tiers)
    lv |> form("#model-form", model_choice: %{key: key(second)}) |> render_change()

    for tier <- ~w(thinking balanced light) do
      assert has_element?(lv, ~s{#model_choice_tiers_#{tier}_model option[value=""][selected]})
      assert has_element?(lv, "#model_choice_tiers_#{tier}_effort[disabled]")
    end

    [first | _rest] = ModelChoices.suggestions(second, ModelChoices.default_runtime())
    assert has_element?(lv, ~s{#model_choice_tiers_thinking_model option[value="#{first.id}"]})

    refute has_element?(
             lv,
             ~s{#model_choice_tiers_thinking_model option[value="claude-opus-5-5"]}
           )

    assert has_element?(lv, "#model-submit[disabled]")

    assert has_element?(
             lv,
             "#model-fallbacks-line",
             "When every key of #{second.name} is in cooldown"
           )
  end

  test "a refused save shows the refusal under its field, and nothing is saved", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{
        value_id: "key-2",
        value: "sk-ant-model-page-second-0123456789"
      })

    {:ok, lv, _html} = live(conn, path(scope))
    set_tiers(lv, @tiers)
    lv |> form("#model-form", model_choice: %{key: key(provider, "key-2")}) |> render_change()

    # The key is renamed while the page is open.
    {:ok, provider} = Connections.get_provider(scope, provider.public_id)
    {:ok, _provider} = Connections.rename_provider_key(scope, provider, "key-2", "key-3")

    lv |> form("#model-form") |> render_submit()

    assert has_element?(
             lv,
             "#model_choice_key-error",
             "Choose one of #{provider.name}'s keys: key-2 is not one of them."
           )

    refute has_element?(lv, "#model-tiers [id$='-error']")
    assert choice(scope) == nil
  end

  test "a refused tier effort shows under that tier's Effort", ctx do
    %{conn: conn, scope: scope} = ctx

    # The runtime's effort values no longer have the stored one: the page keeps a
    # stored effort, and the save refuses it.
    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: @tiers
      })

    [release] = Runtimes.list()
    :ok = Runtimes.put_test_list([%{release | effort_values: ~w(low medium)}])

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model_choice_tiers_thinking_effort option[value="high"][selected]}
           )

    lv |> form("#model-form") |> render_submit()

    assert has_element?(
             lv,
             "#model_choice_tiers_thinking_effort-error",
             "Choose one of claude-opus-5-5's effort values: low, medium."
           )

    assert has_element?(lv, ~s{#model_choice_tiers_thinking_effort[aria-invalid="true"]})
    refute has_element?(lv, "#model_choice_tiers_balanced_effort-error")
  end

  test "a refused tier effort shows under that tier, not under another with its model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: %{
          @tiers
          | "thinking" => %{"model" => "claude-sonnet-5-5", "effort" => "low"},
            "balanced" => %{"model" => "claude-sonnet-5-5", "effort" => "high"}
        }
      })

    # The runtime no longer offers Balanced's stored effort.
    [release] = Runtimes.list()
    :ok = Runtimes.put_test_list([%{release | effort_values: ~w(low medium)}])
    {:ok, lv, _html} = live(conn, path(scope))
    lv |> form("#model-form") |> render_submit()

    assert has_element?(
             lv,
             "#model_choice_tiers_balanced_effort-error",
             "Choose one of claude-sonnet-5-5's effort values: low, medium."
           )

    assert has_element?(lv, ~s{#model_choice_tiers_balanced_effort[aria-invalid="true"]})
    refute has_element?(lv, "#model_choice_tiers_thinking_effort-error")
    refute has_element?(lv, "#model-tiers-error-0")
    assert %{"effort" => "high"} = choice(scope).tiers["balanced"]
  end

  test "a stored model the list leaves out is shown, and a save refuses it under its tier",
       ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, stored} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    # Stored before the tier rules, or the provider's list changed since.
    stored
    |> Ecto.Changeset.change(tiers: %{@tiers | "light" => %{"model" => "claude-retired-1"}})
    |> Repo.update!()

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model_choice_tiers_light_model option[value="claude-retired-1"][selected]},
             "claude-retired-1"
           )

    refute has_element?(
             lv,
             ~s{#model_choice_tiers_thinking_model option[value="claude-retired-1"]}
           )

    lv |> form("#model-form") |> render_submit()

    assert has_element?(
             lv,
             "#model_choice_tiers_light_model-error",
             "Choose models of #{provider.name}: claude-retired-1 is not one of its models."
           )

    assert has_element?(lv, ~s{#model_choice_tiers_light_model[aria-invalid="true"]})
    refute has_element?(lv, "#model_choice_tiers_thinking_model-error")
    assert %{"model" => "claude-retired-1"} = choice(scope).tiers["light"]
  end

  test "Model lists the provider's default model first", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, html} = live(conn, path(scope))
    default = Connections.default_model(provider)

    [_prompt, first | _rest] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#model_choice_tiers_balanced_model option")
      |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> hd()))

    assert first == default
    assert has_element?(lv, ~s{#model_choice_tiers_balanced_model option[value="#{default}"]})
  end

  test "a choice that names no key keeps following the provider's default key", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, _} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: @tiers
      })

    assert %ModelChoice{value_id: nil} = choice(scope)
    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model_choice_key-options input[value="#{key(provider)}"][checked]}
           )

    lv |> form("#model-form") |> render_submit()
    assert render(lv) =~ "Model saved."
    assert %ModelChoice{value_id: nil} = choice(scope)

    # Choosing the key by name stores it.
    {:ok, _provider} =
      Connections.add_provider_key(scope, provider, %{
        value_id: "key-2",
        value: "sk-ant-model-page-second-0123456789"
      })

    {:ok, lv, _html} = live(conn, path(scope))
    lv |> form("#model-form", model_choice: %{key: key(provider, "key-2")}) |> render_change()
    lv |> form("#model-form") |> render_submit()
    assert %ModelChoice{value_id: "key-2"} = choice(scope)
  end

  test "a forged key is not saved: the save keeps the page's key", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    %{scope: other} = sign_up_fixture()

    {:ok, foreign} =
      Connections.create_provider(other, %{
        provider: "anthropic",
        keys: [%{value_id: "key-1", value: "sk-ant-model-page-foreign-0123456789"}]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    for forged <- [key(foreign), key(provider, "no-such-key"), "x"] do
      render_hook(lv, "save", %{"model_choice" => %{"key" => forged, "tiers" => @tiers}})
      assert %ModelChoice{value_id: "key-1"} = saved = choice(scope)
      assert saved.connection_id == provider.id
    end
  end

  test "a member sees the fields disabled, no Save, and who changes them", ctx do
    %{scope: scope} = ctx
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

    assert has_element?(lv, "#model_choice_key[disabled]")
    assert has_element?(lv, "#model_choice_tiers_thinking_model[disabled]")
    refute has_element?(lv, "#model-submit")
    assert has_element?(lv, "#model-who", "Only owners and admins change this.")
  end

  test "with no provider, says where to add one" do
    %{scope: scope} = sign_up_fixture()
    %{user: user} = member_fixture(scope, :admin)

    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))
    assert has_element?(lv, "#model-no-provider", "Organisation settings › Model providers")
    refute has_element?(lv, "#model-form")
  end

  test "a saved choice is what a run's settings then use", ctx do
    %{conn: conn, scope: scope} = ctx
    place = handover_place_fixture(scope, allow_secrets: true)
    {:ok, lv, _html} = live(conn, path(scope))

    tiers = %{@tiers | "thinking" => %{"model" => "claude-sonnet-5-5", "effort" => "low"}}
    lv |> set_tiers(tiers) |> form("#model-form") |> render_submit()

    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{documents: documents}} =
      Apiary.DispatchedRunsFixtures.walked_claim(
        place.key,
        Dispatches.now(),
        ~s({"version":1,"time":"2026-10-26T12:00:00Z"})
      )

    settings = documents.run_settings |> Jason.encode!() |> Jason.decode!()
    assert %{"model" => "claude-sonnet-5-5", "effort" => "low"} = settings
    assert %{"light" => %{"model" => "claude-haiku-5-5"}} = settings["tiers"]
  end

  describe "Fallbacks" do
    defp add_provider(scope, kind),
      do:
        Connections.create_provider(scope, %{
          provider: kind,
          keys: [%{value_id: "main", value: "sk-#{kind}-model-page-0123456789"}]
        })

    defp fallbacks(scope) do
      choice = scope |> choice() |> Repo.preload(fallbacks: :connection)
      for f <- choice.fallbacks, do: {f.position, f.connection.public_id, f.model_id, f.effort}
    end

    # Whether a model choice anywhere has a fallback of `provider`.
    defp fallbacks_of_provider?(_scope, provider),
      do:
        Repo.exists?(
          from f in Apiary.ModelChoices.Fallback, where: f.connection_id == ^provider.id
        )

    test "with no other provider, names the chosen one and says what to add", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(lv, "#model-fallbacks h2", "Fallbacks")

      assert has_element?(
               lv,
               "#model-fallbacks-line",
               "When every key of #{provider.name} is in cooldown, runs use these, in order, from the next run."
             )

      refute has_element?(lv, "#model-fallback-rows")
      refute has_element?(lv, "#model-fallback-add")

      assert has_element?(
               lv,
               "#model-fallback-none",
               "Add another model provider that serves #{ModelChoices.default_runtime().title} in Organisation settings › Model providers, then add it here as a fallback."
             )
    end

    test "Add fallback adds a row of a provider left, with the Thinking tier's model", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")
      {:ok, lv, _html} = live(conn, path(scope))

      set_tiers(lv, %{"thinking" => %{"model" => "claude-sonnet-5-5", "effort" => "low"}})

      lv |> element("#model-fallback-add") |> render_click()

      # The first provider left, by name, with the Thinking tier's model and effort.
      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{subscription.public_id}"][selected]}
             )

      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{provider.public_id}"]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_model-options input[value="#{option(subscription, "claude-sonnet-5-5")}"][checked]}
             )

      assert has_element?(lv, ~s{#model_choice_fallbacks_0_effort option[value="low"][selected]})

      # A provider without that model: its first.
      lv |> element("#model-fallback-add") |> render_click()
      first = deepseek |> ModelChoices.suggestions(ModelChoices.default_runtime()) |> hd()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_model-options input[value="#{option(deepseek, first.id)}"][checked]}
             )

      # No provider is left to add.
      refute has_element?(lv, "#model-fallback-add")
      assert has_element?(lv, "#model-fallback-none")

      # A row offers the providers no other row has; one changed takes its model.
      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{deepseek.public_id}"]}
             )

      lv |> element("#model-fallback-1-remove") |> render_click()

      lv
      |> form("#model-form",
        model_choice: %{fallbacks: %{"0" => %{provider: deepseek.public_id}}}
      )
      |> render_change()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_model-options input[value="#{option(deepseek, first.id)}"][checked]}
             )
    end

    test "Save keeps the rows in their order; Move up, Move down and Remove change them", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")

      # Every tier on the provider's default model, with no effort.
      {:ok, _} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: provider.public_id})

      {:ok, lv, _html} = live(conn, path(scope))
      main = Connections.default_model(provider)
      deepseek_first = Connections.default_model(deepseek)

      lv |> element("#model-fallback-add") |> render_click()
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(lv, "#model-fallback-0-up[disabled]")
      assert has_element?(lv, "#model-fallback-1-down[disabled]")
      assert has_element?(lv, ~s{#model-fallback-1-up[aria-label="Move fallback 2 up"]})

      lv |> element("#model-fallback-1-up") |> render_click()
      lv |> form("#model-form") |> render_submit()

      assert fallbacks(scope) == [
               {0, deepseek.public_id, deepseek_first, nil},
               {1, subscription.public_id, main, nil}
             ]

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{deepseek.public_id}"][selected]}
             )

      lv |> element("#model-fallback-0-down") |> render_click()
      lv |> form("#model-form") |> render_submit()
      assert [{0, sub_id, _, _}, {1, ds_id, _, _}] = fallbacks(scope)
      assert {sub_id, ds_id} == {subscription.public_id, deepseek.public_id}

      lv |> element("#model-fallback-0-remove") |> render_click()
      refute has_element?(lv, "#model-fallback-1")
      lv |> form("#model-form") |> render_submit()
      assert fallbacks(scope) == [{0, deepseek.public_id, deepseek_first, nil}]
    end

    test "Remove of an index that no row has removes no row", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, _subscription} = add_provider(scope, "claude-subscription")
      {:ok, lv, _html} = live(conn, path(scope))

      lv |> element("#model-fallback-add") |> render_click()

      for index <- ["-1", "1", "x"] do
        render_hook(lv, "remove_fallback", %{"index" => index})
        assert has_element?(lv, "#model-fallback-0")
      end
    end

    test "a save that chooses a row's provider drops that row and saves the others", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")

      {:ok, _} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          fallbacks: [%{provider: subscription.public_id}, %{provider: deepseek.public_id}]
        })

      {:ok, lv, _html} = live(conn, path(scope))

      # The Key's provider becomes the first row's.
      lv
      |> form("#model-form", model_choice: %{key: key(subscription, "main")})
      |> render_change()

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert has_element?(lv, "#flash-info", "Model saved.")
      assert choice(scope).connection_id == subscription.id
      assert [{0, deepseek_id, _model, _effort}] = fallbacks(scope)
      assert deepseek_id == deepseek.public_id
    end

    test "a refused row shows the refusal under its field, and nothing is saved", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")

      {:ok, _} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: deepseek.public_id,
          fallbacks: [%{provider: subscription.public_id}, %{provider: provider.public_id}]
        })

      {:ok, lv, _html} = live(conn, path(scope))

      # The first row's provider is chosen, so that row is dropped; the second row's
      # refusal shows under the second row.
      lv
      |> form("#model-form", model_choice: %{key: key(subscription, "main")})
      |> render_change()

      render_hook(lv, "save", %{
        "model_choice" => %{
          "key" => key(subscription, "main"),
          "tiers" => @tiers,
          "fallbacks" => %{
            "0" => %{
              "provider" => subscription.public_id,
              "model" => option(subscription, "claude-sonnet-5-5")
            },
            "1" => %{
              "provider" => provider.public_id,
              "model" => option(provider, "claude-sonnet-5-5"),
              "effort" => "turbo"
            }
          }
        }
      })

      assert has_element?(
               lv,
               "#model_choice_fallbacks_1_effort-error",
               "Choose one of claude-sonnet-5-5's effort values"
             )

      refute has_element?(lv, "#model_choice_fallbacks_0_provider-error")
      assert choice(scope).connection_id == deepseek.id
    end

    test "a provider in two rows shows the error under the second row, and nothing is saved",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, lv, _html} = live(conn, path(scope))

      render_hook(lv, "save", %{
        "model_choice" => %{
          "key" => key(provider),
          "tiers" => @tiers,
          "fallbacks" => %{
            "0" => %{
              "provider" => subscription.public_id,
              "model" => option(subscription, "claude-sonnet-5-5")
            },
            "1" => %{
              "provider" => subscription.public_id,
              "model" => option(subscription, "claude-sonnet-5-5")
            }
          }
        }
      })

      assert has_element?(
               lv,
               "#model_choice_fallbacks_1_provider-error",
               "Choose another provider: #{subscription.name} is chosen already."
             )

      assert has_element?(lv, ~s{#model_choice_fallbacks_1_provider[aria-invalid="true"]})
      refute has_element?(lv, "#model_choice_fallbacks_0_provider-error")
      assert choice(scope) == nil
    end

    test "an admin made a member while the page is open saves no fallback", ctx do
      %{scope: scope} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      lv |> element("#model-fallback-add") |> render_click()
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert has_element?(lv, "#flash-error", "Only owners and admins change this.")
      assert choice(scope) == nil
      refute has_element?(lv, "#model-fallback-add")
      refute fallbacks_of_provider?(scope, subscription)
    end

    test "a member's events change no row and save nothing", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      %{user: user} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      render_hook(lv, "add_fallback", %{})
      refute has_element?(lv, "#model-fallback-0")

      render_hook(lv, "save", %{
        "model_choice" => %{
          "key" => key(provider),
          "tiers" => @tiers,
          "fallbacks" => %{"0" => %{"provider" => subscription.public_id}}
        }
      })

      assert choice(scope) == nil
    end

    test "a sent row with another organisation's provider is refused, and nothing is saved",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, _subscription} = add_provider(scope, "claude-subscription")
      %{scope: other} = sign_up_fixture()
      {:ok, foreign} = add_provider(other, "claude-subscription")
      {:ok, lv, _html} = live(conn, path(scope))

      lv |> element("#model-fallback-add") |> render_click()

      render_hook(lv, "save", %{
        "model_choice" => %{
          "key" => key(provider),
          "tiers" => @tiers,
          "fallbacks" => %{
            "0" => %{
              "provider" => foreign.public_id,
              "model" => option(foreign, "claude-sonnet-5-5")
            }
          }
        }
      })

      assert has_element?(lv, "#model_choice_fallbacks_0_provider-error")
      assert choice(scope) == nil
      refute fallbacks_of_provider?(other, foreign)
    end

    test "a member sees the rows disabled, and no button to change them", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")

      {:ok, _} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          fallbacks: [%{provider: subscription.public_id}]
        })

      %{user: user} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      assert has_element?(lv, "#model_choice_fallbacks_0_provider[disabled]")
      assert has_element?(lv, "#model_choice_fallbacks_0_model[disabled]")
      refute has_element?(lv, "#model-fallback-0-remove")
      refute has_element?(lv, "#model-fallback-add")
      refute has_element?(lv, "#model-fallback-none")
    end
  end

  describe "the runtime" do
    # The release's runtime, and a copy of it with a name of its own that reads a key
    # only from the bearer variable: Anthropic (an `x-api-key` header) serves the first
    # alone, OpenRouter (bearer) serves both.
    defp two_runtimes do
      [release] = Runtimes.list()

      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Runtimes.put_test_list([release, bearer])
      {release, bearer}
    end

    defp openrouter(scope) do
      {:ok, openrouter} =
        Connections.create_provider(scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-model-page-0123456789"}]
        })

      openrouter
    end

    # OpenRouter's tiers: its first model with effort `high` on each tier.
    defp openrouter_tiers(openrouter) do
      model =
        openrouter
        |> ModelChoices.suggestions(ModelChoices.default_runtime())
        |> Enum.find(&("high" in &1.effort))

      Map.new(Map.keys(@tiers), &{&1, %{"model" => model.id, "effort" => "high"}})
    end

    # Two runtimes that no provider serves both: the release's runtime as it reads a key
    # from a header other than bearer, which Anthropic serves alone, and the bearer
    # runtime, which OpenRouter serves alone.
    defp split_runtimes do
      [release] = Runtimes.list()
      bearer_auth = %{"scheme" => "bearer"}

      header = %{
        release
        | model_keys: Enum.reject(release.model_keys, &(&1["auth"] == bearer_auth))
      }

      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == bearer_auth))
      }

      :ok = Runtimes.put_test_list([header, bearer])
      {header, bearer}
    end

    defp choose_key(lv, value),
      do: lv |> form("#model-form", model_choice: %{key: value}) |> render_change()

    defp choose_runtime(lv, name),
      do: lv |> form("#model-form", model_choice: %{runtime: name}) |> render_change()

    test "with one runtime of the catalogue, is its name as text; the choice names none",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      [release] = Runtimes.list()
      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      assert has_element?(
               lv,
               "#model-runtime-line",
               "#{release.title} is the only runtime that works with #{provider.name}."
             )

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: nil, model_id: "claude-opus-5-5"} = choice(scope)
    end

    test "comes after the tiers and before the fallbacks", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, _lv, html} = live(conn, path(scope))

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#model_choice_key, #model-tiers, #model-runtime, #model-fallbacks")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert ids == ["model_choice_key", "model-tiers", "model-runtime", "model-fallbacks"]
    end

    test "one runtime fits the key's provider: its name as text, no select", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {release, _bearer} = two_runtimes()
      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      assert has_element?(
               lv,
               "#model-runtime-line",
               "#{release.title} is the only runtime that works with #{provider.name}."
             )

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: name} = choice(scope)
      assert name == release.name
    end

    test "several fit: a select, set to the stored runtime", ctx do
      %{conn: conn, scope: scope} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)

      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: openrouter_tiers(openrouter)
        })

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{release.name}"]})
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{bearer.name}"][selected]})
      refute has_element?(lv, "#model-runtime-name")

      assert has_element?(
               lv,
               "#model-runtime-line",
               "These runtimes work with #{openrouter.name}."
             )
    end

    test "Key lists every key, whichever runtime is chosen", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {_release, bearer} = two_runtimes()
      openrouter = openrouter(scope)

      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: openrouter_tiers(openrouter)
        })

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(lv, ~s{#model_choice_key-options input[value="#{key(provider)}"]})

      assert has_element?(
               lv,
               ~s{#model_choice_key-options input[value="#{key(openrouter, "main")}"][checked]}
             )
    end

    test "a change of Key keeps the runtime the new provider serves, else takes its first",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      # Anthropic serves the release's runtime alone.
      assert has_element?(lv, "#model-runtime-name", release.title)

      # OpenRouter serves it too: it stays, the first of the two in any case.
      choose_key(lv, key(openrouter, "main"))
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{release.name}"][selected]})

      # OpenRouter's second runtime, then back to Anthropic, which does not serve it.
      choose_runtime(lv, bearer.name)
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{bearer.name}"][selected]})

      choose_key(lv, key(provider))
      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()
      assert %ModelChoice{runtime: name} = choice(scope)
      assert name == release.name
    end

    test "a change of Key to a provider that serves the chosen runtime keeps it", ctx do
      %{conn: conn, scope: scope} = ctx
      {_release, bearer} = two_runtimes()
      openrouter = openrouter(scope)

      {:ok, second} =
        Connections.create_provider(scope, %{
          name: "OpenRouter team",
          provider: "openrouter",
          keys: [%{value_id: "team", value: "sk-or-model-page-team-0123456789"}]
        })

      {:ok, lv, _html} = live(conn, path(scope))
      choose_key(lv, key(openrouter, "main"))
      choose_runtime(lv, bearer.name)
      choose_key(lv, key(second, "team"))

      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{bearer.name}"][selected]})
    end

    test "a change of the runtime keeps the models and takes back an effort it refuses", ctx do
      %{conn: conn, scope: scope} = ctx
      [release] = Runtimes.list()

      narrow = %{
        release
        | name: release.name <> "-narrow",
          title: release.title <> " narrow",
          effort_values: ~w(low medium)
      }

      :ok = Runtimes.put_test_list([release, narrow])
      {:ok, lv, _html} = live(conn, path(scope))
      set_tiers(lv, @tiers)

      choose_runtime(lv, narrow.name)

      assert has_element?(
               lv,
               ~s{#model_choice_tiers_thinking_model option[value="claude-opus-5-5"][selected]}
             )

      refute has_element?(lv, ~s{#model_choice_tiers_thinking_effort option[value="high"]})
      assert has_element?(lv, ~s{#model_choice_tiers_thinking_effort option[value=""][selected]})

      assert has_element?(
               lv,
               ~s{#model_choice_tiers_balanced_effort option[value="medium"][selected]}
             )

      lv |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: name, tiers: tiers} = choice(scope)
      assert name == narrow.name
      assert tiers["thinking"] == %{"model" => "claude-opus-5-5"}
      assert tiers["balanced"] == %{"model" => "claude-sonnet-5-5", "effort" => "medium"}
    end

    test "a stored effort stays shown on the stored runtime, and is not offered on a runtime that does not accept it",
         ctx do
      %{conn: conn, scope: scope} = ctx
      [release] = Runtimes.list()
      narrow = %{release | name: release.name <> "-narrow", effort_values: ~w(low medium)}

      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: ctx.provider.public_id,
          tiers: @tiers
        })

      :ok = Runtimes.put_test_list([release, narrow])
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_tiers_thinking_effort option[value="high"][selected]}
             )

      choose_runtime(lv, narrow.name)
      refute has_element?(lv, ~s{#model_choice_tiers_thinking_effort option[value="high"]})
    end

    test "a fallback whose provider does not serve a new runtime stays, with a line", ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      choose_key(lv, key(openrouter, "main"))
      set_tiers(lv, openrouter_tiers(openrouter))
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
             )

      lv
      |> form("#model-form", model_choice: %{fallbacks: %{"0" => %{effort: "low"}}})
      |> render_change()

      lv |> form("#model-form") |> render_submit()
      saved = choice(scope) |> Repo.preload(fallbacks: :connection)
      assert saved.runtime == release.name

      assert [%{connection_id: id, model_id: model_id, effort: "low"}] = saved.fallbacks
      assert id == anthropic.id

      # Anthropic does not serve the bearer runtime: its row stays, with a line under its
      # Provider, and Save is disabled. Add fallback offers none.
      choose_runtime(lv, bearer.name)

      assert has_element?(
               lv,
               "#model-fallback-0-unfit",
               "Choose another provider or remove this fallback. #{anthropic.name} does not work with #{bearer.title}."
             )

      assert has_element?(lv, "#model-submit[disabled]")
      refute has_element?(lv, "#model-fallback-add")

      # A save sent all the same writes nothing.
      lv |> form("#model-form") |> render_submit()
      again = choice(scope) |> Repo.preload(fallbacks: :connection)
      assert again.runtime == release.name
      assert again.updated_at == saved.updated_at
      assert [%{connection_id: ^id, model_id: ^model_id, effort: "low"}] = again.fallbacks

      # Back to the release's runtime: the line goes, Save is enabled, and the row is as
      # it was.
      choose_runtime(lv, release.name)
      refute has_element?(lv, "#model-fallback-0-unfit")
      refute has_element?(lv, "#model-submit[disabled]")

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_model-options input[value="#{option(anthropic, model_id)}"][checked]}
             )

      assert has_element?(lv, ~s{#model_choice_fallbacks_0_effort option[value="low"][selected]})
    end

    test "after a change of Runtime, the line shows only under the row whose provider does not serve it, and goes with the row",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {_release, bearer} = two_runtimes()
      openrouter = openrouter(scope)

      {:ok, second} =
        Connections.create_provider(scope, %{
          name: "OpenRouter team",
          provider: "openrouter",
          keys: [%{value_id: "team", value: "sk-or-model-page-team-0123456789"}]
        })

      {:ok, lv, _html} = live(conn, path(scope))
      choose_key(lv, key(openrouter, "main"))
      lv |> element("#model-fallback-add") |> render_click()
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_provider option[value="#{second.public_id}"][selected]}
             )

      choose_runtime(lv, bearer.name)
      assert has_element?(lv, "#model-fallback-0-unfit", anthropic.name)
      refute has_element?(lv, "#model-fallback-1-unfit")

      lv |> element("#model-fallback-0-remove") |> render_click()
      refute has_element?(lv, "#model-fallback-0-unfit")
    end

    test "a change of Key that moves the runtime shows the line under a fallback whose provider does not serve the new one",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {header, bearer} = split_runtimes()
      openrouter = openrouter(scope)

      {:ok, team} =
        Connections.create_provider(scope, %{
          name: "OpenRouter team",
          provider: "openrouter",
          keys: [%{value_id: "team", value: "sk-or-model-page-team-0123456789"}]
        })

      {:ok, lv, _html} = live(conn, path(scope))

      # OpenRouter serves the bearer runtime alone: Runtime is its name, and Add fallback
      # adds a row of the other provider that serves it.
      choose_key(lv, key(openrouter, "main"))
      assert has_element?(lv, "#model-runtime-name", bearer.title)
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{team.public_id}"][selected]}
             )

      refute has_element?(lv, "#model-fallback-0-unfit")

      # Anthropic serves the header runtime alone: Runtime moves to it, and the row of
      # OpenRouter team shows the line, with Save disabled.
      choose_key(lv, key(anthropic))
      assert has_element?(lv, "#model-runtime-name", header.title)

      assert has_element?(
               lv,
               "#model-fallback-0-unfit",
               "Choose another provider or remove this fallback. #{team.name} does not work with #{header.title}."
             )

      assert has_element?(lv, "#model-submit[disabled]")

      # Back to OpenRouter: the runtime is the bearer one again, and the line goes.
      choose_key(lv, key(openrouter, "main"))
      refute has_element?(lv, "#model-fallback-0-unfit")
    end
  end

  # With no provider that serves the runtime, each line names the cause it is true for,
  # and none asks for a runtime that cannot be chosen.
  describe "with no provider that serves the runtime" do
    test "a provider whose settings no longer fit its entry is to be added again", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx

      # Coded again, as a save codes it, so the row passes its integrity code.
      Connections.Connection
      |> Repo.get!(provider.id)
      |> Ecto.Changeset.change(settings: ~s({"region":"eu"}))
      |> Apiary.Kinds.Coded.seal()
      |> Repo.update!()

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               "#model-changed-#{provider.public_id}",
               "Add #{provider.name} again in Organisation settings › Model providers: its settings no longer fit this version of Qory Apiary."
             )

      refute has_element?(lv, "#model-other_runtime")
      refute has_element?(lv, "#model-none")
      refute has_element?(lv, "#model-submit")
    end

    test "with one runtime, says where to add a model provider", ctx do
      %{conn: conn, scope: scope} = ctx
      [release] = Runtimes.list()
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      :ok = Runtimes.put_test_list([unserved])

      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")
      refute has_element?(lv, "#model-other_runtime")

      assert has_element?(
               lv,
               "#model-none",
               "Add a model provider in Organisation settings › Model providers."
             )

      assert has_element?(
               lv,
               ~s{#model-none a[href="#{~p"/#{scope.organisation}/settings/model-providers"}"]}
             )
    end

    test "to a member, says who adds a model provider", ctx do
      %{scope: scope} = ctx
      [release] = Runtimes.list()
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      :ok = Runtimes.put_test_list([unserved])
      %{user: user} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      assert has_element?(lv, "#model-none", "Only owners and admins add model providers.")
      refute has_element?(lv, "#model-none a")
    end

    test "with two runtimes that no provider serves, says to add a provider", ctx do
      %{conn: conn, scope: scope} = ctx
      [release] = Runtimes.list()
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      other = %{unserved | name: release.name <> "-other", title: release.title <> " other"}
      :ok = Runtimes.put_test_list([unserved, other])

      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model-runtime")
      refute has_element?(lv, "#model-other_runtime")
      assert has_element?(lv, "#model-none")
    end
  end
end

defmodule ApiaryWeb.ModelChoiceLive.ModelProxiesTest do
  # Workspace settings › Model leaves out a provider whose description lists no models,
  # such as LiteLLM, from Key and from a fallback row's Provider, unless the feature
  # `model_proxies` is on. With it on, such a provider's tiers take any model id as text.
  # A saved choice of such a provider stays shown, so a save keeps it. Not async: the
  # features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Apiary.{Connections, Repo}
  alias Apiary.ModelChoices.ModelChoice

  # Tiers of LiteLLM, which takes any model id and no effort.
  @free_tiers %{
    "thinking" => %{"model" => "claude-opus-5-5"},
    "balanced" => %{"model" => "claude-sonnet-5-5"},
    "light" => %{"model" => "claude-haiku-5-5"}
  }

  setup :register_and_log_in_user

  setup %{scope: scope} = ctx do
    %{
      anthropic: provider!(scope, %{provider: "anthropic"}),
      # Added while the feature was on: with it off, a LiteLLM provider is not added.
      litellm:
        Apiary.ConnectionsFixtures.provider_added_with_model_proxies!(
          ctx,
          scope,
          with_key(%{
            provider: "litellm",
            settings: %{"address" => "https://litellm.example.com"}
          })
        )
    }
  end

  defp provider!(scope, attrs) do
    {:ok, provider} = Connections.create_provider(scope, with_key(attrs))
    provider
  end

  defp with_key(attrs),
    do: Map.put(attrs, :keys, [%{value_id: "main", value: "sk-model-proxies-0123456789"}])

  defp path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/model"

  defp choice(scope) do
    Repo.one(
      from c in ModelChoice,
        where: c.workspace_id == ^scope.workspace.id and is_nil(c.target_id)
    )
  end

  defp key(provider), do: "#{provider.public_id}/main"

  # Whether Key has an option of `provider`'s key.
  defp in_key?(lv, provider) do
    has_element?(
      lv,
      ~s{#model-form input[name="model_choice[key]"][value="#{key(provider)}"]}
    )
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: Key and a fallback row leave out LiteLLM", ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert in_key?(lv, anthropic)
    refute in_key?(lv, litellm)

    # Anthropic is chosen, and LiteLLM is the one provider left: no row to add.
    refute has_element?(lv, "#model-fallback-add")
    assert has_element?(lv, "#model-fallback-none")
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: with LiteLLM the one provider, Key is not shown and the page says to add one",
       ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, _provider} = Connections.delete_provider(scope, anthropic)
    {:ok, lv, _html} = live(conn, path(scope))

    refute in_key?(lv, litellm)
    refute has_element?(lv, "#model_choice_key")
    refute has_element?(lv, "#model-tiers")
    assert has_element?(lv, "#model-unserved #model-none")
    refute has_element?(lv, "#model-other_runtime")
  end

  @tag with_features: Apiary.Features.all()
  test "on: Key and a fallback row offer LiteLLM", ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert in_key?(lv, anthropic)
    assert in_key?(lv, litellm)

    lv |> element("#model-fallback-add") |> render_click()

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{litellm.public_id}"][selected]}
           )
  end

  @tag with_features: Apiary.Features.all()
  test "on: a provider with no model list gets a text field per tier, and no Effort", ctx do
    %{conn: conn, scope: scope, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> form("#model-form", model_choice: %{key: key(litellm)}) |> render_change()

    assert has_element?(lv, "#model-tiers-h", "Model per tier")

    for tier <- ~w(thinking balanced light) do
      assert has_element?(
               lv,
               ~s{input#model_choice_tiers_#{tier}_model[type="text"][name="model_choice[tiers][#{tier}][model]"]}
             )

      assert has_element?(lv, ~s{label[for="model_choice_tiers_#{tier}_model"]}, "Model")
      refute has_element?(lv, "#model_choice_tiers_#{tier}_effort")
    end

    assert has_element?(lv, "#model-submit[disabled]")

    lv |> form("#model-form", model_choice: %{tiers: @free_tiers}) |> render_change()
    refute has_element?(lv, "#model-submit[disabled]")

    lv |> form("#model-form") |> render_submit()
    assert has_element?(lv, "#flash-info", "Model saved.")

    assert %ModelChoice{model_id: "claude-opus-5-5", effort: nil, tiers: tiers} =
             saved = choice(scope)

    assert saved.connection_id == litellm.id
    assert tiers == @free_tiers
  end

  @tag with_features: Apiary.Features.all()
  test "on: a bad model id is refused under its tier, and nothing is saved", ctx do
    %{conn: conn, scope: scope, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> form("#model-form", model_choice: %{key: key(litellm)}) |> render_change()
    tiers = %{@free_tiers | "balanced" => %{"model" => "bad id"}}
    lv |> form("#model-form", model_choice: %{tiers: tiers}) |> render_change()
    lv |> form("#model-form") |> render_submit()

    assert has_element?(
             lv,
             "#model_choice_tiers_balanced_model-error",
             "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."
           )

    assert has_element?(
             lv,
             ~s{#model_choice_tiers_balanced_model[value="bad id"][aria-invalid="true"]}
           )

    refute has_element?(lv, "#model-tiers-error-0")
    assert choice(scope) == nil
  end

  @tag with_features: Apiary.Features.all()
  test "on: each bad model id is refused under its tier's field", ctx do
    %{conn: conn, scope: scope, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    rule =
      "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."

    lv |> form("#model-form", model_choice: %{key: key(litellm)}) |> render_change()

    tiers = %{
      @free_tiers
      | "thinking" => %{"model" => "bad thinking"},
        "balanced" => %{"model" => "bad balanced"}
    }

    lv |> form("#model-form", model_choice: %{tiers: tiers}) |> render_change()
    lv |> form("#model-form") |> render_submit()

    for tier <- ~w(thinking balanced) do
      assert has_element?(lv, "#model_choice_tiers_#{tier}_model-error", rule)
      assert has_element?(lv, ~s{#model_choice_tiers_#{tier}_model[aria-invalid="true"]})
    end

    refute has_element?(lv, "#model_choice_tiers_thinking_model-error-2")
    refute has_element?(lv, "#model_choice_tiers_light_model-error")
    refute has_element?(lv, "#model-tiers-error-0")
    assert choice(scope) == nil
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: a saved LiteLLM choice lists only its key of LiteLLM", ctx do
    %{conn: conn, scope: scope, litellm: litellm} = ctx

    {:ok, _provider} =
      Connections.add_provider_key(scope, litellm, %{
        value_id: "second",
        value: "sk-model-proxies-second-0123456789"
      })

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: litellm.public_id,
        key: "main",
        tiers: @free_tiers
      })

    {:ok, lv, _html} = live(conn, path(scope))

    assert in_key?(lv, litellm)

    refute has_element?(
             lv,
             ~s{#model-form input[name="model_choice[key]"][value="#{litellm.public_id}/second"]}
           )
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: a saved LiteLLM choice shows its key and tiers, a save keeps it, and no row offers it",
       ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: litellm.public_id,
        key: "main",
        tiers: @free_tiers
      })

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model-form input[name="model_choice[key]"][value="#{key(litellm)}"][checked]}
           )

    assert has_element?(lv, "button#model_choice_key", "#{litellm.name} · main")
    assert has_element?(lv, ~s{#model_choice_tiers_thinking_model[value="claude-opus-5-5"]})

    lv |> form("#model-form") |> render_submit()
    assert has_element?(lv, "#flash-info", "Model saved.")
    assert %ModelChoice{tiers: @free_tiers} = saved = choice(scope)
    assert saved.connection_id == litellm.id

    # A fallback row is offered Anthropic, not LiteLLM, the Key's provider.
    lv |> element("#model-fallback-add") |> render_click()

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
           )

    # Choosing Anthropic for Key takes LiteLLM out of the page's offers.
    lv |> form("#model-form", model_choice: %{key: key(anthropic)}) |> render_change()

    refute has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{litellm.public_id}"]}
           )
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: a saved LiteLLM fallback stays in its row, and a save keeps it", ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: anthropic.public_id,
        fallbacks: [%{provider: litellm.public_id, model: "claude-opus-5-5"}]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{litellm.public_id}"][selected]}
           )

    assert has_element?(lv, ~s{#model_choice_fallbacks_0_other[value="claude-opus-5-5"]})

    lv |> form("#model-form") |> render_submit()
    assert has_element?(lv, "#flash-info", "Model saved.")

    saved = scope |> choice() |> Repo.preload(fallbacks: :connection)

    assert [{litellm.id, "claude-opus-5-5"}] ==
             for(f <- saved.fallbacks, do: {f.connection_id, f.model_id})
  end
end
