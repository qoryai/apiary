defmodule ApiaryProWeb.FeatureVisibilityLiveTest do
  # A feature hidden from a person is absent for them, its pages and actions not found, and
  # still works in full for the organisation's nodes and runs. The operator's people see
  # in the workspace it operates what the organisation is shown, never more, with
  # `ApiaryPro.Flags.feature_visibility?/0` on or off (`ApiaryPro.Features.hidden/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.ContractFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Policy, Repo}
  alias Apiary.Nodes.Node
  alias Apiary.Policy.Serving
  alias Apiary.Runs.{Event, Run}
  alias ApiaryPro.{Flags, Grants}

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # An operator shown Runs and the security policy; an organisation whose workspace Main it
  # operates, with a rule and a node in Main, which an instance admin left Runs alone, so
  # its security policy is hidden from its people.
  setup do
    %{instance_scope: admin} = suite_instance_admin()
    operator = operator_fixture()

    assert {:ok, _} =
             Grants.set_organisation(admin, operator.organisation.id, [
               "observability",
               "security"
             ])

    operated = operated_fixture(operator.scope, "Acme")
    in_operated = operated.owner.scope
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(in_operated)
    {:ok, _rule} = Policy.deny(in_operated, nil, %{host: "ads.example"})
    {:ok, %{digest: baseline}} = Policy.current_configuration(in_operated, nil)

    assert {:ok, _} = Grants.set_organisation(admin, operated.organisation.id, ["observability"])

    %{operator: operator, operated: operated, key: {key, secret}, node: node, baseline: baseline}
  end

  defp policy_page(operated), do: ~p"/#{operated.organisation}/#{operated.workspace}/policy"

  describe "with the flag on" do
    setup do: Flags.put_feature_visibility(true)

    test "neither the organisation's people nor the operator's open its hidden policy page",
         ctx do
      for user <- [ctx.operated.owner.user, ctx.operator.user] do
        conn = log_in_user(build_conn(), user)

        assert_raise ApiaryWeb.Features.NotFound, fn ->
          live(conn, policy_page(ctx.operated))
        end
      end
    end

    test "an action of the hidden feature is not found for the organisation's people", ctx do
      owner = scope_in(ctx.operated.owner.user, ctx.operated.organisation, ctx.operated.workspace)

      assert {:error, %Policy.Error{reason: :not_found}} =
               Policy.deny(owner, nil, %{host: "paste.example"})
    end

    test "the organisation's nodes are still served its policy, and its runs recorded", ctx do
      {key, _secret} = ctx.key
      assert Serving.managed?(key)
      assert {:ok, configuration} = Serving.fetch(key, %{})
      assert configuration.digest == ctx.baseline

      Repo.update_all(from(n in Node, where: n.id == ^ctx.node.id),
        set: [gateway_choice: :direct]
      )

      run_id = Ecto.UUID.generate()
      {k, secret} = ctx.key
      conn = signed_register(build_conn(), k.key_id, secret, Jason.encode!(registration(run_id)))
      assert %{"security_policy" => _} = json_response(conn, 200)

      {_subject, events} = first_events(run_id)
      assert signed_post(build_conn(), k.key_id, secret, events).status == 202

      run = Repo.one!(from r in Run, where: r.node_run_id == ^run_id)
      assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1
    end
  end

  describe "with the flag off" do
    setup do: Flags.put_feature_visibility(false)

    test "the operator's people are not shown the organisation's hidden policy either", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        live(conn, policy_page(ctx.operated))
      end
    end
  end

  # An open page of a feature follows what its person is shown: told of a change of what
  # is shown (`ApiaryPro.Grants`), it loads its scope again, and a page whose feature is
  # hidden from them now leaves for the organisation's overview and says so.
  describe "an open page of the operated organisation's security policy" do
    setup do
      %{instance_scope: admin} = suite_instance_admin()
      operator = operator_fixture()
      operated = operated_fixture(operator.scope, "Beacon")
      %{admin: admin, operator: operator, operated: operated}
    end

    for on? <- [false, true] do
      @on on?

      test "leaves for the organisation's people when the instance hides it (flag #{@on})", ctx do
        Flags.put_feature_visibility(@on)
        conn = log_in_user(build_conn(), ctx.operated.owner.user)
        {:ok, lv, _html} = live(conn, policy_page(ctx.operated))

        assert {:ok, _} =
                 Grants.set_organisation(ctx.admin, ctx.operated.organisation.id, [
                   "observability"
                 ])

        assert {path, flash} = assert_redirect(lv)
        assert path == ~p"/#{ctx.operated.organisation}"
        assert flash["error"] =~ "is no longer shown in Beacon"
      end
    end

    test "leaves for the operator's people when the instance hides it from the organisation (flag on)",
         ctx do
      Flags.put_feature_visibility(true)
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, policy_page(ctx.operated))

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.operated.organisation.id, [
                 "observability"
               ])

      # Told, it loads its scope again and leaves: the organisation is not shown it any more.
      assert {path, flash} = assert_redirect(lv)
      assert path == ~p"/#{ctx.operated.organisation}"
      assert flash["error"] =~ "is no longer shown in Beacon"
    end
  end
end
