defmodule Apiary.Artifacts.Store do
  # Store is the behaviour of the place the content of artifact files is kept, and the
  # adapter in use (`impl/0`): `Apiary.Artifacts.Store.Volume`, a directory on the
  # instance's volume, unless `config :apiary, Apiary.Artifacts.Store, adapter: module`
  # sets another, such as an S3-compatible store.
  #
  # A file goes in in two steps, so that a version is checked before anything of it is
  # kept under a key. `stage/2` reads the source, a path or a binary, into a staged copy
  # while it counts its bytes and its SHA-256 digest, and stops at `limit` bytes: a source
  # larger than `limit` is never read in full or kept, `{:error, :too_large}`. The format
  # check reads the staged copy's `path` (`Apiary.Artifacts.Format`). Then `commit/1`
  # keeps the content under its store key, a content address made from the digest alone,
  # so the same content twice is one stored copy; or `discard/1` drops the staged copy.
  # `commit/1` runs while the push holds the work item's lock, so an adapter keeps
  # `commit/1` local and fast. `open/1` is a stored copy by its key: a path, or a stream
  # of its bytes.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  @typedoc "What a file is read from: a path on the server, or its bytes."
  @type source :: {:path, Path.t()} | {:binary, binary}

  @typedoc """
  A staged copy: `path`, a local file with the content, `sha256` its digest in lowercase
  hex and `size` its bytes.
  """
  @type staged :: %{path: Path.t(), sha256: String.t(), size: non_neg_integer}

  @doc "Reads `source` into a staged copy of at most `limit` bytes."
  @callback stage(source, limit :: non_neg_integer) ::
              {:ok, staged} | {:error, :too_large | :unreadable | term}

  @doc "Keeps the staged copy under its store key, and returns the key."
  @callback commit(staged) :: {:ok, String.t()} | {:error, term}

  @doc "Drops the staged copy."
  @callback discard(staged) :: :ok

  @doc "The stored copy of `store_key`: a path, or a stream of its bytes."
  @callback open(store_key :: String.t()) ::
              {:ok, Path.t() | Enumerable.t()} | {:error, :not_found | term}

  # impl/0 is the store adapter in use.
  @doc false
  @spec impl() :: module
  def impl do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, Apiary.Artifacts.Store.Volume)
  end
end
