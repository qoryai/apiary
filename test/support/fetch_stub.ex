defmodule Apiary.FetchStub do
  @moduledoc """
  FetchStub is the resolver `Apiary.Integrations.Fetch` asks in the tests, which never
  reach the network: a name resolves by its first label.

  | First label | Addresses |
  |---|---|
  | `private` | `10.1.2.3` |
  | `loopback` | `127.0.0.1` |
  | `metadata` | `169.254.169.254` |
  | `ula` | `fd00::1` |
  | `mixed` | `203.0.113.10` and `10.1.2.3` |
  | `v6` | `2001:db8::10` |
  | `nowhere` | none: `:nxdomain` |
  | any other | `203.0.113.10` |
  """

  @public {203, 0, 113, 10}

  @doc "The address every ordinary name resolves to."
  def public, do: @public

  @doc "resolve/1 answers for `host` by its first label (see the module's documentation)."
  def resolve(host) do
    case host |> String.split(".") |> hd() do
      "private" -> {:ok, [{10, 1, 2, 3}]}
      "loopback" -> {:ok, [{127, 0, 0, 1}]}
      "metadata" -> {:ok, [{169, 254, 169, 254}]}
      "ula" -> {:ok, [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]}
      "mixed" -> {:ok, [@public, {10, 1, 2, 3}]}
      "v6" -> {:ok, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x10}]}
      "nowhere" -> {:error, :nxdomain}
      _ -> {:ok, [@public]}
    end
  end
end
