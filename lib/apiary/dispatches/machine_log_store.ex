defmodule Apiary.Dispatches.MachineLogStore do
  @moduledoc false

  # Where the text of each dispatch's machine log is kept: a file in a folder on the
  # server, the path `APIARY_MACHINE_LOGS_DIR` is set to (`config/runtime.exs`, kept as
  # `config :apiary, :machine_logs_dir`). Callers name a file by its key and nothing else,
  # so a bucket can take the folder's place behind `put/2`, `get/1` and `delete/1`.
  #
  # A key is a dispatch's public id, `dp_` and 16 lower-case Crockford base32 characters
  # (`Apiary.Dispatches.Dispatch.public_id?/1`), and the file's name is the key alone. Any
  # other key is `{:error, :invalid_key}`, looked up nowhere, so no key reaches a path
  # outside the folder; the joined path is checked to be in the folder as well.
  #
  # `put/2` writes the text to a temporary file in the folder, opened only if it does not
  # exist yet, made mode 0600 before any byte is written, then synced and renamed to the
  # key's name, so a reader finds either no file or the whole text. The folder is made
  # where it does not exist yet. A temporary file left by a write that stopped half way
  # starts with `.` and ends with `.tmp`: `files/0` lists it, for the retention job to
  # delete.
  #
  # With no folder set (the variable unset or blank), every function is
  # `{:error, :no_folder}` but `delete/1`, which has nothing to delete and is `:ok`.

  alias Apiary.Dispatches.Dispatch

  @temporary ~r/\A\.dp_[0-9a-hjkmnp-tv-z]{16}\.[0-9a-z]{1,32}\.tmp\z/

  @type error :: :no_folder | :invalid_key | File.posix()

  # dir/0 is the folder, an absolute path, or nil where none is set.
  @doc false
  @spec dir() :: String.t() | nil
  def dir do
    case Application.get_env(:apiary, :machine_logs_dir) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: Path.expand(value)

      _unset ->
        nil
    end
  end

  # put/2 writes `text` as the file of `key`, replacing a file of that key.
  @doc false
  @spec put(String.t(), iodata) :: :ok | {:error, error}
  def put(key, text) do
    with {:ok, dir, path} <- path(key),
         :ok <- File.mkdir_p(dir) do
      temporary = Path.join(dir, ".#{key}.#{suffix()}.tmp")

      case write(temporary, text) do
        :ok ->
          rename(temporary, path)

        {:error, _reason} = error ->
          _ = File.rm(temporary)
          error
      end
    end
  end

  # get/1 is the text of the file of `key`: `{:error, :enoent}` where there is none.
  @doc false
  @spec get(String.t()) :: {:ok, binary} | {:error, error}
  def get(key) do
    with {:ok, _dir, path} <- path(key), do: File.read(path)
  end

  # delete/1 deletes the file of `key`; a file that is not there is deleted already.
  @doc false
  @spec delete(String.t()) :: :ok | {:error, error}
  def delete(key) do
    case path(key) do
      {:ok, _dir, path} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, :no_folder} ->
        if Dispatch.public_id?(key), do: :ok, else: {:error, :invalid_key}

      {:error, _reason} = error ->
        error
    end
  end

  # files/0 is every file of the folder that this module writes, as
  # `{:key, key, modified_at}` for a machine log and `{:temporary, name, modified_at}`
  # for a temporary file, `modified_at` in Unix seconds. Other files are left out. No
  # folder set, or none made yet, is `{:ok, []}`.
  @doc false
  @spec files() :: {:ok, [{:key | :temporary, String.t(), integer}]} | {:error, File.posix()}
  def files do
    case dir() do
      nil ->
        {:ok, []}

      dir ->
        case File.ls(dir) do
          {:ok, names} -> {:ok, Enum.flat_map(names, &file(dir, &1))}
          {:error, :enoent} -> {:ok, []}
          {:error, _reason} = error -> error
        end
    end
  end

  # delete_unchanged/2 deletes the file of `key` where its modification time is still
  # `modified_at`, Unix seconds, as `files/0` listed it: `:ok`. A file written again since
  # is left, `:changed`; a file not there is `:gone`. The check and the delete are two
  # calls, so a rename between them is not seen here: a caller that races a write holds
  # off that write first (`Apiary.Dispatches.MachineLogs.prune/1`).
  @doc false
  @spec delete_unchanged(String.t(), integer) :: :ok | :changed | :gone | {:error, error}
  def delete_unchanged(key, modified_at) when is_integer(modified_at) do
    with {:ok, _dir, path} <- path(key) do
      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{mtime: ^modified_at}} -> remove(path)
        {:ok, %File.Stat{}} -> :changed
        {:error, :enoent} -> :gone
        {:error, _reason} = error -> error
      end
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :gone
      {:error, _reason} = error -> error
    end
  end

  # delete_temporary/1 deletes the temporary file `name` that `files/0` listed: `:ok`, or
  # `:gone` for a file not there any more.
  @doc false
  @spec delete_temporary(String.t()) :: :ok | :gone | {:error, error}
  def delete_temporary(name) do
    with dir when is_binary(dir) <- dir() || {:error, :no_folder},
         true <- Regex.match?(@temporary, name) || {:error, :invalid_key},
         do: remove(Path.join(dir, name))
  end

  defp file(dir, name) do
    kind =
      cond do
        Dispatch.public_id?(name) -> :key
        Regex.match?(@temporary, name) -> :temporary
        true -> nil
      end

    with kind when kind != nil <- kind,
         {:ok, %File.Stat{type: :regular, mtime: mtime}} <-
           File.lstat(Path.join(dir, name), time: :posix) do
      [{kind, name, mtime}]
    else
      _other -> []
    end
  end

  # The folder and the file of `key`, which is a dispatch's public id and nothing else.
  defp path(key) do
    with dir when is_binary(dir) <- dir() || {:error, :no_folder},
         true <- Dispatch.public_id?(key) || {:error, :invalid_key},
         path = Path.join(dir, key),
         true <- Path.dirname(path) == dir || {:error, :invalid_key} do
      {:ok, dir, path}
    end
  end

  defp write(temporary, text) do
    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, text),
             do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp rename(temporary, path) do
    case File.rename(temporary, path) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = File.rm(temporary)
        error
    end
  end

  defp suffix, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
end
