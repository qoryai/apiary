defmodule ApiaryPro.PolicyRequestsTest do
  # An operator asks its clients for changes to their security policy; each client
  # decides. The owners and admins of the operator send and withdraw; whoever writes a
  # client's policy accepts in the workspaces they choose, as their own writes of the
  # policy, all or none, or declines. A client that leaves or is dropped has its pending
  # requests withdrawn with it.
  use Apiary.DataCase, async: true

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Policy
  alias Apiary.Audit.Entry
  alias Apiary.Policy.{Error, Rule}
  alias ApiaryPro.{Grants, PolicyRequests, Transfers}
  alias ApiaryPro.PolicyRequests.{Answer, Request}

  @moduletag needs: [:managed_organisations, :security]

  setup do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    other = client_fixture(operator.scope, "Bolt")
    second = workspace_fixture(client.organisation, "Staging")

    %{
      operator: operator,
      client: client,
      other: other,
      second: second,
      operator_admin: member_fixture(operator.scope, :admin),
      operator_member: member_fixture(operator.scope, :member),
      client_admin: client_member_fixture(client, :admin),
      client_member: client_member_fixture(client, :member)
    }
  end

  @changes %{
    "rules" => [
      %{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"},
      %{
        "change" => "rule_added",
        "action" => "allow",
        "host" => "assets.harness.example",
        "paths" => ["/skills/*"]
      }
    ]
  }

  defp send!(ctx, changes \\ @changes, opts \\ []) do
    attrs =
      %{"changes" => changes, "note" => "The harness calls its API."}
      |> Map.merge(Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end))

    {:ok, request} = PolicyRequests.send_request(ctx.operator.scope, attrs)
    request
  end

  defp answer_of(request, client),
    do: Repo.get_by!(Answer, request_id: request.id, organisation_id: client.organisation.id)

  defp entries(organisation_id, action) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation_id and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp hosts(workspace) do
    Repo.all(
      from r in Rule,
        where: r.workspace_id == ^workspace.id and is_nil(r.target_id),
        order_by: r.host,
        select: {r.host, r.action, r.locked}
    )
  end

  describe "sending a request" do
    test "goes to every client that may receive one by default, each pending, in both trails",
         ctx do
      request = send!(ctx)

      assert %Request{note: "The harness calls its API.", withdrawn_at: nil} = request
      assert %{"mode" => nil, "rules" => [added, held]} = request.changes
      assert %{"change" => "rule_added", "rule" => %{"host" => "api.harness.example"}} = added
      assert %{"rule" => %{"host" => "assets.harness.example", "paths" => ["/skills/*"]}} = held

      answers = Repo.all(from a in Answer, where: a.request_id == ^request.id)

      assert Enum.sort(Enum.map(answers, & &1.organisation_id)) ==
               Enum.sort([ctx.client.organisation.id, ctx.other.organisation.id])

      assert Enum.all?(answers, &(&1.state == :pending))

      assert [sent] = entries(ctx.operator.organisation.id, "policy_request.send")
      assert sent.subject_id == request.id
      assert sent.details["clients"] == 2

      for client <- [ctx.client, ctx.other] do
        assert [received] = entries(client.organisation.id, "policy_request.send")
        assert received.subject_kind == "policy_request_answer"
        assert received.details["operator_id"] == ctx.operator.organisation.id
        assert received.actor_id == ctx.operator.user.id
      end
    end

    test "goes to the clients chosen", ctx do
      request = send!(ctx, @changes, clients: [ctx.other.organisation.id])

      assert [%Answer{organisation_id: id}] =
               Repo.all(from a in Answer, where: a.request_id == ^request.id)

      assert id == ctx.other.organisation.id
      assert entries(ctx.client.organisation.id, "policy_request.send") == []
    end

    test "an admin of the operator sends, a member does not, and no client does", ctx do
      assert {:ok, _request} =
               PolicyRequests.send_request(ctx.operator_admin.scope, %{
                 "changes" => @changes,
                 "note" => "Needed."
               })

      assert {:error, :forbidden} =
               PolicyRequests.send_request(ctx.operator_member.scope, %{
                 "changes" => @changes,
                 "note" => "Needed."
               })

      assert {:error, :not_found} =
               PolicyRequests.send_request(ctx.client.owner.scope, %{
                 "changes" => @changes,
                 "note" => "Needed."
               })
    end

    test "a client without the security policy is not offered, and receives nothing", ctx do
      {:ok, _features} =
        Grants.set_client(ctx.operator.scope, ctx.other.organisation.id, [:observability])

      assert {:ok, [only]} = PolicyRequests.recipients(ctx.operator.scope)
      assert only.id == ctx.client.organisation.id

      request = send!(ctx)
      assert [_one] = Repo.all(from a in Answer, where: a.request_id == ^request.id)

      assert {:error, %Error{field: :clients}} =
               PolicyRequests.send_request(ctx.operator.scope, %{
                 "changes" => @changes,
                 "note" => "Needed.",
                 "clients" => [ctx.other.organisation.id]
               })
    end

    test "the changes are validated as the policy validates them, and the note is said", ctx do
      refuse = fn changes, note ->
        PolicyRequests.send_request(ctx.operator.scope, %{"changes" => changes, "note" => note})
      end

      assert {:error, %Error{reason: :invalid}} = refuse.(%{"rules" => []}, "Needed.")

      assert {:error, %Error{field: :host}} =
               refuse.(
                 %{
                   "rules" => [
                     %{"change" => "rule_added", "action" => "allow", "host" => "Not A Host!"}
                   ]
                 },
                 "Needed."
               )

      assert {:error, %Error{field: :paths}} =
               refuse.(
                 %{
                   "rules" => [
                     %{
                       "change" => "rule_added",
                       "action" => "allow",
                       "host" => "api.example",
                       "paths" => ["no-slash"]
                     }
                   ]
                 },
                 "Needed."
               )

      assert {:error, %Error{message: message}} =
               refuse.(
                 %{
                   "rules" => [
                     %{"change" => "rule_added", "action" => "allow", "host" => "api.example"},
                     %{"change" => "rule_removed", "host" => "api.example"}
                   ]
                 },
                 "Needed."
               )

      assert message =~ "named twice"
      assert {:error, %Error{field: :mode}} = refuse.(%{"mode" => "loose"}, "Needed.")
      assert {:error, %Error{field: :note}} = refuse.(@changes, "   ")
      assert {:error, %Error{field: :note}} = refuse.(@changes, String.duplicate("a", 2001))
      assert Repo.aggregate(Request, :count) == 0
    end
  end

  describe "the lengths" do
    # A letter with a combining accent is two code points, as the database's char_length
    # counts it, and one grapheme: the limits count code points.
    @accented "e\u0301"

    test "a note is at most 2000 code points, whatever a grapheme holds", ctx do
      at_limit = String.duplicate(@accented, 1000)
      assert String.length(at_limit) == 1000 and length(String.codepoints(at_limit)) == 2000

      assert {:ok, %Request{note: ^at_limit}} =
               PolicyRequests.send_request(ctx.operator.scope, %{
                 "changes" => @changes,
                 "note" => at_limit
               })

      for over <- [at_limit <> "a", String.duplicate(@accented, 2000)] do
        assert {:error, %Error{field: :note, message: message}} =
                 PolicyRequests.send_request(ctx.operator.scope, %{
                   "changes" => @changes,
                   "note" => over
                 })

        assert message =~ "at most 2000 characters"
      end

      assert Repo.aggregate(Request, :count) == 1
    end

    test "a reason for declining is at most 500 code points, whatever a grapheme holds",
         ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)
      at_limit = String.duplicate(@accented, 250)

      for over <- [at_limit <> "a", String.duplicate(@accented, 500)] do
        assert {:error, {:reason, message}} =
                 PolicyRequests.decline(ctx.client.owner.scope, answer.id, over)

        assert message =~ "at most 500 characters"
      end

      assert Repo.reload!(answer).state == :pending

      assert {:ok, %Answer{state: :declined, reason: ^at_limit}} =
               PolicyRequests.decline(ctx.client.owner.scope, answer.id, at_limit)
    end
  end

  describe "accepting" do
    test "makes the changes in the workspaces chosen, as the person's own writes", ctx do
      request =
        send!(ctx, %{
          "rules" => [
            %{"change" => "rule_added", "action" => "allow", "host" => "api.harness.example"}
          ],
          "mode" => "enforce"
        })

      answer = answer_of(request, ctx.client)
      workspaces = [ctx.client.workspace.id, ctx.second.id]

      assert {:ok, %Answer{state: :accepted} = accepted} =
               PolicyRequests.accept(ctx.client.owner.scope, answer.id, workspaces)

      assert Enum.sort(accepted.workspace_ids) == Enum.sort(workspaces)
      assert accepted.answered_by_id == ctx.client.owner.user.id

      for workspace <- [ctx.client.workspace, ctx.second] do
        assert hosts(workspace) == [{"api.harness.example", "allow", false}]
        assert Repo.reload!(workspace).egress_mode == "enforce"
      end

      # The policy's entries, one a change and workspace, by the person who accepted; the
      # version 1 of each workspace, written when it was created, is the instance's.
      edits =
        ctx.client.organisation.id
        |> entries("security_policy.edit")
        |> Enum.reject(&(&1.details["change"] == "first_version"))

      modes = entries(ctx.client.organisation.id, "security_policy.set_mode")
      assert length(edits) == 2 and length(modes) == 2
      assert Enum.all?(edits ++ modes, &(&1.actor_id == ctx.client.owner.user.id))

      assert [client_entry] = entries(ctx.client.organisation.id, "policy_request.accept")
      assert client_entry.details["operator_id"] == ctx.operator.organisation.id
      assert [operator_entry] = entries(ctx.operator.organisation.id, "policy_request.accept")
      assert operator_entry.details["organisation_id"] == ctx.client.organisation.id

      # The other client's answer is its own.
      assert answer_of(request, ctx.other).state == :pending

      assert {:error, :answered} =
               PolicyRequests.accept(ctx.client.owner.scope, answer.id, workspaces)
    end

    test "a change that no longer fits refuses the whole, in every workspace", ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)

      # The second workspace has the host already: nothing is made in the first either.
      second = workspace_scope(ctx.client.owner.user, ctx.second)
      {:ok, _rule} = Policy.allow(second, nil, %{host: "api.harness.example"})
      before = entries(ctx.client.organisation.id, "security_policy.edit")

      assert {:error, %Error{reason: :conflict, message: message}} =
               PolicyRequests.accept(ctx.client.owner.scope, answer.id, [
                 ctx.client.workspace.id,
                 ctx.second.id
               ])

      assert message =~ "Staging"
      assert hosts(ctx.client.workspace) == []
      assert entries(ctx.client.organisation.id, "security_policy.edit") == before
      assert Repo.reload!(answer).state == :pending
    end

    test "a rule to change or remove that is gone refuses", ctx do
      for change <- ["rule_changed", "rule_removed"] do
        request =
          send!(ctx, %{
            "rules" => [%{"change" => change, "action" => "deny", "host" => "gone.example"}]
          })

        assert {:error, %Error{reason: :not_found}} =
                 PolicyRequests.accept(
                   ctx.client.owner.scope,
                   answer_of(request, ctx.client).id,
                   [ctx.client.workspace.id]
                 )
      end
    end

    test "a change and a removal replace and take out the rule there", ctx do
      owner = ctx.client.owner.scope
      {:ok, _} = Policy.allow(owner, nil, %{host: "old.example", paths: ["/v1/*"]})
      {:ok, _} = Policy.allow(owner, nil, %{host: "drop.example"})

      request =
        send!(ctx, %{
          "rules" => [
            %{"change" => "rule_changed", "action" => "allow", "host" => "old.example"},
            %{"change" => "rule_removed", "host" => "drop.example"}
          ]
        })

      assert {:ok, _answer} =
               PolicyRequests.accept(owner, answer_of(request, ctx.client).id, [
                 ctx.client.workspace.id
               ])

      assert [%Rule{host: "old.example", paths: nil}] = Policy.list_rules(owner, nil)
    end

    test "a locked rule is an owner's: an admin's acceptance is refused, an owner's is not",
         ctx do
      owner = ctx.client.owner.scope
      {:ok, _} = Policy.deny(owner, nil, %{host: "locked.example", locked: true})

      request =
        send!(ctx, %{
          "rules" => [
            %{"change" => "rule_changed", "action" => "allow", "host" => "locked.example"}
          ]
        })

      answer = answer_of(request, ctx.client)

      assert {:error, %Error{reason: :forbidden}} =
               PolicyRequests.accept(ctx.client_admin.scope, answer.id, [ctx.client.workspace.id])

      assert [%Rule{action: "deny", locked: true}] = Policy.list_rules(owner, nil)

      assert {:ok, _answer} =
               PolicyRequests.accept(owner, answer.id, [ctx.client.workspace.id])

      assert [%Rule{action: "allow"}] = Policy.list_rules(owner, nil)
    end

    test "the mode is an owner's or an admin's: a member's acceptance is refused", ctx do
      request = send!(ctx, %{"mode" => "enforce"})
      answer = answer_of(request, ctx.client)

      assert {:error, %Error{reason: :forbidden}} =
               PolicyRequests.accept(ctx.client_member.scope, answer.id, [ctx.client.workspace.id])

      assert {:ok, _answer} =
               PolicyRequests.accept(ctx.client_admin.scope, answer.id, [ctx.client.workspace.id])
    end

    test "a member accepts in the workspaces they reach, and nowhere else", ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)

      assert Enum.map(PolicyRequests.answerable_workspaces(ctx.client_member.scope), & &1.id) ==
               [ctx.client.workspace.id]

      assert {:error, %Error{reason: :not_found}} =
               PolicyRequests.accept(ctx.client_member.scope, answer.id, [ctx.second.id])

      assert {:ok, _answer} =
               PolicyRequests.accept(ctx.client_member.scope, answer.id, [ctx.client.workspace.id])
    end

    test "nobody but the client's people answers, and no workspace of another organisation",
         ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)
      workspaces = [ctx.client.workspace.id]

      # The operator's people read the client and answer nothing there.
      assert {:error, :forbidden} = PolicyRequests.accept(ctx.client.scope, answer.id, workspaces)
      assert {:error, :forbidden} = PolicyRequests.decline(ctx.client.scope, answer.id, nil)

      # Another client's answer is not found; so is a workspace of another organisation.
      other = answer_of(request, ctx.other)

      assert {:error, :not_found} =
               PolicyRequests.accept(ctx.client.owner.scope, other.id, workspaces)

      assert {:error, :not_found} = PolicyRequests.decline(ctx.client.owner.scope, other.id, nil)

      assert {:error, :not_found} =
               PolicyRequests.accept(ctx.client.owner.scope, answer.id, [ctx.other.workspace.id])

      assert {:error, :not_found} = PolicyRequests.accept(ctx.client.owner.scope, answer.id, [])
      assert Repo.reload!(answer).state == :pending
      assert Repo.reload!(other).state == :pending
    end
  end

  describe "a person who may write the policy of no workspace" do
    # A member of the client added to no workspace of it has `policy_request.decline` by
    # their level, and may change the policy nowhere: an answer is the whole client's, so
    # they give none.
    setup ctx do
      {:ok, _} =
        ApiaryPro.WorkspaceAccess.remove(
          ctx.client.owner.scope,
          ctx.client_member.membership.id,
          ctx.client.workspace.id
        )

      %{unplaced: ctx.client_member.scope}
    end

    test "neither declines nor accepts, and the request stays open", ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)

      assert PolicyRequests.answerable_workspaces(ctx.unplaced) == []
      assert {:error, :forbidden} = PolicyRequests.decline(ctx.unplaced, answer.id, "No")

      assert {:error, :forbidden} =
               PolicyRequests.accept(ctx.unplaced, answer.id, [ctx.client.workspace.id])

      assert Repo.reload!(answer).state == :pending
      assert entries(ctx.client.organisation.id, "policy_request.decline") == []

      # Added to a workspace again, they answer.
      {:ok, _} =
        ApiaryPro.WorkspaceAccess.add(
          ctx.client.owner.scope,
          ctx.client_member.membership.id,
          ctx.second.id
        )

      assert {:ok, %Answer{state: :declined}} =
               PolicyRequests.decline(ctx.unplaced, answer.id, nil)
    end
  end

  describe "declining" do
    test "with a reason, in both trails; a reason is at most 500 characters", ctx do
      request = send!(ctx)
      answer = answer_of(request, ctx.client)

      assert {:error, {:reason, _message}} =
               PolicyRequests.decline(
                 ctx.client_member.scope,
                 answer.id,
                 String.duplicate("a", 501)
               )

      assert {:ok, %Answer{state: :declined, reason: "Not now."}} =
               PolicyRequests.decline(ctx.client_member.scope, answer.id, " Not now. ")

      assert [entry] = entries(ctx.client.organisation.id, "policy_request.decline")
      assert entry.details["reason"] == "Not now."
      assert [_entry] = entries(ctx.operator.organisation.id, "policy_request.decline")
      assert hosts(ctx.client.workspace) == []

      assert {:error, :answered} =
               PolicyRequests.accept(ctx.client.owner.scope, answer.id, [ctx.client.workspace.id])
    end
  end

  describe "withdrawing" do
    test "affects only the clients that have not answered", ctx do
      request = send!(ctx)

      {:ok, _} =
        PolicyRequests.decline(ctx.client.owner.scope, answer_of(request, ctx.client).id, nil)

      assert {:error, :forbidden} = PolicyRequests.withdraw(ctx.operator_member.scope, request.id)

      assert {:ok, %Request{withdrawn_at: %DateTime{}}} =
               PolicyRequests.withdraw(ctx.operator_admin.scope, request.id)

      assert answer_of(request, ctx.client).state == :declined
      assert answer_of(request, ctx.other).state == :withdrawn
      assert [_entry] = entries(ctx.operator.organisation.id, "policy_request.withdraw")
      assert [_entry] = entries(ctx.other.organisation.id, "policy_request.withdraw")
      assert entries(ctx.client.organisation.id, "policy_request.withdraw") == []

      assert {:error, :withdrawn} = PolicyRequests.withdraw(ctx.operator.scope, request.id)

      assert {:error, :withdrawn} =
               PolicyRequests.accept(
                 ctx.other.owner.scope,
                 answer_of(request, ctx.other).id,
                 [ctx.other.workspace.id]
               )

      # Another operator's request is not found.
      elsewhere = operator_fixture()
      assert {:error, :not_found} = PolicyRequests.withdraw(elsewhere.scope, request.id)
    end
  end

  describe "a client parting from its operator" do
    test "leaving withdraws its pending requests, with the reason, in the same change", ctx do
      pending = send!(ctx)

      accepted =
        send!(ctx, %{
          "rules" => [%{"change" => "rule_added", "action" => "deny", "host" => "x.example"}]
        })

      {:ok, _} =
        PolicyRequests.accept(ctx.client.owner.scope, answer_of(accepted, ctx.client).id, [
          ctx.client.workspace.id
        ])

      {:ok, _} = Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)

      assert %Answer{state: :withdrawn, reason: "left"} = answer_of(pending, ctx.client)
      assert answer_of(accepted, ctx.client).state == :accepted
      assert answer_of(pending, ctx.other).state == :pending

      assert [entry] = entries(ctx.client.organisation.id, "policy_request.withdraw")
      assert entry.details["reason"] == "left"
      assert [operator_entry] = entries(ctx.operator.organisation.id, "policy_request.withdraw")
      assert operator_entry.details["organisation_id"] == ctx.client.organisation.id
    end

    test "a client deleted by its operator, with no owner yet, has them withdrawn", ctx do
      {%{organisation: unowned}, _token} =
        create_client_fixture(ctx.operator.scope, %{
          "name" => "Cato",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      request = send!(ctx)
      answer = Repo.get_by!(Answer, request_id: request.id, organisation_id: unowned.id)

      {:ok, _} = ApiaryPro.Deletion.delete_client(ctx.operator.scope, unowned.id, "Cato")

      assert %Answer{state: :withdrawn, reason: "deleted"} = Repo.reload!(answer)
      assert [_entry] = entries(unowned.id, "policy_request.withdraw")
    end

    test "a drop withdraws them too", ctx do
      request = send!(ctx)
      {:ok, _} = Transfers.drop(ctx.operator.scope, ctx.client.organisation.id, "Acme")
      assert %Answer{state: :withdrawn, reason: "dropped"} = answer_of(request, ctx.client)
    end
  end

  describe "reading" do
    test "the operator's people read what they sent; the client's and the operator's read what it received",
         ctx do
      request = send!(ctx)

      assert {:ok, [%{request: %{id: id}, answers: answers}]} =
               PolicyRequests.list_sent(ctx.operator_member.scope)

      assert id == request.id
      assert Enum.map(answers, & &1.client.name) == ["Acme", "Bolt"]

      for scope <- [ctx.client_member.scope, ctx.client.scope] do
        assert {:ok, [%{request: %{id: ^id}, operator: operator}]} =
                 PolicyRequests.list_received(scope)

        assert operator.id == ctx.operator.organisation.id
      end

      assert PolicyRequests.pending_count(ctx.client_member.scope) == 1

      # An organisation of its own receives nothing of another's.
      assert {:ok, []} = PolicyRequests.list_received(sign_up_fixture().scope)
      assert PolicyRequests.pending_count(sign_up_fixture().scope) == 0
      assert {:error, :not_found} = PolicyRequests.list_sent(ctx.client.owner.scope)
    end

    test "a client without the security policy reads none", ctx do
      send!(ctx)

      {:ok, _features} =
        Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [:observability])

      scope = scope_in(ctx.client.owner.user, ctx.client.organisation, ctx.client.workspace)
      assert {:error, :not_found} = PolicyRequests.list_received(scope)
      assert PolicyRequests.pending_count(scope) == 0
      assert PolicyRequests.answerable_workspaces(scope) == []
    end
  end
end
