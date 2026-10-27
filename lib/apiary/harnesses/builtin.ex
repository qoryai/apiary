defmodule Apiary.Harnesses.Builtin do
  # The one harness built into Qory Apiary: qory's hello example at one commit, workflow
  # `hello`. Only the explore run of a test work item gets it
  # (`Apiary.Harnesses.WalkJob.queue/2`), in place of the workspace's levels; a test work
  # item has no target, so no harness file applies. The work item's `test` flag alone
  # decides it: no field of a stored document, a work item or a run's inputs can mark a
  # source as built-in, and a source equal to this one in any other document is walked as
  # any other (`Apiary.Harnesses.Walk`).
  #
  # Its walk resolves when the run is queued and makes no call: the source is not resolved
  # at the adapters, no assignment covers it, and the run gets no link or token for it. Its
  # `ref` is a full commit id and its pin, so its host is in the run's `stack_hosts` alone,
  # and qory fetches it with no credential, as for any pinned source with no link
  # (`Apiary.Policy.ComposedConfiguration`). The base is not read, so it declares no access
  # level: the run reads, and the row's check (`run_harnesses_builtin_check`) keeps it so.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  @git "https://github.com/qoryai/qory"
  @ref "2148b3ae11eff8ccbeb93d1a7c10aeb05595c95b"
  @path "examples/hello"
  @workflow "hello"

  @doc false
  # workflow/0 is the workflow the built-in harness starts: qory starts the command
  # `hello` of the example's `hello` module.
  @spec workflow() :: String.t()
  def workflow, do: @workflow

  @doc false
  # document/0 is the built-in harness section, as a run's documents carry it.
  @spec document() :: map
  def document, do: %{"extends" => %{"git" => @git, "ref" => @ref, "path" => @path}}

  @doc false
  # walked/0 is the resolved walk of a test work item's run, as its row stores it
  # (`Apiary.Harnesses.RunHarness`): the document, its one pin, no link, read.
  @spec walked() :: keyword
  def walked do
    [
      state: :resolved,
      origin: :builtin,
      workflow: @workflow,
      access_level: :read,
      target_version: nil,
      document: document(),
      stack_id: nil,
      owner_organisation_id: nil,
      harness_hidden: false,
      pins: [%{"git" => @git, "ref" => @ref, "at" => @ref}],
      harness_links: []
    ]
  end
end
