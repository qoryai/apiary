defmodule Apiary.Audit do
  @moduledoc """
  The audit trail: what people, access keys and the instance did to what the apiary
  holds. Every change leaves one entry (`Apiary.Audit.Entry`): who, which action, on what,
  when, from where, and the fields it changed as they were and as they are. It is not the
  record: the record is what runs did (their events, their log), the trail is what was
  done to the apiary. The events a runner posts are the record and leave no entry.

  ## Written with the change

  The context function that asked `Apiary.Access.authorize/3` writes the entry with
  `record/6`, in the same transaction as the change: a change that commits has its entry,
  and one that is refused or rolls back has none. `record/6` takes the step of an
  `Ecto.Multi`, or the repository inside `Apiary.Repo.transact/1`:

      Repo.transact(fn ->
        with :ok <- Access.authorize(scope, :"workspace.rename", workspace),
             {:ok, renamed} <- Repo.update(changeset),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"workspace.rename", renamed,
                 Audit.changed(workspace, renamed, [:name])
               ) do
          {:ok, renamed}
        end
      end)

  **The actor** is the scope's: a person (their user id), an access key (its row id), or
  the instance (`Apiary.Accounts.Scope.for_instance/2`), for a job no person enqueued.
  **The action** is one of `Apiary.Access.actions/0`. **The subject** is the row acted
  on, an organisation, a workspace, a membership, an invitation, an access key, a run, a
  target or a rule, and gives the entry its organisation and workspace: none for what the
  organisation itself owns. **From where** is the scope's `origin`: the request's address
  and client, or the job's worker. **Before and after** are the changed fields
  (`changed/3`), and `details` what else the entry says, as JSON maps. They never hold a
  secret, and never a person's name or email address: a person is named by their user id,
  and a page looks the account up when it shows them.

  ## What is audited

  Every action of `Apiary.Access` that changes something (`audited?/1`); the others are
  listed with the reason by `not_audited/0`: reads, and the server contract's calls. What
  the application removes of its own accord is audited too, by the action that removes
  it: an expired invitation deleted when a new one goes to its address, and one whose
  email could not be delivered, are each an `invitation.revoke` by the person who sent
  the new invitation, `details.reason` `expired` or `undelivered`. The record's own
  retention is not a change to the apiary and writes its own record
  (`Apiary.Retention.RetentionRun`); a run marked lost is the record's too.

  ## Append-only

  Nothing in the application changes or deletes an entry but its retention, `prune/2`: the
  trail keeps an organisation's entries for `retention_days/0` days, an instance setting,
  and a daily job per organisation (`Apiary.Audit.PruneJob`) deletes the older ones. The
  address and the client an entry came from are personal data kept for a shorter period,
  `address_retention_days/0`, after which the same job clears them and leaves the rest.
  Each prune that deleted entries is itself an entry, by the instance.

  ## Read

  The organisation's Activity page reads the trail with `list_entries/3`, for a reader who
  may `audit.read`, and looks up the names of what it shows with `names/2`. The security
  policy's history is the trail's entries of the policy's actions
  (`Apiary.Policy.list_changes/3`).
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias Apiary.Policy.Rule
  alias Apiary.Runs.{Run, Target}

  @subject_kinds %{
    Organisation => "organisation",
    Workspace => "workspace",
    Membership => "membership",
    Invitation => "invitation",
    AccessKey => "access_key",
    Run => "run",
    Target => "target",
    Rule => "rule"
  }

  # The actions that change nothing, each with the reason it leaves no entry.
  @not_audited [
    "run.read": "a read changes nothing",
    "run.read_log": "a read changes nothing",
    "security_policy.read": "a read changes nothing",
    "audit.read": "a read changes nothing",
    "run.post_events": "the events a runner posts are the record, not the audit trail",
    "run_configuration.fetch": "a runner's fetch reads the policy and changes nothing"
  ]

  @default_retention_days 365
  @default_address_retention_days 90
  @retention_min 90
  @retention_max 2555
  @page_size 50
  @remote_ip_max 45
  @user_agent_max 255
  @worker_max 120

  @typedoc """
  What an entry holds beyond who, what and when: `before` and `after`, the changed fields
  as they were and are, and `details`. Maps, with atom or string keys.
  """
  @type data :: %{
          optional(:before) => map | nil,
          optional(:after) => map | nil,
          optional(:details) => map | nil
        }

  @typedoc "A value of a step of an `Ecto.Multi`, or a function of the changes before it."
  @type in_multi(value) :: value | (map -> value)

  @typedoc "A page of entries, newest first: `more?` when an older page follows."
  @type page :: %{entries: [Entry.t()], page: pos_integer, more?: boolean}

  ## What is audited

  @doc """
  audited?/1 says whether `action` of `Apiary.Access` leaves an entry: every action but
  those of `not_audited/0`, so a new action is audited unless it says why not.
  """
  @spec audited?(Access.action()) :: boolean
  def audited?(action),
    do: action in Access.actions() and not Keyword.has_key?(@not_audited, action)

  @doc "audited_actions/0 is the actions of `Apiary.Access` that leave an entry."
  @spec audited_actions() :: [Access.action()]
  def audited_actions, do: Enum.filter(Access.actions(), &audited?/1)

  @doc "not_audited/0 is the actions of `Apiary.Access` that leave no entry, and why."
  @spec not_audited() :: [{Access.action(), String.t()}]
  def not_audited, do: @not_audited

  ## Writing

  @doc """
  record/6 writes the entry of a change: `scope` took `action` on `subject`, with `data`
  (`t:data/0`).

  Given an `Ecto.Multi`, it adds a step that writes the entry, and `scope`, `subject` and
  `data` may each be a function of the changes of the steps before it, for a subject the
  multi inserts. Given the repository, as inside `Apiary.Repo.transact/1`, it writes the
  entry at once: `{:ok, entry}`, or `{:error, changeset}` should the database refuse it,
  which rolls the change back with it.

  `opts`, with the repository only: `id:`, the entry's id, for a caller that must name the
  entry before it is written, as a policy change does in the run configurations it
  renders; a version 7 UUID, `Ecto.UUID.generate(version: 7, precision: :monotonic)`.

  Raises `ArgumentError` for an action that is not one of `Apiary.Access.actions/0`, a
  scope without an actor, a subject of a kind the trail does not know, or a subject of
  another organisation than the scope's: a mistake in the caller, never the caller's
  input.
  """
  @spec record(
          Ecto.Multi.t(),
          in_multi(Scope.t()),
          Access.action(),
          in_multi(struct),
          in_multi(data),
          []
        ) :: Ecto.Multi.t()
  @spec record(module, Scope.t(), Access.action(), struct, data, keyword) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(multi_or_repo, scope, action, subject, data \\ %{}, opts \\ [])

  def record(%Ecto.Multi{} = multi, scope, action, subject, data, []) do
    step = {:audit, action, System.unique_integer([:positive])}

    Ecto.Multi.run(multi, step, fn repo, changes ->
      record(repo, value(scope, changes), action, value(subject, changes), value(data, changes))
    end)
  end

  def record(repo, %Scope{} = scope, action, subject, data, opts) when is_atom(repo) do
    entry = build(scope, action, subject, data || %{})

    case Keyword.get(opts, :id) do
      nil -> repo.insert(entry)
      id -> repo.insert(%{entry | id: id})
    end
  end

  defp value(fun, changes) when is_function(fun, 1), do: fun.(changes)
  defp value(value, _changes), do: value

  @doc """
  changed/3 is the `before` and `after` of an edit: the `fields` whose values differ
  between `old` and `new`, each as it was and as it is, `%{before: %{field => old}, after:
  %{field => new}}`; nil when none differs, which is no change to record.
  """
  @spec changed(map, map, [atom]) :: %{before: map, after: map} | nil
  def changed(old, new, fields) when is_map(old) and is_map(new) and is_list(fields) do
    case Enum.reject(fields, &(Map.get(old, &1) == Map.get(new, &1))) do
      [] ->
        nil

      fields ->
        %{
          before: Map.new(fields, &{&1, Map.get(old, &1)}),
          after: Map.new(fields, &{&1, Map.get(new, &1)})
        }
    end
  end

  defp build(%Scope{} = scope, action, subject, data) when is_map(data) do
    unless action in Access.actions() do
      raise ArgumentError, "#{inspect(action)} is not an action of Apiary.Access"
    end

    {actor_kind, actor_id} = actor(scope)
    {subject_kind, subject_id, organisation_id, workspace_id} = subject(subject)

    unless organisation_id == organisation_id(scope) do
      raise ArgumentError, "an audit entry's subject must be of the scope's organisation"
    end

    struct!(
      Entry,
      Map.merge(
        %{
          organisation_id: organisation_id,
          workspace_id: workspace_id,
          actor_kind: actor_kind,
          actor_id: actor_id,
          action: Atom.to_string(action),
          subject_kind: subject_kind,
          subject_id: subject_id,
          before: json(data[:before]),
          after: json(data[:after]),
          details: json(data[:details])
        },
        origin(scope)
      )
    )
  end

  # The one who acts: an access key at the server contract, the instance in its own job,
  # or a person. A scope that is none of them has done nothing to record.
  defp actor(%Scope{access_key: %AccessKey{id: id}}), do: {:access_key, id}
  defp actor(%Scope{instance: true, user: nil}), do: {:instance, nil}
  defp actor(%Scope{user: %User{id: id}}), do: {:person, id}

  defp actor(_scope),
    do: raise(ArgumentError, "an audit entry needs a person, an access key or the instance")

  defp organisation_id(%Scope{access_key: %AccessKey{organisation_id: id}}), do: id
  defp organisation_id(%Scope{organisation: %Organisation{id: id}}), do: id
  defp organisation_id(_scope), do: nil

  defp subject(%module{} = subject) do
    case Map.fetch(@subject_kinds, module) do
      {:ok, kind} ->
        {organisation_id, workspace_id} = place(subject)
        {kind, subject.id, organisation_id, workspace_id}

      :error ->
        raise ArgumentError, "the audit trail knows no subject #{inspect(module)}"
    end
  end

  defp place(%Organisation{id: id}), do: {id, nil}
  defp place(%Workspace{id: id, organisation_id: organisation_id}), do: {organisation_id, id}

  defp place(%{organisation_id: organisation_id, workspace_id: workspace_id}),
    do: {organisation_id, workspace_id}

  # What the database gives back: string keys, and values as JSON has them.
  defp json(nil), do: nil
  defp json(map) when is_map(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp origin(%Scope{origin: %{worker: worker}}), do: %{worker: cut(worker, @worker_max)}

  defp origin(%Scope{origin: %{} = origin}) do
    %{
      remote_ip: cut(origin[:remote_ip], @remote_ip_max),
      user_agent: cut(origin[:user_agent], @user_agent_max)
    }
  end

  defp origin(_scope), do: %{}

  defp cut(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp cut(_value, _max), do: nil

  ## Reading

  @doc """
  list_entries/3 is a page of the scope's organisation's entries, newest first,
  #{@page_size} a page: `{:ok, %{entries:, page:, more?:}}`, `more?` when an older page
  follows. `{:error, reason}` for a reader who may not `audit.read`.

  `filters`, a map or a keyword list: `workspace_id`, a workspace's id, keeps its entries;
  `action`, an action of `Apiary.Access.actions/0` as an atom or a string, keeps that
  action's. A value that is neither is not a filter.
  """
  @spec list_entries(Scope.t(), map | keyword, pos_integer) ::
          {:ok, page} | {:error, Access.reason()}
  def list_entries(scope, filters \\ %{}, page \\ 1)

  def list_entries(
        %Scope{organisation: %Organisation{id: organisation_id}} = scope,
        filters,
        page
      ) do
    with :ok <- Access.check(scope, :"audit.read", scope.organisation) do
      filters = Map.new(filters)
      page = if is_integer(page) and page > 0, do: page, else: 1

      rows =
        from(e in Entry,
          where: e.organisation_id == ^organisation_id,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: ^(@page_size + 1),
          offset: ^((page - 1) * @page_size)
        )
        |> filter_workspace(filters[:workspace_id])
        |> filter_action(filters[:action])
        |> Repo.all()

      {:ok, %{entries: Enum.take(rows, @page_size), page: page, more?: length(rows) > @page_size}}
    end
  end

  def list_entries(_scope, _filters, _page), do: {:error, :forbidden}

  defp filter_workspace(query, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> where(query, [e], e.workspace_id == ^id)
      :error -> query
    end
  end

  defp filter_workspace(query, _id), do: query

  defp filter_action(query, action) when is_atom(action) and not is_nil(action),
    do: filter_action(query, Atom.to_string(action))

  defp filter_action(query, action) when is_binary(action) do
    if action in Enum.map(Access.actions(), &Atom.to_string/1),
      do: where(query, [e], e.action == ^action),
      else: query
  end

  defp filter_action(query, _action), do: query

  @doc """
  action/1 is an entry's action as the atom of `Apiary.Access.actions/0`, or nil for a
  name this release does not know.
  """
  @spec action(Entry.t()) :: Access.action() | nil
  def action(%Entry{action: action}) do
    Enum.find(Access.actions(), &(Atom.to_string(&1) == action))
  end

  @typedoc """
  What a page needs to name the actors and subjects of some entries, read at the time it
  shows them: each map by id.
  """
  @type names :: %{
          users: %{Ecto.UUID.t() => String.t()},
          access_keys: %{Ecto.UUID.t() => %{label: String.t() | nil, key_id: String.t()}},
          workspaces: %{Ecto.UUID.t() => String.t()},
          targets: %{Ecto.UUID.t() => String.t()},
          runs: %{Ecto.UUID.t() => Ecto.UUID.t()}
        }

  @doc """
  names/2 looks up the names of the actors and the subjects of `entries`, as they are now,
  in one query per kind: the email address of each person (the person named as actor, or
  in `details` as `user_id`), the label and key id of each access key, the name of each
  workspace, `system/path` of each target, and the run id of each run. Only what the
  scope's organisation holds is looked up, people aside, whose accounts belong to no
  organisation. A person, a key or a row that is gone has no key: the page says so.
  """
  @spec names(Scope.t(), [Entry.t()]) :: names
  def names(%Scope{organisation: %Organisation{id: organisation_id}}, entries)
      when is_list(entries) do
    ids = fn pick -> entries |> Enum.flat_map(pick) |> Enum.filter(&uuid?/1) |> Enum.uniq() end

    users =
      ids.(fn entry ->
        [if(entry.actor_kind == :person, do: entry.actor_id), details(entry, "user_id")]
      end)

    keys =
      ids.(fn entry ->
        [
          if(entry.actor_kind == :access_key, do: entry.actor_id),
          if(entry.subject_kind == "access_key", do: entry.subject_id)
        ]
      end)

    workspaces = ids.(&[&1.workspace_id])
    targets = ids.(&[if(&1.subject_kind == "target", do: &1.subject_id)])
    runs = ids.(&[if(&1.subject_kind == "run", do: &1.subject_id)])

    %{
      users: lookup(users, from(u in User, select: {u.id, u.email})),
      access_keys:
        lookup(
          keys,
          from(k in AccessKey,
            where: k.organisation_id == ^organisation_id,
            select: {k.id, %{label: k.label, key_id: k.key_id}}
          )
        ),
      workspaces:
        lookup(
          workspaces,
          from(w in Workspace,
            where: w.organisation_id == ^organisation_id,
            select: {w.id, w.name}
          )
        ),
      targets:
        lookup(
          targets,
          from(t in Target,
            where: t.organisation_id == ^organisation_id,
            select: {t.id, fragment("? || '/' || ?", t.system, t.path)}
          )
        ),
      runs:
        lookup(
          runs,
          from(r in Run, where: r.organisation_id == ^organisation_id, select: {r.id, r.run_id})
        )
    }
  end

  defp lookup([], _query), do: %{}

  defp lookup(ids, query),
    do: query |> where([r], r.id in ^ids) |> Repo.all() |> Map.new()

  defp details(%Entry{details: %{} = details}, key), do: details[key]
  defp details(_entry, _key), do: nil

  defp uuid?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))

  ## Retention

  @doc """
  prune/2 deletes the entries of the scope's organisation older than `retention_days/0`
  days, and clears the address and the client (`remote_ip`, `user_agent`) of those older
  than `address_retention_days/0`, which keep the rest of what they say. It records what
  it did as an entry of its own when it deleted any (`audit.prune`, `details` with how
  many it deleted and cleared and the cut-offs), in one transaction: `{:ok, count}`, the
  entries deleted. Clearing alone writes no entry: it comes every day to an organisation
  that is used every day, and the trail would fill with its own upkeep; how long an
  address is kept is the instance's setting, the same for every entry. The scope is the
  instance's (`Apiary.Accounts.Scope.for_instance/2`): nobody else may prune,
  `{:error, :forbidden}`.

  Options: `now:`, the time the periods are counted back from, `days:` and
  `address_days:`, the periods, for tests.
  """
  @spec prune(Scope.t(), keyword) :: {:ok, non_neg_integer} | {:error, term}
  def prune(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        opts \\ []
      ) do
    days = Keyword.get(opts, :days) || retention_days()
    address_days = Keyword.get(opts, :address_days) || address_retention_days()
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cutoff = DateTime.add(now, -days * 86_400, :second)
    address_cutoff = DateTime.add(now, -address_days * 86_400, :second)

    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"audit.prune", organisation) do
        {count, _} =
          Repo.delete_all(
            from e in Entry,
              where: e.organisation_id == ^organisation_id and e.inserted_at < ^cutoff
          )

        # Read through `audit_entries_with_address_index`, which a cleared entry leaves.
        {cleared, _} =
          Repo.update_all(
            from(e in Entry,
              where: e.organisation_id == ^organisation_id and e.inserted_at < ^address_cutoff,
              where: not is_nil(e.remote_ip) or not is_nil(e.user_agent)
            ),
            set: [remote_ip: nil, user_agent: nil]
          )

        if count > 0 do
          details = %{
            removed: count,
            older_than: cutoff,
            retention_days: days,
            addresses_cleared: cleared,
            addresses_older_than: address_cutoff,
            address_retention_days: address_days
          }

          with {:ok, _entry} <-
                 record(Repo, scope, :"audit.prune", organisation, %{details: details}),
               do: {:ok, count}
        else
          {:ok, 0}
        end
      end
    end)
  end

  @doc """
  retention_days/0 is how many days the instance keeps an audit entry:
  `AUDIT_RETENTION_DAYS`, checked at boot (`boot!/0`), #{@default_retention_days} when
  unset.
  """
  @spec retention_days() :: pos_integer
  def retention_days do
    case Application.fetch_env(:apiary, :audit_retention_days) do
      {:ok, days} -> days
      :error -> boot!()
    end
  end

  @doc """
  address_retention_days/0 is how many days the instance keeps the address and the client
  an audit entry came from: `AUDIT_ADDRESS_RETENTION_DAYS`, checked at boot (`boot!/0`),
  #{@default_address_retention_days} when unset.
  """
  @spec address_retention_days() :: pos_integer
  def address_retention_days do
    case Application.fetch_env(:apiary, :audit_address_retention_days) do
      {:ok, days} ->
        days

      :error ->
        boot!()
        Application.fetch_env!(:apiary, :audit_address_retention_days)
    end
  end

  @doc """
  parse_retention_days/1 reads a value of `AUDIT_RETENTION_DAYS`: `{:ok, days}`, a whole
  number of days from #{@retention_min} to #{@retention_max} (seven years), or
  #{@default_retention_days} for nil or a blank value; `{:error, reason}` otherwise.
  """
  @spec parse_retention_days(String.t() | nil) :: {:ok, pos_integer} | {:error, String.t()}
  def parse_retention_days(value),
    do: parse_days(value, @default_retention_days, @retention_min, @retention_max)

  @doc """
  parse_address_retention_days/2 reads a value of `AUDIT_ADDRESS_RETENTION_DAYS`, given
  the trail's period, `retention_days`: `{:ok, days}`, a whole number of days from 1 to
  `retention_days`, since an address is not kept longer than its entry, or
  #{@default_address_retention_days} for nil or a blank value; `{:error, reason}`
  otherwise.
  """
  @spec parse_address_retention_days(String.t() | nil, pos_integer) ::
          {:ok, pos_integer} | {:error, String.t()}
  def parse_address_retention_days(value, retention_days) do
    case parse_days(value, @default_address_retention_days, 1, retention_days) do
      {:ok, days} ->
        {:ok, days}

      {:error, reason} ->
        {:error,
         reason <>
           "; an address is not kept longer than its entry, which AUDIT_RETENTION_DAYS " <>
           "keeps #{retention_days} days"}
    end
  end

  defp parse_days(nil, default, _min, _max), do: {:ok, default}

  defp parse_days(value, default, min, max) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, default}

      trimmed ->
        case Integer.parse(trimmed) do
          {days, ""} when days >= min and days <= max ->
            {:ok, days}

          _other ->
            {:error, "it is a number of days from #{min} to #{max}, got: #{inspect(trimmed)}"}
        end
    end
  end

  @doc """
  boot!/0 reads `AUDIT_RETENTION_DAYS` and `AUDIT_ADDRESS_RETENTION_DAYS` as
  `config/runtime.exs` left them, checks them and fixes both periods for the life of the
  node; it returns the trail's. Called at boot; raises on a value
  `parse_retention_days/1` or `parse_address_retention_days/2` refuses, so the instance
  does not start.
  """
  @spec boot!() :: pos_integer
  def boot! do
    days =
      case parse_retention_days(Application.get_env(:apiary, :audit_retention_setting)) do
        {:ok, days} ->
          days

        {:error, reason} ->
          raise ArgumentError, """
          environment variable AUDIT_RETENTION_DAYS is not valid: #{reason}.
          Leave it unset for #{@default_retention_days} days, or set it, for example:
          AUDIT_RETENTION_DAYS=730
          """
      end

    setting = Application.get_env(:apiary, :audit_address_retention_setting)

    address_days =
      case parse_address_retention_days(setting, days) do
        {:ok, address_days} ->
          address_days

        {:error, reason} ->
          raise ArgumentError, """
          environment variable AUDIT_ADDRESS_RETENTION_DAYS is not valid: #{reason}.
          Leave it unset for #{@default_address_retention_days} days, or set it, for example:
          AUDIT_ADDRESS_RETENTION_DAYS=30
          """
      end

    Application.put_env(:apiary, :audit_retention_days, days)
    Application.put_env(:apiary, :audit_address_retention_days, address_days)
    days
  end
end
