defmodule ApiaryPro.OrganisationVariables do
  @moduledoc """
  The organisation's variables: the level above its workspaces' variables
  (`Apiary.Policy.Above`, its `variables`, which the core resolves first in every chain,
  `Apiary.Variables.Resolution`), carried by the edition's answer whether or not the
  organisation has a policy in force (`c:Apiary.Edition.above_workspace/1` in
  `ApiaryPro.Edition`, `above_without_policy/1`). Every workspace of the organisation,
  and each of its repositories, inherits them, with the core's rules, which the core
  holds below the level too:

  - **A workspace's or a repository's value overrides the organisation's**, as a
    repository's overrides its workspace's.
  - **A name the organisation locks** is set at no level below it, and a value set below
    it before the lock is set aside (`ignored` in the resolution): the lock wins.
  - **Names are compared without case**: one name per organisation, and a workspace's or a
    repository's other spelling of a name the organisation sets is refused.
  - **A name beginning `QORY_`**, whatever its case, is reserved for Forager, and refused
    (`Apiary.Variables.Denied.refused?/1`).
  - **The core's limits**: a name keeps the variable's rule and a value is at most #{4096}
    bytes of one line (`ApiaryPro.OrganisationVariables.Variable`, with the core's
    sentences); and a write at either level, the organisation's or a workspace's, is
    refused where it would raise one holder's set of variables, the resolution of the
    organisation's variables alone, a workspace's or a repository's, above 128 names or
    64 KiB of names and values.

  The limits and the one spelling are checked on every write, at either level, and on
  nothing else. Where the instance does not have the feature, the organisation's variables
  reach no workspace, and a workspace's writes are checked against none of them; the
  instance having the feature again, as when `QORY_FEATURES` changes at a restart, is not
  checked, so a workspace may then hold another spelling of a name of the organisation's,
  or be over a limit with its variables. The organisation's next change to its variables, but
  the deletion of an unlocked one, says so and is refused, naming the workspace; the
  workspace clears it by changing or deleting its variable.

  A run receives only its security policy: the core keeps and resolves variables at every
  level, and the run configuration does not carry them.

  ## Who

  The feature `organisation_variables` (which needs `security` and `secrets`); where the
  organisation does not have it, nothing here is found, and where the instance does not
  have it, the organisation's variables reach no workspace either. Reading is
  `organisation_variable.read` (owners, admins and readers); every change is
  `organisation_variable.edit` (owners and admins), asked of the organisation. Every
  function takes an `Apiary.Accounts.Scope` in the organisation.

  ## A write

  Every write is one transaction, in the lock order of docs/access.md, as a write of the
  organisation's policy takes it (`ApiaryPro.OrganisationPolicy`): the organisation and
  its operator `FOR SHARE`, then every workspace of the organisation in use, and every one
  marked for deletion that may still be restored, in the order of their ids
  `FOR NO KEY UPDATE` (as `Apiary.Policy.lock_workspaces/2` takes those in use, and a
  write of one workspace's variables that workspace's), then the person's membership and account
  `FOR SHARE`, the action asked again of what they hold; then the organisation's
  variables, under a transaction's advisory lock of the organisation's, so two writes of
  them take turns even where the organisation has no workspace in use; then the row
  changed `FOR UPDATE`. A name, a value and a lock are checked as the core checks a
  workspace's, then, after the write, the variables as they are now by themselves and
  against every workspace locked (`Apiary.Variables.check_above/2`): a workspace or a
  repository that spells a name of the organisation's otherwise refuses it, and so does a
  holder the variables would take over the limits, each said with the workspace's name;
  the write rolls back. A workspace marked for deletion is checked as one in use: its
  restore (`Apiary.Deletion.restore_workspace/2`) checks nothing of its variables. A
  deletion adds no name, and is checked only where the variable is locked: its values
  set aside below are back in force, as after an unlock.

  The entry is the variable's (`Apiary.Audit`, `organisation_variable.edit`), by name,
  never by value: `details.change` is `created`, `updated`, `locked`, `unlocked` or
  `deleted`, with the name, the level, `"organisation"`, and, for a change, whether the
  value changed (`value_changed`); `before` and `after` hold the name and the lock. After
  the commit the organisation's pages are told (`topic/1`).

  So a write of a workspace's variables and a write of the organisation's wait for each
  other: both hold the organisation, and both take the workspace in the same order; a
  restore and a write of the organisation's wait for each other on the workspace's row;
  and two writes of the organisation's take turns
  (`test/apiary_pro/organisation_variables_races_test.exs`).
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Variables.{Denied, Resolution}
  alias ApiaryPro.OrganisationVariables.Variable

  @feature :organisation_variables

  @typedoc "Why a change is refused: the reasons of `Apiary.Access`, or what is wrong with it."
  @type refusal :: Access.reason() | Ecto.Changeset.t()

  @typedoc """
  How many holders below the organisation override one of its names: `workspaces`, the
  workspaces in use that set it for themselves, and `repositories`, the repositories of
  those workspaces that set it for themselves; `workspace_locked`, those of the
  repositories whose workspace locks the name itself, which an unlock of the
  organisation's leaves set aside, by the workspace's lock.
  """
  @type override :: %{
          workspaces: non_neg_integer,
          repositories: non_neg_integer,
          workspace_locked: non_neg_integer
        }

  ## Topics

  @doc "topic/1 is the topic of the organisation's variables: `\"organisation_variables:<organisation_id>\"`."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(organisation_id), do: "organisation_variables:#{organisation_id}"

  @doc """
  subscribe/1 subscribes the caller to the variables of the scope's organisation: after
  each write, `{:organisation_variables_changed, %{organisation_id:, change:, name:}}`.
  """
  @spec subscribe(Scope.t()) :: :ok
  def subscribe(%Scope{organisation: %Organisation{id: id}}),
    do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(id))

  ## Reading

  @doc """
  list/1 is the variables of the scope's organisation, by name without case
  (`organisation_variable.read`). `{:ok, variables}`; `Apiary.Access`'s answer otherwise,
  `{:error, :not_found}` where the feature is off.
  """
  @spec list(Scope.t()) :: {:ok, [Variable.t()]} | {:error, Access.reason()}
  def list(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"organisation_variable.read", organisation) do
      {:ok, rows(id)}
    end
  end

  def list(_scope), do: {:error, :not_found}

  @doc """
  get/2 is the variable of the scope's organisation with the id `id`
  (`organisation_variable.read`): `{:ok, variable}`; `{:error, :not_found}` for one the
  organisation does not have.
  """
  @spec get(Scope.t(), term) :: {:ok, Variable.t()} | {:error, Access.reason()}
  def get(%Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope, id) do
    with :ok <- Access.authorize(scope, :"organisation_variable.read", organisation) do
      find(organisation_id, id)
    end
  end

  def get(_scope, _id), do: {:error, :not_found}

  @doc "change/2 is the changeset of a variable, for a form."
  @spec change(Variable.t(), map) :: Ecto.Changeset.t()
  def change(%Variable{} = variable, attrs \\ %{}), do: Variable.changeset(variable, attrs)

  @doc """
  overrides/1 is, for each name the scope's organisation sets, keyed by the name without
  case, how many of its workspaces in use and of their repositories set it themselves
  (`organisation_variable.read`): where the organisation locks the name, how many values
  its lock sets aside; where it does not, how many holders override the
  organisation's value. A repository's override under its workspace's lock is counted
  too: the organisation's value is not the one it resolves to either; `workspace_locked`
  says how many of those its workspace's lock sets aside, so how many values an unlock
  of the organisation's, or the deletion of its locked variable, puts back in force:
  `workspaces + repositories - workspace_locked`. One query however many workspaces there
  are.
  """
  @spec overrides(Scope.t()) :: {:ok, %{String.t() => override}} | {:error, Access.reason()}
  def overrides(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"organisation_variable.read", organisation) do
      keys = id |> rows() |> Enum.map(&String.downcase(&1.name))

      counts =
        Repo.all(
          from v in Apiary.Variables.Variable,
            join: w in Workspace,
            on: w.id == v.workspace_id,
            # A repository's value, and its workspace's lock of the name, if any:
            # one at most, a workspace's names being one whatever their case.
            left_join: l in Apiary.Variables.Variable,
            on:
              not is_nil(v.target_id) and l.workspace_id == v.workspace_id and
                is_nil(l.target_id) and l.locked and
                fragment("lower(?) = lower(?)", l.name, v.name),
            where: v.organisation_id == ^id and is_nil(w.deletion_marked_at),
            where: fragment("lower(?)", v.name) in ^keys,
            group_by: fragment("lower(?)", v.name),
            select:
              {fragment("lower(?)", v.name), filter(count(v.id), is_nil(v.target_id)),
               filter(count(v.id), not is_nil(v.target_id)),
               filter(count(v.id), not is_nil(l.id))}
        )
        |> Map.new(fn {key, workspaces, repositories, workspace_locked} ->
          {key,
           %{
             workspaces: workspaces,
             repositories: repositories,
             workspace_locked: workspace_locked
           }}
        end)

      none = %{workspaces: 0, repositories: 0, workspace_locked: 0}
      {:ok, Map.new(keys, &{&1, Map.get(counts, &1, none)})}
    end
  end

  def overrides(_scope), do: {:error, :not_found}

  @doc """
  for_above/1 is the variables of `workspace`'s organisation, or of `organisation`, as the
  core resolves them at the level above the workspace (`Apiary.Policy.Above`, its
  `variables`): each an `Apiary.Variables.Variable` with its name, value and lock
  (`ApiaryPro.OrganisationVariables.Variable.to_core_variable/1`), by name without case;
  none where the instance does not have the feature. The feature is read from the
  instance alone (`Apiary.Features.on?/1`): an organisation that does not have it still
  has its variables above every workspace.
  """
  @spec for_above(%Workspace{} | %Organisation{}) :: [Apiary.Variables.Variable.t()]
  def for_above(%Workspace{organisation_id: organisation_id}) do
    case Repo.get(Organisation, organisation_id) do
      %Organisation{} = organisation -> for_above(organisation)
      nil -> []
    end
  end

  def for_above(%Organisation{id: id}) do
    if Features.on?(@feature),
      do: id |> rows() |> Enum.map(&Variable.to_core_variable/1),
      else: []
  end

  @doc """
  above_without_policy/1 is the level above `workspace` where its organisation has
  variables (`for_above/1`) and no policy in force (`ApiaryPro.OrganisationPolicy`, none
  kept, or its feature off): a fresh `Apiary.Policy.Above` with `policy: false`, named
  for the organisation, carrying its variables and the core's defaults for the rest, so
  the security policy takes it as nil and the core still resolves its variables
  (`c:Apiary.Edition.above_workspace/1`, `ApiaryPro.Edition`). Nil where it has none.
  Nothing of the organisation's policy settings is read: a policy not in force says
  nothing here.
  """
  @spec above_without_policy(%Workspace{}) :: Apiary.Policy.Above.t() | nil
  def above_without_policy(%Workspace{organisation_id: organisation_id}) do
    with %Organisation{} = organisation <- Repo.get(Organisation, organisation_id),
         [_ | _] = variables <- for_above(organisation) do
      %Apiary.Policy.Above{
        policy: false,
        id: organisation.id,
        name: organisation.name,
        slug: organisation.slug,
        variables: variables
      }
    else
      _none -> nil
    end
  end

  ## Writing

  @doc """
  create/2 sets a new variable of the organisation (`organisation_variable.edit`): `attrs`
  has `name`, `value` and `locked`. `{:ok, variable}`, or `{:error, refusal}`, a
  changeset with the reason on `name` or `value`.
  """
  @spec create(Scope.t(), map) :: {:ok, Variable.t()} | {:error, refusal}
  def create(%Scope{} = scope, attrs) when is_map(attrs) do
    write(scope, fn scope, workspaces ->
      user_id = scope.user && scope.user.id

      changeset =
        Variable.changeset(
          %Variable{
            organisation_id: scope.organisation.id,
            created_by_id: user_id,
            updated_by_id: user_id
          },
          attrs
        )

      with {:ok, changeset} <- check(changeset),
           {:ok, variable} <- Repo.insert(changeset),
           :ok <- within_workspaces(scope.organisation.id, workspaces, variable, changeset),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"organisation_variable.edit", variable, %{
               after: %{name: variable.name, locked: variable.locked},
               details: details(variable, "created")
             }) do
        {:ok, {variable, "created"}}
      end
    end)
  end

  @doc """
  update/3 changes a variable's name or value (`organisation_variable.edit`); the lock is
  `lock/2`'s and `unlock/2`'s. `{:ok, variable}`, or `{:error, refusal}`. A change that
  changes nothing leaves no entry.
  """
  @spec update(Scope.t(), Variable.t() | String.t(), map) ::
          {:ok, Variable.t()} | {:error, refusal}
  def update(%Scope{} = scope, variable, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    edit(scope, variable, Map.take(attrs, ["name", "value"]), "updated")
  end

  @doc """
  lock/2 locks a variable of the organisation against its workspaces and their
  repositories (`organisation_variable.edit`): no level below sets the name from then on,
  and the values set below before the lock are set aside, which `overrides/1` counts.
  """
  @spec lock(Scope.t(), Variable.t() | String.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def lock(%Scope{} = scope, variable),
    do: edit(scope, variable, %{"locked" => true}, "locked")

  @doc "unlock/2 unlocks a variable of the organisation (`organisation_variable.edit`)."
  @spec unlock(Scope.t(), Variable.t() | String.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def unlock(%Scope{} = scope, variable),
    do: edit(scope, variable, %{"locked" => false}, "unlocked")

  @doc """
  delete/2 removes a variable of the organisation (`organisation_variable.edit`):
  `{:ok, variable}`, as it was.
  """
  @spec delete(Scope.t(), Variable.t() | String.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def delete(%Scope{} = scope, variable) do
    write(scope, fn scope, workspaces ->
      with {:ok, current} <- lock_row(scope.organisation.id, variable),
           {:ok, deleted} <- Repo.delete(current),
           :ok <- unlocked_below(scope.organisation.id, workspaces, deleted),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"organisation_variable.edit", deleted, %{
               before: %{name: deleted.name, locked: deleted.locked},
               details: details(deleted, "deleted")
             }) do
        {:ok, {deleted, "deleted"}}
      end
    end)
  end

  defp edit(scope, variable, attrs, change) do
    write(scope, fn scope, workspaces ->
      with {:ok, current} <- lock_row(scope.organisation.id, variable) do
        changeset =
          current
          |> Variable.changeset(attrs)
          |> Ecto.Changeset.put_change(:updated_by_id, scope.user && scope.user.id)

        case Audit.changed(current, Ecto.Changeset.apply_changes(changeset), [
               :name,
               :value,
               :locked
             ]) do
          nil ->
            if changeset.valid?, do: {:ok, {current, nil}}, else: {:error, changeset}

          changed ->
            with {:ok, changeset} <- check(changeset),
                 {:ok, updated} <- Repo.update(changeset),
                 :ok <-
                   within_workspaces(
                     scope.organisation.id,
                     workspaces,
                     updated,
                     changeset,
                     act(change)
                   ),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"organisation_variable.edit", updated, %{
                     before: Map.take(changed.before, [:name, :locked]),
                     after: Map.take(changed.after, [:name, :locked]),
                     details:
                       updated
                       |> details(change)
                       |> Map.put(:value_changed, Map.has_key?(changed.after, :value))
                   }) do
              {:ok, {updated, change}}
            end
        end
      end
    end)
  end

  # What a refusal for another spelling says the write was.
  defp act("locked"), do: :locked
  defp act("unlocked"), do: :unlocked
  defp act(_change), do: :saved

  defp details(%Variable{} = variable, change),
    do: %{change: change, name: variable.name, level: "organisation"}

  ## The checks

  # What the changeset alone cannot see: Forager's names. Run only on a valid
  # changeset. The organisation's names, compared without case, are its unique index's.
  defp check(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp check(changeset) do
    if Denied.refused?(Ecto.Changeset.get_field(changeset, :name)),
      do:
        refuse(
          changeset,
          :name,
          dgettext_noop("errors", "names beginning QORY_ are reserved for Forager")
        ),
      else: {:ok, changeset}
  end

  # The keys of a message never hold `count`: `translate_error/1` reads a message with a
  # count as a plural, whose lookup misses the catalogues' singular entry, so a software
  # workspace would read the engine's word. A number is bound as `limit`.
  defp refuse(changeset, field, message, keys \\ []),
    do: {:error, Ecto.Changeset.add_error(changeset, field, message, keys)}

  # After the write, in its transaction: the organisation's variables as they are now,
  # checked alone against the limits, which the core's check does not see where there is
  # no workspace to check, then against every workspace locked
  # (`Apiary.Variables.check_above/2`); a refusal is said on the changeset of the variable
  # written, with the workspace's name, and rolls the write back. `how` is what the write
  # does, which another spelling's refusal says: `:saved`, `:locked`, `:unlocked` or
  # `:deleted`.
  defp within_workspaces(
         organisation_id,
         workspaces,
         %Variable{} = written,
         changeset,
         how \\ :saved
       ) do
    variables = organisation_id |> rows() |> Enum.map(&Variable.to_core_variable/1)

    case Resolution.check_limits(Resolution.resolve([{:above, variables}])) do
      :ok ->
        case Apiary.Variables.check_above(workspaces, variables) do
          :ok -> :ok
          {:error, reason} -> refused(reason, written, variables, changeset, how)
        end

      {:error, :too_many_names} ->
        refuse(
          changeset,
          :name,
          dgettext_noop("errors", "would raise a target's variables above %{limit}"),
          limit: Resolution.max_names()
        )

      {:error, :too_large} ->
        refuse(
          changeset,
          :value,
          dgettext_noop("errors", "would raise a target's variables above 64 KiB")
        )
    end
  end

  # A deletion adds no name, but one of a locked variable puts back the values its lock
  # set aside below, as an unlock does: checked as an unlock is, against the variables as
  # the deletion leaves them, and refused on the variable as it was. An unlocked one
  # changes nothing below.
  defp unlocked_below(_organisation_id, _workspaces, %Variable{locked: false}), do: :ok

  defp unlocked_below(organisation_id, workspaces, %Variable{} = deleted),
    do:
      within_workspaces(
        organisation_id,
        workspaces,
        deleted,
        Ecto.Changeset.change(deleted),
        :deleted
      )

  # Another spelling below of a name the organisation keeps, said for what the write does.
  defp spelled_otherwise(:saved),
    do:
      dgettext_noop(
        "errors",
        "cannot be saved while %{workspace} spells %{ours} as %{name}: use one spelling"
      )

  defp spelled_otherwise(:locked),
    do:
      dgettext_noop(
        "errors",
        "cannot be locked while %{workspace} spells %{ours} as %{name}: use one spelling"
      )

  defp spelled_otherwise(:unlocked),
    do:
      dgettext_noop(
        "errors",
        "cannot be unlocked while %{workspace} spells %{ours} as %{name}: use one spelling"
      )

  defp spelled_otherwise(:deleted),
    do:
      dgettext_noop(
        "errors",
        "cannot be deleted while %{workspace} spells %{ours} as %{name}: use one spelling"
      )

  defp refused({:spelled_otherwise, workspace, name}, written, variables, changeset, how) do
    if String.downcase(name) == String.downcase(written.name) do
      refuse(
        changeset,
        :name,
        dgettext_noop("errors", "is %{name} in %{workspace}: use the same spelling"),
        name: name,
        workspace: workspace.name
      )
    else
      ours = Enum.find(variables, &(String.downcase(&1.name) == String.downcase(name)))

      refuse(changeset, :name, spelled_otherwise(how),
        ours: ours && ours.name,
        name: name,
        workspace: workspace.name
      )
    end
  end

  defp refused({:too_many_names, workspace}, _written, _variables, changeset, _how) do
    refuse(
      changeset,
      :name,
      dgettext_noop("errors", "would raise a target's variables in %{workspace} above %{limit}"),
      workspace: workspace.name,
      limit: Resolution.max_names()
    )
  end

  defp refused({:too_large, workspace}, _written, _variables, changeset, _how) do
    refuse(
      changeset,
      :value,
      dgettext_noop("errors", "would raise a target's variables in %{workspace} above 64 KiB"),
      workspace: workspace.name
    )
  end

  ## The write

  # One write: the action asked, then, in the lock order, the organisation's rows and
  # every workspace in use or restorable (`lock_workspaces/1`), the person's membership
  # and account, the action again, an advisory lock of the organisation's variables;
  # `fun.(scope, workspaces)` makes the change and answers
  # `{:ok, {variable, change}}` (`change` nil when nothing changed). After the commit, the
  # pages.
  defp write(%Scope{organisation: %Organisation{} = organisation} = scope, fun) do
    with :ok <- Access.authorize(scope, :"organisation_variable.edit", organisation) do
      result =
        Repo.transact(fn ->
          with {:ok, workspaces} <- lock_workspaces(scope),
               scope = Access.reload(%{scope | workspace: nil}, lock: :share),
               :ok <- Access.check(scope, :"organisation_variable.edit", scope.organisation) do
            lock_variables(organisation.id)
            fun.(scope, workspaces)
          end
        end)

      case result do
        {:ok, {variable, change}} ->
          if change, do: broadcast(organisation.id, change, variable.name)
          {:ok, variable}

        {:error, _reason} = refusal ->
          refusal
      end
    end
  end

  defp write(_scope, _fun), do: {:error, :not_found}

  # The lock order: the organisation's rows (`Apiary.Access.lock_places/1`), then every
  # workspace the organisation's variables reach, in the order of their ids,
  # `FOR NO KEY UPDATE`, as `Apiary.Policy.lock_workspaces/2` takes the workspaces in use:
  # those in use and those marked for deletion that may still be restored
  # (`Apiary.Deletion.restore_workspace/2`, which takes the workspace's row as this does,
  # and checks nothing of its variables), so one restored is within the limits and the
  # spellings of the organisation's variables as they are. One ascending order of ids
  # over both, so this write, a write of the organisation's policy, of a workspace's
  # variables and a restore wait for each other without a deadlock. With no workspace,
  # the organisation's rows alone.
  defp lock_workspaces(%Scope{organisation: %Organisation{id: organisation_id}} = scope) do
    :ok = Access.lock_places(scope)

    {:ok,
     Repo.all(
       from w in Workspace,
         where: w.organisation_id == ^organisation_id,
         where:
           is_nil(w.deletion_marked_at) or
             (is_nil(w.purge_started_at) and
                w.purge_after > fragment("(clock_timestamp() AT TIME ZONE 'UTC')")),
         order_by: w.id,
         lock: "FOR NO KEY UPDATE"
     )}
  end

  # The organisation's variables, last in the lock order: two writes of them take turns,
  # so the limits they check hold, whether or not a workspace's lock already orders them.
  defp lock_variables(organisation_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "apiary_pro:organisation_variables:" <> organisation_id
    ])

    :ok
  end

  defp lock_row(organisation_id, %Variable{id: id}), do: lock_row(organisation_id, id)

  defp lock_row(organisation_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Variable{} = variable <-
           Repo.one(
             from v in Variable,
               where: v.id == ^id and v.organisation_id == ^organisation_id,
               lock: "FOR UPDATE"
           ) do
      {:ok, variable}
    else
      _none -> {:error, :not_found}
    end
  end

  defp find(organisation_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Variable{} = variable <- Repo.get_by(Variable, id: id, organisation_id: organisation_id) do
      {:ok, variable}
    else
      _none -> {:error, :not_found}
    end
  end

  defp rows(organisation_id) do
    Repo.all(
      from v in Variable,
        where: v.organisation_id == ^organisation_id,
        order_by: [asc: fragment("lower(?)", v.name), asc: v.id]
    )
  end

  defp broadcast(organisation_id, change, name) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(organisation_id),
      {:organisation_variables_changed,
       %{organisation_id: organisation_id, change: change, name: name}}
    )
  end
end
