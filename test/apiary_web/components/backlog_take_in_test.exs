defmodule ApiaryWeb.BacklogTakeInTest do
  # What a refused Take in says (`ApiaryWeb.BacklogComponents.take_in_refused/3`), for
  # each refusal of `Apiary.WorkItems.take_in/3`, in the source's word for its items; and
  # the Take in block (`take_in_block/1`) for a person who may not take a ticket in.
  use Apiary.DataCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.BacklogComponents

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, facts: %{integration: "Tracker", item_noun: nil}}
  end

  defp said(refusal, ctx, facts \\ %{}),
    do: BacklogComponents.take_in_refused(refusal, ctx.scope, Map.merge(ctx.facts, facts))

  test "each refusal, in plain words", ctx do
    # The engine's words, which a domain without a catalogue reads.
    Gettext.put_locale("en")
    workspace = ctx.scope.workspace.name
    gone = "This ticket is no longer in #{workspace}'s Backlog, so it was not taken in."

    assert said(:not_found, ctx) == gone
    assert said(:not_linked, ctx) == gone

    assert said(:ticket_closed, ctx) ==
             "This ticket is closed at Tracker, so it was not taken in."

    assert said(:no_target, ctx) ==
             "Tracker sent no target for this ticket, so it was not taken in. " <>
               "Each work item in #{workspace} needs one."

    assert said(:target_invalid, ctx) ==
             "Tracker sent a target for this ticket that is not valid, so it was not taken in."

    assert said({:taken, %WorkItem{number: 7}}, ctx) ==
             "Someone took this ticket in already, as work item #7."

    assert said({:taken, %WorkItem{state: :exploring}}, ctx) ==
             "Someone took this ticket in already, in another workspace."

    assert said(:forbidden, ctx) == "Only members of #{workspace} take tickets in."

    for unsaved <- [:owner, %Ecto.Changeset{}] do
      assert said(unsaved, ctx) ==
               "Qory Apiary could not save the work item, so the ticket was not taken in."
    end
  end

  test "a software workspace reads repository for target", ctx do
    Gettext.put_locale("en@software")

    assert said(:no_target, ctx) ==
             "Tracker sent no repository for this ticket, so it was not taken in. " <>
               "Each work item in #{ctx.scope.workspace.name} needs one."

    assert said(:target_invalid, ctx) ==
             "Tracker sent a repository for this ticket that is not valid, so it was not " <>
               "taken in."
  end

  test "in the source's word for its items", ctx do
    assert said(:ticket_closed, ctx, %{item_noun: %{one: "task", other: "tasks"}}) ==
             "This task is closed at Tracker, so it was not taken in."
  end

  test "the block says why in place of Take in to a person who may not take one in", ctx do
    html =
      render_component(&BacklogComponents.take_in_block/1,
        id: "ti",
        ticket_id: "tk_01",
        workspace: ctx.scope.workspace.name,
        refused: BacklogComponents.take_in_who_may(ctx.scope)
      )

    refute html =~ ~s(id="ti-button")
    assert html =~ "Only members of #{ctx.scope.workspace.name} take tickets in."
  end
end
