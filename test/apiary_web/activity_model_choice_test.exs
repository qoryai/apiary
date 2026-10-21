defmodule ApiaryWeb.ActivityModelChoiceTest do
  # The Activity lines of a model choice: the label of `model_choice.write` in the filter,
  # the sentence by the change in the entry's details, the subject by the place of the
  # choice and the line for the run kind. The organisation's default is written under
  # `connection.write`, and says the same sentences.
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures, only: [target!: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Connections, ModelChoices}
  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: :factory

  defp entry(action, details, subject_kind \\ "model_choice"),
    do: %Entry{
      action: action,
      actor_kind: :person,
      details: details,
      subject_kind: subject_kind,
      subject_id: Ecto.UUID.generate()
    }

  defp shown(action, entry),
    do: Enum.find_value(Describer.describers(), & &1.sentence(String.to_atom(action), entry, %{}))

  test "the label is Model choice changed, and the filter offers the action" do
    %{scope: scope} = sign_up_fixture()
    assert Core.label(:"model_choice.write") == "Model choice changed"
    assert Core.offered?(scope, :"model_choice.write")
  end

  test "each change has its sentence, at the workspace and at the organisation's default" do
    for {change, sentence} <- [
          {"choice_set", "Set a model choice"},
          {"choice_changed", "Changed a model choice"},
          {"choice_removed", "Removed a model choice"},
          {"choice_locked", "Locked a model choice"},
          {"choice_unlocked", "Unlocked a model choice"}
        ],
        action <- ["model_choice.write", "connection.write"] do
      assert shown(action, entry(action, %{"change" => change, "level" => 5})) == sentence
    end
  end

  test "the subject is the place, a target or a workspace as it is now, or the default" do
    %{scope: scope} = sign_up_fixture()
    workspace_id = scope.workspace.id
    target_id = Ecto.UUID.generate()
    names = %{workspaces: %{workspace_id => "Renamed site"}, targets: %{target_id => "acme/shop"}}
    subject = &Core.subject(&1, :"model_choice.write", names, scope, scope.workspace)

    for level <- [4, 5] do
      entry = %{
        entry("model_choice.write", %{"level" => level, "name" => "Old name"})
        | workspace_id: workspace_id
      }

      assert %{text: "Renamed site's model choice"} = subject.(entry)
    end

    for level <- [2, 3] do
      entry =
        entry("model_choice.write", %{"level" => level, "name" => "x/y", "target_id" => target_id})

      assert %{text: "acme/shop's model choice"} = subject.(entry)
    end

    # A target that is gone is named as the entry named it.
    gone =
      entry("model_choice.write", %{
        "level" => 3,
        "name" => "x/y",
        "target_id" => Ecto.UUID.generate()
      })

    assert %{text: "x/y's model choice"} = subject.(gone)

    default = entry("connection.write", %{"level" => 6, "name" => scope.organisation.name})
    assert %{text: text} = Core.subject(default, :"connection.write", names, scope, nil)
    assert text == "#{scope.organisation.name}'s default model choice"
  end

  test "the change line is the run kind at levels 2 and 4, and nothing at the others" do
    for {level, action} <- [
          {2, :"model_choice.write"},
          {4, :"model_choice.write"},
          {4, :"connection.write"}
        ] do
      details = %{"change" => "choice_set", "level" => level, "run_kind" => "explore"}

      assert Enum.find_value(Describer.describers(), & &1.change(action, nil, %{}, details)) ==
               "explore runs"
    end

    for level <- [3, 5, 6] do
      details = %{"change" => "choice_set", "level" => level}

      assert Enum.find_value(
               Describer.describers(),
               & &1.change(:"model_choice.write", nil, %{}, details)
             ) == nil
    end
  end

  test "the entries a write leaves are described from the names the trail looks up" do
    %{scope: scope} = sign_up_fixture()
    target = target!(scope, "acme/shop")

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-activity-1"}]
      })

    attrs = %{provider: provider.public_id}
    {:ok, _} = ModelChoices.put_choice(scope, {target, "explore"}, attrs)
    {:ok, _} = ModelChoices.put_choice(scope, :workspace, attrs)
    {:ok, _} = ModelChoices.put_choice(scope, :organisation, attrs)
    {:ok, _} = ModelChoices.lock_choice(scope, :workspace)

    entries =
      Repo.all(
        from e in Entry,
          where: e.subject_kind == "model_choice",
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

    assert lines == [
             {"github.example/acme/shop's model choice", "Set a model choice", "explore runs"},
             {"#{scope.workspace.name}'s model choice", "Set a model choice", nil},
             {"#{scope.organisation.name}'s default model choice", "Set a model choice", nil},
             {"#{scope.workspace.name}'s model choice", "Locked a model choice", nil}
           ]
  end
end
