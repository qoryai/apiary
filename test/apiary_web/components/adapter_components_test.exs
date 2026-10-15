defmodule ApiaryWeb.AdapterComponentsTest do
  # What the pages of an integration say of its summary (`ApiaryWeb.AdapterComponents`):
  # its state, by its key and whether it is connected; and, connected, how many of its
  # repositories or projects have no workspace and when it last sent a change.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Apiary.Nodes.Node
  alias ApiaryWeb.AdapterComponents

  defp summary(fields) do
    Map.merge(
      %{
        adapter: %Node{kind: :adapter, name: "GitHub", public_id: "na_github"},
        key: :active,
        connected?: true,
        collections: 3,
        unassigned: 0,
        last_change_at: nil
      },
      Map.new(fields)
    )
  end

  defp words(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  test "the state follows the key, then whether it is connected" do
    assert AdapterComponents.state(summary(key: :none, connected?: false)) == :no_key
    assert AdapterComponents.state(summary(connected?: false)) == :not_connected
    assert AdapterComponents.state(summary([])) == :connected

    for {fields, said} <- [
          {[key: :none, connected?: false], "No access key yet"},
          {[connected?: false], "Not connected"},
          {[], "Connected"}
        ] do
      html = render_component(&AdapterComponents.state_mark/1, id: "s", summary: summary(fields))
      assert words(html) == said
    end
  end

  test "how many have no workspace" do
    for {count, said} <- [{1, "1 without a workspace"}, {4, "4 without a workspace"}] do
      html = render_component(&AdapterComponents.without_workspace/1, id: "w", count: count)
      assert words(html) == said
    end
  end

  test "the state line: connected, with its last update and those without a workspace" do
    at = DateTime.add(DateTime.utc_now(), -3, :minute)

    html =
      render_component(&AdapterComponents.state_line/1,
        summary: summary(last_change_at: at, unassigned: 2)
      )

    assert words(html) =~ ~r/^Connected · last update .+ · 2 without a workspace$/

    html = render_component(&AdapterComponents.state_line/1, summary: summary(unassigned: 0))
    assert words(html) == "Connected"

    html = render_component(&AdapterComponents.state_line/1, summary: summary(connected?: false))
    assert words(html) == "Not connected"
  end
end
