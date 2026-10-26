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

  test "offers the description's models, the default first, then Another model", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, html} = live(conn, path(scope))

    assert has_element?(lv, "h1", "Model")
    assert has_element?(lv, ~s{#settings-tab-model[aria-current="page"]})

    assert has_element?(
             lv,
             "#model-line",
             "#{scope.workspace.name}'s default model. A workflow or a target can set another model for its runs. If #{scope.workspace.name} sets none, its runs use #{scope.organisation.name}'s model."
           )

    titles =
      for model <- ModelChoices.suggestions(provider), do: model.title

    assert titles == Enum.map(Connections.provider_models(provider), & &1["title"])
    assert hd(ModelChoices.suggestions(provider)).id == Connections.default_model(provider)

    options =
      Regex.scan(~r{<option[^>]*>([^<]+)</option>}, html, capture: :all_but_first)
      |> List.flatten()

    assert Enum.take(options, length(titles) + 1) == titles ++ ["Another model"]
    refute has_element?(lv, "#model_choice_other")
  end

  test "saves a model of the list with an effort", ctx do
    %{conn: conn, scope: scope, provider: provider} = ctx
    {:ok, lv, _html} = live(conn, path(scope))

    lv
    |> form("#model-form", model_choice: %{model: option(provider, "claude-haiku-5-5")})
    |> render_change()

    lv
    |> form("#model-form",
      model_choice: %{model: option(provider, "claude-haiku-5-5"), effort: "high"}
    )
    |> render_submit()

    assert %ModelChoice{model_id: "claude-haiku-5-5", effort: "high"} = choice(scope)
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
end
