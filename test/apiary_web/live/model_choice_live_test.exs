defmodule ApiaryWeb.ModelChoiceLiveTest do
  # Workspace settings › Model (`ApiaryWeb.ModelChoiceLive`): Provider, the tiers of the
  # provider (`ApiaryWeb.ModelTiers`), Runtime, Save once every tier has a model, each
  # refusal under its field, who may save, the fallbacks with their tiers and runtime, a
  # provider that works with no runtime, and a saved choice that a run's settings then
  # use.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Repo}
  alias Apiary.Kinds.Runtimes
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.ModelChoicesFixtures

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

  # The models of `tiers`, with no effort.
  defp models_only(tiers),
    do: Map.new(tiers, fn {tier, set} -> {tier, %{"model" => set["model"]}} end)

  # A subscription's key is the sign-in that `codex login` writes (`Apiary.ModelKeys.Login`).
  defp openai_key("openai-subscription" = kind),
    do: %{
      provider: kind,
      keys: [%{value_id: "main", value: Apiary.ModelKeysFixtures.device_login()}]
    }

  defp openai_key(kind),
    do: %{provider: kind, keys: [%{value_id: "main", value: "sk-#{kind}-model-page-0123456789"}]}

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

  test "has Default models: Provider, each provider by its name, and the tiers", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(lv, "h1", "Model")
    assert has_element?(lv, ~s{#settings-tab-model[aria-current="page"]})
    assert has_element?(lv, "#model-default-title", "Default models")

    assert has_element?(
             lv,
             "#model-default-line",
             "Runs use this provider and these models when their workflow sets none."
           )

    assert has_element?(lv, "aside#page-context > h2#page-context-h", ~r/\AAbout models\z/)
    refute has_element?(lv, ".q-settings-head-sub")

    assert has_element?(
             lv,
             "#page-context #model-line",
             "The models runs in #{scope.workspace.name} use: one provider, and a model and an effort for each tier. A workflow can choose another provider and models in its settings on the Workflows page. If #{scope.workspace.name} sets none, its runs use the models of #{scope.organisation.name}."
           )

    # Provider is a choice with no search, its one provider chosen, by its name alone.
    assert has_element?(lv, "button#model_choice_provider .q-pick-t", provider.name)
    refute has_element?(lv, "button#model_choice_provider", "·")
    refute has_element?(lv, "#model_choice_provider-search")
    refute has_element?(lv, "#model_choice_key")

    assert has_element?(
             lv,
             ~s{#model_choice_provider-options input[name="model_choice[provider]"][value="#{provider.public_id}"][checked]}
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
        "provider" => ctx.provider.public_id,
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

  test "a save writes the provider, each tier, and the Thinking tier as the choice's model",
       ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

    assert render(lv) =~ "Model saved."

    assert %ModelChoice{model_id: "claude-opus-5-5", effort: "high"} = saved = choice(scope)
    assert saved.connection_id == provider.id
    assert saved_tiers(scope) == @tiers
  end

  test "opened again, the page shows the saved provider and tiers", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))
    lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

    {:ok, again, _html} = live(conn, path(scope))

    assert has_element?(
             again,
             ~s{#model_choice_provider-options input[value="#{provider.public_id}"][checked]}
           )

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

  test "with two providers, Provider lists each by its name; another provider empties the tiers",
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
      |> LazyHTML.query("#model_choice_provider-options .q-pick-t")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert Enum.sort(titles) == Enum.sort([provider.name, second.name])

    set_tiers(lv, @tiers)
    lv |> form("#model-form", model_choice: %{provider: second.public_id}) |> render_change()

    assert has_element?(
             lv,
             ~s{#model_choice_provider-options input[value="#{second.public_id}"][checked]}
           )

    assert has_element?(lv, "button#model_choice_provider .q-pick-t", second.name)

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

    # Saved, the choice stores the provider.
    first_tiers = Map.new(Map.keys(@tiers), &{&1, %{"model" => first.id}})
    lv |> set_tiers(first_tiers) |> form("#model-form") |> render_submit()
    assert choice(scope).connection_id == second.id
  end

  test "a provider deleted while the page is open: the refusal shows under Provider, and nothing is saved",
       ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))
    set_tiers(lv, @tiers)

    {:ok, _provider} = Connections.delete_provider(scope, provider)
    lv |> form("#model-form") |> render_submit()

    assert has_element?(lv, "#model_choice_provider-error", "is invalid")
    refute has_element?(lv, "#model-tiers [id$='-error']")
    assert choice(scope) == nil
  end

  test "a refused tier effort shows under that tier's Effort", ctx do
    %{conn: conn, scope: scope} = ctx

    # The runtime's effort values no longer have the stored one: the page keeps a
    # stored effort, and the save refuses it.
    {:ok, _choice} =
      ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: ctx.provider.public_id,
        tiers: @tiers
      })

    release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
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
      ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: %{
          @tiers
          | "thinking" => %{"model" => "claude-sonnet-5-5", "effort" => "low"},
            "balanced" => %{"model" => "claude-sonnet-5-5", "effort" => "high"}
        }
      })

    # The runtime no longer offers Balanced's stored effort.
    release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
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
      ModelChoicesFixtures.put_choice(scope, :workspace, %{
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

  test "a forged provider is refused under Provider, and nothing is saved", ctx do
    %{conn: conn, scope: scope} = ctx
    %{scope: other} = sign_up_fixture()

    {:ok, foreign} =
      Connections.create_provider(other, %{
        provider: "anthropic",
        keys: [%{value_id: "key-1", value: "sk-ant-model-page-foreign-0123456789"}]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    for forged <- [foreign.public_id, "x"] do
      render_hook(lv, "save", %{"model_choice" => %{"provider" => forged, "tiers" => @tiers}})
      assert has_element?(lv, "#model_choice_provider-error", "is invalid")
      assert choice(scope) == nil
    end
  end

  test "a member sees the fields disabled, no Save, and who changes them", ctx do
    %{scope: scope} = ctx
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

    assert has_element?(lv, "#model_choice_provider[disabled]")
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

  # A fallback as a save sends it: of `provider`, with `tiers`, every tier on the
  # provider's default model where nil, on the runtime named `runtime`, the catalogue's
  # default where nil.
  defp fallback(provider, tiers \\ nil, runtime \\ nil),
    do: %{
      provider: provider.public_id,
      runtime: runtime || ModelChoices.default_runtime().name,
      tiers: tiers || ModelChoicesFixtures.every_tier(provider)
    }

  # Sets each tier of the fallback row at `index`, as `set_tiers/2` sets the choice's.
  defp set_row_tiers(lv, index, tiers) do
    models = Map.new(tiers, fn {tier, set} -> {tier, %{model: set["model"]}} end)

    lv
    |> form("#model-form", model_choice: %{fallbacks: %{"#{index}" => %{tiers: models}}})
    |> render_change()

    efforts =
      for {tier, %{"effort" => effort}} <- tiers, effort not in ["", nil], into: %{} do
        {tier, %{effort: effort}}
      end

    if efforts != %{},
      do:
        lv
        |> form("#model-form", model_choice: %{fallbacks: %{"#{index}" => %{tiers: efforts}}})
        |> render_change()

    lv
  end

  defp add_provider(scope, kind),
    do:
      Connections.create_provider(scope, %{
        provider: kind,
        keys: [%{value_id: "main", value: "sk-#{kind}-model-page-0123456789"}]
      })

  # The workspace choice's fallbacks, in their order: each its position, its provider's
  # public id, its runtime and its tiers.
  defp fallbacks(scope) do
    choice = scope |> choice() |> Repo.preload(fallbacks: :connection)

    choice.fallbacks
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&{&1.position, &1.connection.public_id, &1.runtime, &1.tiers})
  end

  describe "Fallbacks" do
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
               "Add another model provider in Organisation settings › Model providers, then add it here as a fallback."
             )
    end

    test "Add fallback adds a row of a provider left with empty tiers; another provider empties them again",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")
      {:ok, lv, _html} = live(conn, path(scope))

      set_tiers(lv, @tiers)
      refute has_element?(lv, "#model-submit[disabled]")

      lv |> element("#model-fallback-add") |> render_click()

      # The first provider left, by its name; the chosen provider is not offered.
      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{subscription.public_id}"][selected]},
               subscription.name
             )

      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{provider.public_id}"]}
             )

      # Its tiers start empty, so Save waits for them.
      assert has_element?(lv, "#model-fallback-0-tiers-h", "Model and effort per tier")

      for tier <- ~w(thinking balanced light) do
        assert has_element?(
                 lv,
                 ~s{select#model_choice_fallbacks_0_tiers_#{tier}_model[name="model_choice[fallbacks][0][tiers][#{tier}][model]"] option[value=""][selected]}
               )

        assert has_element?(lv, "#model_choice_fallbacks_0_tiers_#{tier}_effort[disabled]")
      end

      assert has_element?(lv, "#model-submit[disabled]")

      set_row_tiers(lv, 0, @tiers)
      refute has_element?(lv, "#model-submit[disabled]")

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_effort option[value="high"][selected]}
             )

      # A second row takes the last provider left; no provider is left to add.
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_provider option[value="#{deepseek.public_id}"][selected]}
             )

      assert has_element?(lv, "#model-submit[disabled]")
      refute has_element?(lv, "#model-fallback-add")
      assert has_element?(lv, "#model-fallback-none")

      # A row offers the providers no other row has.
      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{deepseek.public_id}"]}
             )

      lv |> element("#model-fallback-1-remove") |> render_click()
      refute has_element?(lv, "#model-submit[disabled]")

      # Another provider for the row: its tiers are empty again, with that provider's
      # models.
      lv
      |> form("#model-form",
        model_choice: %{fallbacks: %{"0" => %{provider: deepseek.public_id}}}
      )
      |> render_change()

      first = deepseek |> ModelChoices.suggestions(ModelChoices.default_runtime()) |> hd()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_model option[value=""][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_model option[value="#{first.id}"]}
             )

      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_model option[value="claude-opus-5-5"]}
             )

      assert has_element?(lv, "#model-submit[disabled]")
    end

    test "Save keeps the rows in their order with their runtime and tiers; Move up, Move down and Remove change them",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")
      runtime = ModelChoices.default_runtime().name
      subscription_tiers = ModelChoicesFixtures.every_tier(subscription)
      deepseek_tiers = ModelChoicesFixtures.every_tier(deepseek)

      # Every tier on the provider's default model, with no effort.
      {:ok, _} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{provider: provider.public_id})

      {:ok, lv, _html} = live(conn, path(scope))

      lv |> element("#model-fallback-add") |> render_click()
      lv |> element("#model-fallback-add") |> render_click()
      set_row_tiers(lv, 0, subscription_tiers)
      set_row_tiers(lv, 1, deepseek_tiers)

      assert has_element?(lv, "#model-fallback-0-up[disabled]")
      assert has_element?(lv, "#model-fallback-1-down[disabled]")
      assert has_element?(lv, ~s{#model-fallback-1-up[aria-label="Move fallback 2 up"]})

      lv |> element("#model-fallback-1-up") |> render_click()
      lv |> form("#model-form") |> render_submit()

      assert fallbacks(scope) == [
               {0, deepseek.public_id, runtime, deepseek_tiers},
               {1, subscription.public_id, runtime, subscription_tiers}
             ]

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{deepseek.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_light_model option[value="#{deepseek_tiers["light"]["model"]}"][selected]}
             )

      lv |> element("#model-fallback-0-down") |> render_click()
      lv |> form("#model-form") |> render_submit()
      assert [{0, sub_id, _, _}, {1, ds_id, _, _}] = fallbacks(scope)
      assert {sub_id, ds_id} == {subscription.public_id, deepseek.public_id}

      lv |> element("#model-fallback-0-remove") |> render_click()
      refute has_element?(lv, "#model-fallback-1")
      lv |> form("#model-form") |> render_submit()
      assert fallbacks(scope) == [{0, deepseek.public_id, runtime, deepseek_tiers}]
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
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          fallbacks: [fallback(subscription), fallback(deepseek)]
        })

      {:ok, lv, _html} = live(conn, path(scope))

      # The Provider becomes the first row's.
      lv
      |> form("#model-form", model_choice: %{provider: subscription.public_id})
      |> render_change()

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert has_element?(lv, "#flash-info", "Model saved.")
      assert choice(scope).connection_id == subscription.id

      assert fallbacks(scope) == [
               {0, deepseek.public_id, ModelChoices.default_runtime().name,
                ModelChoicesFixtures.every_tier(deepseek)}
             ]
    end

    test "a refused row tier shows under that row's field, and nothing is saved", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, deepseek} = add_provider(scope, "deepseek")

      high = %{
        "thinking" => %{"model" => "claude-sonnet-5-5", "effort" => "high"},
        "balanced" => %{"model" => "claude-sonnet-5-5"},
        "light" => %{"model" => "claude-haiku-5-5"}
      }

      {:ok, stored} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: deepseek.public_id,
          fallbacks: [fallback(subscription), fallback(provider, high)]
        })

      # The runtime no longer offers the second row's stored effort: the row keeps it
      # shown, and the save refuses it.
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      :ok = Runtimes.put_test_list([%{release | effort_values: ~w(low medium)}])
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_tiers_thinking_effort option[value="high"][selected]}
             )

      # The first row's provider is chosen, so that row is dropped; the second row's
      # refusal shows under the second row.
      lv
      |> form("#model-form", model_choice: %{provider: subscription.public_id})
      |> render_change()

      lv |> set_tiers(models_only(@tiers)) |> form("#model-form") |> render_submit()

      assert has_element?(
               lv,
               "#model_choice_fallbacks_1_tiers_thinking_effort-error",
               "Choose one of claude-sonnet-5-5's effort values: low, medium."
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_tiers_thinking_effort[aria-invalid="true"]}
             )

      refute has_element?(lv, "#model_choice_fallbacks_0_provider-error")
      refute has_element?(lv, "#model_choice_fallbacks_0_tiers_thinking_effort-error")
      refute has_element?(lv, "#flash-info")

      again = choice(scope)
      assert again.connection_id == deepseek.id
      assert again.updated_at == stored.updated_at
    end

    test "a provider in two rows shows the error under the second row, and nothing is saved",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")
      {:ok, _deepseek} = add_provider(scope, "deepseek")
      {:ok, lv, _html} = live(conn, path(scope))

      set_tiers(lv, @tiers)
      lv |> element("#model-fallback-add") |> render_click()
      lv |> element("#model-fallback-add") |> render_click()

      # Both rows sent with the first row's provider, as no row's Provider offers it.
      rows = fn tiers ->
        for i <- ["0", "1"],
            into: %{},
            do: {i, %{"provider" => subscription.public_id, "tiers" => tiers}}
      end

      render_hook(lv, "choose", %{"model_choice" => %{"fallbacks" => rows.(%{})}})
      render_hook(lv, "choose", %{"model_choice" => %{"fallbacks" => rows.(models_only(@tiers))}})
      render_hook(lv, "save", %{"model_choice" => %{"fallbacks" => rows.(%{})}})

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
      set_row_tiers(lv, 0, @tiers)
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
          "provider" => provider.public_id,
          "tiers" => @tiers,
          "fallbacks" => %{"0" => %{"provider" => subscription.public_id, "tiers" => @tiers}}
        }
      })

      assert choice(scope) == nil
    end

    test "a sent row with another organisation's provider is refused under its Provider, and nothing is saved",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, _subscription} = add_provider(scope, "claude-subscription")
      %{scope: other} = sign_up_fixture()
      {:ok, foreign} = add_provider(other, "claude-subscription")
      {:ok, lv, _html} = live(conn, path(scope))

      set_tiers(lv, @tiers)
      lv |> element("#model-fallback-add") |> render_click()
      set_row_tiers(lv, 0, @tiers)

      render_hook(lv, "save", %{
        "model_choice" => %{
          "fallbacks" => %{"0" => %{"provider" => foreign.public_id, "tiers" => @tiers}}
        }
      })

      assert has_element?(
               lv,
               "#model_choice_fallbacks_0_provider-error",
               "Choose another provider for this fallback: its provider no longer exists in " <>
                 "this organisation."
             )

      assert choice(scope) == nil
      refute fallbacks_of_provider?(other, foreign)
    end

    test "a member sees the rows disabled, and no button to change them", ctx do
      %{scope: scope, provider: provider} = ctx
      {:ok, subscription} = add_provider(scope, "claude-subscription")

      {:ok, _} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          fallbacks: [fallback(subscription)]
        })

      %{user: user} = member_fixture(scope, :member)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      assert has_element?(lv, "#model_choice_fallbacks_0_provider[disabled]")
      assert has_element?(lv, "#model_choice_fallbacks_0_tiers_thinking_model[disabled]")
      refute has_element?(lv, "#model-fallback-0-remove")
      refute has_element?(lv, "#model-fallback-add")
      refute has_element?(lv, "#model-fallback-none")
    end

    test "every tier of a row needs a model: Save waits, and a save with a tier left out is refused under it",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, _subscription} = add_provider(scope, "claude-subscription")
      {:ok, lv, _html} = live(conn, path(scope))

      set_tiers(lv, @tiers)
      lv |> element("#model-fallback-add") |> render_click()
      set_row_tiers(lv, 0, Map.take(@tiers, ["thinking", "balanced"]))
      assert has_element?(lv, "#model-submit[disabled]")

      # A save sent all the same.
      render_hook(lv, "save", %{"model_choice" => %{}})

      assert has_element?(
               lv,
               "#model_choice_fallbacks_0_tiers_light_model-error",
               "Choose a model for each tier: Light has none."
             )

      assert choice(scope) == nil

      set_row_tiers(lv, 0, Map.take(@tiers, ["light"]))
      refute has_element?(lv, "#model-submit[disabled]")
    end
  end

  describe "the runtime" do
    # The release's runtime, and a copy of it with a name of its own that reads a key
    # only from the bearer variable: Anthropic (an `x-api-key` header) serves the first
    # alone, OpenRouter (bearer) serves both.
    defp two_runtimes do
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))

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

    # A second OpenRouter provider, named "OpenRouter team".
    defp openrouter_team(scope) do
      {:ok, team} =
        Connections.create_provider(scope, %{
          name: "OpenRouter team",
          provider: "openrouter",
          keys: [%{value_id: "team", value: "sk-or-model-page-team-0123456789"}]
        })

      team
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
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
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

    defp choose_provider(lv, value),
      do: lv |> form("#model-form", model_choice: %{provider: value}) |> render_change()

    defp choose_runtime(lv, name),
      do: lv |> form("#model-form", model_choice: %{runtime: name}) |> render_change()

    defp choose_row_runtime(lv, index, name),
      do:
        lv
        |> form("#model-form", model_choice: %{fallbacks: %{"#{index}" => %{runtime: name}}})
        |> render_change()

    test "with one runtime of the catalogue, is its name as text; the choice names none",
         ctx do
      %{conn: conn, scope: scope} = ctx
      release = Enum.find(Runtimes.list(), &(&1.name == "claude"))
      :ok = Runtimes.put_test_list([release])
      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      assert has_element?(
               lv,
               "#model-runtime-line",
               "#{release.title} is the only runtime that works with Anthropic API key."
             )

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: nil, model_id: "claude-opus-5-5"} = choice(scope)
    end

    test "with the release's two runtimes, an OpenAI provider runs on Codex with its models and efforts",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, openai} = Connections.create_provider(scope, openai_key("openai"))
      {:ok, subscription} = Connections.create_provider(scope, openai_key("openai-subscription"))

      {:ok, lv, _html} = live(conn, path(scope))

      # Anthropic works with Claude Code alone, and OpenAI with Codex alone.
      assert has_element?(lv, "#model-runtime-name", "Claude Code")
      choose_provider(lv, openai.public_id)
      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", "Codex")

      assert has_element?(
               lv,
               "#model-runtime-line",
               "Codex is the only runtime that works with OpenAI API key."
             )

      codex = Runtimes.list() |> Enum.find(&(&1.name == "codex"))

      assert [
               %{id: "gpt-6-astra", effort: ~w(low medium high xhigh max)},
               %{id: "gpt-6-luna", effort: ~w(none low medium high xhigh max)} | _
             ] = ModelChoices.suggestions(openai, codex)

      assert [%{id: "gpt-6.1-sol", effort: ~w(low medium high xhigh max ultra)} | _] =
               ModelChoices.suggestions(subscription, codex)

      tiers = Map.new(Map.keys(@tiers), &{&1, %{"model" => "gpt-6-luna", "effort" => "none"}})
      lv |> set_tiers(tiers) |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: "codex", model_id: "gpt-6-luna", effort: "none"} =
               choice(scope)

      assert saved_tiers(scope) == tiers
    end

    test "comes after the tiers and before the fallbacks", ctx do
      %{conn: conn, scope: scope} = ctx
      {:ok, _lv, html} = live(conn, path(scope))

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(
          "#model_choice_provider, #model-tiers, #model-runtime, #model-fallbacks"
        )
        |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))

      assert ids == ["model_choice_provider", "model-tiers", "model-runtime", "model-fallbacks"]
    end

    test "one runtime fits the provider: its name as text, no select", ctx do
      %{conn: conn, scope: scope} = ctx
      {release, _bearer} = two_runtimes()
      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      assert has_element?(
               lv,
               "#model-runtime-line",
               "#{release.title} is the only runtime that works with Anthropic API key."
             )

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()

      assert %ModelChoice{runtime: name} = choice(scope)
      assert name == release.name
    end

    test "several fit: a select, set to the stored runtime, and a line with the provider's title",
         ctx do
      %{conn: conn, scope: scope} = ctx
      {release, bearer} = two_runtimes()

      {:ok, openrouter} =
        Connections.create_provider(scope, %{
          name: "Router of the team",
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-model-page-0123456789"}]
        })

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
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
               "These runtimes work with OpenRouter."
             )

      refute has_element?(lv, "#model-runtime-line", openrouter.name)
    end

    test "Provider lists every provider, whichever runtime is chosen", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {_release, bearer} = two_runtimes()
      openrouter = openrouter(scope)

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: openrouter_tiers(openrouter)
        })

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{provider.public_id}"]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{openrouter.public_id}"][checked]}
             )
    end

    test "a change of Provider keeps the runtime the new provider serves, else takes its first",
         ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      # Anthropic serves the release's runtime alone.
      assert has_element?(lv, "#model-runtime-name", release.title)

      # OpenRouter serves it too: it stays, the first of the two in any case.
      choose_provider(lv, openrouter.public_id)
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{release.name}"][selected]})

      # OpenRouter's second runtime, then back to Anthropic, which does not serve it.
      choose_runtime(lv, bearer.name)
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{bearer.name}"][selected]})

      choose_provider(lv, provider.public_id)
      refute has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, "#model-runtime-name", release.title)

      lv |> set_tiers(@tiers) |> form("#model-form") |> render_submit()
      assert %ModelChoice{runtime: name} = choice(scope)
      assert name == release.name
    end

    test "a change of Provider to a provider that serves the chosen runtime keeps it", ctx do
      %{conn: conn, scope: scope} = ctx
      {_release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      team = openrouter_team(scope)

      {:ok, lv, _html} = live(conn, path(scope))
      choose_provider(lv, openrouter.public_id)
      choose_runtime(lv, bearer.name)
      choose_provider(lv, team.public_id)

      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{bearer.name}"][selected]})
    end

    test "a change of the runtime keeps the models and takes back an effort it refuses", ctx do
      %{conn: conn, scope: scope} = ctx
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))

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
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      narrow = %{release | name: release.name <> "-narrow", effort_values: ~w(low medium)}

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
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

    test "a row's Runtime: its name where one runtime fits its provider, else a select; a save stores each row's runtime and tiers",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      team = openrouter_team(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      choose_provider(lv, openrouter.public_id)
      set_tiers(lv, openrouter_tiers(openrouter))
      lv |> element("#model-fallback-add") |> render_click()
      lv |> element("#model-fallback-add") |> render_click()

      # Anthropic serves the release's runtime alone: its name as text, and a hidden field.
      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
             )

      refute has_element?(lv, "#model_choice_fallbacks_0_runtime")
      assert has_element?(lv, "#model-fallback-0-runtime-name", release.title)

      assert has_element?(
               lv,
               "#model-fallback-0-runtime-line",
               "#{release.title} is the only runtime that works with Anthropic API key."
             )

      assert has_element?(
               lv,
               ~s{#model-fallback-0-runtime input[type=hidden][name="model_choice[fallbacks][0][runtime]"][value="#{release.name}"]}
             )

      # OpenRouter team serves both: a select, with the line of the provider's title.
      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_provider option[value="#{team.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{select#model_choice_fallbacks_1_runtime[name="model_choice[fallbacks][1][runtime]"] option[value="#{release.name}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_runtime option[value="#{bearer.name}"]}
             )

      assert has_element?(
               lv,
               "#model-fallback-1-runtime-line",
               "These runtimes work with OpenRouter."
             )

      refute has_element?(lv, "#model-fallback-1-runtime-line", team.name)

      set_row_tiers(lv, 0, @tiers)
      set_row_tiers(lv, 1, openrouter_tiers(openrouter))
      choose_row_runtime(lv, 1, bearer.name)
      lv |> form("#model-form") |> render_submit()

      assert has_element?(lv, "#flash-info", "Model saved.")
      assert choice(scope).runtime == release.name

      assert fallbacks(scope) == [
               {0, anthropic.public_id, release.name, @tiers},
               {1, team.public_id, bearer.name, openrouter_tiers(openrouter)}
             ]

      # Opened again: each stored row shows its stored runtime.
      {:ok, lv, _html} = live(conn, path(scope))
      assert has_element?(lv, "#model-fallback-0-runtime-name", release.title)

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_runtime option[value="#{bearer.name}"][selected]}
             )

      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{release.name}"][selected]})
    end

    test "a new row starts on the main runtime where its provider serves it, else on the first that fits, and lists a provider that does not serve the main runtime",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {release, bearer} = two_runtimes()
      openrouter = openrouter(scope)
      team = openrouter_team(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      choose_provider(lv, openrouter.public_id)
      choose_runtime(lv, bearer.name)
      set_tiers(lv, openrouter_tiers(openrouter))
      lv |> element("#model-fallback-add") |> render_click()

      # Anthropic does not serve the main runtime, and is offered all the same: its row
      # starts on the release's runtime, the one it serves.
      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
             )

      assert has_element?(lv, "#model-fallback-0-runtime-name", release.title)

      # OpenRouter team serves the main runtime: its row starts on it.
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_provider option[value="#{team.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_1_runtime option[value="#{bearer.name}"][selected]}
             )

      # No line says a row does not fit, and Save waits only for the rows' tiers.
      set_row_tiers(lv, 0, @tiers)
      set_row_tiers(lv, 1, openrouter_tiers(openrouter))
      refute has_element?(lv, "#model-fallback-0-unfit")
      refute render(lv) =~ "remove this fallback"
      refute has_element?(lv, "#model-submit[disabled]")

      lv |> form("#model-form") |> render_submit()
      assert has_element?(lv, "#flash-info", "Model saved.")
      assert choice(scope).runtime == bearer.name

      assert [{0, _anthropic, first, _}, {1, _team, second, _}] = fallbacks(scope)
      assert {first, second} == {release.name, bearer.name}
    end

    test "a change of Provider that moves the main runtime leaves each row on its runtime",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {header, bearer} = split_runtimes()
      openrouter = openrouter(scope)
      team = openrouter_team(scope)
      {:ok, lv, _html} = live(conn, path(scope))

      # OpenRouter serves the bearer runtime alone.
      choose_provider(lv, openrouter.public_id)
      assert has_element?(lv, "#model-runtime-name", bearer.title)
      lv |> element("#model-fallback-add") |> render_click()

      lv
      |> form("#model-form", model_choice: %{fallbacks: %{"0" => %{provider: team.public_id}}})
      |> render_change()

      assert has_element?(lv, "#model-fallback-0-runtime-name", bearer.title)

      # Anthropic serves the header runtime alone: the main runtime moves to it, and the
      # row of OpenRouter team stays on the bearer runtime, with no line.
      choose_provider(lv, anthropic.public_id)
      assert has_element?(lv, "#model-runtime-name", header.title)
      assert has_element?(lv, "#model-fallback-0-runtime-name", bearer.title)
      refute has_element?(lv, "#model-fallback-0-unfit")

      set_tiers(lv, @tiers)
      set_row_tiers(lv, 0, openrouter_tiers(openrouter))
      refute has_element?(lv, "#model-submit[disabled]")
      lv |> form("#model-form") |> render_submit()

      assert has_element?(lv, "#flash-info", "Model saved.")
      assert %ModelChoice{runtime: main} = saved = choice(scope)
      assert {saved.connection_id, main} == {anthropic.id, header.name}
      assert [{0, team_id, runtime, _tiers}] = fallbacks(scope)
      assert {team_id, runtime} == {team.public_id, bearer.name}
    end

    test "a change of a row's Runtime keeps its models and takes back an effort that runtime refuses",
         ctx do
      %{conn: conn, scope: scope} = ctx
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      narrow = %{
        release
        | name: release.name <> "-narrow",
          title: release.title <> " narrow",
          effort_values: ~w(low medium)
      }

      :ok = Runtimes.put_test_list([release, narrow])
      openrouter = openrouter(scope)

      row_tiers = %{
        "thinking" => %{"model" => "anthropic/claude-opus-5.5", "effort" => "high"},
        "balanced" => %{"model" => "anthropic/claude-sonnet-5.5", "effort" => "medium"},
        "light" => %{"model" => "anthropic/claude-haiku-5.5", "effort" => "low"}
      }

      {:ok, lv, _html} = live(conn, path(scope))
      set_tiers(lv, @tiers)
      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{openrouter.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_runtime option[value="#{release.name}"][selected]}
             )

      set_row_tiers(lv, 0, row_tiers)
      choose_row_runtime(lv, 0, narrow.name)

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_runtime option[value="#{narrow.name}"][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_model option[value="anthropic/claude-opus-5.5"][selected]}
             )

      refute has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_effort option[value="high"]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_thinking_effort option[value=""][selected]}
             )

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_tiers_balanced_effort option[value="medium"][selected]}
             )

      # The main choice keeps its runtime and its efforts.
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{release.name}"][selected]})

      assert has_element?(
               lv,
               ~s{#model_choice_tiers_thinking_effort option[value="high"][selected]}
             )

      lv |> form("#model-form") |> render_submit()

      assert fallbacks(scope) == [
               {0, openrouter.public_id, narrow.name,
                %{row_tiers | "thinking" => %{"model" => "anthropic/claude-opus-5.5"}}}
             ]

      assert choice(scope).runtime == release.name
    end
  end

  describe "a provider that works with no runtime" do
    # The catalogue has only a bearer runtime, which Anthropic (an `x-api-key` header)
    # does not serve and OpenRouter does.
    defp bearer_only do
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Runtimes.put_test_list([bearer])
      bearer
    end

    test "is listed; chosen, a line under Provider says to pick another, and Save writes nothing",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      openrouter = openrouter(scope)
      bearer = bearer_only()
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{anthropic.public_id}"]}
             )

      choose_provider(lv, anthropic.public_id)

      assert has_element?(
               lv,
               "#model-provider-unfit",
               "Anthropic API key works with no runtime in this version of Qory Apiary. Pick another provider."
             )

      refute has_element?(lv, "#model-runtime")

      render_hook(lv, "save", %{
        "model_choice" => %{"provider" => anthropic.public_id, "tiers" => @tiers}
      })

      assert choice(scope) == nil
      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#model_choice_provider-error")

      # Another provider: the line goes.
      choose_provider(lv, openrouter.public_id)
      refute has_element?(lv, "#model-provider-unfit")
      assert has_element?(lv, "#model-runtime-name", bearer.title)
    end

    test "names the provider by its catalogue title, not by its name", ctx do
      %{conn: conn, scope: scope} = ctx

      {:ok, named} =
        Connections.create_provider(scope, %{
          name: "Team key",
          provider: "deepseek",
          keys: [%{value_id: "main", value: "sk-deepseek-model-page-0123456789"}]
        })

      _bearer = bearer_only()
      {:ok, lv, _html} = live(conn, path(scope))
      choose_provider(lv, named.public_id)

      assert has_element?(
               lv,
               "#model-provider-unfit",
               "DeepSeek works with no runtime in this version of Qory Apiary. Pick another provider."
             )
    end
  end

  describe "a saved choice whose provider no longer fits" do
    # A second provider, OpenRouter, that fits, so the page has another provider it could
    # have chosen in place of the saved one.
    defp saved_anthropic(scope, provider) do
      {:ok, openrouter} =
        Connections.create_provider(scope, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "sk-or-model-page-0123456789"}]
        })

      {:ok, choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: provider.public_id,
          tiers: @tiers
        })

      {openrouter, choice}
    end

    test "keeps its provider, with the line under Provider that it works with no runtime; Save writes nothing",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {openrouter, choice} = saved_anthropic(scope, anthropic)

      # The catalogue now has only a bearer runtime, which Anthropic does not serve.
      _bearer = bearer_only()
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{anthropic.public_id}"][checked]}
             )

      refute has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{openrouter.public_id}"][checked]}
             )

      assert has_element?(
               lv,
               "#model-provider-unfit",
               "Anthropic API key works with no runtime in this version of Qory Apiary. Pick another provider."
             )

      refute has_element?(lv, "#model-runtime")

      lv |> form("#model-form") |> render_submit()
      again = choice(scope)
      assert again.connection_id == anthropic.id
      assert again.updated_at == choice.updated_at
      assert has_element?(lv, "#model-provider-unfit")
      refute has_element?(lv, "#model_choice_provider-error")

      # Another provider picked: the line goes.
      choose_provider(lv, openrouter.public_id)
      refute has_element?(lv, "#model-provider-unfit")
    end

    test "keeps its provider when its settings no longer fit, with that line under Provider; Save writes nothing",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      {openrouter, choice} = saved_anthropic(scope, anthropic)

      # Coded again, as a save codes it, so the row passes its integrity code.
      Connections.Connection
      |> Repo.get!(anthropic.id)
      |> Ecto.Changeset.change(settings: ~s({"region":"eu"}))
      |> Apiary.Kinds.Coded.seal()
      |> Repo.update!()

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{anthropic.public_id}"][checked]}
             )

      refute has_element?(
               lv,
               ~s{#model_choice_provider-options input[value="#{openrouter.public_id}"][checked]}
             )

      assert has_element?(
               lv,
               "#model-provider-unfit",
               "Add #{anthropic.name} again in Organisation settings › Model providers: its settings no longer fit this version of Qory Apiary."
             )

      refute has_element?(lv, "#model-changed-#{anthropic.public_id}")

      lv |> form("#model-form") |> render_submit()
      again = choice(scope)
      assert again.connection_id == anthropic.id
      assert again.updated_at == choice.updated_at
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
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
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
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      :ok = Runtimes.put_test_list([unserved])
      %{user: user} = member_fixture(scope, :member)

      {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

      assert has_element?(lv, "#model-none", "Only owners and admins add model providers.")
      refute has_element?(lv, "#model-none a")
    end

    test "with two runtimes that no provider serves, says to add a provider", ctx do
      %{conn: conn, scope: scope} = ctx
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      other = %{unserved | name: release.name <> "-other", title: release.title <> " other"}
      :ok = Runtimes.put_test_list([unserved, other])

      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model-runtime")
      refute has_element?(lv, "#model-other_runtime")
      assert has_element?(lv, "#model-none")
    end
  end

  describe "a fallback row whose provider does not fit" do
    # Coded again, as a save codes it, so the row passes its integrity code.
    defp change_provider!(provider, changes) do
      Connections.Connection
      |> Repo.get!(provider.id)
      |> Ecto.Changeset.change(changes)
      |> Apiary.Kinds.Coded.seal()
      |> Repo.update!()
    end

    test "a provider that works with no runtime is listed; in a row, a line says to pick another, and Save writes nothing",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      openrouter = openrouter(scope)
      _bearer = bearer_only()
      {:ok, lv, _html} = live(conn, path(scope))
      choose_provider(lv, openrouter.public_id)

      lv |> element("#model-fallback-add") |> render_click()

      assert has_element?(
               lv,
               ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
             )

      assert has_element?(
               lv,
               "#model-fallback-0-line",
               "Anthropic API key works with no runtime in this version of Qory Apiary. Pick another provider."
             )

      refute has_element?(lv, "#model-fallback-0-tiers")
      refute has_element?(lv, "#model-fallback-0-runtime")
      assert has_element?(lv, "#model-submit[disabled]")

      # A save sent anyway writes nothing, and the line stays under the row's Provider.
      render_hook(lv, "save", %{
        "model_choice" => %{
          "provider" => openrouter.public_id,
          "tiers" => openrouter_tiers(openrouter),
          "fallbacks" => %{"0" => %{"provider" => anthropic.public_id, "tiers" => @tiers}}
        }
      })

      assert choice(scope) == nil
      refute has_element?(lv, "#flash-info")
      assert has_element?(lv, "#model-fallback-0-line")
    end

    test "a stored row whose provider no longer applies to the workspace says so under its Provider",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      openrouter = openrouter(scope)

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: anthropic.public_id,
          tiers: @tiers,
          fallbacks: [fallback(openrouter)]
        })

      change_provider!(openrouter, applies_to: "selected")
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               "#model-fallback-0-line",
               "Choose another provider: #{openrouter.name} is not used in this workspace."
             )

      refute has_element?(lv, "#model-fallback-0-tiers")
    end

    test "a stored row whose provider's settings no longer fit says to add it again", ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      openrouter = openrouter(scope)

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: anthropic.public_id,
          tiers: @tiers,
          fallbacks: [fallback(openrouter)]
        })

      change_provider!(openrouter, settings: ~s({"region":"eu"}))
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               "#model-fallback-0-line",
               "Add #{openrouter.name} again in Organisation settings › Model providers: its settings no longer fit this version of Qory Apiary."
             )

      refute has_element?(lv, "#model-fallback-0-tiers")
    end

    test "a refusal of a stored row's runtime shows under its Provider while the row shows no Runtime",
         ctx do
      %{conn: conn, scope: scope, provider: anthropic} = ctx
      openrouter = openrouter(scope)
      release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      second = %{release | name: release.name <> "-second", title: release.title <> " second"}
      :ok = Runtimes.put_test_list([release, second])

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(scope, :workspace, %{
          provider: anthropic.public_id,
          runtime: release.name,
          tiers: @tiers,
          fallbacks: [fallback(openrouter, nil, second.name)]
        })

      # The second runtime leaves the catalogue, and the row's provider the workspace.
      :ok = Runtimes.put_test_list([release])
      change_provider!(openrouter, applies_to: "selected")
      {:ok, lv, _html} = live(conn, path(scope))
      refute has_element?(lv, "#model-fallback-0-runtime")

      lv |> form("#model-form") |> render_submit()

      assert has_element?(
               lv,
               "#model_choice_fallbacks_0_provider-error",
               "Choose one of the offered runtimes: #{second.name} is not one of them."
             )

      refute has_element?(lv, "#flash-info")
    end
  end
