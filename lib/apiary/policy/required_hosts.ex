defmodule Apiary.Policy.RequiredHosts do
  @moduledoc false

  # The hosts Qory Apiary allows for every run of a workspace, for the policy page's
  # "Allowed for every run" list (read only). Each group is read by the workspace-level
  # function that sits beside the function that builds the same hosts for a run, so the
  # list and a run's document come from the same code:
  #
  #   * harness sources: `ComposedConfiguration.workspace_stack_hosts/1`, beside
  #     `ComposedConfiguration.stack_hosts/1`;
  #   * runtimes: `Apiary.Kinds.Runtimes.egress_hosts/0`, which the policy of every
  #     workspace renders;
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
  # `required_by` is `:instance` for the Qory harness, the runtimes' and the registry's
  # hosts, and for the rest the level that chose it: `:organisation` for an integration
  # added for every workspace of the organisation, else `:workspace`.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Connections
  alias Apiary.Connections.Connection
  alias Apiary.Lingo.Domain
  alias Apiary.Harnesses.Qory
  alias Apiary.Kinds.Runtimes
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.{ComposedConfiguration, Grammar}
  alias Apiary.Registry.RunAccess
  alias Apiary.Repo
  alias Apiary.Runs.{ProviderCredential, RunCredentials}
  alias Apiary.Stacks.Document

  @typedoc "Where a row's host comes from."
  @type source ::
          :qory
          | {:repository, String.t()}
          | {:runtime, String.t()}
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

  @type group :: %{
          key: :harness | :runtimes | :integrations | :providers | :registry | :forge,
          rows: [row]
        }

  @doc false
  # first_hosts/1 is the hosts of the groups whose hosts a run's document has in
  # `egress.allow_first` on every path a rule does not limit: the runtimes', the
  # integrations' and the model providers'. The other groups stay out: only the stack
  # proxy reads the harness sources' hosts, the registry's hosts are held to paths, and a
  # target's system is added only for a run with a work credential.
  @spec first_hosts(Workspace.t()) :: %{
          runtimes: [String.t()],
          integrations: [String.t()],
          providers: [String.t()]
        }
  def first_hosts(%Workspace{} = workspace) do
    %{
      runtimes: Enum.map(Runtimes.egress_hosts(), & &1.host),
      integrations: Enum.map(Connections.egress_hosts(workspace), & &1.host),
      providers: Enum.map(ProviderCredential.workspace_hosts(workspace), & &1.host)
    }
  end

  @doc false
  # covers?/4 is whether enforce lets a request to `host` and `path` through whatever the
  # rules say, given `first_hosts/1` and the `paths` of the effective policy, which the
  # pages read without these hosts:
  #
  #   * a runtime's host is on every path (`Apiary.Policy.Resolution`, point 8);
  #   * an integration's host is held only to a rule's paths on the host itself: a `*.` key
  #     leaves it on every path (point 7);
  #   * a provider's host is held as any allowed host is: a composed document adds no `/*`.
  @spec covers?(map, %{optional(String.t()) => [String.t()]}, String.t(), String.t() | nil) ::
          boolean
  def covers?(%{} = first, paths, host, path) do
    cond do
      host in first.runtimes -> true
      host in first.integrations -> on_paths?(Map.get(paths, host), path)
      host in first.providers -> on_paths?(held(paths, host), path)
      true -> false
    end
  end

  @doc false
  # held/2 is the paths that hold `host`, from the `paths` of an effective policy: its name
  # as a key, else a `*.` key that covers it, else nil.
  def held(paths, host) do
    case paths do
      %{^host => list} ->
        list

      _ ->
        Enum.find_value(paths, fn {key, list} -> if Grammar.matches?([key], host), do: list end)
    end
  end

  defp on_paths?(nil, _path), do: true
  defp on_paths?(_paths, path) when path in [nil, ""], do: true
  defp on_paths?(paths, path), do: Enum.any?(paths, &Grammar.path_matches?(&1, path))

  @doc false
  # of/1 is the groups that have a row, in the page's order, and `target_required?`, whether
  # the workspace's domain refuses a work item with no target (`c:Apiary.Lingo.Domain.target_required?/0`),
  # which chooses the line under the list.
  @spec of(Workspace.t()) :: %{groups: [group], target_required?: boolean}
  def of(%Workspace{} = workspace) do
    groups =
      [
        harness(workspace),
        runtimes(),
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
        qory? = git == Qory.git()

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
  def runtimes do
    rows =
      for %{host: host, runtime: runtime} <- Runtimes.egress_hosts(),
          do: %{host: host, source: {:runtime, runtime.title}, required_by: :instance}

    %{key: :runtimes, rows: rows}
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
