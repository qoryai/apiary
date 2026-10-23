defmodule ApiaryWeb.ActivityTimeLimitTest do
  # The Activity lines of a time limit: the sentence by the change in the entry's details,
  # the subject by the place of the limit, and the lines for the workflow and the minutes,
  # of entries under `time_limit.edit`, and its label in the filter.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures, only: [target!: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, TimeLimits}
  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  @action :"time_limit.edit"

  test "the label is Time limit changed, and the filter offers the action" do
    %{scope: scope} = sign_up_fixture()
    assert Core.label(:"time_limit.edit") == "Time limit changed"
    assert Core.offered?(scope, :"time_limit.edit")
  end

  defp entry(details),
    do: %Entry{
      action: to_string(@action),
      actor_kind: :person,
      details: details,
      subject_kind: "time_limit",
      subject_id: Ecto.UUID.generate()
    }

  defp shown(entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(@action, entry, %{}))

  defp change(before, after_, details),
    do: Enum.find_value(Describer.describers(), & &1.change(@action, before, after_, details))

  test "each change has its sentence" do
    for {change, sentence} <- [
          {"time_limit_set", "Set a time limit"},
          {"time_limit_changed", "Changed a time limit"},
          {"time_limit_removed", "Removed a time limit"}
        ] do
      assert shown(entry(%{"change" => change, "workflow" => "hello"})) == sentence
    end
  end

  test "the subject is the place, a target or a workspace as it is now" do
    %{scope: scope} = sign_up_fixture()
    target_id = Ecto.UUID.generate()

    names = %{
      workspaces: %{scope.workspace.id => "Renamed site"},
      targets: %{target_id => "acme/shop"}
    }

    subject = &Core.subject(&1, @action, names, scope, scope.workspace)

    at_workspace = %{entry(%{"name" => "Old name"}) | workspace_id: scope.workspace.id}
    assert %{text: "Renamed site's time limit"} = subject.(at_workspace)

    at_target = entry(%{"name" => "x/y", "target_id" => target_id})
    assert %{text: "acme/shop's time limit"} = subject.(at_target)

    # A target that is gone is named as the entry named it.
    gone = entry(%{"name" => "x/y", "target_id" => Ecto.UUID.generate()})
    assert %{text: "x/y's time limit"} = subject.(gone)
  end

  test "the change lines are the workflow's runs, then the minutes" do
    set = %{"change" => "time_limit_set", "workflow" => "hello"}
    assert change(nil, %{"minutes" => 90}, set) == ["hello runs", "90 minutes"]

    changed = %{"change" => "time_limit_changed", "workflow" => "hello"}

    assert [
             "hello runs",
             from_to
           ] = change(%{"minutes" => 90}, %{"minutes" => 1}, changed)

    assert from_to == Describer.from_to("90 minutes", "1 minute")

    removed = %{"change" => "time_limit_removed", "workflow" => "hello"}
    assert change(%{"minutes" => 90}, %{}, removed) == ["hello runs"]
  end

  test "the entries a write leaves are described from the names the trail looks up" do
    %{scope: scope} = sign_up_fixture()
    target = target!(scope, "acme/shop")

    {:ok, _} = TimeLimits.put_limit(scope, target, "hello", 600)
    {:ok, _} = TimeLimits.put_limit(scope, :workspace, "hello", 90)
    {:ok, _} = TimeLimits.put_limit(scope, :workspace, "hello", 120)
    {:ok, _} = TimeLimits.delete_limit(scope, target, "hello")

    entries =
      Repo.all(
        from e in Entry,
          where: e.subject_kind == "time_limit",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

    names = Audit.names(scope, entries)

    lines =
      for entry <- entries do
        action = String.to_atom(entry.action)
        subject = Core.subject(entry, action, names, scope, scope.workspace).text

        {subject, Core.sentence(action, entry, names),
         Core.change(action, entry.before || %{}, entry.after || %{}, entry.details)}
      end

    workspace = "#{scope.workspace.name}'s time limit"

    assert [
             {"github.example/acme/shop's time limit", "Set a time limit",
              ["hello runs", "600 minutes"]},
             {^workspace, "Set a time limit", ["hello runs", "90 minutes"]},
             {^workspace, "Changed a time limit", ["hello runs", _from_to]},
             {"github.example/acme/shop's time limit", "Removed a time limit", ["hello runs"]}
           ] = lines
  end
end
