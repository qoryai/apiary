defmodule ApiaryWeb.WorkItemLive.GateChanges do
  # A version that a run stored on a person's request, as the work item page shows it until
  # an approval lists it (`Apiary.Stages.unapproved_changes/2`, vault 0261, 624
  # (a)): the mark "Changed on your request" on the version's line of the gate card and on
  # its frame's caption, and, for acceptance criteria, each changed, added or removed
  # criterion with its earlier and its new text and check, under one line with the next
  # step, so a person approves without opening another page.
  #
  # The words that depend on the reader are decided when the page is drawn: "your request"
  # for the person who wrote the note, "sam's request" for anyone else, "a member's
  # request" where the writer's account is gone. The line with the next step contains only
  # the controls that the gate card shows (`ApiaryWeb.WorkItemLive.StageComponents`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.WorkItemLive.VerifyTab

  @typedoc """
  Who asked for a change, as the reader sees it: `:you`, the reader wrote the note;
  `{:name, name}`, another person, by `ApiaryWeb.People.short/1`; `:member`, a person
  whose account is gone, or no person.
  """
  @type whose :: :you | {:name, String.t()} | :member

  ## The mark

  @doc false
  # mark/1 is the mark of a changed version for the reader: "Changed on your request",
  # "Changed on sam's request" or "Changed on a member's request".
  @spec mark(whose) :: String.t()
  def mark(:you), do: gettext("Changed on your request")
  def mark({:name, name}), do: gettext("Changed on %{name}'s request", name: name)
  def mark(:member), do: gettext("Changed on a member's request")

  ## The comparison

  @doc false
  # compare/2 is what changed between two acceptance criteria documents, each read as
  # `VerifyTab.criteria/1` reads one: `earlier`, the version approved before the change,
  # and `new`, the changed version. Each criterion is compared by its id. `{:ok, %{changes:,
  # unchanged:}}`: `changes` is each changed, added or removed criterion in the order of
  # `new`, and `unchanged` the id of each criterion with the same text, check and removal
  # in both, in that order. A change is `%{id:, kind:, earlier:, new:, earlier_check:,
  # new_check:, reason:}`:
  #
  #   * `:text`: the text differs; `earlier` and `new` are the two texts, and where the
  #     check differs too, `earlier_check` and `new_check` are the two checks.
  #   * `:check`: only the check differs; `new` is the text, the same in both.
  #   * `:added`: `earlier` has no criterion with the id; `new` and `new_check`.
  #   * `:removed`: `new` marks the criterion removed and `earlier` did not; `earlier`, the
  #     text before, and `reason`.
  #
  # `:none` where the page shows the mark only: a document that is not acceptance
  # criteria, no criterion that changed, an id twice in one document, and the cases the
  # page has no text for: a criterion that `new` leaves out, a removed criterion that is
  # live again or whose removal changed, a criterion added as removed, and a check that is
  # empty where it differs.
  @spec compare(map | nil, map | nil) :: {:ok, map} | :none
  def compare(%{criteria: earlier}, %{criteria: new}) do
    before = Map.new(earlier, &{&1.id, &1})
    ids = MapSet.new(new, & &1.id)

    rows = Enum.map(new, &{&1.id, row(before[&1.id], &1)})

    cond do
      map_size(before) != length(earlier) or MapSet.size(ids) != length(new) -> :none
      Enum.any?(earlier, &(not MapSet.member?(ids, &1.id))) -> :none
      Enum.any?(rows, &(elem(&1, 1) == :none)) -> :none
      Enum.all?(rows, &(elem(&1, 1) == :unchanged)) -> :none
      true -> {:ok, split(rows)}
    end
  end

  def compare(_earlier, _new), do: :none

  defp split(rows) do
    %{
      changes: for({_id, %{} = change} <- rows, do: change),
      unchanged: for({id, :unchanged} <- rows, do: id)
    }
  end

  # One criterion of the new version against the criterion with its id in the earlier
  # version, nil for none.
  defp row(same, same), do: :unchanged

  defp row(nil, %{removed: nil, check: check} = new) when is_binary(check),
    do: change(new.id, :added, new: new.text, new_check: check)

  defp row(%{removed: nil} = earlier, %{removed: reason} = new) when is_binary(reason),
    do: change(new.id, :removed, earlier: earlier.text, reason: reason)

  defp row(%{removed: nil} = earlier, %{removed: nil} = new) do
    checks = earlier.check != new.check

    cond do
      checks and not (is_binary(earlier.check) and is_binary(new.check)) ->
        :none

      earlier.text != new.text and checks ->
        change(new.id, :text,
          earlier: earlier.text,
          new: new.text,
          earlier_check: earlier.check,
          new_check: new.check
        )

      earlier.text != new.text ->
        change(new.id, :text, earlier: earlier.text, new: new.text)

      true ->
        change(new.id, :check,
          new: new.text,
          earlier_check: earlier.check,
          new_check: new.check
        )
    end
  end

  defp row(_earlier, _new), do: :none

  defp change(id, kind, fields) do
    Map.merge(
      %{
        id: id,
        kind: kind,
        earlier: nil,
        new: nil,
        earlier_check: nil,
        new_check: nil,
        reason: nil
      },
      Map.new(fields)
    )
  end

  ## The lines

  @doc false
  # action/3 is the line above the changes for a reader who may decide, by the controls
  # the gate card shows (`controls`, `StageComponents`): with Approve and Request changes,
  # "Check that these 3 changes to the acceptance criteria match your request, then pick
  # Approve or Request changes."; with Request changes only, "… match your request. If
  # they do not, pick Request changes."; nil with any other set of controls, which no
  # line has words for. `count` is the number of changes and `whose` who asked for them.
  @spec action(whose, pos_integer, [atom]) :: term
  def action(whose, count, [:approve, :changes]), do: both(whose, count)
  def action(whose, count, [:changes]), do: changes_only(whose, count)
  def action(_whose, _count, _controls), do: nil

  defp both(:you, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches your request, then pick %{approve} or %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match your request, then pick %{approve} or %{changes}.",
      count,
      approve: {:b, gettext("Approve")},
      changes: {:b, gettext("Request changes")}
    )
  end

  defp both({:name, name}, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches %{name}'s request, then pick %{approve} or %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match %{name}'s request, then pick %{approve} or %{changes}.",
      count,
      name: name,
      approve: {:b, gettext("Approve")},
      changes: {:b, gettext("Request changes")}
    )
  end

  defp both(:member, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches a member's request, then pick %{approve} or %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match a member's request, then pick %{approve} or %{changes}.",
      count,
      approve: {:b, gettext("Approve")},
      changes: {:b, gettext("Request changes")}
    )
  end

  defp changes_only(:you, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches your request. If it does not, pick %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match your request. If they do not, pick %{changes}.",
      count,
      changes: {:b, gettext("Request changes")}
    )
  end

  defp changes_only({:name, name}, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches %{name}'s request. If it does not, pick %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match %{name}'s request. If they do not, pick %{changes}.",
      count,
      name: name,
      changes: {:b, gettext("Request changes")}
    )
  end

  defp changes_only(:member, count) do
    rich_ngettext(
      "Check that this change to the acceptance criteria matches a member's request. If it does not, pick %{changes}.",
      "Check that these %{count} changes to the acceptance criteria match a member's request. If they do not, pick %{changes}.",
      count,
      changes: {:b, gettext("Request changes")}
    )
  end

  ## The block

  attr :id, :string, required: true
  attr :lead, :any, default: nil, doc: "the line above the changes, rich text; nil for none"
  attr :lead_id, :string, default: nil, doc: "the DOM id of that line"
  attr :changes, :list, required: true, doc: "`compare/2`'s `changes`"
  attr :unchanged, :list, required: true, doc: "`compare/2`'s `unchanged`"
  attr :mark, :string, required: true, doc: "`mark/1` for the reader"

  @doc false
  # changes/1 is the block of the gate card under its version lines: the line with the
  # next step or with who decides (`lead`), each changed, added or removed criterion with its
  # mark, its earlier and new text and, where the check changed, its earlier and new
  # check, then the ids of the unchanged criteria.
  def changes(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@lead} id={@lead_id}><.rich text={@lead} /></p>
      <ul id={"#{@id}-list"} class="flex flex-col gap-2">
        <li
          :for={change <- @changes}
          id={"#{@id}-#{change.id}"}
          class="flex flex-col"
        >
          <p>
            <span class="font-semibold">{VerifyTab.shown_id(change.id)}</span>
            · <span id={"#{@id}-#{change.id}-mark"} class="text-warning">{@mark}</span>
          </p>
          <p :if={change.kind == :check} id={"#{@id}-#{change.id}-text"}>
            <span class="font-semibold">{gettext("Text:")}</span> {change.new}
          </p>
          <p :if={change.kind != :check} id={"#{@id}-#{change.id}-earlier"}>
            <span class="font-semibold">{gettext("Earlier:")}</span>
            {change.earlier || gettext("none. This criterion is new.")}
          </p>
          <p :if={change.kind != :check} id={"#{@id}-#{change.id}-new"}>
            <span class="font-semibold">{gettext("New:")}</span>
            {if change.kind == :removed,
              do: gettext("Removed. Reason: %{reason}", reason: change.reason),
              else: change.new}
          </p>
          <p :if={change.earlier_check} id={"#{@id}-#{change.id}-earlier-check"}>
            <span class="font-semibold">{gettext("Earlier check:")}</span>
            {change.earlier_check}
          </p>
          <p :if={change.new_check} id={"#{@id}-#{change.id}-new-check"}>
            <span class="font-semibold">{gettext("New check:")}</span> {change.new_check}
          </p>
        </li>
      </ul>
      <p :if={@unchanged != []} id={"#{@id}-unchanged"} class="text-xs opacity-70">
        {ngettext("%{ids} is unchanged.", "%{ids} are unchanged.", length(@unchanged),
          ids: @unchanged |> Enum.map(&VerifyTab.shown_id/1) |> words_list()
        )}
      </p>
    </div>
    """
  end

  defp words_list([one]), do: one

  defp words_list(many) do
    {init, [last]} = Enum.split(many, -1)
    gettext("%{list} and %{last}", list: Enum.join(init, ", "), last: last)
  end
end
