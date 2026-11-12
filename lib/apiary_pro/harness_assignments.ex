defmodule ApiaryPro.HarnessAssignments do
  # An operator's assignments of harness sources to its clients
  # (`ApiaryPro.HarnessAssignments.Assignment`), and the edition's answer to the
  # core's rule for the links of a harness source (`Apiary.Harnesses.allowed?/3`, which
  # asks the edition's `harness_source_allowed?/3`, hidden from the documentation).
  #
  # ## The answer
  #
  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, a run of the organisation
  # `run_organisation_id` may use the links of the organisation `owner_organisation_id`
  # for a source when 1 holds and 2 or 3 holds, read now with no lock, 2 and 3 each in one
  # statement:
  #
  #   1. the run's organisation is a client whose tenant names the owner as its operator;
  #      an owner that a stored row alone names is not enough, so each statement of 2 and
  #      3 joins the client's tenant and drops a row the tenant does not back;
  #   2. an assignment of that operator to that client covers the source exactly; or
  #   3. a harness document that the owner owns in the client lists the source exactly.
  #
  # An assignment covers a source with the same `git` and the same `ref` and the same
  # narrowing key with the same value, compared as the texts are written: no change of
  # case, no ".git" or "/" removed. It covers no other key of `path`, `stack` and
  # `module`, and no source of another `ref`. An assignment of a root, with none of the
  # three, covers the root alone, not the folders, exports and modules in it. This is
  # narrower than an instance assignment, which a root widens to everything in its remote
  # source. A source with a key beyond `git`, `ref`, `path`, `stack` and `module`, with
  # more than one narrowing key, or with a value that is no text, is covered by nothing.
  #
  # A document lists a source when `Apiary.Stacks.Document.harness_sources/1` of its
  # `harness` has a map equal to the source: its base (`extends`) or the `source` of a
  # module, with the same keys and the same texts, compared as written. A document that
  # the client's people saved (its `owner_organisation_id` is the client) lists nothing
  # for the operator: the operator's links are not used for it. The rows are read from the
  # core's table through `Apiary.Stacks.Stack`.
  #
  # ## Writes
  #
  # `assign/3` and `unassign/3` check no access: no route, page or action calls them yet.
  # Both hold the client's row `FOR SHARE`, which a drop of the client
  # (`ApiaryPro.Transfers.drop/3`) locks `FOR NO KEY UPDATE`, so an assignment is never
  # written for a client that is being dropped. A drop deletes the operator's
  # assignments to the client in its transaction.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Stacks.{Document, Stack}
  alias ApiaryPro.{Flags, Tenants}
  alias ApiaryPro.HarnessAssignments.Assignment
  alias ApiaryPro.Tenants.Tenant

  @source_keys ~w(git ref path stack module)
  @text_max 4096
  @git_max 2560

  @typedoc """
  A harness source as it is in a harness document, with text keys: `git` and `ref`, and
  at most one of `path`, `stack` and `module`.
  """
  @type source :: %{required(String.t()) => String.t()}

  ## The answer

  @doc false
  # source_allowed?/3 is the answer of the moduledoc: true or false, false for a source
  # that is no map and for any id that is no text. The assignments are read first, the
  # documents when no assignment covers the source.
  @spec source_allowed?(term, term, term) :: boolean
  def source_allowed?(run_organisation_id, owner_organisation_id, source)
      when is_binary(run_organisation_id) and is_binary(owner_organisation_id) and
             is_map(source) do
    with true <- Flags.operator_infrastructure?(),
         {:ok, source} <- read(source) do
      assigned?(run_organisation_id, owner_organisation_id, source) or
        listed?(run_organisation_id, owner_organisation_id, source)
    else
      _refused -> false
    end
  end

  def source_allowed?(_run_organisation_id, _owner_organisation_id, _source), do: false

  # Whether an assignment of the operator to the client covers `source`. The tenant is
  # joined in the same statement as the rows: a client without that operator has none.
  defp assigned?(
         run_organisation_id,
         owner_organisation_id,
         %{"git" => git, "ref" => ref} = source
       ) do
    narrowing = Map.take(source, Assignment.narrowing())

    Repo.all(
      from a in Assignment,
        join: t in Tenant,
        on: t.organisation_id == a.organisation_id and t.operator_id == a.operator_id,
        where: a.organisation_id == ^run_organisation_id,
        where: a.operator_id == ^owner_organisation_id,
        where: a.git == ^git and a.ref == ^ref
    )
    |> Enum.any?(&(Map.take(Assignment.source(&1), Assignment.narrowing()) == narrowing))
  end

  # Whether a harness document that the operator owns in the client lists `source`. The
  # tenant is joined in the same statement as the rows, as in `assigned?/3`.
  defp listed?(run_organisation_id, owner_organisation_id, source) do
    Repo.all(
      from s in Stack,
        join: t in Tenant,
        on: t.organisation_id == s.organisation_id and t.operator_id == s.owner_organisation_id,
        where: s.organisation_id == ^run_organisation_id,
        where: s.owner_organisation_id == ^owner_organisation_id,
        where: not is_nil(s.harness),
        select: s.harness
    )
    |> Enum.any?(&(source in Document.harness_sources(&1)))
  end

  # A source with only the keys of a harness source, `git` and `ref` as texts, and at most
  # one narrowing key, as a text.
  defp read(source) do
    narrowing = Map.take(source, Assignment.narrowing())

    if Map.keys(source) -- @source_keys == [] and map_size(narrowing) <= 1 and
         Enum.all?(source, fn {_key, value} -> is_binary(value) end) and
         is_binary(source["git"]) and is_binary(source["ref"]),
       do: {:ok, source},
       else: :error
  end

  ## Reading

  @doc false
  # list/2 is the assignments of the operator `operator_id` to the client
  # `client_id`, oldest first. Reads without a lock, and checks no access.
  @spec list(Ecto.UUID.t(), Ecto.UUID.t()) :: [Assignment.t()]
  def list(operator_id, client_id) do
    Repo.all(
      from a in Assignment,
        where: a.operator_id == ^operator_id and a.organisation_id == ^client_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
  end

  ## Writes

  @doc false
  # delete_all/2 deletes every assignment of the operator `operator_id` to the client
  # `client_id`, for the transaction of a drop (`ApiaryPro.Transfers.drop/3`), which holds
  # the client's row. `{:ok, count}`.
  @spec delete_all(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer}
  def delete_all(operator_id, client_id) do
    {count, _rows} =
      Repo.delete_all(
        from a in Assignment,
          where: a.operator_id == ^operator_id and a.organisation_id == ^client_id
      )

    {:ok, count}
  end

  @doc false
  # assign/3 assigns `source` to the client `client_id` of the operator `operator_id`:
  # the client's runs may use the operator's links for it. `{:ok, assignment}`;
  # `{:error, changeset}` for a source of a harness source that is not one, with the reason
  # on `source`, and for one assigned already; `{:error, :not_found}` for an organisation
  # that is no client of the operator, one dropped meanwhile included; `{:error, :busy}`
  # for a deadlock Postgres broke.
  @spec assign(Ecto.UUID.t(), Ecto.UUID.t(), source) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | :not_found | :busy}
  def assign(operator_id, client_id, source) do
    changeset = changeset(operator_id, client_id, source)
    held(operator_id, client_id, fn -> Repo.insert(changeset) end)
  end

  @doc false
  # unassign/3 deletes the operator's assignment of `source` to the client, the source as
  # `assign/3` took it. `{:ok, assignment}`, as it was; `{:error, :not_found}` with none,
  # for a client of another operator included.
  @spec unassign(Ecto.UUID.t(), Ecto.UUID.t(), source) ::
          {:ok, Assignment.t()} | {:error, :not_found | :busy}
  def unassign(operator_id, client_id, source) do
    held(operator_id, client_id, fn ->
      case find(operator_id, client_id, source) do
        %Assignment{} = assignment -> Repo.delete(assignment)
        nil -> {:error, :not_found}
      end
    end)
  end

  # The assignment of exactly `source`, locked for update, or nil.
  defp find(operator_id, client_id, source) do
    with {:ok, %{"git" => git, "ref" => ref} = source} <- read_any(source) do
      narrowing = Map.take(source, Assignment.narrowing())

      Repo.all(
        from a in Assignment,
          where: a.operator_id == ^operator_id and a.organisation_id == ^client_id,
          where: a.git == ^git and a.ref == ^ref,
          lock: "FOR UPDATE"
      )
      |> Enum.find(&(Map.take(Assignment.source(&1), Assignment.narrowing()) == narrowing))
    else
      _unreadable -> nil
    end
  end

  defp read_any(source) when is_map(source), do: read(source)
  defp read_any(_source), do: :error

  # `fun` in a transaction, once the client's and the operator's rows are held `FOR SHARE`
  # and the client's tenant names the operator.
  defp held(operator_id, client_id, fun) do
    with {:ok, _operator} <- Ecto.UUID.cast(operator_id),
         {:ok, _client} <- Ecto.UUID.cast(client_id) do
      locked(operator_id, client_id, fun)
    else
      :error -> {:error, :not_found}
    end
  end

  defp locked(operator_id, client_id, fun) do
    Repo.transaction(fn ->
      with {:ok, held} <-
             Tenants.lock_organisations([client_id, operator_id], fn _id -> :share end),
           %{} = client <- held[client_id],
           true <- Tenants.operator_id(client) == operator_id,
           %{} <- held[operator_id],
           {:ok, result} <- fun.() do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
        _not_a_client -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # The changeset of an assignment of `source`; a source that is no harness source has
  # its reason on `source`.
  defp changeset(operator_id, client_id, source) do
    assignment = %Assignment{operator_id: operator_id, organisation_id: client_id}

    case read_any(source) do
      {:ok, source} ->
        assignment
        |> cast(source, [:git, :ref, :path, :stack, :module], empty_values: [])
        |> validate_required([:git, :ref])
        |> validate_length(:git, min: 1, max: @git_max)
        |> validate_length(:ref, min: 1, max: @text_max)
        |> validate_length(:path, min: 1, max: @text_max)
        |> validate_length(:stack, min: 1, max: @text_max)
        |> validate_length(:module, min: 1, max: @text_max)
        |> unique_constraint(:source, name: :operator_harness_assignments_source_index)
        |> check_constraint(:source, name: :operator_harness_assignments_narrowing)
        |> check_constraint(:source, name: :operator_harness_assignments_not_empty)
        |> foreign_key_constraint(:operator_id)
        |> foreign_key_constraint(:organisation_id)

      :error ->
        assignment
        |> change()
        |> add_error(
          :source,
          "is not a harness source: give git and ref as texts, " <>
            "and at most one of path, stack and module"
        )
    end
  end
end
