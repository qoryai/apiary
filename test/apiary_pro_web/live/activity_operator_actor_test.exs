defmodule ApiaryProWeb.ActivityOperatorActorTest do
  # Who made an entry in a client, on its Activity page, while the operator owns its
  # clients (`ApiaryPro.Flags.operator_infrastructure?/0`): a person who acted there
  # through its operator, beside the operator's name; anyone else as the core says them.
  # With the flag off, as it was. The flag is set per process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Nodes, Organisations, Repo}
  alias ApiaryPro.{Flags, Grants, Operators, PolicyRequests, Reach}

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    Flags.put_operator_infrastructure(true)
    %{operator: operator, operator_name: name, client: client}
  end

  defp entry(organisation, action) do
    Repo.one(
      from e in Apiary.Audit.Entry,
        where: e.organisation_id == ^organisation.id and e.action == ^Atom.to_string(action),
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  defp actor(user, organisation, entry) do
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), "/#{organisation.slug}/audit-log")
    render_async(lv)

    lv
    |> element("#entry-#{entry.id}-actor")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".q-cut, .q-faint")
    |> Enum.map_join(" ", &(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Every entry in `organisation` that names an operator beside its person.
  defp tagged(organisation) do
    Repo.all(from e in Apiary.Audit.Entry, where: e.organisation_id == ^organisation.id)
    |> Enum.filter(&Map.has_key?(&1.details || %{}, "via_operator_id"))
  end

  defp url, do: &"http://localhost/invitations/#{&1}"

  # A client made with the flag as it is, with its first admin's invitation pending.
  defp fresh_client(ctx, name) do
    {%{organisation: client}, _token} =
      create_client_fixture(ctx.operator.scope, %{
        "name" => name,
        "email" => Apiary.AccountsFixtures.unique_user_email()
      })

    client
  end

  # A policy request the operator sent while the flag was off, pending in the client.
  defp pending_request!(ctx) do
    Flags.put_operator_infrastructure(false)

    {:ok, request} =
      PolicyRequests.send_request(ctx.operator.scope, %{
        "changes" => %{
          "rules" => [
            %{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"}
          ]
        },
        "note" => "The harness calls its API."
      })

    Flags.put_operator_infrastructure(true)
    request
  end

  defp withdrawn_for_client(ctx) do
    {:ok, 1} =
      Repo.transact(fn ->
        PolicyRequests.withdraw_for_client(
          ctx.operator.scope,
          ctx.client.organisation,
          ctx.operator.organisation,
          "dropped"
        )
      end)

    entry(ctx.client.organisation, :"policy_request.withdraw")
  end

  # `user` in the operator at `operator_level` and in the client at `client_level`, joined
  # while the flag was off.
  defp in_both(ctx, operator_level, client_level) do
    Flags.put_operator_infrastructure(false)
    %{user: user} = member_fixture(ctx.operator.scope, operator_level)
    %{membership: joined} = join_fixture(ctx.client.owner.scope, user)

    if client_level != :member,
      do:
        {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, client_level)

    Flags.put_operator_infrastructure(true)
    user
  end

  # A node made in the client by the scope's person, and its entry.
  defp made_node(ctx, scope, name) do
    {:ok, _node} = Nodes.create_node(scope, %{kind: "node", name: name})
    entry(ctx.client.organisation, :"node.create")
  end

  describe "while the operator owns its clients" do
    test "an operator person's entry names the operator beside them", ctx do
      made = made_node(ctx, ctx.client.scope, "build-1")
      assert made.details["via_operator_id"] == ctx.operator.organisation.id

      email = ctx.operator.user.email
      expected = "#{email} of #{ctx.operator_name}"

      assert actor(ctx.client.owner.user, ctx.client.organisation, made) == expected
      # The operator's person reads the entry they made as theirs.
      assert actor(ctx.operator.user, ctx.client.organisation, made) == "#{expected} you"
    end

    test "a client person's entry, and the operator's trail, are as the core says", ctx do
      # The client's owner renames its workspace: no operator beside them.
      {:ok, _} =
        Apiary.Organisations.update_workspace(ctx.client.owner.scope, %{"name" => "Platform"})

      renamed = entry(ctx.client.organisation, :"workspace.rename")
      refute Map.has_key?(renamed.details || %{}, "via_operator_id")

      assert actor(ctx.client.owner.user, ctx.client.organisation, renamed) ==
               "#{ctx.client.owner.user.email} you"

      # In the operator itself, its owner acts as anywhere.
      {:ok, _} = Nodes.create_node(ctx.operator.scope, %{kind: "node", name: "own-1"})
      own = entry(ctx.operator.organisation, :"node.create")
      refute Map.has_key?(own.details || %{}, "via_operator_id")

      assert actor(ctx.operator.user, ctx.operator.organisation, own) ==
               "#{ctx.operator.user.email} you"
    end
  end

  describe "while the operator owns its clients, from the operator's pages" do
    test "a client's creation, and its first admin's invitation, its renewal and its revocation",
         ctx do
      client = fresh_client(ctx, "Beta")
      operator_admin = member_fixture(ctx.operator.scope, :admin)
      [invitation] = Operators.list_clients(ctx.operator.scope) |> elem(1) |> pending_of(client)

      Apiary.Mail.put_test_source(:none)

      {:ok, _, {:link, _}} =
        Operators.renew_admin_invitation(operator_admin.scope, client.id, invitation.id, url())

      [renewed] = Operators.list_clients(ctx.operator.scope) |> elem(1) |> pending_of(client)
      {:ok, _} = Operators.revoke_admin_invitation(ctx.operator.scope, client.id, renewed.id)

      owner = "#{ctx.operator.user.email} of #{ctx.operator_name}"
      admin = "#{operator_admin.user.email} of #{ctx.operator_name}"

      for {action, words} <- [
            {:"client.create", "#{owner} you"},
            {:"client.invite_admin", "#{owner} you"},
            {:"client.renew_admin_invitation", admin},
            {:"client.revoke_admin_invitation", "#{owner} you"}
          ] do
        made = entry(client, action)
        assert made.details["via_operator_id"] == ctx.operator.organisation.id, "#{action}"
        assert actor(ctx.operator.user, client, made) == words, "#{action}"
      end

      # The operator's trail is as it was.
      assert tagged(ctx.operator.organisation) == []
    end

    test "a client's features granted", ctx do
      {:ok, _} =
        Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [:observability])

      made = entry(ctx.client.organisation, :"client.grant_features")
      assert made.details["via_operator_id"] == ctx.operator.organisation.id

      assert actor(ctx.client.owner.user, ctx.client.organisation, made) ==
               "#{ctx.operator.user.email} of #{ctx.operator_name}"

      assert tagged(ctx.operator.organisation) == []
    end

    @tag needs: :security
    test "a client's answers withdrawn with it, the client's copy", ctx do
      pending_request!(ctx)
      made = withdrawn_for_client(ctx)
      assert made.details["via_operator_id"] == ctx.operator.organisation.id

      assert actor(ctx.client.owner.user, ctx.client.organisation, made) ==
               "#{ctx.operator.user.email} of #{ctx.operator_name}"

      # The operator's copy names the client, and nobody beside its person.
      copy = entry(ctx.operator.organisation, :"policy_request.withdraw")
      assert copy.details["organisation_id"] == ctx.client.organisation.id
      assert tagged(ctx.operator.organisation) == []
    end

    @tag needs: :security
    test "a client deleted by the operator: its invitations and answers, not the operator's entry",
         ctx do
      Flags.put_operator_infrastructure(false)
      client = fresh_client(ctx, "Cato")
      pending_request!(ctx)

      {:ok, _} = ApiaryPro.Deletion.delete_client(ctx.operator.scope, client.id, "Cato")

      for action <- [:"invitation.revoke", :"policy_request.withdraw"] do
        assert entry(client, action).details["via_operator_id"] == ctx.operator.organisation.id,
               "#{action}"
      end

      assert entry(ctx.operator.organisation, :"client.delete")
      assert tagged(ctx.operator.organisation) == []
    end

    test "nobody without a level in the operator, and nobody in the client's scope", ctx do
      stranger = Apiary.OrganisationsFixtures.sign_up_fixture()
      client = ctx.client.organisation

      for scope <- [stranger.scope, ctx.client.owner.scope] do
        assert ApiaryPro.Edition.audit_details(Reach.in_client(scope, client), client.id, %{}) ==
                 %{}
      end
    end
  end

  describe "someone in both organisations" do
    # Their entry in the client, made in it, and the one their scope in the operator would
    # write in it from the operator's pages.
    defp both_ways(ctx, user) do
      {:ok, _} =
        Organisations.update_workspace(
          scope_in(user, ctx.client.organisation, ctx.client.workspace),
          %{"name" => "Renamed #{System.unique_integer([:positive])}"}
        )

      made = entry(ctx.client.organisation, :"workspace.rename")

      from_operator =
        Reach.in_client(scope_in(user, ctx.operator.organisation), ctx.client.organisation)

      {made.details || %{},
       ApiaryPro.Edition.audit_details(from_operator, ctx.client.organisation.id, %{})}
    end

    test "an admin of the operator who is a member of the client is named with the operator",
         ctx do
      user = in_both(ctx, :admin, :member)
      operator_id = ctx.operator.organisation.id

      assert {%{"via_operator_id" => ^operator_id}, %{"via_operator_id" => ^operator_id}} =
               both_ways(ctx, user)
    end

    test "equal levels in both: not named with the operator", ctx do
      user = in_both(ctx, :admin, :admin)
      {made, from_operator} = both_ways(ctx, user)
      refute Map.has_key?(made, "via_operator_id")
      assert from_operator == %{}
    end

    test "a member of the operator who is an admin of the client: not named with the operator",
         ctx do
      user = in_both(ctx, :member, :admin)
      {made, from_operator} = both_ways(ctx, user)
      refute Map.has_key?(made, "via_operator_id")
      assert from_operator == %{}
    end

    test "equal levels in both, the one in the client suspended: named with the operator",
         ctx do
      user = in_both(ctx, :admin, :admin)
      client = ctx.client.organisation

      joined =
        Repo.get_by!(Apiary.Organisations.Membership,
          organisation_id: client.id,
          user_id: user.id
        )

      Flags.put_operator_infrastructure(false)
      {:ok, _} = Organisations.suspend_member(ctx.client.owner.scope, joined.id)
      Flags.put_operator_infrastructure(true)

      from_operator = Reach.in_client(scope_in(user, ctx.operator.organisation), client)
      operator_id = ctx.operator.organisation.id

      assert ApiaryPro.Edition.audit_details(from_operator, client.id, %{}) ==
               %{"via_operator_id" => operator_id}
    end
  end

  describe "with the flag off" do
    test "an entry made while it was on reads as the core says it", ctx do
      made = made_node(ctx, ctx.client.scope, "build-2")
      Flags.put_operator_infrastructure(false)

      assert actor(ctx.client.owner.user, ctx.client.organisation, made) ==
               ctx.operator.user.email
    end

    @tag needs: :security
    test "an operator's entries in a client name nobody beside its person", ctx do
      pending_request!(ctx)
      Flags.put_operator_infrastructure(false)

      client = fresh_client(ctx, "Delta")

      {:ok, _} =
        Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [:observability])

      withdrawn = withdrawn_for_client(ctx)

      assert tagged(client) == []
      assert tagged(ctx.client.organisation) == []
      assert tagged(ctx.operator.organisation) == []

      assert actor(ctx.client.owner.user, ctx.client.organisation, withdrawn) ==
               ctx.operator.user.email
    end

    test "nothing is added to an entry", ctx do
      Flags.put_operator_infrastructure(false)

      {:ok, _} =
        Apiary.Organisations.update_workspace(ctx.client.owner.scope, %{"name" => "Platform"})

      renamed = entry(ctx.client.organisation, :"workspace.rename")
      refute Map.has_key?(renamed.details || %{}, "via_operator_id")

      assert ApiaryPro.Edition.audit_details(ctx.client.scope, ctx.client.organisation.id, %{}) ==
               %{}
    end
  end

  defp pending_of(rows, client),
    do: Enum.find(rows, &(&1.organisation.id == client.id)).owner_invitations
end
