defmodule ApiaryPro.SetUpTest do
  @moduledoc """
  The steps of the set-up's pages that the edition answers
  (`c:Apiary.Edition.set_up_steps/2`): signed out, the account's steps alone, with Invitation
  alone on a client's invitation; signed in, the core's list. The workspace's steps are set
  up inside the workspace, so the sign-up and the invitation's page list none of them. The
  title and the About column's line are the core's, with
  `ApiaryPro.Flags.operator_infrastructure?/0` on and off.
  """
  # Not async: the sign-up settings, the flag and the features are the node's, and an
  # operator is made by an instance admin, an owner of the suite's one instance organisation.
  use Apiary.DataCase, async: false

  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.{Features, Mail, Organisations}
  alias ApiaryPro.Flags
  alias ApiaryWeb.SetUpComponents

  @moduletag with_features: Features.all()

  setup do: Flags.put_operator_infrastructure(false)

  # The core's flow, as the indicator names its steps, with every feature.
  @flow_labels [
    "Name",
    "Work sources",
    "Destinations",
    "Model",
    "Harness",
    "Machines",
    "Test run"
  ]

  # The steps the set-up's pages list for the scope, on `current`.
  defp steps(scope, current \\ :name), do: SetUpComponents.steps_for(scope, current)

  # The place of the current step among the steps: the indicator's "Step N".
  defp number(steps), do: Enum.find_index(steps, &(&1.state == :current)) + 1

  defp shape(steps), do: Enum.map(steps, &{&1.label, &1.state})

  defp labels(steps), do: Enum.map(steps, & &1.label)

  # The steps of an invitation read signed out: its page, or the sign-up with `?invitation=`.
  defp invitation_steps(token, current) do
    invitation = Organisations.get_invitation_by_token(token)
    SetUpComponents.steps_for(nil, current, invitation: invitation, token: token)
  end

  # A client of a fresh operator, named Acme, and the person its invitation is to, who has
  # accepted it: the client's owner while the flag is off, its admin while it is on.
  defp client_of_an_operator do
    operator = operator_fixture()
    address = unique_user_email()

    {%{organisation: client}, token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => address})

    first = sign_up_fixture(%{email: address, invitation_token: token})
    %{operator: operator, client: client, first: first}
  end

  describe "the sign-up, signed out" do
    test "lists Your account alone, with no step of the workspace's flow" do
      list = steps(nil, :account)

      assert shape(list) == [{"Your account", :current}]
      assert ApiaryPro.SetUp.steps(nil, list) == list
    end

    @tag with_features: Features.all() -- [:factory, :workflow_model]
    test "lists Your account alone without the factory feature too" do
      assert labels(steps(nil, :account)) == ["Your account"]
    end

    test "lists the instance's steps on the set-up link's page, and none of the flow" do
      Mail.put_test_source(:none)
      list = SetUpComponents.steps_for(nil, :account, first: true)

      assert hd(list).label == "Your account"
      assert "Mail" in labels(list)
      assert Enum.all?(@flow_labels, &(&1 not in labels(list)))
    end
  end

  describe "a client's invitation, read signed out" do
    setup do
      operator = operator_fixture()
      address = unique_user_email()

      {%{organisation: client}, token} =
        create_client_fixture(operator.scope, %{"name" => "Acme", "email" => address})

      %{operator: operator, client: client, token: token, address: address}
    end

    for {flag, state} <- [{false, "off"}, {true, "on"}] do
      test "lists Invitation alone on the invitation page, with the flag #{state}", ctx do
        Flags.put_operator_infrastructure(unquote(flag))

        list = invitation_steps(ctx.token, :invitation)
        assert labels(list) == ["Invitation"]
        assert {1, 1} == {length(list), number(list)}

        [invitation] = list

        assert {invitation.id, invitation.group, invitation.path, invitation.note} ==
                 {:invitation, nil, "/invitations/#{ctx.token}", nil}

        refute Map.has_key?(invitation, :organisation_id)
      end

      test "lists Invitation alone, current, on the sign-up, with the flag #{state}", ctx do
        Flags.put_operator_infrastructure(unquote(flag))

        list = invitation_steps(ctx.token, :account)
        assert shape(list) == [{"Invitation", :current}]
      end
    end

    @tag with_features: Features.all() -- [:factory, :workflow_model]
    test "lists Invitation alone without the factory feature too", ctx do
      assert shape(invitation_steps(ctx.token, :invitation)) == [{"Invitation", :current}]
    end

    test "keeps Invitation and Your account once the client has a workspace", ctx do
      # The invitation was written before the workspace was made, so it still has none.
      # An owner of the operator makes it while the flag is on.
      Flags.put_operator_infrastructure(true)

      {:ok, _workspace} =
        Organisations.create_workspace_of_kind(
          scope_in(ctx.operator.user, ctx.client),
          Apiary.Lingo.Domain.default(),
          :first
        )

      for current <- [:invitation, :account] do
        list = invitation_steps(ctx.token, current)

        assert labels(list) == ["Invitation", "Your account"]
        assert ApiaryPro.SetUp.steps(nil, list) == list
      end
    end
  end

  describe "the invitation of an organisation that is no client, read signed out" do
    test "lists Invitation and Your account, and none of the flow" do
      open!([:organisation])
      %{scope: scope} = sign_up_fixture()

      {:ok, %{organisation: organisation}} =
        ApiaryPro.Organisations.create_organisation(scope, %{"name" => "Kestrel Works"})

      %{token: token} =
        invitation_fixture(scope_in(scope.user, organisation), %{"email" => unique_user_email()})

      for current <- [:invitation, :account] do
        list = invitation_steps(token, current)

        assert labels(list) == ["Invitation", "Your account"]
        assert ApiaryPro.SetUp.steps(nil, list) == list
      end
    end
  end

  describe "a person signed in keeps the core's list" do
    test "a person of a client, with the flag off" do
      %{client: client, first: first} = client_of_an_operator()
      assert first.membership.level == :owner

      list = steps(scope_in(first.user, client))

      assert labels(list) == ["Your account" | @flow_labels]
      assert {8, 2} == {length(list), number(list)}
      assert Enum.all?(list, &(&1.note == nil))
      assert ApiaryPro.SetUp.steps(scope_in(first.user, client), list) == list
    end

    test "a person of a client, with the flag on: no waiting list and no line from the operator" do
      Flags.put_operator_infrastructure(true)
      %{client: client, first: first} = client_of_an_operator()
      assert first.membership.level == :admin
      scope = scope_in(first.user, client)

      assert labels(steps(scope)) == ["Your account" | @flow_labels]
      assert Enum.all?(steps(scope), &(&1.note == nil))
      assert Apiary.Edition.set_up_steps(scope, []) == []
      assert Apiary.Edition.set_up_context(scope, :workspace) == nil
      assert Apiary.Edition.set_up_title(scope, nil) == "Set up your workspace"
    end

    test "an owner of the operator in a client, with the flag on" do
      Flags.put_operator_infrastructure(true)
      %{operator: operator, client: client} = client_of_an_operator()
      scope = scope_in(operator.user, client)

      list = steps(scope)
      assert Enum.all?(list, &(&1.note == nil))
      assert Apiary.Edition.set_up_context(scope, :workspace) == nil
      assert Apiary.Edition.set_up_title(scope, nil) == "Set up your workspace"
      assert ApiaryPro.SetUp.steps(scope, list) == list
    end

    test "a person who signed up with a kind" do
      open!([:organisation])
      %{scope: scope} = sign_up_fixture()

      assert shape(steps(scope)) ==
               [
                 {"Your account", :done},
                 {"Name", :current}
               ] ++ Enum.map(Enum.drop(@flow_labels, 1), &{&1, :to_come})
    end

    test "an instance admin in the organisation they signed up with, with Mail" do
      %{scope: scope} = instance_admin_fixture()
      Mail.put_test_source(:none)

      assert labels(steps(scope)) |> Enum.take(1) == ["Your account"]
      assert "Mail" in labels(steps(scope))
      assert Enum.take(labels(steps(scope)), -7) == @flow_labels
    end

    test "an instance admin where the environment sets mail has no Mail step" do
      Mail.put_test_source(:env)
      %{scope: scope} = instance_admin_fixture()

      refute "Mail" in labels(steps(scope))
      assert Enum.take(labels(steps(scope)), -7) == @flow_labels
    end

    test "the instance's pages list the same steps with another step current" do
      %{scope: scope} = instance_admin_fixture()
      Mail.put_test_source(:none)
      list = steps(scope, :mail)

      assert Enum.find(list, &(&1.id == :mail)).state == :current
      assert hd(list).label == "Your account"
    end
  end
end
