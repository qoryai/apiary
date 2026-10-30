defmodule ApiaryWeb.SetUpSteps do
  @moduledoc """
  Reads the set-up's progress indicator (`ApiaryWeb.SetUpComponents.steps/1`) of a page
  under test: each step's name with its state, and the count above the list; and the
  workspace sidebar's group Set up.
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

  @doc """
  set_up_group/1 is the steps of the workspace sidebar's group Set up on the page `lv`
  (`ApiaryWeb.Layouts.app/1`), in order: `{name, state}`, state `:current` for the page's
  step, else `:done` or `:to_come`. `[]` where the sidebar shows no group.
  """
  def set_up_group(lv) do
    lv
    |> html()
    |> LazyHTML.query("#nav-group-set-up .q-nav-step")
    |> Enum.map(fn step ->
      name = step |> LazyHTML.query(".q-nav-text") |> LazyHTML.text() |> String.split()
      name = name |> Enum.join(" ") |> String.replace_suffix(", done", "")
      [class] = LazyHTML.attribute(step, "class")

      state =
        cond do
          LazyHTML.attribute(step, "aria-current") == ["page"] -> :current
          class =~ "is-done" -> :done
          true -> :to_come
        end

      {name, state}
    end)
  end

  @doc "set_up_heading/1 is the heading of the group Set up, such as \"Set up · 1 of 7\"."
  def set_up_heading(lv) do
    case lv |> html() |> LazyHTML.query("#nav-set-up-heading") |> Enum.to_list() do
      [] -> nil
      [heading] -> heading |> LazyHTML.text() |> String.split() |> Enum.join(" ")
    end
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
