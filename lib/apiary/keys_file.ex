defmodule Apiary.KeysFile do
  @moduledoc """
  The keys file, `$APIARY_KEYS_DIR/apiary.env`, that `bin/keys` (`rel/overlays/bin/keys`)
  writes at first start: `SECRET_KEY_BASE`, `APIARY_ENCRYPTION_SECRET`,
  `APIARY_SIGNING_SECRET` and `DATABASE_PASSWORD`, one `NAME=value` line each, mode 0600.
  `bin/keys` generates a name only when the environment does not set it and the file does
  not hold it yet, and never changes one the file holds.

  `config/runtime.exs` reads it in production: `read/1` gives the names the file holds, and
  `get/2` gives a name's value from the environment, or from the file where the environment
  does not set it. The environment always wins. A blank value is an unset one, as a line
  left blank in `.env` is.

  The file is read as `bin/keys` reads it: a line `NAME=value` of one of the four names,
  with a value, is that name's, the first such line wins, and every other line is ignored.
  Nothing here logs a value or puts one in an exception.
  """

  @names ~w(SECRET_KEY_BASE APIARY_ENCRYPTION_SECRET APIARY_SIGNING_SECRET DATABASE_PASSWORD)

  @typedoc "The names the keys file holds, with their values."
  @type t :: %{optional(String.t()) => String.t()}

  @doc """
  read/1 is the keys the file `apiary.env` in `dir` holds: none when `dir` is unset or
  blank, or the file does not exist. A file that exists and cannot be read raises
  `File.Error`, which names the path and the reason.
  """
  @spec read(String.t() | nil) :: t()
  def read(dir) when dir in [nil, ""], do: %{}

  def read(dir) when is_binary(dir) do
    path = Path.join(dir, "apiary.env")

    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc """
  get/2 is `name`'s value: the environment's, or where the environment does not set it,
  the one `keys` holds, or nil.
  """
  @spec get(t(), String.t()) :: String.t() | nil
  def get(keys, name) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> Map.get(keys, name)
      value -> value
    end
  end

  defp parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, keys ->
      case String.split(line, "=", parts: 2) do
        [name, value] when name in @names and value != "" -> Map.put_new(keys, name, value)
        _other -> keys
      end
    end)
  end
end
