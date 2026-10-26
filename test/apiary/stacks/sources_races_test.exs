defmodule Apiary.Stacks.SourcesRacesTest do
  # Two saves of Workspace settings › Workflow (`Apiary.Stacks.Sources.save/3`) of one
  # workspace at the same time. Each side runs on a connection outside the SQL sandbox,
  # so each commits and each waits on the other's locks as it would in production
  # (`Apiary.Races`). Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  #
  # The rule under test: saves of one workspace take turns, so the second sees the
  # first's row and replaces it, and the workspace keeps one workflow.
  use ExUnit.Case, async: false

  import Apiary.Races
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Stacks
  alias Apiary.Stacks.{Sources, Stack}

  @moduletag needs: :factory

  @base %{"git" => "https://code.example.com/acme/harness", "ref" => "HEAD"}

  setup_all :clean_up_leftovers
  setup :setup_races

  test "the second save of another workflow waits for the first, and one row is left" do
    %{scope: scope, workspace: workspace} = sign_up()

    {first, first_pid} = hold(fn -> Sources.save(scope, @base, "triage") end)
    assert {:ok, %Stack{workflow: "triage"}} = first.result

    second = start(fn -> Sources.save(scope, @base, "fix") end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Stack{workflow: "fix"}} = Task.await(second.task)

    assert Repo.all(
             from s in Stack,
               where: s.workspace_id == ^workspace.id and is_nil(s.target_id),
               where: not is_nil(s.workflow),
               select: s.workflow
           ) == ["fix"]

    assert Stacks.workflow(workspace, nil) == "fix"
  end
end
