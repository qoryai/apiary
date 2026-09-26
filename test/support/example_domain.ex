defmodule Apiary.Lingo.Domain.Example do
  @moduledoc """
  A domain for the tests only, registered beside the software domain in `config/test.exs`:
  its target is named by the `account` label in the system the `platform` label names. It
  has no catalogue, so its locales fall back to the language's.
  """
  @behaviour Apiary.Lingo.Domain

  alias Apiary.Runs.Target

  @impl true
  def target(%{} = labels) do
    with system when is_binary(system) <- Target.label(labels["platform"]),
         path when is_binary(path) <- Target.label(labels["account"]) do
      {:ok, %{system: system, path: path}}
    else
      _ -> :none
    end
  end

  @impl true
  def target_labels, do: ["platform", "account"]

  @impl true
  def name, do: "example"
end
