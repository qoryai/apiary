defmodule Apiary.Secrets.Reference do
  @moduledoc """
  Where a secret is, in two parts: the **store**, and the **entry** in that store. Written
  as `<store>:<entry>`, as `builtin:sec_0123456789abcdef`.

  - The store is `builtin`, the instance's built-in store (`Apiary.Secrets.Instance`), or
    an adapter's public id (`na_` and 16 lowercase Crockford base32 characters), for a
    store reached through that adapter. Only the built-in store resolves an entry.
  - The entry is 1 to 256 printable ASCII characters, space to `~`. In the built-in store
    it is the public id of an instance secret (`sec_…`); in another store it is that
    store's and is not read.

  The built-in store resolves an entry only for the one who holds the reference: an
  adapter's reference finds only an instance secret of that adapter
  (`Apiary.Secrets.Instance`).
  """

  @enforce_keys [:store, :entry]
  defstruct [:store, :entry]

  @typedoc "Where a secret is: its store and its entry there."
  @type t :: %__MODULE__{store: String.t(), entry: String.t()}

  @builtin "builtin"
  @entry ~r/\A[ -~]{1,256}\z/

  @doc "builtin/0 is the name of the instance's built-in store."
  @spec builtin() :: String.t()
  def builtin, do: @builtin

  @doc """
  new/2 is the reference of `entry` in `store`: `{:ok, reference}`, or `:error` for a
  store or an entry outside the forms of the module's documentation.
  """
  @spec new(term, term) :: {:ok, t} | :error
  def new(store, entry) when is_binary(store) and is_binary(entry) do
    if store?(store) and entry?(store, entry),
      do: {:ok, %__MODULE__{store: store, entry: entry}},
      else: :error
  end

  def new(_store, _entry), do: :error

  @doc """
  parse/1 reads a reference written as `<store>:<entry>`: `{:ok, reference}`, or `:error`
  for anything else. The first `:` ends the store.
  """
  @spec parse(term) :: {:ok, t} | :error
  def parse(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [store, entry] -> new(store, entry)
      _other -> :error
    end
  end

  def parse(_value), do: :error

  @doc "to_string/1 writes `reference` as `<store>:<entry>`."
  @spec to_string(t) :: String.t()
  def to_string(%__MODULE__{store: store, entry: entry}), do: store <> ":" <> entry

  @doc "builtin?/1 says whether `reference` is to the built-in store."
  @spec builtin?(t) :: boolean
  def builtin?(%__MODULE__{store: store}), do: store == @builtin

  defp store?(@builtin), do: true
  defp store?(store), do: Apiary.PublicId.valid?("na", store)

  defp entry?(@builtin, entry), do: Apiary.PublicId.valid?("sec", entry)
  defp entry?(_store, entry), do: Regex.match?(@entry, entry)
end
