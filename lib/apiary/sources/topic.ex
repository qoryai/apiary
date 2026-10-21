defmodule Apiary.Sources.Topic do
  @moduledoc false

  # The PubSub topic of a workspace's Backlog. Its messages carry ids only, and are sent
  # after the change they tell of commits.

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: "backlog:" <> workspace_id
end
