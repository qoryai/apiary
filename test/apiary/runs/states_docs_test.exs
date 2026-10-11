defmodule Apiary.Runs.StatesDocsTest do
  # The documents name every state a run can be in, by the word the console shows and in
  # its family (`Apiary.Runs.Run.states/0`, `Apiary.Runs.Filters.families/0`): the table of
  # How a run ends in docs/contract-assumptions.md, and the runs list's Filter menu in
  # docs/ui.md. A state added, renamed or moved to another family fails here until both
  # say so.
  use ExUnit.Case, async: true

  alias Apiary.Runs.{Filters, Run}
  alias ApiaryWeb.RunComponents

  @root Path.expand("../../..", __DIR__)

  defp read(file), do: File.read!(Path.join(@root, file))

  # A document's prose on one line: its line breaks and indents are layout.
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp family_of(state), do: Enum.find(Filters.families(), &(state in &1.states))

  test "contract-assumptions.md lists every state with its word and family" do
    text = read("docs/contract-assumptions.md")

    rows =
      for [_, state, word, family] <-
            Regex.scan(~r/^\| `([a-z_]+)` \| ([A-Z][a-z ]+) \| ([A-Z][a-z ]+) \|/m, text),
          into: %{},
          do: {state, {word, family}}

    for state <- Run.states() do
      assert rows[state] == {RunComponents.state_label(state), family_of(state).label},
             "docs/contract-assumptions.md has no row for #{state} with its word and family"
    end

    assert Map.keys(rows) -- Run.states() == [],
           "docs/contract-assumptions.md lists a state that is not one"

    for old <- Run.old_states(),
        do: assert(text =~ "`#{old}`", "docs/contract-assumptions.md does not name #{old}")
  end

  test "ui.md lists every state under its family, as the Filter menu does" do
    families =
      Enum.map(Filters.families(), fn family ->
        words = Enum.map_join(family.states, ", ", &RunComponents.state_label/1)
        "#{family.label} (#{words})"
      end)

    {last, rest} = List.pop_at(families, -1)
    listed = Enum.join(rest, ", ") <> " and " <> last

    assert flat(read("docs/ui.md")) =~ listed,
           "docs/ui.md does not list the states under their families: #{listed}"
  end
end
