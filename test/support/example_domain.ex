defmodule Apiary.Lingo.Domain.Example do
  @moduledoc """
  A domain for the tests only, registered beside the software domain in `config/test.exs`:
  its target is named by the `account` label in the system the `platform` label names. It
  has no catalogue, so its locales fall back to the language's. A work item needs no
  target, any target with a system and a path keeps its rules, a run gets no run
  variables, no environment is prebuilt, and no target has a harness file.
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

  @impl true
  def label, do: "Example workspace"

  @impl true
  def description, do: "For the tests only."

  @impl true
  def type_name, do: "Example"

  @impl true
  def type_line, do: "For the tests only."

  @impl true
  def target_required?, do: false

  @impl true
  def check_target(%{system: system, path: path}) when is_binary(system) and is_binary(path),
    do: :ok

  @impl true
  def run_variables(%{}, picked) when is_list(picked), do: {:ok, nil}

  @impl true
  def prebuilds?, do: false

  @impl true
  def harness_file?, do: false
end
