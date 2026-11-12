defmodule ApiaryProWeb.FeatureVisibilityLiveTest do
  # A feature hidden from a person is absent for them, its pages and actions not found, and
  # still works in full for the organisation's nodes and runs. With
  # `ApiaryPro.Flags.feature_visibility?/0` on, the operator's people see in a client what
  # the operator is shown (`ApiaryPro.Features.hidden/1`).
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

  # An operator shown Runs and the security policy; its client, whose workspace has a rule
  # and a node, shown Runs alone, so its security policy is hidden from its people.
  setup do
    %{instance_scope: admin} = suite_instance_admin()
    operator = operator_fixture()

    assert {:ok, _} =
             Grants.set_organisation(admin, operator.organisation.id, [
               "observability",
               "security"
             ])

    client = client_fixture(operator.scope, "Acme")
    in_client = client.owner.scope
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(in_client)
    {:ok, _rule} = Policy.deny(in_client, nil, %{host: "ads.example"})
    {:ok, %{digest: baseline}} = Policy.current_configuration(in_client, nil)

    assert {:ok, _} = Grants.set_client(operator.scope, client.organisation.id, ["observability"])

    %{operator: operator, client: client, key: {key, secret}, node: node, baseline: baseline}
  end

  defp policy_page(client), do: ~p"/#{client.organisation}/#{client.workspace}/policy"

  describe "with the flag on" do
    setup do: Flags.put_feature_visibility(true)

    test "the operator's people open the client's hidden policy page; the client's people do not",
         ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, policy_page(ctx.client))
      assert render(lv) =~ "ads.example"

      conn = log_in_user(build_conn(), ctx.client.owner.user)

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        live(conn, policy_page(ctx.client))
      end
    end

    test "an action of the hidden feature is not found for the client's people", ctx do
      owner = scope_in(ctx.client.owner.user, ctx.client.organisation, ctx.client.workspace)

      assert {:error, %Policy.Error{reason: :not_found}} =
               Policy.deny(owner, nil, %{host: "paste.example"})
    end

    test "the client's nodes are still served its policy, and its runs recorded", ctx do
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

    test "the operator's people are not shown the client's hidden policy either", ctx do
      conn = log_in_user(build_conn(), ctx.operator.user)

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        live(conn, policy_page(ctx.client))
      end
    end
  end

  # An open page of a feature follows what its person is shown: told of a change of what
  # is shown (`ApiaryPro.Grants`), it loads its scope again, and a page whose feature is
  # hidden from them now leaves for the organisation's overview and says so.
  describe "an open page of the client's security policy" do
    setup do
      %{instance_scope: admin} = suite_instance_admin()
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Beacon")
      %{admin: admin, operator: operator, client: client}
    end

    for on? <- [false, true] do
      @on on?

      test "leaves for its client's people when the operator hides it (flag #{@on})", ctx do
        Flags.put_feature_visibility(@on)
        conn = log_in_user(build_conn(), ctx.client.owner.user)
        {:ok, lv, _html} = live(conn, policy_page(ctx.client))

        assert {:ok, _} =
                 Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [
                   "observability"
                 ])

        assert {path, flash} = assert_redirect(lv)
        assert path == ~p"/#{ctx.client.organisation}"
        assert flash["error"] =~ "is no longer shown in Beacon"
      end
    end

    test "stays for the operator's people when the operator hides it from the client (flag on)",
         ctx do
      Flags.put_feature_visibility(true)
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, policy_page(ctx.client))

      assert {:ok, _} =
               Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [
                 "observability"
               ])

      # Told, it loads its scope again and stays: the operator is still shown it.
      assert render(lv) =~ "Policy"
      assert Process.alive?(lv.pid)
      refute_redirected(lv, ~p"/#{ctx.client.organisation}")
    end

    test "leaves for the operator's people when the operator is not shown it (flag on)", ctx do
      Flags.put_feature_visibility(true)
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, policy_page(ctx.client))

      assert {:ok, _} =
               Grants.set_organisation(ctx.admin, ctx.operator.organisation.id, [
                 "observability"
               ])

      assert {path, flash} = assert_redirect(lv)
      assert path == ~p"/#{ctx.client.organisation}"
      assert flash["error"] =~ "is no longer shown in Beacon"
    end
  end
end
