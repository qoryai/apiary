defmodule Apiary.Artifacts.Store.Volume do
  # Volume is the default artifact store (`Apiary.Artifacts.Store`): a directory on the
  # instance's volume, the root `QORY_ARTIFACTS_DIR` is set to, `/var/lib/apiary/artifacts`
  # unset (`config/runtime.exs`, kept as `config :apiary, :artifacts_dir`).
  #
  # A store key is the content's SHA-256 digest, 64 lowercase hex characters, and the
  # stored copy's path is made from that digest alone: `<root>/ab/cd/<digest>`, with `ab`
  # and `cd` its first four characters. No filename or other text of a caller is ever
  # part of a path; a key of any other form is refused before any path is made.
  #
  # `stage/2` writes to a temporary file in the root, `.staging-<random>.tmp`, opened only
  # if it does not exist yet and made mode 0600 before any byte is written. It reads the
  # source in chunks of 64 KiB and stops as soon as the bytes pass the limit, so a source
  # over the limit is read at most one chunk past it and its staged copy deleted. The
  # copy is synced before `stage/2` returns. `commit/1` renames it to the key's path,
  # in the same file system, so a reader finds either no file or the whole content; where
  # that path has a file already, the content is the same and the staged copy is deleted.
  # A temporary file left in the root, by a stage that stopped half way or by a push whose
  # process was killed between its stage and its commit, is removed by a later
  # `commit/1` once it is an hour old (`sweep/1`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  @behaviour Apiary.Artifacts.Store

  @chunk 65_536
  @stale_seconds 3600
  @key ~r/\A[0-9a-f]{64}\z/

  # root/0 is the store's root, an absolute path, or nil where none is set.
  @doc false
  @spec root() :: String.t() | nil
  def root do
    case Application.get_env(:apiary, :artifacts_dir) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: Path.expand(value)

      _unset ->
        nil
    end
  end

  # path/1 is the path of the stored copy of `key`, a SHA-256 digest in lowercase hex:
  # `{:ok, path}`, or `{:error, :invalid_key}` for any other key, and
  # `{:error, :no_root}` with no root set.
  @doc false
  @spec path(String.t()) :: {:ok, String.t()} | {:error, :invalid_key | :no_root}
  def path(key) do
    with root when is_binary(root) <- root() || {:error, :no_root},
         true <- (is_binary(key) and Regex.match?(@key, key)) || {:error, :invalid_key} do
      <<a::binary-size(2), b::binary-size(2), _rest::binary>> = key
      {:ok, Path.join([root, a, b, key])}
    end
  end

  @impl true
  def stage(source, limit) when is_integer(limit) and limit >= 0 do
    with root when is_binary(root) <- root() || {:error, :no_root},
         :ok <- fits(source, limit),
         :ok <- File.mkdir_p(root) do
      temporary = Path.join(root, ".staging-#{suffix()}.tmp")

      case write(temporary, source, limit) do
        {:ok, sha256, size} ->
          {:ok, %{path: temporary, sha256: sha256, size: size}}

        {:error, _reason} = error ->
          _ = File.rm(temporary)
          error
      end
    end
  end

  # A binary is in memory already: one over the limit is refused before a byte is written.
  defp fits({:binary, binary}, limit) when is_binary(binary),
    do: if(byte_size(binary) > limit, do: {:error, :too_large}, else: :ok)

  defp fits({:path, path}, _limit) when is_binary(path), do: :ok
  defp fits(_source, _limit), do: {:error, :unreadable}

  @impl true
  def commit(staged) do
    result = keep(staged)
    if root = root(), do: sweep(root)
    result
  end

  defp keep(%{path: temporary, sha256: sha256}) do
    with {:ok, path} <- path(sha256),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          _ = File.rm(temporary)
          {:ok, sha256}

        _none ->
          case File.rename(temporary, path) do
            :ok -> {:ok, sha256}
            {:error, _reason} = error -> error
          end
      end
    end
  end

  @impl true
  def discard(%{path: temporary}) do
    _ = File.rm(temporary)
    :ok
  end

  @impl true
  def open(key) do
    with {:ok, path} <- path(key) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, path}
        _none -> {:error, :not_found}
      end
    end
  end

  # Removes the temporary files in the root last written more than an hour ago. A push
  # in progress wrote its staged copy at its stage, seconds or minutes before its commit,
  # so its copy is never that old. A file that cannot be read or removed stays.
  defp sweep(root) when is_binary(root) do
    cutoff = System.os_time(:second) - @stale_seconds

    with {:ok, names} <- File.ls(root) do
      for name <- names,
          String.starts_with?(name, ".staging-"),
          String.ends_with?(name, ".tmp"),
          path = Path.join(root, name),
          stale?(path, cutoff),
          do: File.rm(path)
    end

    :ok
  end

  defp stale?(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime < cutoff
      _other -> false
    end
  end

  defp write(temporary, source, limit) do
    with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             {:ok, hash, size} <- copy(source, file, limit),
             :ok <- :file.sync(file) do
          {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower), size}
        end
      after
        File.close(file)
      end
    end
  end

  defp copy({:binary, binary}, file, _limit) do
    with :ok <- :file.write(file, binary),
         do: {:ok, :crypto.hash_update(:crypto.hash_init(:sha256), binary), byte_size(binary)}
  end

  defp copy({:path, path}, file, limit) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, input} ->
        try do
          copy_chunks(input, file, limit, :crypto.hash_init(:sha256), 0)
        after
          File.close(input)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp copy_chunks(input, file, limit, hash, size) do
    case :file.read(input, @chunk) do
      {:ok, chunk} ->
        size = size + byte_size(chunk)

        if size > limit do
          {:error, :too_large}
        else
          with :ok <- :file.write(file, chunk),
               do: copy_chunks(input, file, limit, :crypto.hash_update(hash, chunk), size)
        end

      :eof ->
        {:ok, hash, size}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp suffix, do: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
end
