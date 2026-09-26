defmodule Apiary.AccessTest do
  # Not async: the rows of a feature switched off switch the features of the whole node.
  use Apiary.DataCase, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Features

  # Every action, and who may take it on a workspace of one organisation (decision 0076).
  # Each actor a row does not list is asserted a no. The actors:
  #
  #   member              a member of the workspace
  #   owner               an owner of the workspace
  #   other_owner         an owner of another organisation
  #   operator_on_client  an operator's staff, on an organisation the operator manages
  #   operator_elsewhere  an operator's staff, on an organisation it does not manage
  #   instance_admin      the instance admin, without a membership in the organisation
  #   access_key          a runner, with an access key of the workspace
  #   feature_off         whoever the action is for, an owner or an access key, on an
  #                       instance without the action's feature
  #
  # The managing relationship and the instance admin role of decision 0070 are not built
  # yet: an operator's staff and the instance admin reach an organisation through a
  # membership or not at all, so their rows are no. They change when those are built.
  @table [
    {:"organisation.rename", yes: [:owner, :feature_off]},
    {:"member.invite", yes: [:owner, :feature_off]},
    {:"member.change_level", yes: [:owner, :feature_off]},
    {:"member.remove", yes: [:owner, :feature_off]},
    {:"invitation.revoke", yes: [:owner, :feature_off]},
    {:"workspace.rename", yes: [:owner, :feature_off]},
    {:"access_key.create", yes: [:member, :owner, :feature_off]},
    {:"access_key.rotate", yes: [:member, :owner, :feature_off]},
    {:"access_key.revoke", yes: [:member, :owner, :feature_off]},
    {:"run.read", yes: [:member, :owner]},
    {:"run.read_log", yes: [:member, :owner]},
    {:"run.close", yes: [:member, :owner]},
    {:"retention.edit", yes: [:owner]},
    {:"security_policy.read", yes: [:member, :owner]},
    {:"security_policy.edit", yes: [:member, :owner]},
    {:"security_policy.lock", yes: [:owner]},
    {:"security_policy.set_mode", yes: [:owner]},
    {:"run.post_events", yes: [:access_key]},
    {:"run_configuration.fetch", yes: [:access_key]}
  ]

  @actors [
    :member,
    :owner,
    :other_owner,
    :operator_on_client,
    :operator_elsewhere,
    :instance_admin,
    :access_key,
    :feature_off
  ]

  # The rows are asked on an instance with every feature, whatever the suite runs under,
  # except the ones of `feature_off`, which take one away.
  @moduletag with_features: Features.all()

  test "every action has a row, and every row an action" do
    assert Enum.map(@table, &elem(&1, 0)) == Access.actions()
  end

  test "every row names only the actors of the table" do
    for {action, yes: yes} <- @table, actor <- yes do
      assert actor in @actors, "#{action} names #{inspect(actor)}, which is not an actor"
    end
  end

  test "the role table names only actions of the list" do
    for {role, actions} <- Access.roles(), action <- actions do
      assert action in Access.actions(), "#{role} names #{inspect(action)}"
    end
  end

  describe "who may" do
    setup do
      client = sign_up_fixture()
      owner = client.scope
      member = member_fixture(owner, :member).scope
      other = sign_up_fixture().scope
      operator = sign_up_fixture().scope
      unmanaged = sign_up_fixture()
      admin = sign_up_fixture().user
      %{access_key: key} = access_key_fixture(owner)

      %{
        client: client,
        unmanaged: unmanaged,
        scopes: %{
          member: member,
          owner: owner,
          other_owner: other,
          # Staff of the operator's organisation, asking in the client's: through the
          # relationship, not a membership there.
          operator_on_client: reach(operator, client),
          operator_elsewhere: reach(operator, unmanaged),
          instance_admin: %Scope{
            user: admin,
            organisation: client.organisation,
            workspace: client.workspace
          },
          access_key: Scope.for_access_key(key)
        }
      }
    end

    for {action, yes: yes} <- @table, actor <- @actors do
      @tag action: action, actor: actor, answer: actor in yes
      test "#{action}: #{actor} #{if actor in yes, do: "may", else: "may not"}", ctx do
        %{action: action, actor: actor, answer: answer} = ctx
        {scope, subject} = asked(ctx, action, actor)

        {can?, authorized} =
          if actor == :feature_off,
            do: without_feature(action, fn -> answers(scope, action, subject) end),
            else: answers(scope, action, subject)

        assert can? == answer
        assert authorized == :ok == answer

        # Why not: a feature that is off and a subject out of reach are not found; a role
        # is forbidden.
        cond do
          answer ->
            :ok

          actor == :feature_off ->
            assert authorized == {:error, :not_found}

          actor in [:other_owner, :operator_elsewhere] ->
            assert authorized == {:error, :not_found}

          true ->
            assert authorized == {:error, :forbidden}
        end
      end
    end
  end

  describe "a row of another organisation" do
    # Each action whose subject can be a row, asked by an owner of one organisation of a row
    # of another's: not found, and yes for that organisation's own owner.
    @rows [
      {:run, [:"run.read", :"run.read_log", :"run.close"]},
      {:rule, [:"security_policy.edit", :"security_policy.lock"]},
      {:access_key, [:"access_key.rotate", :"access_key.revoke"]},
      {:membership, [:"member.change_level", :"member.remove"]},
      {:invitation, [:"invitation.revoke"]}
    ]

    setup do
      %{scope: owner} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      {:ok, rule} = Apiary.Policy.allow(other, nil, %{host: "api.example"})

      %{
        owner: owner,
        other: other,
        rows: %{
          run: run_fixture(other),
          rule: rule,
          access_key: access_key_fixture(other).access_key,
          membership: member_fixture(other).membership,
          invitation: invitation_fixture(other).invitation
        }
      }
    end

    for {row, actions} <- @rows, action <- actions do
      @tag row: row, action: action
      test "#{action} of another organisation's #{row} is not found", ctx do
        %{row: row, action: action, owner: owner, other: other} = ctx
        subject = Map.fetch!(ctx.rows, row)

        refute Access.can?(owner, action, subject)
        assert Access.authorize(owner, action, subject) == {:error, :not_found}

        assert Access.can?(other, action, subject)
        assert Access.authorize(other, action, subject) == :ok
      end
    end
  end

  describe "authorize/3" do
    test "reads the membership again; can?/3 answers from the scope as loaded" do
      %{scope: owner} = sign_up_fixture()
      %{scope: stale, membership: membership} = member_fixture(owner, :owner)

      {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, :member)

      assert Access.can?(stale, :"workspace.rename", stale.workspace)
      assert Access.authorize(stale, :"workspace.rename", stale.workspace) == {:error, :forbidden}
      assert Access.authorize(stale, :"access_key.create", stale.workspace) == :ok

      {:ok, _} = Apiary.Organisations.remove_member(owner, membership.id)

      assert Access.authorize(stale, :"access_key.create", stale.workspace) ==
               {:error, :forbidden}
    end

    test "reload/1 reads once; check/3 answers from what it read" do
      %{scope: owner} = sign_up_fixture()
      %{scope: stale, membership: membership} = member_fixture(owner, :owner)
      {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, :member)

      fresh = Access.reload(stale)
      assert fresh.membership.level == :member
      assert Access.check(fresh, :"workspace.rename", fresh.workspace) == {:error, :forbidden}
      assert Access.check(fresh, :"access_key.create", fresh.workspace) == :ok
    end

    test "a scope without a user reads no membership and may nothing a role allows" do
      %{scope: owner} = sign_up_fixture()
      userless = %{owner | user: nil}

      assert Access.reload(userless).membership == nil

      assert Access.authorize(userless, :"workspace.rename", userless.workspace) ==
               {:error, :forbidden}

      assert Access.authorize(userless, :"access_key.create", userless.workspace) ==
               {:error, :forbidden}
    end

    test "without a scope, nothing" do
      for action <- Access.actions() do
        refute Access.can?(nil, action, nil)
        assert {:error, _reason} = Access.authorize(nil, action, nil)
      end
    end
  end

  # An operator's staff member, asking in `target`'s organisation and workspace with the
  # membership of the operator's own.
  defp reach(%Scope{} = staff, %{organisation: organisation, workspace: workspace}),
    do: %{staff | organisation: organisation, workspace: workspace}

  # The scope that asks and what it asks about: the organisation for the organisation's
  # actions, the workspace for the rest; another organisation's owner and an operator's
  # staff elsewhere ask about the client's.
  defp asked(ctx, action, :feature_off) do
    actor = if action in Access.roles().access_key, do: :access_key, else: :owner
    {ctx.scopes[actor], subject(ctx.client, action)}
  end

  defp asked(ctx, action, actor), do: {ctx.scopes[actor], subject(ctx.client, action)}

  defp subject(%{organisation: organisation}, action)
       when action in [:"organisation.rename", :"invitation.revoke"],
       do: organisation

  defp subject(%{workspace: workspace}, _action), do: workspace

  defp answers(scope, action, subject),
    do: {Access.can?(scope, action, subject), Access.authorize(scope, action, subject)}

  # Runs `fun` on an instance without the action's feature, and without the features that
  # need it. An action every instance has is asked on the fewest features an instance can
  # have. `observability` is on in every instance a boot accepts; its rows take it away
  # all the same, to show the answer reads it.
  defp without_feature(action, fun) do
    features =
      case Access.feature(action) do
        nil -> [:observability]
        off -> Enum.reject(Features.all(), &(&1 == off or off in Features.needs(&1)))
      end

    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, features)

    try do
      fun.()
    after
      Application.put_env(:apiary, :features, previous)
    end
  end
end
