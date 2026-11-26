defmodule ApiaryWeb.StagesLive.ModelTest do
  @moduledoc """
  The model part of a workflow's fold on Workspace settings › Workflows
  (`ApiaryWeb.StagesLive.ModelPart`): Provider, "Use workspace default" or a provider,
  the line of what the workflow uses, the tiers of a provider, Runtime and Save model
  choice, which writes the workflow's model choice (level 4) or removes it; a refusal
  under its field; a provider that works with no runtime; a draft row; who may save; the
  feature `model_proxies`; and a run of the workflow that uses the saved choice.

  Not async: each test sets the instance's features, which are the whole node's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, Processes, Repo, Stacks}
  alias Apiary.Dispatches.RunSettings
  alias Apiary.Kinds.{Coded, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias ApiaryWeb.StagesLive.Inspector

  @moduletag with_features: Apiary.Features.all() -- [:model_proxies]

  # Explore's first row, explore-a-ticket: its model part's ids.
  @workflow "explore-a-ticket"
  @form "#stage-entry-0-model-form"
  @provider "#stage-entry-0-model-provider"
  @line "#stage-entry-0-model-line"
  @tiers_id "#stage-entry-0-model-tiers"
  @save "#stage-entry-0-model-save"
  @saved "#stage-entry-0-model-saved"

  @default_tiers %{
    "thinking" => %{"model" => "claude-opus-5-5", "effort" => "high"},
    "balanced" => %{"model" => "claude-sonnet-5-5", "effort" => "medium"},
    "light" => %{"model" => "claude-haiku-5-5", "effort" => "low"}
  }

  # Tiers of OpenRouter's description, which offers effort values for them.
  @override_tiers %{
    "thinking" => %{"model" => "anthropic/claude-opus-5.5", "effort" => "high"},
    "balanced" => %{"model" => "anthropic/claude-sonnet-5.5", "effort" => "low"},
    "light" => %{"model" => "anthropic/claude-haiku-5.5"}
  }

  @free_tiers %{
    "thinking" => %{"model" => "claude-opus-5-5"},
    "balanced" => %{"model" => "claude-sonnet-5-5"},
    "light" => %{"model" => "claude-haiku-5-5"}
  }

  setup :register_and_log_in_user

  setup %{scope: scope} do
    anthropic = provider!(scope, "anthropic", "anthropic-main")
    openrouter = provider!(scope, "openrouter", "openrouter-main")

    %{
      path: workspace_path(scope, "/settings/workflows"),
      anthropic: anthropic,
      openrouter: openrouter
    }
  end

  defp provider!(scope, kind, value_id) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: kind,
        keys: [%{value_id: value_id, value: "sk-fold-model-#{kind}-0123456789"}]
      })

    provider
  end

  defp default!(scope, provider) do
    {:ok, _choice} =
      ModelChoices.put_choice(scope, :workspace, %{
        provider: provider.public_id,
        tiers: @default_tiers
      })
  end

  defp override!(scope, provider) do
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
        provider: provider.public_id,
        tiers: @override_tiers
      })
  end

  defp override(scope, workflow \\ @workflow) do
    Repo.one(
      from c in ModelChoice,
        where:
          c.workspace_id == ^scope.workspace.id and is_nil(c.target_id) and
            c.workflow == ^workflow,
        preload: :fallbacks
    )
  end

  defp change_model(view, params),
    do: view |> element(@form) |> render_change(%{"model" => params})

  defp save_model(view, params),
    do: view |> element(@form) |> render_submit(%{"model" => params})

  # The options of Provider, in order: each value, its text, and whether it is selected.
  defp provider_options(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select#{@provider} option")
    |> Enum.map(
      &{hd(LazyHTML.attribute(&1, "value")), String.trim(LazyHTML.text(&1)),
       LazyHTML.attribute(&1, "selected") != []}
    )
  end

  # The workspace's process with Explore's sequence set to `sequence`, saved.
  defp explore_sequence!(scope, sequence) do
    document = Processes.current(scope.workspace).document

    stages =
      for stage <- document["stages"] do
        if stage["name"] == "Explore", do: Map.put(stage, "sequence", sequence), else: stage
      end

    {:ok, _version} = Processes.save(scope, scope.workspace, Map.put(document, "stages", stages))
  end

  # Whether `first` comes before `second` in the page's markup.
  defp before?(html, first, second) do
    {a, _} = :binary.match(html, first)
    {b, _} = :binary.match(html, second)
    a < b
  end

  test "with no override: Use workspace default, the default's line, no tiers and no button",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    {:ok, view, html} = live(conn, path)

    assert has_element?(view, ~s{label[for="stage-entry-0-model-provider"]}, "Provider")

    # Provider belongs to the row's separate form, not to the stage's form.
    assert has_element?(
             view,
             ~s{select#{@provider}[name="model[provider]"][form="stage-entry-0-model-form"]}
           )

    refute has_element?(view, "#stage-form #{@form}")

    assert provider_options(view) == [
             {"", "Use workspace default", true},
             {anthropic.public_id, anthropic.name, false},
             {openrouter.public_id, openrouter.name, false}
           ]

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name}."
           )

    refute has_element?(view, @tiers_id)
    refute has_element?(view, @save)

    # After the time limit, before the Access line.
    assert before?(html, ~s{id="stage-entry-0-time-limit"}, ~s{id="stage-entry-0-model-provider"})
  end

  test "the line names the organisation's default, else says to set one", %{
    conn: conn,
    path: path,
    scope: scope,
    anthropic: anthropic
  } do
    {:ok, view, _html} = live(conn, path)

    assert has_element?(
             view,
             @line,
             "No default is set. Set one in Workspace settings › Model."
           )

    {:ok, _choice} =
      ModelChoices.put_choice(scope, :organisation, %{
        provider: anthropic.public_id,
        tiers: @default_tiers
      })

    {:ok, view, _html} = live(conn, path)

    assert has_element?(
             view,
             @line,
             "Uses the default of #{scope.organisation.name}: #{anthropic.name}."
           )
  end

  test "a provider shows its tiers; Save model choice waits for every tier, then writes level 4 with no fallbacks",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    versions = length(Processes.list_versions(scope.workspace))
    {:ok, view, _html} = live(conn, path)

    change_model(view, %{"provider" => openrouter.public_id})

    assert has_element?(
             view,
             @line,
             "This workflow uses this provider and these models in place of the workspace's."
           )

    assert has_element?(view, "#{@tiers_id}-h", "Model and effort per tier")

    # The line under each tier (ModelTiers.line/1).
    for line <- [
          "Plans and reviews: the most capable model.",
          "Writes and runs most steps.",
          "Simple, scripted steps: the cheapest model."
        ] do
      assert has_element?(view, @tiers_id, line)
    end

    # The tiers' fields have ids of the row and belong to the row's form.
    assert has_element?(
             view,
             ~s{select#stage-entry-0-model-tiers_thinking_model[name="model[tiers][thinking][model]"][form="stage-entry-0-model-form"]}
           )

    assert has_element?(
             view,
             "#stage-entry-0-model-tiers_thinking_model option[selected]",
             "Choose a model"
           )

    assert has_element?(view, "#{@save}[disabled]", "Save model choice")

    change_model(view, %{
      "tiers" =>
        Map.new(@override_tiers, fn {tier, set} -> {tier, %{"model" => set["model"]}} end)
    })

    change_model(view, %{
      "tiers" => %{"thinking" => %{"effort" => "high"}, "balanced" => %{"effort" => "low"}}
    })

    refute has_element?(view, "#{@save}[disabled]")
    save_model(view, %{})

    assert %ModelChoice{fallbacks: []} = choice = override(scope)
    assert choice.connection_id == openrouter.id
    assert choice.tiers == @override_tiers
    assert length(Processes.list_versions(scope.workspace)) == versions

    assert has_element?(view, "#{@saved}[role=status]", "Saved.")
    assert has_element?(view, "#{@save}[disabled]")
    assert has_element?(view, "#stages-save[disabled]")

    # Opened again: the override's provider and tiers, nothing to save.
    {:ok, view, _html} = live(conn, path)

    assert {openrouter.public_id, openrouter.name, true} in provider_options(view)

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_balanced_effort option[value="low"][selected]}
           )

    assert has_element?(view, "#{@save}[disabled]")
    refute has_element?(view, @saved)
  end

  test "Use workspace default, saved, removes the override", %{
    conn: conn,
    path: path,
    scope: scope,
    anthropic: anthropic,
    openrouter: openrouter
  } do
    default!(scope, anthropic)
    override!(scope, openrouter)
    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, @tiers_id)
    assert has_element?(view, "#{@save}[disabled]")

    change_model(view, %{"provider" => ""})

    refute has_element?(view, @tiers_id)

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name}."
           )

    refute has_element?(view, "#{@save}[disabled]")

    # Back to the override's provider, its tiers come back.
    change_model(view, %{"provider" => openrouter.public_id})

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_thinking_model option[value="anthropic/claude-opus-5.5"][selected]}
           )

    assert has_element?(view, "#{@save}[disabled]")

    change_model(view, %{"provider" => ""})
    save_model(view, %{"provider" => ""})

    assert override(scope) == nil
    assert has_element?(view, "#{@save}[disabled]")
    assert has_element?(view, @saved, "Saved.")

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name}."
           )

    # Opened again: no override, so no button.
    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, @save)
  end

  test "a refused save shows the refusal under Provider, keeps Save enabled, and writes nothing",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    {:ok, view, _html} = live(conn, path)

    change_model(view, %{"provider" => openrouter.public_id})
    change_model(view, %{"tiers" => @override_tiers})

    # The provider is deleted while the page is open.
    {:ok, _provider} = Connections.delete_provider(scope, openrouter)

    save_model(view, %{})

    assert has_element?(
             view,
             "#stage-entry-0-model-provider-error",
             "is invalid"
           )

    assert has_element?(view, ~s{select#{@provider}.select-error[aria-invalid="true"]})

    assert has_element?(
             view,
             @line,
             "This workflow uses this provider and these models in place of the workspace's."
           )

    refute has_element?(view, "#{@save}[disabled]")
    refute has_element?(view, @saved)
    assert override(scope) == nil
  end

  test "a provider of another organisation, sent by hand, is refused on Provider, and nothing is written",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic} do
    default!(scope, anthropic)
    %{scope: other} = sign_up_fixture()
    foreign = provider!(other, "anthropic", "anthropic-main")
    {:ok, view, _html} = live(conn, path)

    # A change keeps Provider as it was.
    change_model(view, %{"provider" => foreign.public_id})
    assert {"", "Use workspace default", true} in provider_options(view)

    save_model(view, %{"provider" => foreign.public_id, "tiers" => @default_tiers})

    assert has_element?(view, "#stage-entry-0-model-provider-error", "is invalid")
    assert override(scope) == nil

    {:ok, choices} = ModelChoices.list_choices(other)
    assert choices == []
  end

  test "a workflow of the draft alone has Provider disabled, no button, and a line to save the stage first",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic} do
    default!(scope, anthropic)
    {:ok, view, _html} = live(conn, path)

    view
    |> form("#stage-form")
    |> render_change(%{"stage" => %{"sequence" => %{"0" => %{"workflow" => "write-a-brief"}}}})

    assert has_element?(view, "#{@provider}[disabled]")
    assert {"", "Use workspace default", true} in provider_options(view)

    assert has_element?(
             view,
             @line,
             "Save the stage first to set this workflow's model choice."
           )

    refute has_element?(view, @tiers_id)
    refute has_element?(view, @save)

    # A save sent anyway writes nothing.
    save_model(view, %{"provider" => anthropic.public_id, "tiers" => @default_tiers})
    assert override(scope, "write-a-brief") == nil
  end

  test "a draft row of a workflow with an override shows Use workspace default, and its save keeps the override",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)

    # An override set while the workflow is in no version.
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, "write-a-brief"}, %{
        provider: openrouter.public_id,
        tiers: @override_tiers
      })

    {:ok, view, _html} = live(conn, path)

    view
    |> form("#stage-form")
    |> render_change(%{"stage" => %{"sequence" => %{"0" => %{"workflow" => "write-a-brief"}}}})

    assert {"", "Use workspace default", true} in provider_options(view)
    refute has_element?(view, @tiers_id)

    assert has_element?(
             view,
             @line,
             "Save the stage first to set this workflow's model choice."
           )

    # Saved, the workflow is in the process, which keeps its override.
    view |> element("#stages-save") |> render_click()
    assert override(scope, "write-a-brief").connection_id == openrouter.id

    {:ok, view, _html} = live(conn, path)
    id = openrouter.public_id
    assert Enum.any?(provider_options(view), &match?({^id, _label, true}, &1))
    refute has_element?(view, "#{@provider}[disabled]")
  end

  test "a save sends the runtime Runtime shows: the override's, kept by a change of Provider",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    release = Runtimes.list() |> Enum.find(&(&1.name == "claude"))
    second = %{release | name: release.name <> "-second", title: release.title <> " second"}
    :ok = Runtimes.put_test_list([release, second])
    default!(scope, anthropic)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
        provider: openrouter.public_id,
        tiers: @override_tiers,
        runtime: second.name
      })

    {:ok, view, _html} = live(conn, path)

    # The same provider: the override's runtime stays.
    change_model(view, %{"tiers" => %{"balanced" => %{"effort" => ""}}})
    save_model(view, %{})
    assert %ModelChoice{connection_id: id, runtime: name} = override(scope)
    assert {id, name} == {openrouter.id, second.name}

    # Another provider that serves the override's runtime too: Runtime keeps it (792).
    change_model(view, %{"provider" => anthropic.public_id})

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-runtime option[value="#{second.name}"][selected]}
           )

    change_model(view, %{
      "tiers" => Map.new(@default_tiers, fn {tier, set} -> {tier, %{"model" => set["model"]}} end)
    })

    save_model(view, %{})
    assert %ModelChoice{connection_id: id, runtime: name} = override(scope)
    assert {id, name} == {anthropic.id, second.name}

    # Runtime chosen again: the save sends that one.
    change_model(view, %{"runtime" => release.name})
    save_model(view, %{})
    assert %ModelChoice{runtime: name} = override(scope)
    assert name == release.name
  end

  test "Use workspace default saved with no override in a workspace marked for deletion shows no Saved.",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic} do
    default!(scope, anthropic)
    {:ok, view, _html} = live(conn, path)

    {1, _rows} =
      Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), 30, :day),
          purge_trigger: "grace_period"
        ]
      )

    save_model(view, %{"provider" => ""})
    refute has_element?(view, @saved)
    assert override(scope) == nil
  end

  test "an admin made a member while the page is open saves nothing, and sees the fields disabled",
       %{path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    override!(scope, openrouter)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    {:ok, view, _html} = live(log_in_user(build_conn(), user), path)

    refute has_element?(view, "#{@provider}[disabled]")
    {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

    save_model(view, %{"provider" => ""})

    assert has_element?(view, "#flash-error", "Only owners and admins change this.")
    assert override(scope).connection_id == openrouter.id

    assert has_element?(view, "#{@provider}[disabled]")
    assert has_element?(view, "#stage-entry-0-model-tiers_thinking_model[disabled]")
    refute has_element?(view, @save)
  end

  test "a member reads no model part, and a save sent anyway writes nothing", %{
    scope: scope,
    anthropic: anthropic,
    openrouter: openrouter
  } do
    default!(scope, anthropic)
    %{user: user} = member_fixture(scope)

    {:ok, view, _html} =
      live(log_in_user(build_conn(), user), workspace_path(scope, "/settings/workflows"))

    refute has_element?(view, @provider)

    # The row's key as the page builds it, so only the member's rights stop the save.
    stage = Processes.current(scope.workspace).document["stages"] |> hd()

    render_hook(view, "model_save", %{
      "model" => %{
        "row" => Inspector.time_limit_key(stage["id"], "stage-entry-0"),
        "workflow" => @workflow,
        "provider" => openrouter.public_id,
        "tiers" => @override_tiers
      }
    })

    assert override(scope) == nil
  end

  describe "Runtime" do
    @runtime "#stage-entry-0-model-runtime"
    @runtime_part "#stage-entry-0-model-runtime-part"

    # The release's runtime, and a copy of it with another name that reads a key only
    # from the bearer variable: Anthropic (an `x-api-key` header) serves the first alone,
    # OpenRouter (bearer) serves both.
    defp two_runtimes do
      release = Apiary.Kinds.Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Apiary.Kinds.Runtimes.put_test_list([release, bearer])
      {release, bearer}
    end

    test "is not shown with the workspace default", %{
      conn: conn,
      path: path,
      scope: scope,
      anthropic: anthropic
    } do
      default!(scope, anthropic)
      {:ok, view, _html} = live(conn, path)

      refute has_element?(view, @runtime_part)
      refute has_element?(view, @runtime)
    end

    test "follows the tiers of an override, as text where one runtime fits", %{
      conn: conn,
      path: path,
      scope: scope,
      anthropic: anthropic
    } do
      release = Apiary.Kinds.Runtimes.list() |> Enum.find(&(&1.name == "claude"))
      default!(scope, anthropic)
      {:ok, view, _html} = live(conn, path)

      html = change_model(view, %{"provider" => anthropic.public_id})

      assert before?(
               html,
               ~s{id="stage-entry-0-model-tiers"},
               ~s{id="stage-entry-0-model-runtime-part"}
             )

      assert before?(
               html,
               ~s{id="stage-entry-0-model-runtime-part"},
               ~s{id="stage-entry-0-model-save"}
             )

      refute has_element?(view, @runtime)
      assert has_element?(view, "#{@runtime_part}-name", release.title)

      assert has_element?(
               view,
               "#{@runtime_part}-line",
               "#{release.title} is the only runtime that works with Anthropic API key."
             )

      # The hidden field belongs to the row's form.
      assert has_element?(
               view,
               ~s{#{@runtime_part} input[type=hidden][name="model[runtime]"][form="stage-entry-0-model-form"][value="#{release.name}"]}
             )
    end

    test "several fit: a select, the first fitting one chosen; a save writes the one chosen",
         %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
      {release, bearer} = two_runtimes()
      default!(scope, anthropic)
      {:ok, view, _html} = live(conn, path)

      change_model(view, %{"provider" => openrouter.public_id})

      assert has_element?(
               view,
               ~s{select#{@runtime}[form="stage-entry-0-model-form"] option[value="#{release.name}"][selected]}
             )

      assert has_element?(view, ~s{#{@runtime} option[value="#{bearer.name}"]})

      assert has_element?(
               view,
               "#{@runtime_part}-line",
               "These runtimes work with OpenRouter."
             )

      change_model(view, %{"tiers" => @override_tiers})
      change_model(view, %{"runtime" => bearer.name})
      refute has_element?(view, "#{@save}[disabled]")
      save_model(view, %{})

      assert %ModelChoice{runtime: name} = override(scope)
      assert name == bearer.name

      # Opened again: the stored runtime is chosen.
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ~s{#{@runtime} option[value="#{bearer.name}"][selected]})
      assert has_element?(view, "#{@save}[disabled]")
    end

    test "Provider lists every provider; a new override starts from the default's runtime, which a change of Provider keeps while the provider serves it",
         %{
           conn: conn,
           path: path,
           scope: scope,
           anthropic: anthropic,
           openrouter: openrouter
         } do
      {release, bearer} = two_runtimes()

      # The workspace default runs the bearer runtime, which Anthropic does not serve.
      {:ok, _choice} =
        ModelChoices.put_choice(scope, :workspace, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: @override_tiers
        })

      {:ok, view, _html} = live(conn, path)

      values = for {value, _text, _selected} <- provider_options(view), do: value
      assert anthropic.public_id in values
      assert openrouter.public_id in values

      # OpenRouter serves the default's runtime: it is chosen.
      change_model(view, %{"provider" => openrouter.public_id})
      assert has_element?(view, ~s{#{@runtime} option[value="#{bearer.name}"][selected]})

      # Anthropic does not: Runtime moves to the one it serves.
      change_model(view, %{"provider" => anthropic.public_id, "runtime" => bearer.name})
      refute has_element?(view, @runtime)
      assert has_element?(view, "#{@runtime_part}-name", release.title)

      # Back to OpenRouter, which serves that one too: it stays.
      change_model(view, %{"provider" => openrouter.public_id, "runtime" => release.name})

      assert has_element?(view, ~s{#{@runtime} option[value="#{release.name}"][selected]})
    end

    test "a change of the runtime keeps the models and takes back an effort it refuses", %{
      conn: conn,
      path: path,
      scope: scope,
      anthropic: anthropic,
      openrouter: openrouter
    } do
      release = Apiary.Kinds.Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      narrow = %{
        release
        | name: release.name <> "-narrow",
          title: release.title <> " narrow",
          effort_values: ~w(low medium)
      }

      :ok = Apiary.Kinds.Runtimes.put_test_list([release, narrow])
      default!(scope, anthropic)
      {:ok, view, _html} = live(conn, path)

      change_model(view, %{"provider" => openrouter.public_id})
      change_model(view, %{"tiers" => @override_tiers})
      change_model(view, %{"runtime" => narrow.name})

      assert has_element?(
               view,
               ~s{#stage-entry-0-model-tiers_thinking_model option[value="anthropic/claude-opus-5.5"][selected]}
             )

      assert has_element?(
               view,
               ~s{#stage-entry-0-model-tiers_thinking_effort option[value=""][selected]}
             )

      assert has_element?(
               view,
               ~s{#stage-entry-0-model-tiers_balanced_effort option[value="low"][selected]}
             )

      save_model(view, %{})

      assert %ModelChoice{runtime: name, tiers: tiers} = override(scope)
      assert name == narrow.name
      assert tiers["thinking"] == %{"model" => "anthropic/claude-opus-5.5"}
      assert tiers["balanced"] == %{"model" => "anthropic/claude-sonnet-5.5", "effort" => "low"}
    end

    test "an override that names no runtime shows the catalogue's default, not the workspace default's",
         %{conn: conn, path: path, scope: scope, openrouter: openrouter} do
      {release, bearer} = two_runtimes()

      # The workspace default runs the bearer runtime; the override names none, so its
      # runs take the catalogue's default, the release's runtime.
      {:ok, _choice} =
        ModelChoices.put_choice(scope, :workspace, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: @override_tiers
        })

      override!(scope, openrouter)
      assert %ModelChoice{runtime: nil} = override(scope)

      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ~s{#{@runtime} option[value="#{release.name}"][selected]})
      assert has_element?(view, "#{@save}[disabled]")

      change_model(view, %{"tiers" => %{"balanced" => %{"effort" => ""}}})
      save_model(view, %{})

      assert %ModelChoice{runtime: name} = override(scope)
      assert name in [nil, release.name]
    end

    test "a stored runtime the catalogue no longer has is a change, and a save writes the one shown",
         %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
      {release, bearer} = two_runtimes()
      default!(scope, anthropic)

      {:ok, _choice} =
        ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
          provider: openrouter.public_id,
          runtime: bearer.name,
          tiers: @override_tiers
        })

      # The catalogue drops the bearer runtime: the row shows the release's, and Save
      # model choice is enabled with nothing else changed.
      :ok = Apiary.Kinds.Runtimes.put_test_list([release])
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#{@runtime_part}-name", release.title)
      refute has_element?(view, "#{@save}[disabled]")

      save_model(view, %{})

      # With one runtime in the catalogue, the choice names none.
      assert %ModelChoice{runtime: nil} = override(scope)
      assert has_element?(view, "#{@save}[disabled]")
    end

    test "a provider that works with no runtime is listed; chosen, a line under Provider, Save model choice disabled, and a save writes nothing",
         %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
      default!(scope, anthropic)

      # The catalogue has only a bearer runtime, which Anthropic (an `x-api-key` header)
      # does not serve and OpenRouter does.
      release = Apiary.Kinds.Runtimes.list() |> Enum.find(&(&1.name == "claude"))

      bearer = %{
        release
        | name: release.name <> "-bearer",
          title: release.title <> " bearer",
          model_keys: Enum.filter(release.model_keys, &(&1["auth"] == %{"scheme" => "bearer"}))
      }

      :ok = Apiary.Kinds.Runtimes.put_test_list([bearer])
      {:ok, view, _html} = live(conn, path)

      assert {anthropic.public_id, anthropic.name, false} in provider_options(view)

      change_model(view, %{"provider" => anthropic.public_id})

      assert has_element?(
               view,
               "#stage-entry-0-model-provider-error",
               "Anthropic API key works with no runtime in this version of Qory. Pick another provider."
             )

      assert has_element?(view, ~s{select#{@provider}[aria-invalid="true"]})
      refute has_element?(view, @runtime_part)
      assert has_element?(view, "#{@save}[disabled]")

      # A save sent all the same writes nothing.
      save_model(view, %{"provider" => anthropic.public_id, "tiers" => @default_tiers})
      assert override(scope) == nil
      refute has_element?(view, @saved)

      # OpenRouter serves the bearer runtime: the line goes.
      change_model(view, %{"provider" => openrouter.public_id})
      refute has_element?(view, "#stage-entry-0-model-provider-error")
      assert has_element?(view, "#{@runtime_part}-name", bearer.title)
    end
  end

  test "a row in a loop has ids and a form of its row, and a save updates every row of the workflow",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)

    explore_sequence!(scope, [
      %{"workflow" => @workflow},
      %{"loop" => %{"rounds" => 2, "body" => [%{"workflow" => @workflow}]}}
    ])

    {:ok, view, _html} = live(conn, path)

    assert has_element?(
             view,
             ~s{select#stage-entry-1-0-model-provider[name="model[provider]"][form="stage-entry-1-0-model-form"]}
           )

    assert has_element?(view, "#stage-entry-1-0-model-line", "Uses the workspace default")

    view
    |> element("#stage-entry-1-0-model-form")
    |> render_change(%{"model" => %{"provider" => openrouter.public_id}})

    assert has_element?(
             view,
             ~s{select#stage-entry-1-0-model-tiers_thinking_model[form="stage-entry-1-0-model-form"]}
           )

    # The first row stays at its saved state until the save.
    refute has_element?(view, @tiers_id)

    view
    |> element("#stage-entry-1-0-model-form")
    |> render_change(%{"model" => %{"tiers" => @override_tiers}})

    view |> element("#stage-entry-1-0-model-form") |> render_submit(%{"model" => %{}})

    assert override(scope).connection_id == openrouter.id
    assert has_element?(view, "#stage-entry-1-0-model-saved", "Saved.")

    # The other row of the workflow shows the saved override, not marked as just saved.
    assert {openrouter.public_id, openrouter.name, true} in provider_options(view)

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_balanced_effort option[value="low"][selected]}
           )

    refute has_element?(view, @saved)
  end

  test "a row whose workflow changes in the draft after an unsaved Provider shows the new workflow's choice",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    explore_sequence!(scope, [%{"workflow" => @workflow}, %{"workflow" => "shape-a-ticket"}])
    {:ok, view, _html} = live(conn, path)

    change_model(view, %{"provider" => openrouter.public_id})
    assert has_element?(view, @tiers_id)

    view
    |> form("#stage-form")
    |> render_change(%{"stage" => %{"sequence" => %{"0" => %{"workflow" => "shape-a-ticket"}}}})

    assert {"", "Use workspace default", true} in provider_options(view)
    refute has_element?(view, @tiers_id)
    refute has_element?(view, @save)

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name}."
           )

    assert override(scope) == nil
    assert override(scope, "shape-a-ticket") == nil
  end

  test "an override whose provider can no longer be read keeps its provider, and a save of the default removes it",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    override!(scope, openrouter)

    # Settings that no longer fit OpenRouter's entry: its description cannot be read.
    Apiary.Connections.Connection
    |> Repo.get!(openrouter.id)
    |> Ecto.Changeset.change(settings: ~s({"region":"eu"}))
    |> Coded.seal()
    |> Repo.update!()

    assert {:error, :provider_changed} =
             Connections.provider(Repo.get!(Apiary.Connections.Connection, openrouter.id))

    {:ok, view, _html} = live(conn, path)

    assert {openrouter.public_id, openrouter.name, true} in provider_options(view)

    assert has_element?(
             view,
             @line,
             "This workflow uses this provider and these models in place of the workspace's."
           )

    # No runtime is read for the provider, and the override's efforts stay shown.
    refute has_element?(view, @runtime_part)

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_thinking_effort option[value="high"][selected]}
           )

    change_model(view, %{"provider" => ""})
    refute has_element?(view, "#{@save}[disabled]")
    save_model(view, %{"provider" => ""})

    assert override(scope) == nil
    assert has_element?(view, @saved, "Saved.")
  end

  test "Provider lists a key group once, by its first provider, and shows an override on a later provider as it",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    # A second Anthropic provider, for the workspace alone: of Anthropic's key group.
    {:ok, checkout} =
      Connections.create_provider(
        scope,
        %{
          provider: "anthropic",
          name: "Checkout API keys",
          keys: [%{value_id: "checkout", value: "sk-fold-model-checkout-0123456789"}]
        },
        :workspace
      )

    default!(scope, checkout)

    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
        provider: checkout.public_id,
        tiers: @default_tiers
      })

    {:ok, view, _html} = live(conn, path)

    assert provider_options(view) == [
             {"", "Use workspace default", false},
             {anthropic.public_id, "Anthropic API key", true},
             {openrouter.public_id, openrouter.name, false}
           ]

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_thinking_effort option[value="high"][selected]}
           )

    # The default's line shows the group's label too.
    save_model(view, %{"provider" => ""})
    assert has_element?(view, @line, "Uses the workspace default: Anthropic API key.")
    refute render(view) =~ "Checkout API keys"
  end

  describe "the feature model_proxies" do
    setup %{scope: scope} = ctx do
      litellm =
        Apiary.ConnectionsFixtures.provider_added_with_model_proxies!(ctx, scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "litellm-main", value: "sk-fold-model-litellm-0123456789"}]
        })

      %{litellm: litellm}
    end

    test "off: Provider leaves out LiteLLM", %{conn: conn, path: path, litellm: litellm} do
      {:ok, view, _html} = live(conn, path)

      values = for {value, _text, _selected} <- provider_options(view), do: value
      refute litellm.public_id in values
      assert length(values) == 3
    end

    test "off: a saved LiteLLM override shows its provider and tiers, and a save keeps it", %{
      conn: conn,
      path: path,
      scope: scope,
      litellm: litellm
    } do
      {:ok, _choice} =
        Apiary.ModelChoicesFixtures.put_choice(scope, {:workspace, @workflow}, %{
          provider: litellm.public_id,
          tiers: @free_tiers
        })

      {:ok, view, _html} = live(conn, path)

      # Named by its key group: its kind's title and its address.
      assert {litellm.public_id, "LiteLLM at https://litellm.example.com", true} in provider_options(
               view
             )

      assert has_element?(
               view,
               ~s{input#stage-entry-0-model-tiers_light_model[value="claude-haiku-5-5"]}
             )

      change_model(view, %{"tiers" => %{"light" => %{"model" => "claude-haiku-5-6"}}})
      save_model(view, %{})

      assert %ModelChoice{tiers: %{"light" => %{"model" => "claude-haiku-5-6"}}} =
               choice = override(scope)

      assert choice.connection_id == litellm.id
    end

    @tag with_features: Apiary.Features.all()
    test "on: Provider offers LiteLLM, with a text field per tier, and a save writes them", %{
      conn: conn,
      path: path,
      scope: scope,
      litellm: litellm
    } do
      {:ok, view, _html} = live(conn, path)

      change_model(view, %{"provider" => litellm.public_id})

      assert has_element?(view, "#{@tiers_id}-h", "Model per tier")

      for tier <- ~w(thinking balanced light) do
        assert has_element?(
                 view,
                 ~s{input#stage-entry-0-model-tiers_#{tier}_model[type="text"][form="stage-entry-0-model-form"]}
               )

        refute has_element?(view, "#stage-entry-0-model-tiers_#{tier}_effort")
      end

      change_model(view, %{"tiers" => @free_tiers})
      save_model(view, %{})

      assert %ModelChoice{tiers: @free_tiers, fallbacks: []} = choice = override(scope)
      assert choice.connection_id == litellm.id
    end
  end

  test "a run of the workflow uses the choice the fold saved", %{
    conn: conn,
    path: path,
    scope: scope,
    anthropic: anthropic,
    openrouter: openrouter
  } do
    default!(scope, anthropic)
    place = handover_place_fixture(scope, allow_secrets: true)

    # The run's workflow comes from the workspace's stack row.
    {:ok, _stack} =
      Stacks.put_stack(
        scope,
        {:workspace, scope.workspace, @workflow},
        "extends: {git: https://code.example.com/team/stacks, ref: main, path: core}\n"
      )

    {:ok, view, _html} = live(conn, path)
    change_model(view, %{"provider" => openrouter.public_id})
    change_model(view, %{"tiers" => @override_tiers})
    save_model(view, %{})

    assert %ModelChoice{fallbacks: []} = override(scope)

    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    assert {4, %ModelChoice{}} = RunSettings.choice_in_effect(queued)

    {:ok, %{documents: documents}} =
      walked_claim(place.key, Dispatches.now(), ~s({"version":1,"time":"2026-11-18T12:00:00Z"}))

    settings = documents.run_settings |> Jason.encode!() |> Jason.decode!()
    assert %{"model" => "anthropic/claude-opus-5.5", "effort" => "high"} = settings
    assert settings["tiers"]["light"] == "anthropic/claude-haiku-5.5"
  end
end
