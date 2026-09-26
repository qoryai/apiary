defmodule Apiary.DeliveryMailAdapter do
  @moduledoc """
  A Swoosh adapter whose relay fails after something happened during the delivery: it
  calls the function the test put in the process's dictionary under `:during_delivery`,
  given the email, then answers as a relay that took the message and timed out.
  """
  use Swoosh.Adapter

  @impl true
  def deliver(email, _config) do
    if during = Process.get(:during_delivery), do: during.(email)
    {:error, :timeout}
  end
end
