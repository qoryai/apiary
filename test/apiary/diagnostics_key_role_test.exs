defmodule Apiary.DiagnosticsKeyRoleTest do
  # What a diagnostics key may in `Apiary.Access`: `run.read_diagnostics` on a run of any
  # organisation, and `run.list_instance` on the runs of the instance, while
  # `observability` is on, and nothing else. The signed routes are
  # `ApiaryWeb.Contract.DiagnosticsControllerTest`'s. Not async: a test takes a feature away
  # from the whole node.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Access
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Run

  @action :"run.read_diagnostics"
  @list :"run.list_instance"

  setup do
    %{scope: owner} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    id = Ecto.UUID.generate()
    key = %AccessKey{node_id: id, node: %Node{id: id, kind: :diagnostics}}

    %{owner: owner, other: other, key_scope: Scope.for_access_key(key), key: key}
  end

  # Runs `fun` where every feature is on, so an action is refused by the key's rule and not
  # by its feature. The features are the whole node's.
  defp with_every_feature(fun) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())

    try do
      fun.()
    after
      Application.put_env(:apiary, :features, previous)
    end
  end

  test "reads a run of any organisation and workspace", ctx do
    assert Access.role(ctx.key_scope) == :diagnostics_key
    assert Access.check(ctx.key_scope, @action, run_fixture(ctx.owner)) == :ok
    assert Access.check(ctx.key_scope, @action, run_fixture(ctx.other)) == :ok
    assert Access.authorize(ctx.key_scope, @action, run_fixture(ctx.other)) == :ok
  end

  test "lists the runs of the instance, asked of a run with no place", ctx do
    assert Access.check(ctx.key_scope, @list, %Run{}) == :ok
    assert Access.authorize(ctx.key_scope, @list, %Run{}) == :ok

    for subject <- [ctx.owner.workspace, ctx.owner.organisation, %Node{kind: :diagnostics}, nil] do
      assert Access.check(ctx.key_scope, @list, subject) == {:error, :not_found},
             inspect(subject)
    end

    # No key of another kind lists them, nor does a person.
    %{access_key: key} = access_key_fixture(ctx.owner, node: gateway_fixture(ctx.owner))
    assert Access.check(Scope.for_access_key(key), @list, %Run{}) == {:error, :not_found}
    assert Access.check(ctx.owner, @list, %Run{}) == {:error, :not_found}
  end

  test "is not found on any other subject", ctx do
    subjects = [
      ctx.owner.workspace,
      ctx.owner.organisation,
      %Node{id: ctx.key.node_id, kind: :diagnostics},
      %Node{kind: :gateway},
      %{organisation_id: ctx.owner.organisation.id, workspace_id: ctx.owner.workspace.id},
      nil
    ]

    for subject <- subjects do
      assert Access.check(ctx.key_scope, @action, subject) == {:error, :not_found},
             inspect(subject)
    end
  end

  @tag :feature_sets
  test "is not found for any other action, on a run or anywhere", ctx do
    run = run_fixture(ctx.owner)

    # Creating an organisation is asked of no place, and refused to every scope without a
    # person (`ApiaryPro.Access`).
    answers =
      for action <- Access.actions() -- [@action, @list],
          subject <- [run, ctx.owner.workspace, ctx.owner.organisation, %Node{kind: :diagnostics}],
          answer = with_every_feature(fn -> Access.check(ctx.key_scope, action, subject) end),
          answer != {:error, :not_found},
          uniq: true,
          do: {action, answer}

    assert answers == [{:"organisation.create", {:error, :forbidden}}]
  end

  test "a key of that kind with a place is not at the instance, and reads no other run", ctx do
    id = Ecto.UUID.generate()

    misplaced = %AccessKey{
      node_id: id,
      organisation_id: ctx.owner.organisation.id,
      workspace_id: ctx.owner.workspace.id,
      workspace: ctx.owner.workspace,
      node: %Node{id: id, kind: :diagnostics}
    }

    scope = Scope.for_access_key(misplaced)

    assert Access.check(scope, @action, run_fixture(ctx.other)) == {:error, :not_found}
  end

  test "no key of another kind reads diagnostics, nor does a person", ctx do
    run = run_fixture(ctx.owner)

    for node <- [
          node_fixture(ctx.owner),
          gateway_fixture(ctx.owner),
          pool_fixture(ctx.owner)
        ] do
      %{access_key: key} = access_key_fixture(ctx.owner, node: node)
      assert Access.check(Scope.for_access_key(key), @action, run) == {:error, :forbidden}
    end

    assert Access.check(ctx.owner, @action, run) == {:error, :forbidden}
    assert Access.check(ctx.other, @action, run) == {:error, :not_found}

    assert Access.check(Scope.for_instance(ctx.owner.organisation), @action, run) ==
             {:error, :not_found}
  end

  test "an organisation's key reads none", ctx do
    gateway = organisation_gateway_fixture(ctx.owner)
    %{access_key: key} = access_key_fixture(ctx.owner, node: gateway)
    scope = Scope.for_access_key(%{key | workspace: nil})

    assert Access.check(scope, @action, run_fixture(ctx.owner)) == {:error, :not_found}
    assert Access.check(scope, @action, run_fixture(ctx.other)) == {:error, :not_found}
  end

  @tag :feature_sets
  test "is not found where observability is off", ctx do
    run = run_fixture(ctx.owner)
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, [])
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    assert Access.check(ctx.key_scope, @action, run) == {:error, :not_found}
    assert Access.check(ctx.key_scope, @list, %Run{}) == {:error, :not_found}
  end
end
