defmodule ApiaryWeb.WorkItemLive.GateChangesTest do
  # The comparison of two versions of the acceptance criteria that the gate card shows
  # under a changed version (`GateChanges.compare/2`), and the mark for each reader.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ApiaryWeb.WorkItemLive.{GateChanges, VerifyTab}

  @ac1 %{"id" => "ac-1", "text" => "A member cancels a booking.", "check" => "Cancel one."}

  defp criteria(list), do: VerifyTab.criteria(%{"summary" => "Bookings.", "criteria" => list})

  defp compare(earlier, new), do: GateChanges.compare(criteria(earlier), criteria(new))

  test "a changed text with a changed check: both texts, then both checks" do
    earlier = %{"id" => "ac-2", "text" => "Up to 24 hours.", "check" => "Try 25 and 23."}
    new = %{"id" => "ac-2", "text" => "Up to 12 hours.", "check" => "Try 11."}

    assert compare([@ac1, earlier], [@ac1, new]) ==
             {:ok,
              %{
                changes: [
                  %{
                    id: "ac-2",
                    kind: :text,
                    earlier: "Up to 24 hours.",
                    new: "Up to 12 hours.",
                    earlier_check: "Try 25 and 23.",
                    new_check: "Try 11.",
                    reason: nil
                  }
                ],
                unchanged: ["ac-1"]
              }}
  end

  test "a changed text with the same check: no check line" do
    earlier = %{"id" => "ac-2", "text" => "Up to 24 hours.", "check" => "Try it."}
    new = %{"id" => "ac-2", "text" => "Up to 12 hours.", "check" => "Try it."}

    assert {:ok, %{changes: [change], unchanged: ["ac-1"]}} =
             compare([@ac1, earlier], [@ac1, new])

    assert %{kind: :text, earlier_check: nil, new_check: nil} = change
  end

  test "a changed check alone: the text once, then both checks" do
    earlier = %{"id" => "ac-5", "text" => "Up to 12 hours.", "check" => "Try 13."}
    new = %{"id" => "ac-5", "text" => "Up to 12 hours.", "check" => "Try 11."}

    assert compare([earlier], [new]) ==
             {:ok,
              %{
                changes: [
                  %{
                    id: "ac-5",
                    kind: :check,
                    earlier: nil,
                    new: "Up to 12 hours.",
                    earlier_check: "Try 13.",
                    new_check: "Try 11.",
                    reason: nil
                  }
                ],
                unchanged: []
              }}
  end

  test "an added criterion: its text and its check" do
    added = %{"id" => "ac-4", "text" => "The court is free.", "check" => "Open the page."}

    assert compare([@ac1], [@ac1, added]) ==
             {:ok,
              %{
                changes: [
                  %{
                    id: "ac-4",
                    kind: :added,
                    earlier: nil,
                    new: "The court is free.",
                    earlier_check: nil,
                    new_check: "Open the page.",
                    reason: nil
                  }
                ],
                unchanged: ["ac-1"]
              }}
  end

  test "a removed criterion: its earlier text and the reason, no check" do
    live = %{"id" => "ac-3", "text" => "An email confirms it.", "check" => "Read the inbox."}
    removed = Map.put(live, "removed", %{"reason" => "The club sends no emails yet."})

    assert compare([@ac1, live], [@ac1, removed]) ==
             {:ok,
              %{
                changes: [
                  %{
                    id: "ac-3",
                    kind: :removed,
                    earlier: "An email confirms it.",
                    new: nil,
                    earlier_check: nil,
                    new_check: nil,
                    reason: "The club sends no emails yet."
                  }
                ],
                unchanged: ["ac-1"]
              }}
  end

  test "the changes and the unchanged ids follow the new version's order" do
    two = %{"id" => "ac-2", "text" => "Two.", "check" => "Check two."}
    three = %{"id" => "ac-3", "text" => "Three.", "check" => "Check three."}
    four = %{"id" => "ac-4", "text" => "Four.", "check" => "Check four."}

    assert {:ok, %{changes: changes, unchanged: ["ac-3", "ac-1"]}} =
             compare([@ac1, two, three], [three, %{two | "text" => "Two again."}, four, @ac1])

    assert ["ac-2", "ac-4"] = Enum.map(changes, & &1.id)
  end

  test "unchanged criteria, a removed criterion kept as it was, are no change" do
    removed = %{
      "id" => "ac-3",
      "text" => "Gone.",
      "check" => "No.",
      "removed" => %{"reason" => "R."}
    }

    assert compare([@ac1, removed], [@ac1, removed]) == :none
  end

  test "the cases with no text show the mark only" do
    live = %{"id" => "ac-3", "text" => "Three.", "check" => "Check three."}
    removed = Map.put(live, "removed", %{"reason" => "R."})

    # A criterion that the new version leaves out.
    assert compare([@ac1, live], [@ac1]) == :none
    # A removed criterion that is live again.
    assert compare([removed], [live]) == :none
    # A removed criterion whose reason changed.
    assert compare([removed], [Map.put(live, "removed", %{"reason" => "S."})]) == :none
    # A criterion added as removed.
    assert compare([@ac1], [@ac1, removed]) == :none
    # An id twice in one version.
    assert compare([@ac1], [@ac1, %{@ac1 | "text" => "Again."}]) == :none
    # A document that is not acceptance criteria.
    assert GateChanges.compare(nil, criteria([@ac1])) == :none
    assert GateChanges.compare(criteria([@ac1]), VerifyTab.criteria(%{"text" => "# AC"})) == :none
  end

  # Rich text as words, its bold parts between "**".
  defp words(pieces) when is_list(pieces), do: Enum.map_join(pieces, &words/1)
  defp words({:b, inner}), do: "**#{words(inner)}**"
  defp words(text) when is_binary(text), do: text

  test "the line of what to do contains the controls the card shows, and none with no text" do
    assert words(GateChanges.action(:you, 3, [:approve, :changes])) ==
             "Check that these 3 changes to the acceptance criteria match your request, then pick **Approve** or **Request changes**."

    assert words(GateChanges.action({:name, "sam"}, 3, [:approve, :changes])) ==
             "Check that these 3 changes to the acceptance criteria match sam's request, then pick **Approve** or **Request changes**."

    assert words(GateChanges.action(:you, 1, [:approve, :changes])) ==
             "Check that this change to the acceptance criteria matches your request, then pick **Approve** or **Request changes**."

    assert words(GateChanges.action({:name, "sam"}, 1, [:approve, :changes])) ==
             "Check that this change to the acceptance criteria matches sam's request, then pick **Approve** or **Request changes**."

    assert words(GateChanges.action(:member, 3, [:approve, :changes])) ==
             "Check that these 3 changes to the acceptance criteria match a member's request, then pick **Approve** or **Request changes**."

    assert words(GateChanges.action(:you, 3, [:changes])) ==
             "Check that these 3 changes to the acceptance criteria match your request. If they do not, pick **Request changes**."

    assert words(GateChanges.action({:name, "sam"}, 1, [:changes])) ==
             "Check that this change to the acceptance criteria matches sam's request. If it does not, pick **Request changes**."

    assert GateChanges.action(:you, 3, [:form]) == nil
    assert GateChanges.action(:you, 3, [:approve]) == nil
    assert GateChanges.action(:you, 3, []) == nil
  end

  test "the block of a check that alone changed: the text once, then the two checks" do
    earlier = %{"id" => "ac-5", "text" => "Up to 12 hours.", "check" => "Try 13."}
    new = %{"id" => "ac-5", "text" => "Up to 12 hours.", "check" => "Try 11."}
    {:ok, compared} = compare([@ac1, earlier], [@ac1, new])

    html =
      render_component(&GateChanges.changes/1,
        id: "gate-criteria",
        lead: GateChanges.action(:you, length(compared.changes), [:approve, :changes]),
        lead_id: "gate-criteria-action",
        changes: compared.changes,
        unchanged: compared.unchanged,
        mark: GateChanges.mark(:you)
      )

    doc = LazyHTML.from_fragment(html)

    lines =
      doc
      |> LazyHTML.query("#gate-criteria-ac-5 p")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert lines == [
             "AC-5 · Changed on your request",
             "Text: Up to 12 hours.",
             "Earlier check: Try 13.",
             "New check: Try 11."
           ]

    assert doc |> LazyHTML.query("#gate-criteria-action") |> LazyHTML.text() ==
             "Check that this change to the acceptance criteria matches your request, then pick Approve or Request changes."

    assert doc |> LazyHTML.query("#gate-criteria-unchanged") |> LazyHTML.text() |> String.trim() ==
             "AC-1 is unchanged."

    assert doc |> LazyHTML.query("#gate-criteria-ac-5-earlier") |> Enum.to_list() == []
    assert doc |> LazyHTML.query("#gate-criteria-ac-5-new") |> Enum.to_list() == []
  end

  test "two unchanged criteria: one line for both" do
    two = %{"id" => "ac-2", "text" => "Two.", "check" => "Check two."}
    five = %{@ac1 | "id" => "ac-5"}

    {:ok, compared} =
      compare([@ac1, two, five], [@ac1, %{two | "text" => "Two again."}, five])

    assert compared.unchanged == ["ac-1", "ac-5"]

    html =
      render_component(&GateChanges.changes/1,
        id: "gate-criteria",
        changes: compared.changes,
        unchanged: compared.unchanged,
        mark: GateChanges.mark(:member)
      )

    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query("#gate-criteria-unchanged") |> LazyHTML.text() |> String.trim() ==
             "AC-1 and AC-5 are unchanged."

    assert doc |> LazyHTML.query("#gate-criteria-ac-2 .text-warning") |> LazyHTML.text() ==
             "Changed on a member's request"
  end

  test "the mark for the reader who asked, another reader, and an account that is gone" do
    assert GateChanges.mark(:you) == "Changed on your request"
    assert GateChanges.mark({:name, "sam"}) == "Changed on sam's request"
    assert GateChanges.mark(:member) == "Changed on a member's request"
  end
end