end

defmodule ApiaryWeb.ModelChoiceLive.ModelProxiesTest do
  # Workspace settings › Model leaves out a provider whose description lists no models,
  # such as LiteLLM, from Provider and from a fallback row's Provider, unless the feature
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

  # Whether Provider has an option of `provider`.
  defp in_provider?(lv, provider) do
    has_element?(
      lv,
      ~s{#model-form input[name="model_choice[provider]"][value="#{provider.public_id}"]}
    )
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: Provider and a fallback row leave out LiteLLM", ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert in_provider?(lv, anthropic)
    refute in_provider?(lv, litellm)

    # Anthropic is chosen, and LiteLLM is the one provider left: no row to add.
    refute has_element?(lv, "#model-fallback-add")
    assert has_element?(lv, "#model-fallback-none")
  end

  @tag with_features: Apiary.Features.all() -- [:model_proxies]
  test "off: with LiteLLM the one provider, Provider is not shown and the page says to add one",
       ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, _provider} = Connections.delete_provider(scope, anthropic)
    {:ok, lv, _html} = live(conn, path(scope))

    refute in_provider?(lv, litellm)
    refute has_element?(lv, "#model_choice_provider")
    refute has_element?(lv, "#model-tiers")
    assert has_element?(lv, "#model-unserved #model-none")
    refute has_element?(lv, "#model-other_runtime")
  end

  @tag with_features: Apiary.Features.all()
  test "on: Provider and a fallback row offer LiteLLM", ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    assert in_provider?(lv, anthropic)
    assert in_provider?(lv, litellm)

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

    lv |> form("#model-form", model_choice: %{provider: litellm.public_id}) |> render_change()

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

    lv |> form("#model-form", model_choice: %{provider: litellm.public_id}) |> render_change()
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

    lv |> form("#model-form", model_choice: %{provider: litellm.public_id}) |> render_change()

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
  test "off: a saved LiteLLM choice shows its provider and tiers, a save keeps it, and no row offers it",
       ctx do
    %{conn: conn, scope: scope, anthropic: anthropic, litellm: litellm} = ctx

    {:ok, _choice} =
      Apiary.ModelChoicesFixtures.put_choice(scope, :workspace, %{
        provider: litellm.public_id,
        tiers: @free_tiers
      })

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model-form input[name="model_choice[provider]"][value="#{litellm.public_id}"][checked]}
           )

    assert has_element?(lv, "button#model_choice_provider", litellm.name)
    assert has_element?(lv, ~s{#model_choice_tiers_thinking_model[value="claude-opus-5-5"]})

    lv |> form("#model-form") |> render_submit()
    assert has_element?(lv, "#flash-info", "Model saved.")
    assert %ModelChoice{tiers: @free_tiers} = saved = choice(scope)
    assert saved.connection_id == litellm.id

    # A fallback row is offered Anthropic, not LiteLLM, the chosen provider.
    lv |> element("#model-fallback-add") |> render_click()

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{anthropic.public_id}"][selected]}
           )

    # Choosing Anthropic for Provider takes LiteLLM out of the page's offers.
    lv |> form("#model-form", model_choice: %{provider: anthropic.public_id}) |> render_change()

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
        fallbacks: [
          %{
            provider: litellm.public_id,
            runtime: Apiary.ModelChoices.default_runtime().name,
            tiers: @free_tiers
          }
        ]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_provider option[value="#{litellm.public_id}"][selected]}
           )

    assert has_element?(
             lv,
             ~s{#model_choice_fallbacks_0_tiers_thinking_model[value="claude-opus-5-5"]}
           )

    assert has_element?(lv, "#model-fallback-0-runtime")

    lv |> form("#model-form") |> render_submit()
    assert has_element?(lv, "#flash-info", "Model saved.")

    saved = scope |> choice() |> Repo.preload(fallbacks: :connection)

    assert [{litellm.id, @free_tiers}] ==
             for(f <- saved.fallbacks, do: {f.connection_id, f.tiers})
  end
end
