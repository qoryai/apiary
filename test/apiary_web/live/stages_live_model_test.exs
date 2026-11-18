defmodule ApiaryWeb.StagesLive.ModelTest do
  @moduledoc """
  The model part of a workflow's fold on Workspace settings › Workflows
  (`ApiaryWeb.StagesLive.ModelPart`): Key, "Use workspace default" or a key, the line of
  what the workflow uses, the tiers of a key and Save model choice, which writes the
  workflow's model choice (level 4) or removes it; a refusal under its field; a draft
  row; who may save; the feature `model_proxies`; and a run of the workflow that uses
  the saved choice.

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
  alias Apiary.ModelChoices.ModelChoice

  @moduletag with_features: Apiary.Features.all() -- [:model_proxies]

  # Explore's first row, explore-a-ticket: its model part's ids.
  @workflow "explore-a-ticket"
  @form "#stage-entry-0-model-form"
  @key "#stage-entry-0-model-key"
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
        key: "anthropic-main",
        tiers: @default_tiers
      })
  end

  defp override!(scope, provider) do
    {:ok, _choice} =
      ModelChoices.put_choice(scope, {:workspace, @workflow}, %{
        provider: provider.public_id,
        key: "openrouter-main",
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

  defp key(provider, value_id), do: "#{provider.public_id}/#{value_id}"

  defp change_model(view, params),
    do: view |> element(@form) |> render_change(%{"model" => params})

  defp save_model(view, params),
    do: view |> element(@form) |> render_submit(%{"model" => params})

  # The options of Key, in order: each value, its text, and whether it is selected.
  defp key_options(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select#{@key} option")
    |> Enum.map(
      &{hd(LazyHTML.attribute(&1, "value")), String.trim(LazyHTML.text(&1)),
       LazyHTML.attribute(&1, "selected") != []}
    )
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

    assert has_element?(view, ~s{label[for="stage-entry-0-model-key"]}, "Key")

    # Key belongs to the row's separate form, not to the stage's form.
    assert has_element?(
             view,
             ~s{select#{@key}[name="model[key]"][form="stage-entry-0-model-form"]}
           )

    refute has_element?(view, "#stage-form #{@form}")

    assert key_options(view) == [
             {"", "Use workspace default", true},
             {key(anthropic, "anthropic-main"), "#{anthropic.name} · anthropic-main", false},
             {key(openrouter, "openrouter-main"), "#{openrouter.name} · openrouter-main", false}
           ]

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name} · anthropic-main."
           )

    refute has_element?(view, @tiers_id)
    refute has_element?(view, @save)

    # After the time limit, before the Access line.
    assert before?(html, ~s{id="stage-entry-0-time-limit"}, ~s{id="stage-entry-0-model-key"})
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
        key: "anthropic-main",
        tiers: @default_tiers
      })

    {:ok, view, _html} = live(conn, path)

    assert has_element?(
             view,
             @line,
             "Uses the default of #{scope.organisation.name}: #{anthropic.name} · anthropic-main."
           )
  end

  test "a key shows its tiers; Save model choice waits for every tier, then writes level 4 with no fallbacks",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    versions = length(Processes.list_versions(scope.workspace))
    {:ok, view, _html} = live(conn, path)

    change_model(view, %{"key" => key(openrouter, "openrouter-main")})

    assert has_element?(
             view,
             @line,
             "This workflow uses this key and these models in place of the workspace's."
           )

    assert has_element?(view, "#{@tiers_id}-h", "Model and effort per tier")

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
    assert choice.value_id == "openrouter-main"
    assert choice.tiers == @override_tiers
    assert length(Processes.list_versions(scope.workspace)) == versions

    assert has_element?(view, "#{@saved}[role=status]", "Saved.")
    assert has_element?(view, "#{@save}[disabled]")
    assert has_element?(view, "#stages-save[disabled]")

    # Opened again: the override's key and tiers, nothing to save.
    {:ok, view, _html} = live(conn, path)

    assert {key(openrouter, "openrouter-main"), "#{openrouter.name} · openrouter-main", true} in key_options(
             view
           )

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

    change_model(view, %{"key" => ""})

    refute has_element?(view, @tiers_id)

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name} · anthropic-main."
           )

    refute has_element?(view, "#{@save}[disabled]")

    # Back to the override's key, its tiers come back.
    change_model(view, %{"key" => key(openrouter, "openrouter-main")})

    assert has_element?(
             view,
             ~s{#stage-entry-0-model-tiers_thinking_model option[value="anthropic/claude-opus-5.5"][selected]}
           )

    assert has_element?(view, "#{@save}[disabled]")

    change_model(view, %{"key" => ""})
    save_model(view, %{"key" => ""})

    assert override(scope) == nil
    assert has_element?(view, "#{@save}[disabled]")
    assert has_element?(view, @saved, "Saved.")

    assert has_element?(
             view,
             @line,
             "Uses the workspace default: #{anthropic.name} · anthropic-main."
           )

    # Opened again: no override, so no button.
    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, @save)
  end

  test "a refused save shows the refusal under Key, keeps Save enabled, and writes nothing",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    {:ok, view, _html} = live(conn, path)

    change_model(view, %{"key" => key(openrouter, "openrouter-main")})
    change_model(view, %{"tiers" => @override_tiers})

    # The key is renamed while the page is open: another key becomes the default first,
    # as a default key keeps its name.
    {:ok, openrouter} =
      Connections.add_provider_key(scope, openrouter, %{
        value_id: "openrouter-spare",
        value: "sk-fold-model-spare-0123456789"
      })

    {:ok, openrouter} = Connections.put_default_key(scope, openrouter, "openrouter-spare")

    {:ok, _provider} =
      Connections.rename_provider_key(scope, openrouter, "openrouter-main", "openrouter-next")

    save_model(view, %{})

    assert has_element?(
             view,
             "#stage-entry-0-model-key-error",
             "Choose one of #{openrouter.name}'s keys: openrouter-main is not one of them."
           )

    assert has_element?(view, ~s{select#{@key}.select-error[aria-invalid="true"]})

    assert has_element?(
             view,
             @line,
             "This workflow uses this key and these models in place of the workspace's."
           )

    refute has_element?(view, "#{@save}[disabled]")
    refute has_element?(view, @saved)
    assert override(scope) == nil
  end

  test "a key of another organisation, sent by hand, is refused on Key, and nothing is written",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic} do
    default!(scope, anthropic)
    %{scope: other} = sign_up_fixture()
    foreign = provider!(other, "anthropic", "anthropic-main")
    {:ok, view, _html} = live(conn, path)

    # A change keeps Key as it was.
    change_model(view, %{"key" => key(foreign, "anthropic-main")})
    assert {"", "Use workspace default", true} in key_options(view)

    save_model(view, %{"key" => key(foreign, "anthropic-main"), "tiers" => @default_tiers})

    assert has_element?(view, "#stage-entry-0-model-key-error", "is invalid")
    assert override(scope) == nil

    {:ok, choices} = ModelChoices.list_choices(other)
    assert choices == []
  end

  test "a workflow of the draft alone has Key disabled, no button, and a line to save the stage first",
       %{conn: conn, path: path, scope: scope, anthropic: anthropic} do
    default!(scope, anthropic)
    {:ok, view, _html} = live(conn, path)

    view
    |> form("#stage-form")
    |> render_change(%{"stage" => %{"sequence" => %{"0" => %{"workflow" => "write-a-brief"}}}})

    assert has_element?(view, "#{@key}[disabled]")
    assert {"", "Use workspace default", true} in key_options(view)

    assert has_element?(
             view,
             @line,
             "Save the stage first to set this workflow's model choice."
           )

    refute has_element?(view, @tiers_id)
    refute has_element?(view, @save)

    # A save sent anyway writes nothing.
    save_model(view, %{"key" => key(anthropic, "anthropic-main"), "tiers" => @default_tiers})
    assert override(scope, "write-a-brief") == nil
  end

  test "an admin made a member while the page is open saves nothing, and sees the fields disabled",
       %{path: path, scope: scope, anthropic: anthropic, openrouter: openrouter} do
    default!(scope, anthropic)
    override!(scope, openrouter)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    {:ok, view, _html} = live(log_in_user(build_conn(), user), path)

    refute has_element?(view, "#{@key}[disabled]")
    {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)

    save_model(view, %{"key" => ""})

    assert has_element?(view, "#flash-error", "Only owners and admins change this.")
    assert override(scope).connection_id == openrouter.id

    assert has_element?(view, "#{@key}[disabled]")
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

    refute has_element?(view, @key)

    render_hook(view, "model_save", %{
      "model" => %{
        "row" =>
          "#{Processes.default_document("software")["stages"] |> hd() |> Map.fetch!("id")}/stage-entry-0",
        "workflow" => @workflow,
        "key" => key(openrouter, "openrouter-main"),
        "tiers" => @override_tiers
      }
    })

    assert override(scope) == nil
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

    test "off: Key leaves out LiteLLM", %{conn: conn, path: path, litellm: litellm} do
      {:ok, view, _html} = live(conn, path)

      values = for {value, _text, _selected} <- key_options(view), do: value
      refute key(litellm, "litellm-main") in values
      assert length(values) == 3
    end

    @tag with_features: Apiary.Features.all()
    test "on: Key offers LiteLLM, with a text field per tier, and a save writes them", %{
      conn: conn,
      path: path,
      scope: scope,
      litellm: litellm
    } do
      {:ok, view, _html} = live(conn, path)

      change_model(view, %{"key" => key(litellm, "litellm-main")})

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
    change_model(view, %{"key" => key(openrouter, "openrouter-main")})
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
