defmodule Apiary.FailingMailAdapter do
  @moduledoc "A Swoosh adapter whose relay refuses every message."
  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :relay_refused}
end
