defmodule Apiary.Harnesses.FetchSource do
  @moduledoc false

  # The harness source a host belongs to, as a run's harness record (`Apiary.Harnesses.RunHarness`)
  # has it, for the rows of the workspace's Network access that are harness fetches
  # (`Apiary.Runs.harness_fetches/3`).
  #
  #   * `:hidden`: the run's harness is hidden, so no source is shown;
  #   * `:unrecorded`: the run has no harness record;
  #   * `:qory`: a pinned source is the Qory harness, at that host;
  #   * `{:repository, name}`: any other pinned source at that host, by its repository path,
  #     such as `acme/tools`;
  #   * `:none`: a record that pins no source at that host.
  #
  # A host that two sources share has both.

  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Stacks.Document

  @type t :: :hidden | :unrecorded | :qory | {:repository, String.t()} | :none

  @doc false
  # of/4 is the sources of `host` for a run whose record has `pins` and `hidden`;
  # `unrecorded` is true where the run has no record.
  @spec of(String.t(), [map] | nil, boolean | nil, boolean) :: [t]
  def of(_host, _pins, _hidden, true), do: [:unrecorded]
  def of(_host, _pins, true, _unrecorded), do: [:hidden]

  def of(host, pins, _hidden, _unrecorded) do
    case for(%{"git" => git} <- pins || [], is_binary(git), at?(git, host), do: label(git)) do
      [] -> [:none]
      sources -> Enum.uniq(sources)
    end
  end

  defp at?(git, host), do: ComposedConfiguration.source_host(git) == String.downcase(host)

  defp label(git) do
    if git == Definition.qory_harness().git,
      do: :qory,
      else: {:repository, Document.repository(git)}
  end
end
