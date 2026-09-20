defmodule Apiary.AccessKeysFixtures do
  @moduledoc "Test helpers for access keys."

  alias Apiary.AccessKeys

  def unique_label, do: "runner #{System.unique_integer([:positive])}"

  @doc "A key in the scope's hive, and the secret it was created with."
  def access_key_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{label: unique_label()})
    {:ok, access_key, secret} = AccessKeys.create_access_key(scope, attrs)
    %{access_key: access_key, secret: secret}
  end
end
