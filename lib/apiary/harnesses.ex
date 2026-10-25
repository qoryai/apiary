defmodule Apiary.Harnesses do
  # The instance's assignments of harness sources (`Apiary.Harnesses.Assignment`): each
  # lets the runs of one organisation, or of every organisation, use the instance's links
  # for one harness source. The instance's organisation owns every assignment the core
  # keeps. The module also has the rule that decides which links' access tokens a run may
  # use for its harness (`allowed?/3`).
  #
  # ## The rule
  #
  # A link is one installation of an adapter's app on one external account, a grant of an
  # organisation's connection (`Apiary.Adapters.Grant`); its owner is the organisation of
  # that connection. A run of an organisation may use a link for a harness source, in this
  # order:
  #
  #   1. when the link's owner is the run's organisation;
  #   2. when the owner is the instance's organisation
  #      (`Apiary.Edition.instance_organisation_id/0`), and an instance assignment of the
  #      run's organisation or of every organisation covers the source;
  #   3. otherwise, when the edition allows it
  #      (`Apiary.Edition.harness_source_allowed?/3`). The core allows nothing more.
  #
  # An assignment covers a source with the same `git` and the same `ref`, compared as
  # texts. An assignment with a `path`, a `stack` or a `module` covers only the source
  # with that key and value, and no other key of the three. An assignment of a root, with
  # none of the three, covers every source of that `git` and `ref`: the root itself, and
  # each folder, export and module in it. A source of another `ref` is never covered.
  #
  # ## Writes
  #
  # An instance admin (`Apiary.Access.instance_admin?/1`) who signed in recently
  # (`Apiary.Accounts.sudo_mode?/2`), on an instance with the feature `factory`, creates
  # one (`assign/3`, `harness.assigned`) and deletes one (`unassign/2`,
  # `harness.unassigned`), whatever organisation the scope carries; no role takes either
  # action. Both call `Apiary.Adapters.authorize_instance/2` with `sudo: true`. Where the
  # feature is off, both are `{:error, :not_found}`; for an instance admin who did not
  # sign in recently, `{:error, :sudo}`; for anyone else, `{:error, :forbidden}`. Each
  # change writes its entry, in its transaction, in the trail of the instance's
  # organisation, with the source and the organisation it covers. No route or page calls
  # either.
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

  alias Apiary.{Adapters, Audit, Edition, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{Assignment, RunHarness}
  alias Apiary.Organisations.Organisation
  alias Apiary.Stacks.Document

  @source_keys ~w(git ref path stack module)

  # The keys that narrow a source to a part of its remote source.
  @narrowing ~w(path stack module)

  @typedoc """
  A harness source as it is in a harness document, with text keys: `git` and `ref`, and at
  most one of `path`, `stack` and `module`.
  """
  @type source :: %{required(String.t()) => String.t()}

  ## The rule

  @doc false
  # allowed?/3 says whether a run of the organisation `run_organisation_id` may use a link
  # whose owner is the organisation `owner_organisation_id` for the harness source
  # `source`, by the rule of the moduledoc. Reads the assignments without a lock.
  # False for a nil run organisation, a nil owner or a source that is no map.
  @spec allowed?(Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, source) :: boolean
  def allowed?(run_organisation_id, owner_organisation_id, source)
      when is_binary(run_organisation_id) and is_binary(owner_organisation_id) and
             is_map(source) do
    cond do
      owner_organisation_id == run_organisation_id ->
        true

      owner_organisation_id == Edition.instance_organisation_id() and
          assigned?(run_organisation_id, source) ->
        true

      true ->
        Edition.harness_source_allowed?(run_organisation_id, owner_organisation_id, source)
    end
  end

  def allowed?(_run_organisation_id, _owner_organisation_id, _source), do: false

  # Whether an instance assignment of the run's organisation, or of every organisation,
  # covers `source`.
  defp assigned?(run_organisation_id, %{"git" => git, "ref" => ref} = source)
       when is_binary(git) and is_binary(ref) do
    Repo.all(
      from a in Assignment,
        where: a.every_organisation or a.organisation_id == ^run_organisation_id,
        where: fragment("? ->> 'git'", a.source) == ^git,
        where: fragment("? ->> 'ref'", a.source) == ^ref,
        select: a.source
    )
    |> Enum.any?(&covers?(&1, source))
  end

  defp assigned?(_run_organisation_id, _source), do: false

  # An assignment of a root covers every source of its `git` and `ref`; any other covers
  # the source with the same narrowing key and value alone.
  defp covers?(assigned, source) do
    case Map.take(assigned, @narrowing) do
      root when map_size(root) == 0 -> true
      narrowing -> Map.take(source, @narrowing) == narrowing
    end
  end

  ## A run's links

  @doc false
  # entries/1 is the links the run of the queue `run` reads its harness sources through,
  # read only, as its walk resolved them (`Apiary.Harnesses.Walk`): one per link, its
  # grant, with the resources the walk found under it. `[]` for a run whose walk has not
  # resolved, or resolved none.
  @spec entries(DispatchRun.t()) :: [
          %{purpose: :harness, link_id: Ecto.UUID.t(), resources: [term], access: :read}
        ]
  def entries(%DispatchRun{id: id}) do
    Repo.one(
      from h in RunHarness,
        where: h.dispatch_run_id == ^id and h.state == :resolved,
        select: h.harness_links
    )
    |> List.wrap()
    |> Enum.map(fn link ->
      %{purpose: :harness, link_id: link["grant_id"], resources: link["resources"], access: :read}
    end)
  end

  ## Writes

  @doc false
  # assign/3 lets the runs of `organisation`, or of every organisation for `:every`, use
  # the instance's links for `source` (`harness.assigned`, an instance admin; the
  # moduledoc). `{:ok, assignment}`, `{:error, changeset}` with the reason on `source`,
  # `{:error, :forbidden}`, `{:error, :sudo}`, or `{:error, :not_found}` where the feature
  # is off.
  @spec assign(Scope.t() | nil, source, Organisation.t() | :every) ::
          {:ok, Assignment.t()}
          | {:error, Ecto.Changeset.t() | :forbidden | :sudo | :not_found}
  def assign(scope, source, organisation) do
    {organisation_id, every} =
      case organisation do
        :every -> {nil, true}
        %Organisation{id: id} -> {id, false}
      end

    Repo.transact(fn ->
      with :ok <- Adapters.authorize_instance(scope, sudo: true),
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
  # `{:error, :not_found}` for one already deleted, or where the feature is off;
  # `{:error, :sudo}`; or `{:error, :forbidden}`.
  @spec unassign(Scope.t() | nil, Assignment.t()) ::
          {:ok, Assignment.t()} | {:error, :forbidden | :sudo | :not_found}
  def unassign(scope, %Assignment{id: id}) do
    Repo.transact(fn ->
      with :ok <- Adapters.authorize_instance(scope, sudo: true),
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
