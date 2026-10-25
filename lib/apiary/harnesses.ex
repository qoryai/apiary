defmodule Apiary.Harnesses do
  # The instance's assignments of harness sources (`Apiary.Harnesses.Assignment`): each
  # lets the runs of one organisation, or of every organisation, use the instance's links
  # for one harness source. The instance's organisation owns every assignment the core
  # keeps.
  #
  # ## Writes
  #
  # An instance admin (`Apiary.Access.instance_admin?/1`) on an instance with the feature
  # `factory` creates one (`assign/3`, `harness.assigned`) and deletes one (`unassign/2`,
  # `harness.unassigned`), whatever organisation the scope carries; no role takes either
  # action. Where the feature is off, both are `{:error, :not_found}`; for anyone else,
  # `{:error, :forbidden}`. Each change writes its entry, in its transaction, in the trail
  # of the instance's organisation, with the source and the organisation it covers. No
  # route or page calls either.
  #
  # ## Refused on save
  #
  # `source`: a map with the text keys `git` and `ref` and at most one of `path`, `stack`
  # and `module`, each a text. It is checked as a harness document's base is, or, with
  # `module`, as a module's source is (`Apiary.Stacks.Document`): an https address with no
  # user name, password, query or fragment, and no `path` with `stack` or `module`. A
  # source with none of the three is the root of the remote source. One assignment per
  # source and organisation: a second is a changeset error on `source`.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Access, Adapters, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Harnesses.Assignment
  alias Apiary.Organisations.Organisation
  alias Apiary.Stacks.Document

  @source_keys ~w(git ref path stack module)

  @typedoc """
  A harness source as it is in a harness document, with text keys: `git` and `ref`, and at
  most one of `path`, `stack` and `module`.
  """
  @type source :: %{required(String.t()) => String.t()}

  ## Writes

  @doc false
  # assign/3 lets the runs of `organisation`, or of every organisation for `:every`, use
  # the instance's links for `source` (`harness.assigned`, an instance admin; the
  # moduledoc). `{:ok, assignment}`, `{:error, changeset}` with the reason on `source`,
  # `{:error, :forbidden}`, or `{:error, :not_found}` where the feature is off.
  @spec assign(Scope.t() | nil, source, Organisation.t() | :every) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def assign(scope, source, organisation) do
    {organisation_id, every} =
      case organisation do
        :every -> {nil, true}
        %Organisation{id: id} -> {id, false}
      end

    Repo.transact(fn ->
      with :ok <- authorize(scope),
           {:ok, recorder} <- Adapters.instance_scope(scope),
           {:ok, assignment} <-
             %Assignment{
               organisation_id: organisation_id,
               every_organisation: every,
               created_by_id: scope.user.id
             }
             |> changeset(source)
             |> Repo.insert(),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"harness.assigned", assignment, %{
               after: entry_data(assignment)
             }) do
        {:ok, assignment}
      end
    end)
  end

  @doc false
  # unassign/2 deletes `assignment` (`harness.unassigned`, an instance admin; the
  # moduledoc), with its row held `FOR UPDATE`. `{:ok, assignment}`, as it was;
  # `{:error, :not_found}` for one already deleted, or where the feature is off; or
  # `{:error, :forbidden}`.
  @spec unassign(Scope.t() | nil, Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, :forbidden | :not_found}
  def unassign(scope, %Assignment{id: id}) do
    Repo.transact(fn ->
      with :ok <- authorize(scope),
           {:ok, recorder} <- Adapters.instance_scope(scope),
           %Assignment{} = current <-
             Repo.one(from a in Assignment, where: a.id == ^id, lock: "FOR UPDATE") ||
               {:error, :not_found},
           {:ok, deleted} <- Repo.delete(current),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"harness.unassigned", deleted, %{
               before: entry_data(deleted)
             }) do
        {:ok, deleted}
      end
    end)
  end

  # An instance admin on an instance with the feature `factory`.
  defp authorize(scope) do
    cond do
      not Features.on?(:factory) -> {:error, :not_found}
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      true -> :ok
    end
  end

  # What an assignment's entry has: the source, and the organisation it covers.
  defp entry_data(%Assignment{} = assignment),
    do: Map.take(assignment, [:source, :organisation_id, :every_organisation])

  defp changeset(%Assignment{} = assignment, source) do
    assignment
    |> change(source: source)
    |> validate_change(:source, fn :source, value ->
      for error <- source_errors(value), do: {:source, error}
    end)
    |> check_constraint(:source, name: :harness_assignments_source_shape, message: "is invalid")
    |> unique_constraint(:source, name: :harness_assignments_source_index)
    |> foreign_key_constraint(:organisation_id)
  end

  # The refusals of a source, `[]` or one `{message, values}`: the save rules of a harness
  # document (`Apiary.Stacks.Document.errors/1`), applied to a document whose base is the
  # source, or, for a module's source, whose one module's source it is. The document is
  # written as JSON, which the YAML reader reads.
  defp source_errors(source) when is_map(source) do
    if Enum.all?(source, fn {key, value} -> key in @source_keys and is_binary(value) end),
      do: source |> document() |> Jason.encode!(pretty: true) |> Document.errors(),
      else: [{"is invalid", []}]
  end

  defp source_errors(_source), do: [{"is invalid", []}]

  defp document(%{"module" => _module} = source),
    do: %{"extends" => Map.take(source, ["git", "ref"]), "modules" => [%{"source" => source}]}

  defp document(source), do: %{"extends" => source}
end
