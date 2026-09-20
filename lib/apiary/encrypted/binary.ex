defmodule Apiary.Encrypted.Binary do
  @moduledoc "An Ecto type for a string stored encrypted with `Apiary.Vault`."
  use Cloak.Ecto.Binary, vault: Apiary.Vault
end
