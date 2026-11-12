defmodule ApiaryPro.PolicyRequests do
  @moduledoc """
  An operator's requests for changes to its clients' security policy, and the clients'
  answers. The policy is the client's: an operator provides the harness its clients run,
  and when the harness needs a host or a mode the client's policy does not give it, the
  operator asks, the way an application installed in an organisation asks it for new
  permissions, and each client decides.

  ## A request

  An owner or an admin of the operator writes one (`send_request/2`,
  `policy_request.send`): the changes, rules to add, change or remove in a workspace's
  baseline and the mode, validated as the policy validates a write
  (`Apiary.Policy.requested_changes/1`), and a note saying why the harness needs them. It
  goes to the clients chosen, every client by default, of those that may receive one
  (`recipients/1`): in use, not suspended, with the `security` feature. Each client
  answers separately: one `ApiaryPro.PolicyRequests.Answer` a client, `pending` until it is
  answered. The operator's owners and admins withdraw a request (`withdraw/2`,
  `policy_request.withdraw`) from the clients that have not answered it; an answer given
  stays. Every person of the operator reads its requests and the answers on its Policy
  requests page (`list_sent/1`, `client.read`).

  ## An answer

  In the client, whoever may write its policy answers (`policy_request.accept`,
  `policy_request.decline`, with `security_policy.edit` in at least one workspace: an
  answer is the whole client's, so a person who may write the policy nowhere, a member
  added to no workspace, answers nothing). `accept/3` makes the changes in
  the workspaces chosen, each one the person may write, through the policy's writes
  as that person (`Apiary.Policy.apply_requested/3`): every check, lock and audit entry of
  a write of the policy holds, so a locked rule is an owner's to change or remove and the
  mode an owner's or an admin's. It is all or nothing across the workspaces: a change that
  no longer fits the policy as it is, a rule to add that is there already, one to change or
  remove that is gone, one the person may not make or the policy refuses, refuses the
  acceptance with its sentence, and nothing is made. `decline/3` declines, with a reason or
  none. The operator's people read a client's requests there and answer none. Where the
  client's organisation requires `enforce` in every workspace
  (`ApiaryPro.OrganisationPolicy`, the floor), a requested mode of `enforce` is what holds
  already and changes nothing, and `observe` refuses the whole acceptance with the floor's
  sentence; a requested rule the organisation's policy denies is made and listed, and not
  in force.

  ## Parting

  A client that is dropped or deleted by its operator has its pending answers withdrawn
  in that transaction (`withdraw_for_client/4`, called by `ApiaryPro.Transfers` and
  `Apiary.Deletion`), with the reason `dropped` or `deleted`.

  ## The trail

  Each step is an entry, in the operator's trail and in the client's, where each sees it:
  sending (`policy_request.send`, the request in the operator's, and its receipt, the
  answer, in each client's), accepting, declining and withdrawing, each naming the other
  side. The changes accepted are the policy's entries, one a change and workspace.

  ## The feature

  Requests are the security policy's, and the `security` feature's: the operator needs it
  to send one, and a client to receive one and to answer it. Where it is off, every
  function here answers `{:error, :not_found}`.

  ## Race safety

  In the lock order of docs/access.md. Sending holds the clients chosen `FOR SHARE`, in
  the order of their ids, then the operator (`Apiary.Access.reload/2` with
  `lock: :share`), so a client's drop waits for it or came first and is seen.
  Accepting holds the client and its operator `FOR SHARE`, locks the workspaces chosen in
  the order of their ids as a write of the policy does (`Apiary.Policy.lock_workspaces/2`),
  reads the membership and the account `FOR SHARE`, then locks the answer; declining the
  same without the workspaces. Accepting and declining also need a workspace whose policy
  the person may write, their workspace access held `FOR SHARE`, since an answer is the
  whole client's. Withdrawing holds the operator, the membership and the account
  `FOR SHARE`, then locks the request, then the answers pending, in the order of their
  ids, and asks the action again. A drop locks the client first, then the answers. So of
  an acceptance and a withdrawal, two acceptances of one answer, or an acceptance and a
  drop, the second waits for the first, and then finds the answer given or withdrawn.
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Policy, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.Error
  alias ApiaryPro.{Reach, Tenants, WorkspaceAccess}
  alias ApiaryPro.PolicyRequests.{Answer, Request}
  alias ApiaryPro.Tenants.Tenant

  @note_max 2000
  @reason_max 500

  @typedoc "Why a request or an answer is refused."
  @type refusal ::
          {:error,
           Access.reason() | :answered | :withdrawn | :busy | {:reason, String.t()} | Error.t()}

  @typedoc "A request with its answers, each with its client, for the operator's page."
  @type sent :: %{request: Request.t(), answers: [%{answer: Answer.t(), client: %Organisation{}}]}

  @typedoc "An answer of the client's, with its request and the operator that sent it."
  @type received :: %{answer: Answer.t(), request: Request.t(), operator: %Organisation{} | nil}

  @doc "note_max/0 is the most characters a request's note holds."
  @spec note_max() :: pos_integer
  def note_max, do: @note_max

  @doc "reason_max/0 is the most characters a reason for declining holds."
  @spec reason_max() :: pos_integer
  def reason_max, do: @reason_max

  ## The operator

  @doc """
  recipients/1 is the clients of the scope's organisation, an operator, that may receive
  a policy request, by name: in use, not suspended, with the `security` feature. A client
  without it is not offered. `{:ok, clients}`; `Apiary.Access`'s answer to
  `policy_request.send` otherwise.
  """
  @spec recipients(Scope.t()) :: {:ok, [%Organisation{}]} | {:error, Access.reason()}
  def recipients(%Scope{organisation: %Organisation{} = operator} = scope) do
    with :ok <- Access.authorize(scope, :"policy_request.send", operator) do
      {:ok, operator.id |> clients_query() |> Repo.all() |> Tenants.put() |> eligible()}
    end
  end

  def recipients(_scope), do: {:error, :not_found}

  @doc """
  list_sent/1 is the policy requests of the scope's organisation, an operator, newest
  first, each with its answers and their clients, by the clients' names (`client.read`,
  where `security` is on). `{:ok, [sent]}`; `{:error, :not_found}` in an organisation
  that is no operator or without the feature, and `Apiary.Access`'s answer otherwise.
  """
  @spec list_sent(Scope.t()) :: {:ok, [sent]} | {:error, Access.reason()}
  def list_sent(%Scope{organisation: %Organisation{id: operator_id} = operator} = scope) do
    with :ok <- Access.authorize(scope, :"client.read", operator),
         :ok <- feature(scope) do
      requests =
        Repo.all(
          from r in Request,
            where: r.organisation_id == ^operator_id,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 200,
            preload: :author
        )

      answers =
        Repo.all(
          from a in Answer,
            join: o in Organisation,
            on: o.id == a.organisation_id,
            where: a.request_id in ^Enum.map(requests, & &1.id),
            order_by: [asc: o.name, asc: o.id],
            preload: :answered_by,
            select: {a, o}
        )
        |> Enum.group_by(&elem(&1, 0).request_id, fn {answer, client} ->
          %{answer: answer, client: client}
        end)

      {:ok,
       for(
         request <- requests,
         do: %{request: request, answers: Map.get(answers, request.id, [])}
       )}
    end
  end

  def list_sent(_scope), do: {:error, :not_found}

  @doc """
  send_request/2 sends a policy request from the scope's organisation, an operator
  (`policy_request.send`, an owner's or an admin's of it). `attrs`, with string keys:

  - `"changes"`: the changes, as `Apiary.Policy.requested_changes/1` takes them;
  - `"note"`: why the harness needs them, 1 to #{@note_max} characters, counted in code
    points as the database counts them;
  - `"clients"`: the ids of the clients it goes to, of `recipients/1`; absent or nil for
    all of them.

  An answer `pending` for each client, an entry of `policy_request.send` in the operator's
  trail, the request its subject, and one in each client's, its answer the subject.
  `{:ok, request}`, its answers preloaded; `{:error, %Apiary.Policy.Error{}}` for changes
  the policy refuses, a note that is empty or too long (`field: :note`), or no client to
  send it to (`field: :clients`), a client chosen that may not receive one among them;
  `Apiary.Access`'s answer otherwise, asked before anything else.
  """
  @spec send_request(Scope.t(), map) :: {:ok, Request.t()} | refusal
  def send_request(%Scope{organisation: %Organisation{} = operator} = scope, attrs)
      when is_map(attrs) do
    with :ok <- Access.authorize(scope, :"policy_request.send", operator),
         {:ok, changes} <- Policy.requested_changes(attrs["changes"] || %{}),
         {:ok, note} <- note(attrs["note"]),
         {:ok, chosen} <- chosen(attrs["clients"]) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the clients and the operator `FOR SHARE`, at one
        # point, in the lock order, the clients first; then the person's membership
        # (`Apiary.Access.reload/2`), which takes the operator's row again, in the same
        # mode.
        clients = lock_clients(operator.id)
        scope = Access.reload(scope, lock: :share)

        with :ok <- Access.check(scope, :"policy_request.send", scope.organisation),
             {:ok, recipients} <- pick(eligible(clients), chosen) do
          write_request(scope, changes, note, recipients)
        end
      end)
    end
  end

  def send_request(_scope, _attrs), do: {:error, :not_found}

  defp write_request(scope, changes, note, recipients) do
    now = DateTime.utc_now()

    with {:ok, request} <- insert_request(scope, changes, note, now),
         answers =
           for(
             client <- recipients,
             do:
               Repo.insert!(%Answer{
                 organisation_id: client.id,
                 request_id: request.id,
                 state: :pending,
                 inserted_at: now
               })
           ),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"policy_request.send", request, %{
             details: %{
               clients: length(recipients),
               client_ids: Enum.map(recipients, & &1.id),
               rules: length(changes["rules"]),
               mode: changes["mode"]
             }
           }),
         :ok <-
           each(Enum.zip(recipients, answers), fn {client, answer} ->
             Audit.record(
               Repo,
               Reach.in_client(scope, client),
               :"policy_request.send",
               answer,
               %{details: %{operator_id: scope.organisation.id, request_id: request.id}}
             )
           end) do
      {:ok, %{request | answers: answers}}
    end
  end

  # The database's check of the note's length refuses as `note/1` does, should the two
  # ever count differently: an error for the form, never a raise.
  defp insert_request(scope, changes, note, now) do
    %Request{inserted_at: now}
    |> Ecto.Changeset.change(
      organisation_id: scope.organisation.id,
      author_id: scope.user.id,
      note: note,
      changes: changes
    )
    |> Ecto.Changeset.check_constraint(:note,
      name: :policy_requests_note_check,
      message: note_too_long()
    )
    |> Repo.insert()
    |> case do
      {:ok, request} ->
        {:ok, request}

      {:error, %Ecto.Changeset{errors: [{:note, {message, _meta}} | _]}} ->
        {:error, Error.new(:invalid, message, :note)}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  withdraw/2 withdraws the request `request_id` of the scope's organisation, an operator
  (`policy_request.withdraw`, an owner's or an admin's of it), from the clients that have
  not answered it: their answers are `withdrawn`, each an entry of
  `policy_request.withdraw` in the client's trail, and the request's in the operator's.
  An answer given stays. `{:ok, request}`; `{:error, :withdrawn}` for a request withdrawn
  already; `{:error, :not_found}` for a request that is not the operator's, and
  `Apiary.Access`'s answer otherwise, asked before anything is locked and again under the
  locks.
  """
  @spec withdraw(Scope.t(), String.t()) :: {:ok, Request.t()} | refusal
  def withdraw(%Scope{organisation: %Organisation{id: operator_id}} = scope, request_id) do
    with {:ok, id} <- cast(request_id),
         %Request{} = request <-
           Repo.get_by(Request, id: id, organisation_id: operator_id) || {:error, :not_found},
         :ok <- Access.authorize(scope, :"policy_request.withdraw", request) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the operator, the person's membership and
        # account (`Apiary.Access.reload/2`), then the request and its answers pending, in
        # the order of their ids; the action is asked again of what they hold.
        scope = Access.reload(scope, lock: :share)
        request = Repo.one!(from r in Request, where: r.id == ^id, lock: "FOR UPDATE")

        answers =
          Repo.all(
            from a in Answer,
              where: a.request_id == ^id and a.state == :pending,
              order_by: a.id,
              lock: "FOR UPDATE"
          )

        with :ok <- Access.check(scope, :"policy_request.withdraw", request),
             :ok <- if(request.withdrawn_at, do: {:error, :withdrawn}, else: :ok),
             now = DateTime.utc_now(),
             {:ok, request} <-
               request |> Ecto.Changeset.change(withdrawn_at: now) |> Repo.update(),
             {:ok, _withdrawn} <- withdraw_answers(scope, answers, now, nil),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"policy_request.withdraw", request, %{
                 details: %{clients: length(answers)}
               }) do
          {:ok, request}
        end
      end)
    end
  end

  def withdraw(_scope, _request_id), do: {:error, :not_found}

  ## The client

  @doc """
  list_received/1 is the policy requests of the scope's organisation, a client or one
  that was, newest first: each answer with its request and the operator that sent it,
  nil once that operator is gone (`security_policy.read`: the operator's people read
  them too). `{:ok, [received]}`; `Apiary.Access`'s answer otherwise, `{:error,
  :not_found}` where `security` is off.
  """
  @spec list_received(Scope.t()) :: {:ok, [received]} | {:error, Access.reason()}
  def list_received(%Scope{organisation: %Organisation{id: client_id} = client} = scope) do
    with :ok <- Access.authorize(scope, :"security_policy.read", client) do
      rows =
        Repo.all(
          from a in Answer,
            join: r in Request,
            on: r.id == a.request_id,
            left_join: o in Organisation,
            on: o.id == r.organisation_id,
            where: a.organisation_id == ^client_id,
            order_by: [desc: a.inserted_at, desc: a.id],
            limit: 200,
            preload: [answered_by: []],
            select: %{answer: a, request: r, operator: o}
        )

      {:ok, rows}
    end
  end

  def list_received(_scope), do: {:error, :not_found}

  @doc """
  pending_count/1 is how many policy requests of its operator wait for the scope's
  organisation's answer: 0 for an organisation that is no client, and where `security`
  is off. For the notice on the policy page, which has asked `security_policy.read`.
  """
  @spec pending_count(Scope.t()) :: non_neg_integer
  def pending_count(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    if Tenants.client?(organisation) and Features.visible?(scope, :security) do
      Repo.aggregate(
        from(a in Answer, where: a.organisation_id == ^id and a.state == :pending),
        :count
      )
    else
      0
    end
  end

  def pending_count(_scope), do: 0

  @doc """
  answerable_workspaces/1 is the workspaces of the scope's organisation whose policy the
  scope's person may write (`security_policy.edit`), by name: those an acceptance may go
  into, every one they reach where `security` is on. [] for a reader, who answers
  nothing.
  """
  @spec answerable_workspaces(Scope.t()) :: [%Workspace{}]
  def answerable_workspaces(scope), do: answerable(scope, false)

  # The workspaces the person may write the policy of; `lock?`, inside an answer's
  # transaction, reads their workspace access `FOR SHARE`, which a removal from a workspace
  # locks alone, so one committed first is seen and one asked after waits.
  defp answerable(
         %Scope{organisation: %Organisation{id: organisation_id}, user: %User{}} = scope,
         lock?
       ) do
    workspaces =
      Repo.all(
        from w in Workspace,
          where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at),
          order_by: [asc: w.name, asc: w.id]
      )

    query =
      from a in WorkspaceAccess.Row,
        where: a.organisation_id == ^organisation_id and a.user_id == ^scope.user.id,
        order_by: a.id

    query = if lock?, do: lock(query, "FOR SHARE"), else: query
    accesses = query |> Repo.all() |> Map.new(&{&1.workspace_id, &1})

    # What the person is not shown does not depend on the workspace: the scope's, as it
    # was loaded or read again, or asked of the edition once for a scope that carries
    # none.
    hidden = scope.hidden || Features.hidden_of(Apiary.Edition.hidden(scope))

    Enum.filter(workspaces, fn workspace ->
      there =
        %{scope | workspace: workspace, hidden: hidden}
        |> ApiaryPro.WorkspaceAccess.put(accesses[workspace.id])

      Access.can?(there, :"security_policy.edit", workspace)
    end)
  end

  defp answerable(_scope, _lock?), do: []

  @doc """
  accept/3 accepts the answer `answer_id` of the scope's organisation, a client
  (`policy_request.accept`, for whoever may write its policy), in the workspaces
  `workspace_ids` of it, at least one: the request's changes are made in each, as the
  scope's person, through the policy's writes (`Apiary.Policy.apply_requested/3`), all of
  them or none. The answer is `accepted`, naming the workspaces, with an entry of
  `policy_request.accept` in the client's trail and one in the operator's; each change
  made is the policy's entry.

  `{:ok, answer}`; `{:error, %Apiary.Policy.Error{}}` with the sentence of a change that
  no longer fits, a locked rule's for a person who is no owner among them;
  `{:error, :answered}` for an answer given already, `{:error, :withdrawn}` for one
  withdrawn; `{:error, :not_found}` for an answer of another organisation, or a
  workspace that is not one of the client's in use; `{:error, :forbidden}` for a person
  who may write the policy of no workspace of the client; and `Apiary.Access`'s answer
  otherwise, asked before anything is locked and again under the locks.
  """
  @spec accept(Scope.t(), String.t(), [String.t()]) :: {:ok, Answer.t()} | refusal
  def accept(%Scope{} = scope, answer_id, workspace_ids) when is_list(workspace_ids) do
    with {:ok, answer} <- get_answer(scope, answer_id),
         :ok <- Access.authorize(scope, :"policy_request.accept", answer) do
      result =
        Repo.transact(fn ->
          with {:ok, workspaces} <- Policy.lock_workspaces(scope, workspace_ids),
               {:ok, scope, answer} <- lock_answer(scope, :"policy_request.accept", answer),
               request = Repo.get!(Request, answer.request_id),
               {:ok, made} <- Policy.apply_requested(scope, workspaces, request.changes),
               {:ok, answer} <- answer_as(answer, scope, :accepted, workspaces, nil),
               {:ok, _entries} <-
                 record_answer(scope, :"policy_request.accept", answer, request, %{
                   workspace_ids: answer.workspace_ids
                 }) do
            {:ok, {answer, made}}
          end
        end)

      case result do
        {:ok, {answer, made}} ->
          Policy.announce(made)
          {:ok, answer}

        {:error, _reason} = refusal ->
          refusal
      end
    end
  end

  def accept(_scope, _answer_id, _workspace_ids), do: {:error, :not_found}

  @doc """
  decline/3 declines the answer `answer_id` of the scope's organisation, a client
  (`policy_request.decline`, for whoever may write its policy), with `reason`, at most
  #{@reason_max} characters, or none: an entry of `policy_request.decline` in the
  client's trail and one in the operator's. `{:ok, answer}`; `{:error, {:reason,
  message}}` for a reason too long, counted in code points as the database counts;
  `{:error, :answered}` or `{:error, :withdrawn}` for an answer that is no longer
  pending; `{:error, :not_found}` for an answer of another organisation;
  `{:error, :forbidden}` for a person who may write the policy of no workspace of the
  client; and `Apiary.Access`'s answer otherwise.
  """
  @spec decline(Scope.t(), String.t(), String.t() | nil) :: {:ok, Answer.t()} | refusal
  def decline(%Scope{} = scope, answer_id, reason) do
    with {:ok, answer} <- get_answer(scope, answer_id),
         :ok <- Access.authorize(scope, :"policy_request.decline", answer),
         {:ok, reason} <- reason(reason) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the client and its operator, then what
        # `Apiary.Access.reload/2` reads, then the answer.
        :ok = Access.lock_places(scope)

        with {:ok, scope, answer} <- lock_answer(scope, :"policy_request.decline", answer),
             request = Repo.get!(Request, answer.request_id),
             {:ok, answer} <- answer_as(answer, scope, :declined, [], reason),
             {:ok, _entries} <-
               record_answer(scope, :"policy_request.decline", answer, request, %{
                 reason: reason
               }) do
          {:ok, answer}
        end
      end)
    end
  end

  ## Parting

  @doc """
  withdraw_for_client/4 withdraws, inside the caller's transaction, every answer of
  `client` still pending to a request of `operator`: the client is dropped or deleted by
  it, `reason` `"dropped"` or `"deleted"`. Each is an entry
  of `policy_request.withdraw` in the client's trail and one in the operator's, by the
  scope's person. The caller holds the client's row, which it changes, so an acceptance,
  which holds it `FOR SHARE`, came first or waits and then finds the answer withdrawn.
  `{:ok, count}`, or the entry's error, which rolls the caller back.
  """
  @spec withdraw_for_client(Scope.t(), %Organisation{}, %Organisation{}, String.t()) ::
          {:ok, non_neg_integer} | {:error, term}
  def withdraw_for_client(
        %Scope{} = scope,
        %Organisation{id: client_id} = client,
        %Organisation{id: operator_id} = operator,
        reason
      )
      when reason in ~w(left dropped deleted) do
    answers =
      Repo.all(
        from a in Answer,
          where: a.organisation_id == ^client_id and a.state == :pending,
          where:
            a.request_id in subquery(
              from r in Request, where: r.organisation_id == ^operator_id, select: r.id
            ),
          order_by: a.id,
          lock: "FOR UPDATE"
      )

    requests =
      Repo.all(from r in Request, where: r.id in ^Enum.map(answers, & &1.request_id))
      |> Map.new(&{&1.id, &1})

    with {:ok, withdrawn} <-
           withdraw_answers(
             Reach.in_client(scope, client),
             answers,
             DateTime.utc_now(),
             reason,
             client: client
           ),
         :ok <-
           each(withdrawn, fn answer ->
             Audit.record(
               Repo,
               Scope.in_organisation(scope, operator),
               :"policy_request.withdraw",
               requests[answer.request_id],
               %{details: %{organisation_id: client_id, reason: reason}}
             )
           end) do
      {:ok, length(withdrawn)}
    end
  end

  ## Inside

  defp clients_query(operator_id) do
    from o in Organisation,
      join: t in Tenant,
      on: t.organisation_id == o.id,
      where: t.operator_id == ^operator_id and is_nil(o.deletion_marked_at),
      order_by: o.id
  end

  # The operator's clients and the operator `FOR SHARE`, in one statement in the lock
  # order (`ApiaryPro.Tenants.lock_organisations!/2`), then their tenants read in a
  # statement after the locks: a client that left, was dropped or was suspended while this
  # waited, each under the client's row locked for update, is seen so. The clients, in the
  # order of their ids.
  defp lock_clients(operator_id) do
    ids = Repo.all(from o in clients_query(operator_id), select: o.id)

    [operator_id | ids]
    |> Tenants.lock_organisations!(:share)
    |> Map.delete(operator_id)
    |> Map.values()
    |> Enum.filter(&(Tenants.operator_id(&1) == operator_id and is_nil(&1.deletion_marked_at)))
    |> Enum.sort_by(& &1.id)
  end

  # The clients that may receive a request, by name: not suspended, with `security`.
  defp eligible(clients) do
    features = ApiaryPro.Features.of_all(clients)

    clients
    |> Enum.filter(&(not Tenants.suspended?(&1) and :security in Map.fetch!(features, &1.id)))
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  defp chosen(nil), do: {:ok, :all}

  defp chosen(ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: {:ok, Enum.uniq(ids)}, else: no_recipients()
  end

  defp chosen(_ids), do: no_recipients()

  defp pick([], _chosen), do: no_recipients()
  defp pick(eligible, :all), do: {:ok, eligible}
  defp pick(_eligible, []), do: no_recipients()

  defp pick(eligible, ids) do
    picked = Enum.filter(eligible, &(&1.id in ids))

    if length(picked) == length(ids) do
      {:ok, picked}
    else
      {:error,
       Error.new(
         :invalid,
         gettext(
           "A client chosen cannot receive the request any more: it left, or does not have the security policy now. Choose again."
         ),
         :clients
       )}
    end
  end

  defp no_recipients,
    do:
      {:error,
       Error.new(
         :invalid,
         gettext("Choose at least one client to send the request to."),
         :clients
       )}

  defp note(note) when is_binary(note) do
    note = String.trim(note)

    cond do
      note == "" ->
        {:error, Error.new(:invalid, gettext("Say why the harness needs these changes."), :note)}

      characters(note) > @note_max ->
        {:error, Error.new(:invalid, note_too_long(), :note)}

      true ->
        {:ok, note}
    end
  end

  defp note(_note), do: note("")

  defp reason(nil), do: {:ok, nil}

  defp reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" ->
        {:ok, nil}

      reason ->
        if characters(reason) > @reason_max,
          do: {:error, {:reason, reason_too_long()}},
          else: {:ok, reason}
    end
  end

  defp reason(_reason), do: {:ok, nil}

  # Characters as the database's `char_length` counts them, which its checks compare:
  # code points, so a letter with a combining accent is two.
  defp characters(text), do: text |> String.codepoints() |> length()

  defp note_too_long, do: gettext("The note is at most %{max} characters.", max: @note_max)

  defp reason_too_long,
    do: gettext("The reason is at most %{max} characters.", max: @reason_max)

  defp feature(scope) do
    if Features.visible?(scope, :security), do: :ok, else: {:error, :not_found}
  end

  # An answer of the scope's organisation, by id.
  defp get_answer(%Scope{organisation: %Organisation{id: organisation_id}}, id) do
    with {:ok, id} <- cast(id) do
      case Repo.get_by(Answer, id: id, organisation_id: organisation_id) do
        %Answer{} = answer -> {:ok, answer}
        nil -> {:error, :not_found}
      end
    end
  end

  defp get_answer(_scope, _id), do: {:error, :not_found}

  # After the organisation's rows (and an acceptance's workspaces): the person's membership
  # and account read again `FOR SHARE`, the action asked of what they find, and a workspace
  # whose policy they may write, their workspace access held `FOR SHARE`: whoever may
  # write none answers nothing, since an answer is the whole client's. Then the answer is
  # locked and found pending.
  defp lock_answer(scope, action, %Answer{id: id} = answer) do
    scope = Access.reload(%{scope | workspace: nil}, lock: :share)

    with :ok <- Access.check(scope, action, answer),
         :ok <- writes_somewhere(scope) do
      case Repo.one(from a in Answer, where: a.id == ^id, lock: "FOR UPDATE") do
        %Answer{state: :pending} = answer -> {:ok, scope, answer}
        %Answer{state: :withdrawn} -> {:error, :withdrawn}
        %Answer{} -> {:error, :answered}
        nil -> {:error, :not_found}
      end
    end
  end

  defp writes_somewhere(scope) do
    if answerable(scope, true) == [], do: {:error, :forbidden}, else: :ok
  end

  # The database's check of the reason's length refuses as `reason/1` does, should the two
  # ever count differently.
  defp answer_as(answer, scope, state, workspaces, reason) do
    answer
    |> Ecto.Changeset.change(
      state: state,
      answered_by_id: scope.user.id,
      answered_at: DateTime.utc_now(),
      workspace_ids: Enum.map(workspaces, & &1.id),
      reason: reason
    )
    |> Ecto.Changeset.check_constraint(:reason,
      name: :policy_request_answers_reason_check,
      message: reason_too_long()
    )
    |> Repo.update()
    |> case do
      {:ok, answer} ->
        {:ok, answer}

      {:error, %Ecto.Changeset{errors: [{:reason, {message, _meta}} | _]}} ->
        {:error, {:reason, message}}

      {:error, _changeset} = error ->
        error
    end
  end

  # An answer's entry in the client's trail, and the request's in the operator's.
  defp record_answer(scope, action, answer, request, details) do
    operator = Repo.get!(Organisation, request.organisation_id)

    with {:ok, client_entry} <-
           Audit.record(Repo, scope, action, answer, %{
             details: Map.merge(details, %{operator_id: operator.id, request_id: request.id})
           }),
         {:ok, operator_entry} <-
           Audit.record(Repo, Scope.in_organisation(scope, operator), action, request, %{
             details: Map.put(details, :organisation_id, answer.organisation_id)
           }) do
      {:ok, [client_entry, operator_entry]}
    end
  end

  # The answers withdrawn, each an entry in its client's trail; `opts[:client]` when they
  # are all one client's, whose scope `scope` is, else each client is read.
  defp withdraw_answers(scope, answers, now, reason, opts \\ [])

  defp withdraw_answers(_scope, [], _now, _reason, _opts), do: {:ok, []}

  defp withdraw_answers(scope, answers, now, reason, opts) do
    {_count, withdrawn} =
      Repo.update_all(
        from(a in Answer, where: a.id in ^Enum.map(answers, & &1.id), select: a),
        set: [
          state: :withdrawn,
          answered_at: now,
          answered_by_id: scope.user && scope.user.id,
          reason: reason
        ]
      )

    clients =
      case opts[:client] do
        %Organisation{} = client ->
          %{client.id => client}

        nil ->
          Repo.all(
            from o in Organisation, where: o.id in ^Enum.map(withdrawn, & &1.organisation_id)
          )
          |> Map.new(&{&1.id, &1})
      end

    withdrawn = Enum.sort_by(withdrawn, & &1.id)

    with :ok <-
           each(withdrawn, fn answer ->
             request = Repo.get!(Request, answer.request_id)

             Audit.record(
               Repo,
               Reach.in_client(scope, clients[answer.organisation_id]),
               :"policy_request.withdraw",
               answer,
               %{details: withdrawal(request, reason)}
             )
           end) do
      {:ok, withdrawn}
    end
  end

  defp withdrawal(request, nil),
    do: %{operator_id: request.organisation_id, request_id: request.id}

  defp withdrawal(request, reason), do: Map.put(withdrawal(request, nil), :reason, reason)

  # Each entry written, or the first error, which rolls the caller back.
  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
