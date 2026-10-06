defmodule Apiary.VariablesCheckAboveTest do
  @moduledoc """
  `Apiary.Variables.check_above/2`: a change of the level above's variables, as an edition
  hands it over, checked against the workspaces below it and their repositories.
  """
  use Apiary.DataCase, async: true

  @moduletag needs: :security

  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, Policy, Variables}
  alias Apiary.Runs.Target
  alias Apiary.Variables.Variable

  setup do
    owner = sign_up_fixture()
    other = workspace_scope(owner.user, workspace_fixture(owner.organisation, "Acme docs"))
    %{scope: owner.scope, other: other, site: target!(owner.scope, "acme/site")}
  end

  defp target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp set!(scope, holder, name, value) do
    {:ok, variable} = Variables.create_variable(scope, holder, %{name: name, value: value})
    variable
  end

  # A variable of the level as the edition hands it over: a struct it has not saved.
  defp above(name, value, opts \\ []),
    do: %Variable{name: name, value: value, locked: Keyword.get(opts, :locked, false)}

  # 15 names of 4 bytes with 4096 bytes each: 61500 bytes.
  defp large, do: for(i <- 10..24, do: above("A_#{i}", String.duplicate("a", 4096)))

  test "for no workspace it is :ok, whatever the level holds" do
    assert Variables.check_above([], []) == :ok
    assert Variables.check_above([], large() ++ large()) == :ok
  end

  test "a set spelled as below and within the limits is :ok, and nothing is written",
       %{scope: scope, other: other, site: site} do
    set!(scope, :workspace, "REGION", "us-east-1")
    set!(scope, site, "LOG_LEVEL", "debug")
    set = [above("REGION", "eu-west-1"), above("LOG_LEVEL", "info", locked: true)]

    assert Enum.all?(set, &is_nil(&1.id))
    assert Variables.check_above([scope.workspace, other.workspace], set) == :ok
    assert Repo.aggregate(Variable, :count) == 2
  end

  test "another spelling below is refused with its spelling there, in the first workspace found",
       %{scope: scope, other: other, site: site} do
    set!(other, :workspace, "Region", "us-east-1")
    set!(scope, site, "log_level", "debug")
    set = [above("REGION", "eu-west-1"), above("LOG_LEVEL", "info")]
    first = scope.workspace
    second = other.workspace

    assert {:error, {:spelled_otherwise, ^first, "log_level"}} =
             Variables.check_above([first, second], set)

    assert {:error, {:spelled_otherwise, ^second, "Region"}} =
             Variables.check_above([second, first], set)

    # The same spelling is none, locked or not.
    assert Variables.check_above([first, second], [
             above("Region", "eu-west-1", locked: true),
             above("log_level", "info")
           ]) == :ok

    # Another organisation's spelling is not this one's.
    stranger = sign_up_fixture().scope
    set!(stranger, :workspace, "region", "x")
    assert Variables.check_above([first], [above("Region", "eu-west-1")]) == :ok
  end

  test "too many names for the workspace, or for a repository, said with its workspace",
       %{scope: scope, other: other, site: site} do
    first = scope.workspace
    second = other.workspace
    for i <- 1..5, do: set!(scope, :workspace, "W#{i}", "")
    for i <- 1..5, do: set!(other, :workspace, "W#{i}", "")
    for i <- 1..3, do: set!(scope, site, "T#{i}", "")
    set = for i <- 1..120, do: above("O#{i}", "")

    # 125 names for each workspace, 128 for the repository: the limit.
    assert Variables.check_above([second, first], set) == :ok

    # One more takes the repository over, and neither workspace.
    one_more = set ++ [above("O121", "")]
    assert {:error, {:too_many_names, ^first}} = Variables.check_above([second, first], one_more)
    assert Variables.check_above([second], one_more) == :ok

    # Four more take a workspace itself over.
    more = set ++ for i <- 121..124, do: above("O#{i}", "")
    assert {:error, {:too_many_names, ^second}} = Variables.check_above([second, first], more)
  end

  test "too large for the workspace, or for a repository, said with its workspace",
       %{scope: scope, other: other, site: site} do
    first = scope.workspace
    second = other.workspace
    # 61500 + 4001 = 65501 for each workspace; 65536 with the repository's own 35, the limit.
    set!(scope, :workspace, "W", String.duplicate("w", 4000))
    set!(other, :workspace, "W", String.duplicate("w", 4000))
    set!(scope, site, "S", String.duplicate("s", 34))
    assert Variables.check_above([second, first], large()) == :ok

    # A byte more takes the repository over, and neither workspace.
    one_more = large() ++ [above("X", "")]
    assert {:error, {:too_large, ^first}} = Variables.check_above([second, first], one_more)
    assert Variables.check_above([second], one_more) == :ok

    # 36 more take a workspace itself over.
    more = large() ++ [above("X", String.duplicate("x", 35))]
    assert {:error, {:too_large, ^second}} = Variables.check_above([second, first], more)
  end

  test "a name the level locks counts its own value, and none of the values it sets aside",
       %{scope: scope, site: site} do
    workspace = scope.workspace
    set!(scope, :workspace, "BIG", String.duplicate("w", 4096))
    set!(scope, site, "BIG", String.duplicate("s", 4096))

    # Unlocked, the workspace's value replaces the level's: 61500 + 3 + 4096 = 65599.
    assert {:error, {:too_large, ^workspace}} =
             Variables.check_above([workspace], large() ++ [above("BIG", "x")])

    # Locked, the workspace's and the repository's are set aside: 61504. Not an error.
    assert Variables.check_above([workspace], large() ++ [above("BIG", "x", locked: true)]) ==
             :ok
  end

  test "what a variable must be on its own is not checked here", %{scope: scope} do
    assert Variables.check_above([scope.workspace], [
             above("QORY_TOKEN", "x"),
             above("not a name", "x"),
             above("LONG", String.duplicate("v", 5000))
           ]) == :ok
  end

  test "runs inside the caller's transaction, under the locks it took",
       %{scope: scope, other: other} do
    ids = [scope.workspace.id, other.workspace.id]

    assert {:ok, :ok} =
             Repo.transact(fn ->
               {:ok, workspaces} = Policy.lock_workspaces(scope, ids)
               %{} = Access.reload(scope, lock: :share)
               {:ok, Variables.check_above(workspaces, [above("REGION", "eu-west-1")])}
             end)
  end
end
