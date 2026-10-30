defmodule Apiary.Policy.RequiredHosts do
  @moduledoc false

  # The hosts Qory Apiary allows for every run of a workspace, for the policy page's
  # "Allowed for every run" list (read only). Each group is read by the workspace-level
  # function that sits beside the function that builds the same hosts for a run, so the
  # list and a run's document come from the same code:
  #
  #   * harness sources: `ComposedConfiguration.workspace_stack_hosts/1`, beside
  #     `ComposedConfiguration.stack_hosts/1`;
  #   * integrations: `Apiary.Connections.egress_hosts/1`, which the policy of every
  #     workspace renders;
  #   * model providers: `Apiary.Runs.ProviderCredential.workspace_hosts/1`, beside
  #     `for_run/1`;
  #   * registry and Qory Apiary: `Apiary.Registry.RunAccess.workspace_hosts/0`, beside
  #     `member/1`;
  #   * the system of the target: `Apiary.Runs.RunCredentials.workspace_hosts/1`, beside
  #     `work/1`.
  #
  # What the run's target, work item or claim add (the harness sources that the pins of its
  # walk name, the provider and API it is given, the one collection it takes) is not here.
  #
  # `required_by` is `:instance` for the Qory harness and the registry's hosts, and for
  # the rest the level that chose it: `:organisation` for an integration added for every
  # workspace of the organisation, else `:workspace`.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Registry.RunAccess
  alias Apiary.Repo
  alias Apiary.Runs.{ProviderCredential, RunCredentials}
  alias Apiary.Stacks.Document

  @typedoc "Where a row's host comes from."
  @type source ::
          :qory
          | {:repository, String.t()}
          | {:integration, String.t()}
          | {:provider, String.t()}
          | :instance
          | :registry
          | {:adapter, String.t()}

  @type row :: %{
          host: String.t(),
          source: source,
          required_by: :instance | :workspace | :organisation
        }

  @type group :: %{key: :harness | :integrations | :providers | :registry | :forge, rows: [row]}

  @doc false
  # of/1 is the groups that have a row, in the page's order, and `target_required?`, whether
  # the workspace's domain refuses a work item with no target (`c:Apiary.Lingo.Domain.target_required?/0`),
  # which chooses the line under the list.
  @spec of(Workspace.t()) :: %{groups: [group], target_required?: boolean}
  def of(%Workspace{} = workspace) do
    groups =
      [
        harness(workspace),
        integrations(workspace),
        providers(workspace),
        registry(),
        forge(workspace)
      ]
      |> Enum.reject(&(&1.rows == []))

    %{groups: groups, target_required?: Domain.for_workspace(workspace).target_required?()}
  end

  @doc false
  def harness(workspace) do
    rows =
      for %{host: host, git: git, shared: shared} <-
            ComposedConfiguration.workspace_stack_hosts(workspace) do
        qory? = git == Definition.qory_harness().git

        %{
          host: host,
          source: if(qory?, do: :qory, else: {:repository, Document.repository(git)}),
          required_by:
            cond do
              shared -> :organisation
              qory? -> :instance
              true -> :workspace
            end
        }
      end

    %{key: :harness, rows: rows}
  end

  @doc false
  def integrations(workspace) do
    hosts = Connections.egress_hosts(workspace)
    ids = hosts |> Enum.map(& &1.connection.id) |> Enum.uniq()

    applies_to =
      Map.new(Repo.all(from c in Connection, where: c.id in ^ids, select: {c.id, c.applies_to}))

    rows =
      for %{host: host, connection: connection} <- hosts do
        %{
          host: host,
          source: {:integration, connection.name},
          required_by: if(applies_to[connection.id] == "all", do: :organisation, else: :workspace)
        }
      end

    %{key: :integrations, rows: rows}
  end

  @doc false
  def providers(workspace) do
    rows =
      for %{host: host, connection: connection} <- ProviderCredential.workspace_hosts(workspace),
          do: %{host: host, source: {:provider, connection.name}, required_by: :workspace}

    %{key: :providers, rows: rows}
  end

  @doc false
  def registry do
    rows =
      for %{host: host, kind: kind} <- RunAccess.workspace_hosts(),
          do: %{host: host, source: kind, required_by: :instance}

    %{key: :registry, rows: rows}
  end

  @doc false
  def forge(workspace) do
    rows =
      for %{host: host, adapter: adapter} <- RunCredentials.workspace_hosts(workspace),
          do: %{host: host, source: {:adapter, adapter}, required_by: :workspace}

    %{key: :forge, rows: rows}
  end
end
