defmodule ApiaryPro.PolicyRequestRacesTest do
  # A client's acceptance of its operator's policy request while the operator withdraws
  # it, while the client leaves its operator, and while another person of the client
  # accepts it too. Each side runs on a connection of its own, outside the SQL sandbox, so
  # each commits and each waits on the other's locks as it would in production. Not async:
  # what these tests commit is visible to every other test while they run, and they delete
  # it again before they end.
  #
  # The rules under test (`ApiaryPro.PolicyRequests`, docs/access.md, The lock order): an
  # acceptance holds the client and its operator `FOR SHARE`, locks the workspaces chosen
  # in the order of their ids, reads the membership and the account `FOR SHARE`, then locks
  # the answer. A withdrawal locks the request, then the answers pending. A leaving locks
  # the client `FOR NO KEY UPDATE`, then its answers pending. Whichever comes second waits
  # for the first and then finds what it did: the answer given, or withdrawn, and exactly
  # one of the two takes effect, with nothing made in the policy by the one refused.
  #
  # Each test holds the first side's transaction open until the second side is seen, in
  # the database, waiting on a lock the first side holds (`pg_blocking_pids`).
  use ExUnit.Case, async: false
  @before_compile Apiary.TestSetup

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Ecto.Query
  import Apiary.Races
  import ApiaryPro.Races

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Policy.Rule
  alias ApiaryPro.{Operators, PolicyRequests, Transfers}
  alias ApiaryPro.PolicyRequests.{Answer, Request}
  alias Ecto.Adapters.SQL.Sandbox
  alias ApiaryPro.Tenants.Tenant

  # Requests are the security policy's, between an operator and its clients: left out of
  # a run without it.
  @moduletag needs: [:managed_organisations, :security]

  setup_all :clean_up_leftovers
  setup :setup_races

  # An operator, made one by an instance admin as the product makes one, with a client of
  # it, the client's owner and an admin, a second workspace of the client, and a request
  # of the operator's pending in the client.
  setup do
    admin = sign_up()
    instance_organisation = ApiaryPro.Organisations.instance_organisation()

    Repo.insert!(%Membership{
      organisation_id: instance_organisation.id,
      user_id: admin.user.id,
      level: :owner
    })

    on_exit(fn -> clean_up_instance_entries(instance_organisation.id, admin.user.id) end)
    instance_admin = scope_in(admin.user, instance_organisation)

    operator = sign_up()
    {:ok, _operator} = Operators.change_kind(instance_admin, operator.organisation.id, :operator)
    owner = scope_in(operator.user, Repo.get!(Organisation, operator.organisation.id))
    client = client(owner)
    client_admin = member(client.owner.scope, :admin)

    {:ok, request} =
      PolicyRequests.send_request(owner, %{
        "changes" => %{
          "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "race.example"}]
        },
        "note" => "The harness calls it."
      })

    [answer] = request.answers

    %{
      operator: operator,
      owner: owner,
      client: client,
      client_admin: scope_in(client_admin.user, client.organisation, client.workspace),
      request: request,
      answer: answer
    }
  end

  describe "an acceptance racing the request's withdrawal" do
    test "accepted first: the withdrawal waits, and leaves the answer given", ctx do
      {acceptance, acceptance_pid} = hold(fn -> accept(ctx, ctx.client.owner.scope) end)
      assert {:ok, %Answer{state: :accepted}} = acceptance.result

      withdrawal = start(fn -> PolicyRequests.withdraw(ctx.owner, ctx.request.id) end)
      await_blocked(withdrawal.backend, acceptance_pid)
      commit(acceptance)

      assert {:ok, _request} = Task.await(withdrawal.task)
      assert state(ctx) == :accepted
      assert hosts(ctx) == ["race.example"]
      assert actions(ctx.client.organisation) == ["policy_request.accept"]
    end

    test "withdrawn first: the acceptance waits, and makes nothing", ctx do
      {withdrawal, withdrawal_pid} =
        hold(fn -> PolicyRequests.withdraw(ctx.owner, ctx.request.id) end)

      assert {:ok, _request} = withdrawal.result

      acceptance = start(fn -> accept(ctx, ctx.client.owner.scope) end)
      await_blocked(acceptance.backend, withdrawal_pid)
      commit(withdrawal)

      assert {:error, :withdrawn} = Task.await(acceptance.task)
      assert state(ctx) == :withdrawn
      assert hosts(ctx) == []
      assert actions(ctx.client.organisation) == ["policy_request.withdraw"]
    end
  end

  describe "an acceptance racing the client's leaving" do
    test "accepted first: the leaving waits, and the answer stays given", ctx do
      {acceptance, acceptance_pid} = hold(fn -> accept(ctx, ctx.client.owner.scope) end)
      assert {:ok, %Answer{state: :accepted}} = acceptance.result

      leaving = start(fn -> leave(ctx) end)
      await_blocked(leaving.backend, acceptance_pid)
      commit(acceptance)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Task.await(leaving.task)

      assert state(ctx) == :accepted
      assert hosts(ctx) == ["race.example"]
    end

    test "left first: the acceptance waits, and finds the request withdrawn", ctx do
      {leaving, leaving_pid} = hold(fn -> leave(ctx) end)
      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} = leaving.result

      acceptance = start(fn -> accept(ctx, ctx.client.owner.scope) end)
      await_blocked(acceptance.backend, leaving_pid)
      commit(leaving)

      # The client has no operator any more: its answers to one are not found, or withdrawn.
      assert {:error, reason} = Task.await(acceptance.task)
      assert reason in [:not_found, :withdrawn]
      assert %Answer{state: :withdrawn, reason: "left"} = Repo.get!(Answer, ctx.answer.id)
      assert hosts(ctx) == []
    end
  end

  describe "two acceptances of one answer" do
    test "the owner's first, in the same workspace: the admin's waits, and finds it answered",
         ctx do
      {first, first_pid} = hold(fn -> accept(ctx, ctx.client.owner.scope) end)
      assert {:ok, %Answer{state: :accepted}} = first.result

      second = start(fn -> accept(ctx, ctx.client_admin) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:error, :answered} = Task.await(second.task)
      assert hosts(ctx) == ["race.example"]
      assert Repo.get!(Answer, ctx.answer.id).answered_by_id == ctx.client.owner.user.id
      assert actions(ctx.client.organisation) == ["policy_request.accept"]
    end

    test "the admin's first, in another workspace: the owner's waits on the answer, and finds it answered",
         ctx do
      other = Repo.insert!(workspace(ctx.client.organisation))

      {first, first_pid} = hold(fn -> accept(ctx, ctx.client_admin, [other.id]) end)
      assert {:ok, %Answer{state: :accepted}} = first.result

      second = start(fn -> accept(ctx, ctx.client.owner.scope) end)
      await_blocked(second.backend, first_pid)
      commit(first)

      assert {:error, :answered} = Task.await(second.task)
      assert Repo.get!(Answer, ctx.answer.id).workspace_ids == [other.id]
      assert rules_in(other) == ["race.example"]
      assert hosts(ctx) == []
    end
  end

  describe "a withdrawal racing its author's demotion" do
    # An admin of the operator sent a request, and withdraws it while an owner of the
    # operator makes them a member, who may withdraw nothing. The withdrawal holds the
    # admin's membership `FOR SHARE` and asks again under it; the demotion updates it.
    setup ctx do
      author = member(ctx.operator.scope, :admin)
      scope = scope_in(author.user, Repo.get!(Organisation, ctx.operator.organisation.id))

      {:ok, request} =
        PolicyRequests.send_request(scope, %{
          "changes" => %{
            "rules" => [
              %{"change" => "rule_added", "action" => "deny", "host" => "demoted.example"}
            ]
          },
          "note" => "The harness no longer needs it."
        })

      %{author: author, author_scope: scope, authored: request}
    end

    test "withdrawn first: the demotion waits, and the request stays withdrawn", ctx do
      {withdrawal, withdrawal_pid} =
        hold(fn -> PolicyRequests.withdraw(ctx.author_scope, ctx.authored.id) end)

      assert {:ok, _request} = withdrawal.result

      demotion = start(fn -> demote(ctx) end)
      await_blocked(demotion.backend, withdrawal_pid)
      commit(withdrawal)

      assert {:ok, %Membership{level: :member}} = Task.await(demotion.task)
      assert %{withdrawn_at: %DateTime{}} = Repo.get!(Request, ctx.authored.id)
      assert [%Answer{state: :withdrawn}] = answers(ctx.authored)
    end

    test "demoted first: the withdrawal waits, is refused, and withdraws nothing", ctx do
      {demotion, demotion_pid} = hold(fn -> demote(ctx) end)
      assert {:ok, %Membership{level: :member}} = demotion.result

      withdrawal = start(fn -> PolicyRequests.withdraw(ctx.author_scope, ctx.authored.id) end)
      await_blocked(withdrawal.backend, demotion_pid)
      commit(demotion)

      assert {:error, :forbidden} = Task.await(withdrawal.task)
      assert %{withdrawn_at: nil} = Repo.get!(Request, ctx.authored.id)
      assert [%Answer{state: :pending}] = answers(ctx.authored)
    end
  end

  defp demote(ctx),
    do: Organisations.set_member_level(ctx.owner, ctx.author.membership.id, :member)

  defp answers(request),
    do: Repo.all(from a in Answer, where: a.request_id == ^request.id)

  defp accept(ctx, scope, workspace_ids \\ nil),
    do: PolicyRequests.accept(scope, ctx.answer.id, workspace_ids || [ctx.client.workspace.id])

  defp leave(ctx), do: Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)

  defp state(ctx), do: Repo.get!(Answer, ctx.answer.id).state

  defp hosts(ctx), do: rules_in(ctx.client.workspace)

  defp rules_in(workspace) do
    Repo.all(
      from r in Rule,
        where: r.workspace_id == ^workspace.id and is_nil(r.target_id),
        order_by: r.host,
        select: r.host
    )
  end

  defp workspace(organisation) do
    name = "Races workspace #{System.unique_integer([:positive])}"

    %Organisations.Workspace{organisation_id: organisation.id}
    |> Organisations.Workspace.create_changeset(%{name: name, domain: "software"})
    |> Organisations.Workspace.put_slug(Organisations.Slug.from_name(name, "workspace"))
  end

  defp scope_in(user, organisation, workspace \\ nil) do
    {:ok, scope} =
      Organisations.resolve_scope(
        Scope.for_user(user),
        organisation.slug,
        workspace && workspace.slug
      )

    scope
  end

  # The client's entries of a request's answer since it was sent, oldest first.
  defp actions(%Organisation{id: id}) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^id,
        where: e.action in ["policy_request.accept", "policy_request.withdraw"],
        order_by: [asc: e.inserted_at, asc: e.id],
        select: e.action
    )
  end

  # The instance admin's entries in the instance organisation's trail, which is not
  # deleted with the race's organisations.
  defp clean_up_instance_entries(instance_organisation_id, admin_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    Repo.delete_all(
      from e in Entry,
        where: e.organisation_id == ^instance_organisation_id and e.actor_id == ^admin_id
    )

    Sandbox.checkin(Repo)
  end
end
