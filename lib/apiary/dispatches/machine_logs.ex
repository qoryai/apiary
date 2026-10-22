defmodule Apiary.Dispatches.MachineLogs do
  @moduledoc false

  # Each dispatch's machine log: what the machine a node pool's starter created for the
  # dispatch wrote, from its creation to its end, uploaded once per dispatch, whether or
  # not a run opened (the provisioner contract's `machine-log.schema.json`). The text is a
  # file (`Apiary.Dispatches.MachineLogStore`); its record is a row of
  # `dispatch_machine_logs` (`Apiary.Dispatches.MachineLog`), linked to the dispatch and,
  # through it, to its run. `Apiary.Dispatches` delegates here.
  #
  # ## The upload: `upload/3`
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.Dispatches.current_key/1`): revoked, of a pool deleted, or of a place
  #      out of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, and `dispatch.machine_log` asked of it
  #      (`Apiary.Access`): an unknown dispatch, one another pool claimed and any refusal
  #      of the key are one answer, `{:error, :forbidden}`;
  #   3. the record written, unless the dispatch has one: `{:error, :machine_log_exists}`.
  #      Of two uploads at once, the second waits on the first's record and is refused
  #      once the first commits;
  #   4. the file written (`Apiary.Dispatches.MachineLogStore.put/2`).
  #
  # A dispatch that ended, or whose lease lapsed, takes its machine log as any other. A
  # refusal writes nothing. A file that cannot be written, with no folder set among the
  # causes, rolls the record back and is `{:error, :unavailable}`, with one log line that
  # names the cause and nothing of the request, so the starter's next upload of the same
  # log can succeed. An exception is the same, its log line the exception's module alone.
  # A record rolled back after its file was written leaves a file with no record, which
  # the retention job deletes.
  #
  # ## The read: `machine_log/2`
  #
  # An instance admin's alone (`Apiary.Access.instance_admin?/1`), for a dispatch of any
  # organisation: the text and its record. Anyone else is `{:error, :forbidden}`, before
  # anything is looked up.
  #
  # ## Retention: `retention_days/0` and `prune/1`
  #
  # A machine log is kept `retention_days/0` days after its upload: `MACHINE_LOG_RETENTION_DAYS`,
  # checked at boot (`boot!/0`), else the value saved in Instance settings › Configuration
  # (`Apiary.InstanceConfig`), else 30 days. `prune/1`, which the retention job runs
  # (`Apiary.Retention.prune_all/1`), deletes each older one, its file first and then its
  # record, and the files whose record is gone, a dispatch's row deleted with its run of
  # the queue among them, once they are an hour old.
  #
  # ## The purge: `delete_files/2`
  #
  # The purge of an organisation or a workspace deletes the files of its machine logs
  # before its rows (`Apiary.Deletion`); the records go with the rows.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Access, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches
  alias Apiary.Dispatches.{Dispatch, DispatchRun, MachineLog, MachineLogStore}

  @default_retention_days 30
  @retention_min 1
  @retention_max 365
  # A file without a record is left alone this long, so a file written for a record not
  # yet committed is not deleted under it.
  @orphan_seconds 3_600
  @batch 500

  @type refusal :: :unauthorized | :forbidden | :machine_log_exists | :unavailable
  @type upload :: %{log: String.t(), truncated: boolean}

  @type machine_log :: %{
          dispatch_id: String.t(),
          run_id: Ecto.UUID.t(),
          organisation_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t(),
          byte_size: non_neg_integer,
          truncated: boolean,
          uploaded_at: DateTime.t(),
          text: String.t()
        }

  ## The upload

  # upload/3 stores the machine log of the dispatch `dispatch_id` of the pool of
  # `access_key`: the moduledoc.
  @doc false
  @spec upload(AccessKey.t(), term, upload) :: :ok | {:error, refusal}
  def upload(%AccessKey{key_id: key_id}, dispatch_id, %{log: log, truncated: truncated})
      when is_binary(log) and is_boolean(truncated) do
    if Dispatch.public_id?(dispatch_id) do
      Repo.transact(fn ->
        with {:ok, key} <- Dispatches.current_key(key_id),
             {:ok, dispatch} <- dispatch_of(key, dispatch_id),
             # The record first: its key to the dispatch locks the dispatch's row
             # `FOR KEY SHARE` until the commit, before the file is written, which the
             # retention job's delete of a file with no record waits on (`prune/1`).
             :ok <- insert(dispatch, log, truncated) do
          store(dispatch, log)
        end
      end)
      |> case do
        {:ok, :stored} -> :ok
        {:error, _reason} = refused -> refused
      end
    else
      {:error, :forbidden}
    end
  rescue
    exception ->
      Logger.error("a machine log could not be stored: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  # The dispatch by its public id when the key may take `dispatch.machine_log` on it: one
  # answer for an unknown one, another pool's and a refusal.
  defp dispatch_of(key, dispatch_id) do
    scope = Scope.for_access_key(key)

    with %Dispatch{} = dispatch <- Repo.get_by(Dispatch, public_id: dispatch_id),
         :ok <- Access.authorize(scope, :"dispatch.machine_log", dispatch) do
      {:ok, dispatch}
    else
      _unknown_or_refused -> {:error, :forbidden}
    end
  end

  defp insert(%Dispatch{} = dispatch, log, truncated) do
    row = %{
      id: Ecto.UUID.generate(),
      organisation_id: dispatch.organisation_id,
      workspace_id: dispatch.workspace_id,
      dispatch_id: dispatch.id,
      storage_key: dispatch.public_id,
      byte_size: byte_size(log),
      truncated: truncated,
      uploaded_at: DateTime.utc_now()
    }

    case Repo.insert_all(MachineLog, [row], on_conflict: :nothing, conflict_target: :dispatch_id) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :machine_log_exists}
    end
  end

  defp store(%Dispatch{public_id: key}, log) do
    case MachineLogStore.put(key, log) do
      :ok ->
        {:ok, :stored}

      {:error, :no_folder} ->
        Logger.error("a machine log could not be stored: APIARY_MACHINE_LOGS_DIR is not set")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.error("a machine log could not be stored: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  ## The read

  # machine_log/2 is the machine log of the dispatch `dispatch_id` for an instance admin:
  # `{:ok, machine_log}`; `{:error, :forbidden}` for anyone else; `{:error, :not_found}`
  # for a dispatch with no machine log, or no dispatch; `{:error, :unreadable}` for a
  # record whose file cannot be read, with one log line that names the cause.
  @doc false
  @spec machine_log(Scope.t() | nil, term) ::
          {:ok, machine_log} | {:error, :forbidden | :not_found | :unreadable}
  def machine_log(scope, dispatch_id) do
    cond do
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      not Dispatch.public_id?(dispatch_id) -> {:error, :not_found}
      true -> read(dispatch_id)
    end
  end

  defp read(dispatch_id) do
    found =
      Repo.one(
        from l in MachineLog,
          join: d in Dispatch,
          on: d.id == l.dispatch_id,
          join: r in DispatchRun,
          on: r.id == d.dispatch_run_id,
          where: d.public_id == ^dispatch_id,
          select: {l, r.run_id}
      )

    with {%MachineLog{} = record, run_id} <- found || {:error, :not_found},
         {:ok, text} <- text(record) do
      {:ok,
       %{
         dispatch_id: dispatch_id,
         run_id: run_id,
         organisation_id: record.organisation_id,
         workspace_id: record.workspace_id,
         byte_size: record.byte_size,
         truncated: record.truncated,
         uploaded_at: record.uploaded_at,
         text: text
       }}
    end
  end

  defp text(%MachineLog{storage_key: key}) do
    case MachineLogStore.get(key) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Logger.error("a machine log could not be read: #{inspect(reason)}")
        {:error, :unreadable}
    end
  end

  ## Retention

  # retention_days/0 is how many days a machine log is kept after its upload.
  @doc false
  @spec retention_days() :: pos_integer
  def retention_days, do: Apiary.InstanceConfig.value(:machine_log_retention_days)

  # retention_min_days/0 and retention_max_days/0 are the bounds of the setting.
  @doc false
  @spec retention_min_days() :: pos_integer
  def retention_min_days, do: @retention_min

  @doc false
  @spec retention_max_days() :: pos_integer
  def retention_max_days, do: @retention_max

  # parse_retention_days/1 reads a value of `MACHINE_LOG_RETENTION_DAYS`: `{:ok, days}`, a
  # whole number of days from 1 to 365, or 30 for nil or a blank value; `{:error, reason}`
  # otherwise.
  @doc false
  @spec parse_retention_days(String.t() | nil) :: {:ok, pos_integer} | {:error, String.t()}
  def parse_retention_days(nil), do: {:ok, @default_retention_days}

  def parse_retention_days(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, @default_retention_days}

      trimmed ->
        case Integer.parse(trimmed) do
          {days, ""} when days >= @retention_min and days <= @retention_max ->
            {:ok, days}

          _other ->
            {:error,
             "it is a number of days from #{@retention_min} to #{@retention_max}, got: #{inspect(trimmed)}"}
        end
    end
  end

  # boot!/0 reads `MACHINE_LOG_RETENTION_DAYS` as `config/runtime.exs` left it, checks it,
  # and keeps its value for the life of the node, under `:machine_log_retention_days`: the
  # number of days where the variable is set and not blank, nil otherwise, so the value
  # saved in Instance settings › Configuration applies. It returns the days the variable
  # gives, 30 where it is not set. Called at boot; raises on a value
  # `parse_retention_days/1` refuses, so the instance does not start.
  @doc false
  @spec boot!() :: pos_integer
  def boot! do
    setting = Application.get_env(:apiary, :machine_log_retention_setting)

    case parse_retention_days(setting) do
      {:ok, days} ->
        set = is_binary(setting) and String.trim(setting) != ""
        Application.put_env(:apiary, :machine_log_retention_days, if(set, do: days))
        days

      {:error, reason} ->
        raise ArgumentError, """
        environment variable MACHINE_LOG_RETENTION_DAYS is not valid: #{reason}.
        Leave it unset for #{@default_retention_days} days, or set it, for example:
        MACHINE_LOG_RETENTION_DAYS=14
        """
    end
  end

  # prune/1 deletes the machine logs uploaded more than `retention_days/0` days before
  # `:now` (the clock unless given), file then record, and the files with no record
  # that are an hour old or older. With `dry_run: true` it deletes nothing and returns
  # the same counts: `%{machine_logs_deleted: n, files_deleted: m}`. A file that cannot
  # be deleted keeps its record, for the next job to try again.
  @doc false
  @spec prune(keyword) :: %{machine_logs_deleted: non_neg_integer, files_deleted: non_neg_integer}
  def prune(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    dry_run? = Keyword.get(opts, :dry_run, false)
    cutoff = DateTime.add(now, -retention_days(), :day)

    deleted = prune_older(cutoff, dry_run?, nil, 0)
    files = prune_files(DateTime.to_unix(now) - @orphan_seconds, dry_run?)
    %{machine_logs_deleted: deleted, files_deleted: files}
  end

  defp prune_older(cutoff, dry_run?, after_id, deleted) do
    query =
      from l in MachineLog,
        where: l.uploaded_at < ^cutoff,
        order_by: l.id,
        limit: @batch,
        select: {l.id, l.storage_key}

    query = if after_id, do: from(l in query, where: l.id > ^after_id), else: query

    case Repo.all(query) do
      [] ->
        deleted

      rows ->
        ids =
          if dry_run?,
            do: Enum.map(rows, &elem(&1, 0)),
            else: for({id, key} <- rows, MachineLogStore.delete(key) == :ok, do: id)

        unless dry_run?,
          do: Repo.delete_all(from l in MachineLog, where: l.id in ^ids)

        {last_id, _key} = List.last(rows)
        prune_older(cutoff, dry_run?, last_id, deleted + length(ids))
    end
  end

  # The files of no record, and the temporary files, modified at `before` or earlier.
  defp prune_files(before, dry_run?) do
    case MachineLogStore.files() do
      {:ok, files} ->
        old = for {kind, name, mtime} <- files, mtime <= before, do: {kind, name, mtime}
        {listed, temporary} = Enum.split_with(old, &(elem(&1, 0) == :key))
        keys = Enum.map(listed, &elem(&1, 1))

        kept =
          keys
          |> Enum.chunk_every(@batch)
          |> Enum.flat_map(fn chunk ->
            Repo.all(from l in MachineLog, where: l.storage_key in ^chunk, select: l.storage_key)
          end)
          |> MapSet.new()

        orphans = Enum.reject(listed, &MapSet.member?(kept, elem(&1, 1)))

        if dry_run? do
          length(orphans) + length(temporary)
        else
          Enum.count(orphans, &delete_orphan/1) +
            Enum.count(temporary, &(MachineLogStore.delete_temporary(elem(&1, 1)) == :ok))
        end

      {:error, reason} ->
        Logger.error("the machine logs folder could not be read: #{inspect(reason)}")
        0
    end
  end

  # A file listed with no record, deleted with its dispatch's row locked `FOR UPDATE`. An
  # upload takes `FOR KEY SHARE` on that row when it writes its record, through the
  # record's key to the dispatch, before it writes its file, and holds it until it
  # commits (`upload/3`). So the delete waits for an upload in progress, and finds its
  # record once it committed; an upload that starts later waits for the delete. With the
  # row held, a record leaves the file, and so does a file written since the listing, by
  # an upload rolled back since. With no dispatch row, nothing can upload for it.
  defp delete_orphan({:key, key, mtime}) do
    {:ok, deleted?} =
      Repo.transact(fn ->
        Repo.one(from d in Dispatch, where: d.public_id == ^key, select: d.id, lock: "FOR UPDATE")

        deleted? =
          not Repo.exists?(from l in MachineLog, where: l.storage_key == ^key) and
            MachineLogStore.delete_unchanged(key, mtime) == :ok

        {:ok, deleted?}
      end)

    deleted?
  end

  ## The purge

  # delete_files/2 deletes the files of the machine logs of the organisation
  # `organisation_id`, or of its workspace `workspace_id` where it is not nil, and leaves
  # their records to the purge: the files deleted. A file that cannot be deleted is left,
  # for the retention job to delete once its record is gone.
  @doc false
  @spec delete_files(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: non_neg_integer
  def delete_files(organisation_id, workspace_id) when is_binary(organisation_id) do
    delete_files(organisation_id, workspace_id, nil, 0)
  end

  defp delete_files(organisation_id, workspace_id, after_id, deleted) do
    query =
      from l in MachineLog,
        where: l.organisation_id == ^organisation_id,
        order_by: l.id,
        limit: @batch,
        select: {l.id, l.storage_key}

    query =
      if workspace_id, do: from(l in query, where: l.workspace_id == ^workspace_id), else: query

    query = if after_id, do: from(l in query, where: l.id > ^after_id), else: query

    case Repo.all(query) do
      [] ->
        deleted

      rows ->
        count = Enum.count(rows, fn {_id, key} -> MachineLogStore.delete(key) == :ok end)
        {last_id, _key} = List.last(rows)
        delete_files(organisation_id, workspace_id, last_id, deleted + count)
    end
  end
end
