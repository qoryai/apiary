defmodule Apiary.Adapters.Installed.CodeFile do
  # The file an adapter installed with Qory Apiary reads its one-time code from: `code`, in
  # a folder per adapter, `<name>`, in the directory of the codes
  # (`Apiary.Adapters.Installed.dir/0`), which only that adapter mounts. It holds the code
  # as the adapter sends it, its prefix, its 26 characters, `.` and the fingerprint of the
  # server's key (`Apiary.Contract.Enrolment.issued_code/2`), and one newline.
  #
  # **The folder.** Made when it is missing, mode 0755 (`make_folder/1`), at boot for each
  # name listed (`Apiary.Adapters.Installed.make_folders/0`) and again before each write. A
  # folder that is there must be a directory: a symbolic link, or anything else, in its
  # place is refused, `{:error, :enotdir}`, and nothing is written. Deleting the code leaves
  # the folder.
  #
  # **A write replaces the file whole.** The code goes to a new file in the same folder,
  # `.code.<random>`, made new (an existing file is not opened), then is flushed to the disk
  # (`:file.sync/1`), given mode 0644, so the adapter, which runs as another user, reads it,
  # and renamed over `code`: a reader finds the old file or the new one, never a part of
  # one. A failed write deletes what it made and leaves the old file.
  #
  # **The code is a secret until it is used.** It is written there and nowhere else: this
  # module logs nothing, and a failure says only its reason.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  alias Apiary.Adapters.Installed

  @doc false
  # The folder of the adapter installed as `name`.
  @spec folder(String.t()) :: String.t()
  def folder(name) when is_binary(name), do: Path.join(Installed.dir(), name)

  @doc false
  # The path of the code of the adapter installed as `name`.
  @spec path(String.t()) :: String.t()
  def path(name) when is_binary(name), do: Path.join(folder(name), "code")

  @doc false
  # Makes the folder of the adapter installed as `name` when it is missing, mode 0755:
  # `:ok` once it is a directory, `{:error, :enotdir}` where something else is in its
  # place, a symbolic link included, or `{:error, reason}`, a `:file` error.
  @spec make_folder(String.t()) :: :ok | {:error, atom}
  def make_folder(name) when is_binary(name) do
    folder = folder(name)

    case File.lstat(folder) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :enotdir}
      {:error, :enoent} -> make(folder)
      {:error, reason} -> {:error, reason}
    end
  end

  # A folder made new, then given its mode, which the umask may have narrowed; one made
  # meanwhile by another process is checked as one found.
  defp make(folder) do
    case File.mkdir(folder) do
      :ok ->
        File.chmod(folder, 0o755)

      {:error, :eexist} ->
        case File.lstat(folder) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, %File.Stat{}} -> {:error, :enotdir}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Writes `code`, the code as the adapter sends it, and a newline, to the file of the
  # adapter installed as `name`, its folder made first when it is missing, replacing the
  # file whole: `:ok`, or `{:error, reason}`, the reason a `:file` error, and the file as
  # it was.
  @spec write(String.t(), String.t()) :: :ok | {:error, atom}
  def write(name, code) when is_binary(name) and is_binary(code) do
    with :ok <- make_folder(name) do
      final = path(name)
      temp = Path.join(folder(name), ".code.#{random()}")

      with :ok <- write_synced(temp, [code, ?\n]),
           :ok <- File.chmod(temp, 0o644),
           :ok <- File.rename(temp, final) do
        :ok
      else
        {:error, reason} ->
          _ = File.rm(temp)
          {:error, reason}
      end
    end
  end

  @doc false
  # Deletes the file of the adapter installed as `name`, and leaves its folder: `:ok`, a
  # missing file included, or `{:error, reason}`.
  @spec delete(String.t()) :: :ok | {:error, atom}
  def delete(name) when is_binary(name) do
    case File.rm(path(name)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # exists?/1 says whether the file of the adapter installed as `name` is there.
  @spec exists?(String.t()) :: boolean
  def exists?(name) when is_binary(name), do: File.regular?(path(name))

  # A file made new, written and flushed to the disk before it is closed.
  defp write_synced(path, data) do
    case :file.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, data),
               do: :file.sync(io)

        closed = :file.close(io)
        if result == :ok, do: closed, else: result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
