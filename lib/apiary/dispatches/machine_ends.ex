defmodule Apiary.Dispatches.MachineEnds do
  @moduledoc false

  # What a node pool's starter reports about the removal of the machine it created for a
  # dispatch (the provisioner contract's `machine-end.schema.json`): `deleting`, the
  # machine adapter accepted the removal and the machine may still exist; `gone`, the
  # starter confirmed that the machine no longer exists; `delete_failed`, the removal
  # failed and the machine still exists as far as the starter knows. The last report is
  # kept on the dispatch, `machine_end_state` and `machine_end_at`
  # (`Apiary.Dispatches.Dispatch`), and the run page shows it
  # (`Apiary.Runs.Preparation`). `Apiary.Dispatches` delegates here.
  #
  # ## The report: `report/3`
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.Dispatches.current_key/1`): revoked, of a pool deleted, or of a place
  #      out of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, and a check that the key may take
  #      `dispatch.machine_end` on it (`Apiary.Access`): an unknown dispatch, one another
  #      pool claimed and any refusal of the key are one answer, `{:error, :forbidden}`;
  #   3. the dispatch locked `FOR UPDATE`, so two reports for one dispatch take turns and
  #      are applied in the order they hold the lock;
  #   4. a dispatch whose state is `gone` keeps it: `:ok`, and nothing is written. Any
  #      other report replaces the state and its time, the clock's.
  #
  # A dispatch that ended, or whose lease lapsed, takes a report as any other: a machine
  # usually ends after its dispatch. The times of the reports are not compared.
  #
  # ## The audit trail
  #
  # A report writes at most one entry, `dispatch.machine_end`, by the pool's key, about the
  # pool, its `details` the dispatch's public id and the state: for the first report of the
  # dispatch, for the first `delete_failed`, and for `gone`. So a dispatch has at most
  # three entries, however often the removal goes back and forth between states. An
  # earlier `delete_failed` is found by its entry in the trail, in the transaction.
  #
  # ## The answer
  #
  # `:ok` once the report is written, or kept for `gone`. Once a change commits, a message
  # goes out on the topic of the run registered at the dispatch's claim
  # (`Apiary.Runs.broadcast_machine_end/1`); a failure of that broadcast is logged by its
  # kind alone and never changes the answer. An exception rolls the transaction back, is
  # logged by its module alone, and is `{:error, :unavailable}`.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Access, Audit, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run

  @states [:deleting, :gone, :delete_failed]
  @action :"dispatch.machine_end"

  @type state :: :deleting | :gone | :delete_failed
  @type refusal :: :unauthorized | :forbidden | :unavailable
  @type report :: %{state: state}

  # states/0 is every state a starter reports, in the contract's order.
  @doc false
  @spec states() :: [state]
  def states, do: @states

  # report/3 keeps the state the starter of the pool of `access_key` reports for the
  # machine of the dispatch `dispatch_id`: the moduledoc.
  @doc false
  @spec report(AccessKey.t(), term, report) :: :ok | {:error, refusal}
  def report(%AccessKey{key_id: key_id}, dispatch_id, %{state: state}) when state in @states do
    if Dispatch.public_id?(dispatch_id) do
      Repo.transact(fn ->
        with {:ok, key} <- Dispatches.current_key(key_id),
             {:ok, dispatch} <- dispatch_of(key, dispatch_id) do
          dispatch
          |> lock()
          |> apply_report(key, state)
        end
      end)
      |> case do
        {:ok, {:changed, dispatch}} -> broadcast_to_runs(dispatch)
        {:ok, :kept} -> :ok
        {:error, _reason} = refused -> refused
      end
    else
      {:error, :forbidden}
    end
  rescue
    exception ->
      Logger.error("a machine end could not be stored: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  # The dispatch by its public id when the key may take `dispatch.machine_end` on it: one
  # answer for an unknown one, another pool's and a refusal.
  defp dispatch_of(key, dispatch_id) do
    scope = Scope.for_access_key(key)

    with %Dispatch{} = dispatch <- Repo.get_by(Dispatch, public_id: dispatch_id),
         :ok <- Access.authorize(scope, @action, dispatch) do
      {:ok, dispatch}
    else
      _unknown_or_refused -> {:error, :forbidden}
    end
  end

  defp lock(%Dispatch{id: id}),
    do: Repo.one!(from d in Dispatch, where: d.id == ^id, lock: "FOR UPDATE")

  defp apply_report(%Dispatch{machine_end_state: :gone}, _key, _state), do: {:ok, :kept}

  defp apply_report(%Dispatch{id: id} = dispatch, key, state) do
    now = Dispatches.now()

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [machine_end_state: state, machine_end_at: now, updated_at: now]
      )

    if audited?(dispatch, state), do: record(key, dispatch, state)
    {:ok, {:changed, dispatch}}
  end

  # The first report, the first `delete_failed` and `gone` leave an entry; nothing else.
  defp audited?(%Dispatch{machine_end_state: nil}, _state), do: true
  defp audited?(%Dispatch{}, :gone), do: true

  defp audited?(%Dispatch{} = dispatch, :delete_failed),
    do: not Repo.exists?(entries(dispatch, "delete_failed"))

  defp audited?(%Dispatch{}, :deleting), do: false

  # The entries of the dispatch's reports of `state`, in the trail of its organisation.
  defp entries(%Dispatch{organisation_id: organisation_id, public_id: public_id}, state) do
    action = Atom.to_string(@action)

    from e in Entry,
      where:
        e.organisation_id == ^organisation_id and e.action == ^action and
          fragment("?->>'dispatch_id' = ?", e.details, ^public_id) and
          fragment("?->>'state' = ?", e.details, ^state)
  end

  # The one entry, in the transaction, about the key's pool, in the trail of the
  # dispatch's organisation: the key's, or, for the instance's pool's key, which has none,
  # the organisation of the workspace it served
  # (`Apiary.Accounts.Scope.key_in_organisation/2`).
  defp record(%AccessKey{} = key, %Dispatch{} = dispatch, state) do
    details = %{"dispatch_id" => dispatch.public_id, "state" => Atom.to_string(state)}

    {:ok, _entry} =
      Audit.record(Repo, scope(key, dispatch), @action, key.node, %{details: details})

    :ok
  end

  defp scope(%AccessKey{organisation_id: nil} = key, %Dispatch{organisation_id: id}),
    do: Scope.key_in_organisation(Scope.for_access_key(key), Repo.get!(Organisation, id))

  defp scope(%AccessKey{} = key, %Dispatch{}), do: Scope.for_access_key(key)

  # Once the report commits, a message goes out on the topic of the run registered at the
  # dispatch's claim: the run whose start failed with this dispatch, or the run of its run
  # of the queue. A failure is logged by its kind alone and never changes the answer.
  defp broadcast_to_runs(%Dispatch{id: id, dispatch_run_id: dispatch_run_id}) do
    from(r in Run, where: r.dispatch_id == ^id or r.dispatch_run_id == ^dispatch_run_id)
    |> Repo.all()
    |> Enum.each(&Runs.broadcast_machine_end/1)

    :ok
  rescue
    exception ->
      Logger.error("a machine end could not be broadcast: #{inspect(exception.__struct__)}")
      :ok
  end
end
