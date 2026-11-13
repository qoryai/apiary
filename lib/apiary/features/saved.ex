defmodule Apiary.Features.Saved do
  @moduledoc """
  The features an instance admin turns on and off in Instance settings › Features, saved
  in the instance's row (`Apiary.Features.Saved.Row`) and in force on every node without a
  restart.

  **The list in force** is, in order:

  1. `QORY_FEATURES`, where it is set and not blank (`env?/0`), as
     `Apiary.Features.boot!/0` checks it: an unknown name or a missing need stops the boot.
     Each boot with it set also saves its list, so that the instance keeps the same
     features once the variable is removed;
  2. else the saved list, with each feature it has not seen at its default (below). A
     saved name this release does not have is skipped with one log line, `Features:
     skipped the saved feature <name>, which this release does not have.`, and stops
     nothing;
  3. else the defaults, `Apiary.Features.parse/1` of nil.

  The saved list and the defaults then pass through the locks (`locks/0`): a feature
  locked on is on with the features it needs, a feature locked off is off with the
  features that need it, and a feature whose needs are not all on is off.

  **Each node's copy** is the application's environment under `:features`, which
  `Apiary.Features.enabled/0` reads. `Apiary.Features.boot!/0` writes it first, from the
  variable or the defaults; `Apiary.Features.Cache` writes it again after the migrator,
  from the list in force (`refresh/0`), and on each broadcast of a save
  (`Apiary.Features.Cache.changed/0`), which every node of the cluster receives. Without the
  cache, as under `bin/apiary eval` and in the tests, the copy is the one
  `Apiary.Features.boot!/0` wrote, and a save writes it on the node that saves. A node
  whose migration of the columns has not run yet, with `MIGRATE_ON_BOOT=false`, reads them
  as none saved, and its save returns `{:error, :not_migrated}` and saves nothing.

  **Saving** (`save/3`) is an instance admin's (`instance.features_save`, asked in the
  instance's organisation, `Apiary.Access.in_instance/1`). It takes the wanted list and
  the version of the saved list it was read at (`current/0`), closes the list over the
  features' needs (`close/2`), and returns an error for a save made from an older read, a
  change to a locked feature, and any change while `QORY_FEATURES` is set. A change is an
  `instance.features_save` entry in the trail of the instance's organisation, by the
  admin, about the organisation, with the features on before and after.

  **A run** keeps the features in force when it was claimed (`Apiary.Runs.Run`,
  `features`), and its requests are checked against those (`Apiary.Features.on?/2`).

  **The features the saved list has seen.** The instance's row keeps, beside the saved
  list, the names of every feature that list has seen, on or off (`features_seen`). A
  feature the list has not seen takes its default: on for a default feature, off for an
  opt-in one, and `registry` on where `QORY_REGISTRY` is set (`Apiary.Features.parse/1` of
  nil). So a later release's new default feature comes on with the upgrade, an opt-in one
  stays off, and a feature that was seen and turned off stays off. Each write of the list
  marks every feature of the release as seen: a save, and a boot with `QORY_FEATURES`
  set. A save that changes no feature marks them too, where a list is saved, and writes
  the list in force with them, which stays the same. `registry` is not marked while
  `QORY_REGISTRY` is not set, which locks it off: once the variable is set, it takes its
  default, on. A node without the variable writes `registry` in the saved list as the
  list had it, so its saves do not turn `registry` off for the nodes that have the
  variable.

  **Features an older release switched in the config** (`c:Apiary.Edition.config_features/0`)
  are read once, while the saved list has not seen them. At each boot where
  `QORY_FEATURES` is not set, the cache's first read (`boot/0`) takes the ones not seen:
  under the row's lock, it turns on in the saved list each one whose config value is on,
  with the features it needs (`close/2`), raising the version, and marks them seen, on or
  off, with no entry in the trail; where it writes the list, it marks every feature of
  the release. The list and the names are written in one transaction, so a node that
  boots at the same time waits for the lock, then finds them seen and writes nothing; so
  does every later boot. From then on the page applies, and the config value is not read
  again. Where nothing is saved yet and no config value is on, only their names are
  written, and the defaults stay in force. While `QORY_FEATURES` is set and not empty, each
  one the config turns on counts as listed in it, at every boot, but where an `all-…`
  leaves it out by name (`Apiary.Features.parse/2`, `config:`): the boot saves the list
  with it and marks them seen, so the first boot without the variable keeps the list.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Features.Cache
  alias Apiary.Features.Saved.Row
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.Run

  @typedoc "A feature: one of `Apiary.Features.all/0`."
  @type feature :: Features.feature()

  @typedoc """
  Why a feature is locked: `:always`, `observability`, which every instance has;
  `:installed_adapters`, `factory`, while `QORY_INSTALLED_ADAPTERS`, `QORY_INSTALLED_POOL`
  or `QORY_INSTALLED_GATEWAY` sets adapters in the server's environment; `:no_registry`,
  `registry`, while `QORY_REGISTRY` is not set; `{:needed_by, feature}`, a feature that
  `feature`, locked on by the server's environment, needs, directly or through another.
  """
  @type lock_reason :: :always | :installed_adapters | :no_registry | {:needed_by, feature}

  @typedoc "The locked features, each with the state it is locked in and why."
  @type locks :: %{feature => {:on | :off, lock_reason}}

  @typedoc """
  The list in force, from the database: the features on, in the order of
  `Apiary.Features.all/0`; the version of the saved list, which `save/3` takes; and where
  the list comes from.
  """
  @type current :: %{
          features: [feature],
          version: non_neg_integer,
          source: :env | :saved | :default
        }

  @typedoc """
  A row that a save changes (`preview/2`): the feature, whether it turns on or off, and
  the other features that turn on or off with it.
  """
  @type change :: %{feature: feature, turns: :on | :off, with: [feature]}

  @doc "env?/0 is whether `QORY_FEATURES` is set and not blank: then its features apply."
  @spec env?() :: boolean
  def env? do
    case Application.get_env(:apiary, :features_setting) do
      value when is_binary(value) -> String.trim(value) != ""
      _unset -> false
    end
  end

  @doc """
  current/0 is the list in force as the database has it now, with the version of the saved
  list, which `save/3` takes, and where it comes from: `:env` while `QORY_FEATURES` is
  set, `:saved` once an instance admin saved a list, else `:default`.
  """
  @spec current() :: current
  def current do
    row = row()

    if env?() do
      %{features: Features.enabled(), version: version(row), source: :env}
    else
      saved = row && row.features
      {features, _skipped} = resolve(row)
      %{features: features, version: version(row), source: if(saved, do: :saved, else: :default)}
    end
  end

  @doc """
  version/0 is the version of the saved list as the database has it now: 0 where nothing
  is saved, or where the migration of its columns has not run yet.
  """
  @spec version() :: non_neg_integer
  def version, do: version(row())

  @doc """
  locks/0 is the features a save may not change, each with the state it is locked in and
  the reason (`t:lock_reason/0`): `observability` on, always; `factory` on, while adapters
  are set in the server's environment, with the features it needs; `registry` off, while
  `QORY_REGISTRY` is not set.
  """
  @spec locks() :: locks
  def locks do
    locks = %{observability: {:on, :always}}

    locks =
      if Apiary.Adapters.Installed.names() != [] or Apiary.Nodes.Installed.names() != [],
        do: Map.put(locks, :factory, {:on, :installed_adapters}),
        else: locks

    locks =
      if registry_set?(), do: locks, else: Map.put(locks, :registry, {:off, :no_registry})

    needed_by_locked(locks)
  end

  # `locks` with each feature that a feature locked on by the server's environment needs,
  # directly or through another, locked on and naming that feature. A feature already
  # locked keeps that lock: `observability`, always.
  defp needed_by_locked(locks) do
    for {feature, {:on, reason}} <- locks,
        reason != :always,
        needed <- with_needs([feature]) -- [feature],
        reduce: locks do
      locks -> Map.put_new(locks, needed, {:on, {:needed_by, feature}})
    end
  end

  @doc """
  close/2 is the list `wanted` sets, from `current`, closed over the features' needs: a
  feature turned on turns on what it needs, directly or through another; a feature turned
  off turns off what needs it. Where one row turns a feature on and another turns off one
  it needs, the one turned off stays off, with the features that need it. In the order of
  `Apiary.Features.all/0`.
  """
  @spec close([feature], [feature]) :: [feature]
  def close(current, wanted) when is_list(current) and is_list(wanted) do
    on = with_needs(Enum.reject(wanted, &(&1 in current)))
    off = with_dependants(Enum.reject(current, &(&1 in wanted)))
    ordered(Enum.reject(current ++ on, &(&1 in off)))
  end

  @doc """
  preview/2 is each row whose switch differs between `current` and `wanted`, in the order of
  `Apiary.Features.all/0`, with the other features it turns on or off with it: for a
  feature turned on, the features it needs that are off in `current`; for a feature turned
  off, the features on in `current` that need it. A feature of `with` may also be a row
  that changes.
  """
  @spec preview([feature], [feature]) :: [change]
  def preview(current, wanted) when is_list(current) and is_list(wanted) do
    for feature <- Features.all(), feature in wanted != feature in current do
      if feature in wanted do
        with = Enum.reject(with_needs([feature]), &(&1 == feature or &1 in current))
        %{feature: feature, turns: :on, with: ordered(with)}
      else
        with = Enum.filter(with_dependants([feature]), &(&1 != feature and &1 in current))
        %{feature: feature, turns: :off, with: ordered(with)}
      end
    end
  end

  @doc "running_runs/0 is how many runs are running now, in every workspace."
  @spec running_runs() :: non_neg_integer
  def running_runs, do: Repo.aggregate(from(r in Run, where: r.state == "running"), :count)

  @doc """
  save/3 saves the features listed in `wanted`, atoms or their names, for the instance admin
  of `scope`, given the `version` of the saved list they were read at (`current/0`). The
  list is closed over the features' needs from the list in force (`close/2`). Once
  committed, this node's copy is written and every node reads the list again. A save that
  changes no feature writes only the features it marks seen (in the moduledoc).

  Returns `{:ok, current}`, the list in force after the save (`current/0`);
  `{:error, :env}` while `QORY_FEATURES` is set; `{:error, :stale}` where the saved list
  changed after `version`, so the wanted list was read from an older one;
  `{:error, {:locked, feature}}` where the closed list changes a locked feature
  (`locks/0`); `{:error, :unknown_feature}` where `wanted` lists one that is no feature;
  `{:error, :not_found}` for anyone outside the instance's organisation;
  `{:error, :forbidden}` for anyone else there but an instance admin; or
  `{:error, :not_migrated}` where the migration of the saved features' columns has not run
  yet, which saves nothing.
  """
  @spec save(Scope.t() | nil, [feature | String.t()], non_neg_integer) ::
          {:ok, current}
          | {:error,
             :env
             | :stale
             | {:locked, feature}
             | :unknown_feature
             | :not_found
             | :forbidden
             | :not_migrated}
  def save(scope, wanted, version) when is_list(wanted) and is_integer(version) do
    with :ok <-
           Access.authorize(
             Access.in_instance(scope),
             :"instance.features_save",
             Access.instance_organisation()
           ),
         :ok <- if(env?(), do: {:error, :env}, else: :ok),
         {:ok, wanted} <- cast(wanted) do
      write(scope, wanted, version)
    end
  end

  defp write(scope, wanted, version) do
    Repo.transact(fn ->
      row = lock_row()
      {before, skipped} = resolve(row)
      features = close(before, wanted)

      cond do
        row.features_version != version ->
          {:error, :stale}

        locked = locked(features) ->
          {:error, {:locked, locked}}

        features == before ->
          with {:ok, _row} <- mark_seen(row, before, skipped), do: {:ok, :unchanged}

        true ->
          with {:ok, organisation} <- instance_organisation(),
               {:ok, _row} <- write_row(row, features),
               :ok <- record(scope, organisation, before, features),
               do: {:ok, :changed}
      end
    end)
    |> case do
      {:ok, :changed} ->
        refresh()
        Cache.changed()
        {:ok, current()}

      {:ok, :unchanged} ->
        {:ok, current()}

      {:error, _reason} = error ->
        error
    end
  rescue
    error in Postgrex.Error -> missing_column!(error, __STACKTRACE__, {:error, :not_migrated})
  end

  # The first locked feature, in the order of `Apiary.Features.all/0`, whose state in
  # `features` is not the one it is locked in; nil for none.
  defp locked(features) do
    locks = locks()

    Enum.find(Features.all(), fn feature ->
      case locks do
        %{^feature => {state, _reason}} -> feature in features != (state == :on)
        _unlocked -> false
      end
    end)
  end

  defp write_row(row, features) do
    row
    |> Ecto.Changeset.change(
      features: saved_names(row, features),
      features_version: row.features_version + 1,
      features_seen: seen(row, Features.all()),
      updated_at: DateTime.utc_now()
    )
    |> Repo.update()
  end

  # A save that changes no feature marks every feature of the release as seen, where a
  # list is saved and one is not seen yet. It writes the list in force, `before`, with
  # them, so that an unseen feature on by default stays on once seen; the version stays,
  # as the list in force does. `skipped` keeps the saved names this release does not have.
  defp mark_seen(%Row{features: nil} = row, _before, _skipped), do: {:ok, row}

  defp mark_seen(row, before, skipped) do
    case seen(row, Features.all()) do
      seen when seen == row.features_seen ->
        {:ok, row}

      seen ->
        row
        |> Ecto.Changeset.change(
          features: saved_names(row, before) ++ skipped,
          features_seen: seen,
          updated_at: DateTime.utc_now()
        )
        |> Repo.update()
    end
  end

  defp record(scope, organisation, before, features) do
    changes = %{before: %{features: names(before)}, after: %{features: names(features)}}

    with {:ok, _entry} <-
           Audit.record(
             Repo,
             Scope.in_organisation(scope, organisation),
             :"instance.features_save",
             organisation,
             changes
           ),
         do: :ok
  end

  # The instance's organisation, whose trail contains the entry; its owners are the
  # instance's admins.
  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :forbidden}
    end
  end

  # The features listed in `wanted`, atoms or their names.
  defp cast(wanted) do
    known = Map.new(Features.all(), &{Atom.to_string(&1), &1})

    features =
      Enum.map(wanted, fn
        name when is_atom(name) or is_binary(name) -> Map.get(known, to_string(name))
        _other -> nil
      end)

    if nil in features, do: {:error, :unknown_feature}, else: {:ok, Enum.uniq(features)}
  end

  ## Each node's copy

  @doc """
  boot/0 is the cache's first read, after the migrator: while `QORY_FEATURES` is set, it
  saves the variable's list, with the features the config turns on, where the saved one
  differs, raising its version, with no entry in the trail; else it reads, once, the
  features an older release switched in the config (`c:Apiary.Edition.config_features/0`,
  in the moduledoc). Then it writes this node's copy (`refresh/0`).
  """
  @spec boot() :: [feature]
  def boot do
    if env?(), do: keep_env_list(), else: read_config_features()
    refresh()
  end

  @doc """
  refresh/0 writes this node's copy of the list in force, as `load/0` reads it, where it
  changed, sends a message to the processes that subscribed to it
  (`Apiary.Features.Cache.subscribe/0`), and returns it.
  """
  @spec refresh() :: [feature]
  def refresh do
    features = load()

    if Application.get_env(:apiary, :features) != features do
      Application.put_env(:apiary, :features, features)
      Cache.written(features)
    end

    features
  end

  @doc """
  load/0 is the list in force: the variable's while `QORY_FEATURES` is set, as
  `Apiary.Features.boot!/0` checked it; else the saved list, each name this release does
  not have skipped with a log line, else the defaults, through the locks.
  """
  @spec load() :: [feature]
  def load do
    if env?() do
      Features.boot!()
    else
      row = row()
      {features, skipped} = resolve(row)

      Enum.each(skipped, &log_skipped/1)
      features
    end
  end

  # One log line for a saved name this release does not have, the first time this node
  # reads it, and none on a later read: the node keeps the names it logged.
  defp log_skipped(name) do
    logged = :persistent_term.get({__MODULE__, :skipped}, MapSet.new())

    unless MapSet.member?(logged, name) do
      :persistent_term.put({__MODULE__, :skipped}, MapSet.put(logged, name))

      Logger.warning(
        "Features: skipped the saved feature #{name}, which this release does not have."
      )
    end
  end

  # Every feature of the release is seen by the variable's list, the config features too:
  # the list has the ones the config turns on (`Apiary.Features.boot!/0`).
  defp keep_env_list do
    names = names(Features.boot!())

    Repo.transact(fn ->
      row = lock_row()
      seen = seen(row, Features.all())

      if row.features == names and row.features_seen == seen,
        do: {:ok, row},
        else: write_names(row, names, seen)
    end)

    :ok
  rescue
    error in Postgrex.Error -> missing_column!(error, __STACKTRACE__, :ok)
  end

  # The edition's config features the row has not read yet, read under the row's lock:
  # each one on turned on in the saved list, and every one added to the row's names.
  defp read_config_features do
    case unread(Apiary.Edition.config_features(), row()) do
      [] ->
        :ok

      _unread ->
        Repo.transact(fn ->
          row = lock_row()

          case unread(Apiary.Edition.config_features(), row) do
            [] -> {:ok, row}
            unread -> write_config_features(row, unread)
          end
        end)

        :ok
    end
  rescue
    error in Postgrex.Error -> missing_column!(error, __STACKTRACE__, :ok)
  end

  # The config features the saved list of `row` has not seen; every one where there is no
  # row.
  defp unread(config_features, row) do
    seen = (row && row.features_seen) || []
    Enum.reject(config_features, fn {feature, _on?} -> Atom.to_string(feature) in seen end)
  end

  # Where the list changes, every feature of the release is marked seen with it; else only
  # the config features read.
  defp write_config_features(row, unread) do
    on = for {feature, true} <- unread, feature in Features.all(), do: feature
    {before, _skipped} = resolve(row)
    features = close(before, before ++ on)

    changes =
      if features == before,
        do: [features_seen: seen(row, Enum.map(unread, &elem(&1, 0)))],
        else: [
          features: saved_names(row, features),
          features_version: row.features_version + 1,
          features_seen: seen(row, Features.all())
        ]

    row
    |> Ecto.Changeset.change(changes ++ [updated_at: DateTime.utc_now()])
    |> Repo.update()
  end

  defp write_names(row, names, seen) do
    changes = [features_seen: seen, updated_at: DateTime.utc_now()]

    changes =
      if row.features == names,
        do: changes,
        else: changes ++ [features: names, features_version: row.features_version + 1]

    row
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
  end

  # The names of `features` to save in `row`, with `registry` kept as `row` has it while
  # `QORY_REGISTRY` is not set on this node: the lock that turns it off here is this
  # node's, so a save made here leaves the saved value of `registry` to the nodes that
  # have the variable. It is kept only while `features` has every feature it needs, so a
  # save here that turns one of them off turns `registry` off too, as a save on a node
  # with the variable does.
  defp saved_names(row, features) do
    keep? = not registry_set?() and is_list(row.features) and "registry" in row.features
    names(if keep?, do: ordered(met(Enum.uniq(features ++ [:registry]))), else: features)
  end

  # The names `row` has seen, with `features` added after them. `registry` is not added
  # while `QORY_REGISTRY` is not set, which locks it off: it takes its default once the
  # variable is set, which turns it on.
  defp seen(row, features) do
    features = if registry_set?(), do: features, else: features -- [:registry]
    Enum.uniq(row.features_seen ++ names(features))
  end

  ## The list

  # The list in force for the row's saved list, with each default feature the list has not
  # seen; or the defaults, for none saved or no row. And the saved names this release
  # does not have.
  defp resolve(%Row{features: names, features_seen: seen}) when is_list(names) do
    known = Map.new(Features.all(), &{Atom.to_string(&1), &1})
    {kept, skipped} = Enum.split_with(names, &Map.has_key?(known, &1))
    {:ok, defaults} = Features.parse(nil)
    unseen = Enum.reject(defaults, &(Atom.to_string(&1) in seen))
    {locked_list(Enum.map(kept, &Map.fetch!(known, &1)) ++ unseen), skipped}
  end

  defp resolve(_none) do
    {:ok, defaults} = Features.parse(nil)
    {locked_list(defaults), []}
  end

  # `features` through the locks: a feature locked on with what it needs, one locked off
  # without what needs it, and without a feature whose needs are not all there.
  defp locked_list(features) do
    locks = locks()
    on = for {feature, {:on, _reason}} <- locks, do: feature
    off = with_dependants(for {feature, {:off, _reason}} <- locks, do: feature)

    (features ++ with_needs(on))
    |> Enum.reject(&(&1 in off))
    |> met()
    |> ordered()
  end

  # `features` without each one whose needs are not all among them, until none is left.
  defp met(features) do
    case Enum.reject(features, fn feature ->
           Enum.all?(Features.needs(feature), &(&1 in features))
         end) do
      [] -> features
      unmet -> met(Enum.reject(features, &(&1 in unmet)))
    end
  end

  # `features` with every feature one of them needs, directly or through another.
  defp with_needs(features) do
    more =
      features
      |> Enum.flat_map(&Features.needs/1)
      |> Enum.reject(&(&1 in features))
      |> Enum.uniq()

    if more == [], do: features, else: with_needs(features ++ more)
  end

  # `features` with every feature that needs one of them, directly or through another.
  defp with_dependants(features) do
    more =
      for feature <- Features.all(),
          feature not in features,
          Enum.any?(Features.needs(feature), &(&1 in features)),
          do: feature

    if more == [], do: features, else: with_dependants(features ++ more)
  end

  defp ordered(features), do: Enum.filter(Features.all(), &(&1 in features))

  defp names(features), do: Enum.map(features, &Atom.to_string/1)

  defp registry_set?,
    do: String.trim(Application.get_env(:apiary, :registry_setting) || "") != ""

  ## The row

  defp version(nil), do: 0
  defp version(%Row{features_version: version}), do: version

  # The instance's row, nil where there is none, or where the migration of its columns has
  # not run yet.
  defp row do
    Repo.get(Row, true)
  rescue
    error in Postgrex.Error -> missing_column!(error, __STACKTRACE__, nil)
  end

  # The row, locked for the save, made where there is none yet.
  defp lock_row do
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.one!(from r in Row, where: r.id == true, lock: "FOR UPDATE")
  end

  defp missing_column!(error, stacktrace, value) do
    case error.postgres do
      %{code: code} when code in [:undefined_column, :undefined_table] -> value
      _other -> reraise error, stacktrace
    end
  end
end
