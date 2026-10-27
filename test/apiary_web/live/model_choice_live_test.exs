defmodule ApiaryWeb.ModelChoiceLiveTest do
  # Workspace settings › Model (`ApiaryWeb.ModelChoiceLive`): the Model field and its
  # suggestions, Another model with any model id, the effort, each refusal under its field,
  # who may save, and a saved choice that a run's settings then use.
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

  defp option(provider, model \\ nil),
    do: if(model, do: "#{provider.public_id}/#{model}", else: provider.public_id)

  # A software workspace says repository for target (`docs/lingo.md`).
  test "offers the suggested models, the default first, then Another model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, html} = live(conn, path(scope))

    assert has_element?(lv, "h1", "Model")
    assert has_element?(lv, ~s{#settings-tab-model[aria-current="page"]})

    assert has_element?(lv, "aside#page-context h2", "About this step")
    refute has_element?(lv, ".q-settings-head-sub")

    assert has_element?(
             lv,
             "#page-context #model-line",
             "#{scope.workspace.name}'s default model. A workflow or a repository can set another model for its runs. If #{scope.workspace.name} sets none, its runs use #{scope.organisation.name}'s model."
           )

    suggestions = ModelChoices.suggestions(provider, ModelChoices.default_runtime())
    titles = Enum.map(suggestions, & &1.title)

    assert hd(suggestions).id == Connections.default_model(provider)

    # Read as text, so a title with `&` or `'` compares unescaped.
    options =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#model_choice_model-options .q-pick-t")
      |> Enum.map(&LazyHTML.text/1)

    assert Enum.take(options, length(titles) + 1) == titles ++ ["Another model"]
    refute has_element?(lv, "#model_choice_other")
  end

  test "Model is a choice with search: each model's title over its id, then Another model",
       ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    [first | _rest] =
      suggestions = ModelChoices.suggestions(provider, ModelChoices.default_runtime())

    assert has_element?(lv, "button#model_choice_model", first.title)
    refute has_element?(lv, "select#model_choice_model")

    assert has_element?(
             lv,
             "#model_choice_model-0[value='#{option(provider, first.id)}'][checked]"
           )

    assert has_element?(lv, "#model_choice_model-0-s.mono", first.id)

    other = length(suggestions)

    assert has_element?(
             lv,
             "label[for=model_choice_model-#{other}][data-keep=true]",
             "Another model"
           )

    assert has_element?(lv, "#model_choice_model-#{other}-s", "A model id this list leaves out.")

    # One provider: no heading. The search is there whatever the count.
    refute has_element?(lv, "#model_choice_model-options .q-pick-group")
    assert has_element?(lv, "#model_choice_model-search[aria-label='Find a model']")

    assert has_element?(
             lv,
             ~s(#model_choice_model-choice[data-found="%{shown} of %{total} models"])
           )
  end

  test "a model chosen is checked and shown on the button", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))
    radio = "#model_choice_model-options input[type=radio]"

    # Not the default, which the page checks when it opens.
    second = provider |> ModelChoices.suggestions(ModelChoices.default_runtime()) |> Enum.at(1)
    value = option(provider, second.id)

    lv |> form("#model-form", model_choice: %{model: value}) |> render_change()

    assert has_element?(lv, ~s{#{radio}[value="#{value}"][checked]})
    refute has_element?(lv, ~s{#{radio}[checked]:not([value="#{value}"])})
    assert has_element?(lv, "button#model_choice_model .q-pick-t", second.title)
  end

  test "with two providers, Model groups the models under each provider's name", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx

    {:ok, second} =
      Connections.create_provider(scope, %{
        provider: "deepseek",
        keys: [%{value_id: "key-1", value: "sk-deepseek-model-page-0123456789"}]
      })

    {:ok, lv, _html} = live(conn, path(scope))

    headings =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#model_choice_model-options .q-pick-group")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert Enum.sort(headings) == Enum.sort([provider.name, second.name])

    assert has_element?(
             lv,
             ~s{#model_choice_model-options input[value="#{option(second)}"]}
           )
  end

  test "saves a model of the list with an effort", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    # A suggested model with effort values, from the list, so a new file changes no test.
    %{id: id, effort: effort} =
      provider
      |> ModelChoices.suggestions(ModelChoices.default_runtime())
      |> Enum.filter(&(&1.effort != []))
      |> List.last()

    effort = List.last(effort)

    lv
    |> form("#model-form", model_choice: %{model: option(provider, id)})
    |> render_change()

    lv
    |> form("#model-form", model_choice: %{model: option(provider, id), effort: effort})
    |> render_submit()

    assert %ModelChoice{model_id: ^id, effort: ^effort} = choice(scope)
    assert render(lv) =~ "Model saved."
  end

  test "saves a model off the list through Another model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> form("#model-form", model_choice: %{model: option(provider)}) |> render_change()
    assert has_element?(lv, "#model_choice_other")
    refute has_element?(lv, "#model_choice_effort")

    lv
    |> form("#model-form", model_choice: %{model: option(provider), other: "claude-next-1"})
    |> render_submit()

    assert %ModelChoice{model_id: "claude-next-1", effort: nil} = choice(scope)

    # Opened again, the page shows the id it saved under Another model.
    {:ok, again, _html} = live(conn, path(scope))
    assert has_element?(again, ~s{#model_choice_other[value="claude-next-1"]})
  end

  test "refuses a bad model id under Another model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv |> form("#model-form", model_choice: %{model: option(provider)}) |> render_change()

    html =
      lv
      |> form("#model-form", model_choice: %{model: option(provider), other: "bad id"})
      |> render_submit()

    assert html =~
             "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."

    assert has_element?(lv, ~s{#model_choice_other[aria-invalid="true"]})
    assert choice(scope) == nil
  end

  test "a member sees the fields disabled, no Save, and who changes them", ctx do
    %{scope: scope} = ctx
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path(scope))

    assert has_element?(lv, "#model_choice_model[disabled]")
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
    %{conn: conn, scope: scope, provider: provider} = ctx
    place = handover_place_fixture(scope, allow_secrets: true)
    {:ok, lv, _html} = live(conn, path(scope))

    lv
    |> form("#model-form",
      model_choice: %{model: option(provider, "claude-sonnet-5-5"), effort: "low"}
    )
    |> render_submit()

    work_item = work_item_fixture(scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    {:ok, %{documents: documents}} =
      Dispatches.claim(
        place.key,
        Dispatches.now(),
        ~s({"version":1,"time":"2026-10-26T12:00:00Z"})
      )

    settings = documents.run_settings |> Jason.encode!() |> Jason.decode!()
    assert %{"model" => "claude-sonnet-5-5", "effort" => "low"} = settings
  end

  describe "the runtime" do
    test "is hidden while the list has one runtime, and the choice names none", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      {:ok, lv, _html} = live(conn, path(scope))

      refute has_element?(lv, "#model_choice_runtime")

      lv
      |> form("#model-form", model_choice: %{model: option(provider, "claude-haiku-5-5")})
      |> render_submit()

      assert %ModelChoice{runtime: nil, model_id: "claude-haiku-5-5"} = choice(scope)
    end

    test "with two, is a field; Model lists only the providers that serve the runtime", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx
      [release] = Runtimes.list()
      second = %{release | name: release.name <> "-second", title: release.title <> " second"}

      unserved = %{
        release
        | name: release.name <> "-unserved",
          title: release.title <> " unserved",
          model: %{release.model | "formats" => ["no-such-format"]}
      }

      :ok = Runtimes.put_test_list([release, second, unserved])
      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(lv, "#model_choice_runtime")
      assert has_element?(lv, ~s{#model_choice_runtime option[value="#{second.name}"]})

      lv
      |> form("#model-form", model_choice: %{runtime: unserved.name})
      |> render_change()

      refute has_element?(lv, "#model_choice_model")
      refute has_element?(lv, "#model-submit")

      assert has_element?(
               lv,
               "#model-other_runtime",
               "Choose another runtime: no model provider of #{scope.organisation.name} serves #{unserved.title}."
             )

      refute has_element?(lv, "#model-none")

      lv
      |> form("#model-form", model_choice: %{runtime: second.name})
      |> render_change()

      assert has_element?(
               lv,
               ~s{#model_choice_model-options input[value="#{option(provider, "claude-opus-5-5")}"]}
             )

      lv
      |> form("#model-form",
        model_choice: %{runtime: second.name, model: option(provider, "claude-opus-5-5")}
      )
      |> render_submit()

      assert %ModelChoice{model_id: "claude-opus-5-5", runtime: name} = choice(scope)
      assert name == second.name
    end
  end

  # With no provider that serves the runtime, each line names the cause it is true for,
  # and none asks for a runtime that cannot be chosen.
  describe "with no provider that serves the runtime" do
    test "a provider whose description changed is to be added again", ctx do
      %{conn: conn, scope: scope, provider: provider} = ctx

      Repo.update_all(
        from(c in Connections.Connection, where: c.id == ^provider.id),
        set: [description_sha256: String.duplicate("0", 64)]
      )

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(
               lv,
               "#model-changed-#{provider.public_id}",
               "Add #{provider.name} again in Organisation settings › Model providers: its description changed after it was added."
             )

      refute has_element?(lv, "#model-other_runtime")
      refute has_element?(lv, "#model-none")
      refute has_element?(lv, "#model-submit")
    end

    test "with one runtime, says to add a provider that serves it", ctx do
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
               "Add a model provider that serves #{unserved.title} in Organisation settings › Model providers. None of the model providers of #{scope.organisation.name} serves #{unserved.title}."
             )
    end

    test "with two runtimes that no provider serves, says to add a provider", ctx do
      %{conn: conn, scope: scope} = ctx
      [release] = Runtimes.list()
      unserved = %{release | model: %{release.model | "formats" => ["no-such-format"]}}
      other = %{unserved | name: release.name <> "-other", title: release.title <> " other"}
      :ok = Runtimes.put_test_list([unserved, other])

      {:ok, lv, _html} = live(conn, path(scope))

      assert has_element?(lv, "#model_choice_runtime")
      refute has_element?(lv, "#model-other_runtime")
      assert has_element?(lv, "#model-none")
    end
  end
end
