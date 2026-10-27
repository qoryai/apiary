defmodule ApiaryWeb.SetUpSteps do
  @moduledoc """
  Reads the set-up's progress indicator (`ApiaryWeb.SetUpComponents.steps/1`) of a page
  under test: each step's name with its state, and the count above the list.
  """

  import Phoenix.LiveViewTest, only: [render: 1]

  @doc """
  steps/1 is the indicator's steps on the page `lv` (a view, or its HTML), in order:
  `{name, state}`, state one of `:done`, `:skipped`, `:current` and `:to_come`, with
  `:link` beside it, `{name, state, :link}`, for a step that is a link. `[]` where the
  page shows no indicator.
  """
  def steps(lv) do
    lv
    |> html()
    |> LazyHTML.query("#set-up-step-list .q-su-step")
    |> Enum.map(fn step ->
      name = step |> LazyHTML.query(".q-su-nm") |> LazyHTML.text() |> String.trim()
      [class] = LazyHTML.attribute(step, "class")
      state = state(class)

      if LazyHTML.tag(step) == ["a"], do: {name, state, :link}, else: {name, state}
    end)
  end

  @doc "count/1 is the indicator's count, such as \"Step 2 of 4\", or nil where none shows."
  def count(lv) do
    case lv |> html() |> LazyHTML.query("#set-up-step") |> Enum.to_list() do
      [] -> nil
      [count] -> count |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end
  end

  defp html(html) when is_binary(html), do: LazyHTML.from_document(html)
  defp html(lv), do: lv |> render() |> LazyHTML.from_fragment()

  defp state(class) do
    cond do
      class =~ "is-done" -> :done
      class =~ "is-skipped" -> :skipped
      class =~ "is-current" -> :current
      class =~ "is-to_come" -> :to_come
    end
  end
end
