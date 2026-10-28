defmodule Apiary.Lingo.Domain.Example do
  @moduledoc """
  A domain for the tests only, registered beside the software domain in `config/test.exs`:
  its target is named by the `account` label in the system the `platform` label names. It
  has no catalogue, so its locales fall back to the language's. A work item needs no
  target. A target it has is a host name (`Apiary.Lingo.Domain.host?/1`) and a path of 1
  to 200 characters that can be a label. A run gets no run variables, no environment is
  prebuilt, and no target has a harness file. Its workspace type is `qory.example`
  (`definition/0`).
  """
  @behaviour Apiary.Lingo.Domain

  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.Definition
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
  def check_target(%{system: system, path: path}) do
    if Domain.host?(system) and is_binary(Target.label(path)) and String.length(path) <= 200,
      do: :ok,
      else: {:error, :target_invalid}
  end

  @impl true
  def run_variables(%{}, picked) when is_list(picked), do: {:ok, nil}

  @impl true
  def prebuilds?, do: false

  @impl true
  def harness_file?, do: false

  @impl true
  def definition, do: Definition.qory("qory.example")
end
