defmodule Apiary.Lingo.Domain do
  @moduledoc """
  What makes the engine one kind of work. The engine speaks of a **target** in a
  **system**; a domain names them for one kind of work and says which of a run's labels
  identify the target (its labelling rule). The software domain
  (`Apiary.Lingo.Domain.Software`) calls a target a repository and its system a forge.

  A workspace has its domain, stored by name in `workspaces.domain` and chosen when it is
  created; every member of the workspace reads the same words. `domains/0` is the registry
  of the domains there are, by name; `for_workspace/1` reads a workspace's through it.
  There is one: the software domain, the default, which a render outside any workspace
  reads. Nothing changes a workspace's domain. Code that reads a run's labels for its
  target asks here and never names a label itself.

  A domain also sets the rules of a work item's target: whether a work item needs one
  (`c:target_required?/0`), what a target's path may be (`c:check_target/1`), the run
  variables a run of the target gets (`c:run_variables/2`), whether its collections'
  environments are prebuilt (`c:prebuilds?/0`), and whether a target may have a harness
  file (`c:harness_file?/0`). Code that applies one of these rules asks here, through the
  workspace (`check_target/2`, `run_variables/3`, `prebuilds?/1`, `harness_file?/1`).
  A domain also sets the type settings of each session of a stage's run
  (`c:type_settings/1`, `type_settings/2`), and lists every value they can have
  (`c:type_settings_values/0`).

  A domain is a workspace type, with a definition (`c:definition/0`,
  `Apiary.Lingo.Domain.Definition`). A workspace stores the key of its type's definition
  in `workspaces.type`, set when it is created, beside its domain.
  """

  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Organisations.Workspace

  # Every domain there is, by the name a workspace stores. A new domain is a module here
  # and a catalogue per language (`docs/lingo.md`), never a migration. The tests register
  # one more of their own (`config/test.exs`), so they see a workspace's domain read
  # through the registry and not assumed.
  @domains Map.merge(
             %{"software" => Apiary.Lingo.Domain.Software},
             Application.compile_env(:apiary, [__MODULE__, :test_domains], %{})
           )
  @default Apiary.Lingo.Domain.Software

  # The tests' domains are test support, which a build that runs the core's tests from a
  # project depending on the core compiles after the core: not there to check a call
  # against yet.
  @compile {:no_warn_undefined, Map.values(@domains)}

  @typedoc "An address as a run's labels name it: its system and its path in that system."
  @type address :: %{system: String.t(), path: String.t()}

  @typedoc """
  A target: one of an adapter's collections, by the adapter and the adapter's ref of it,
  and its address, `system` and `path`, both nil for a place with no address.
  """
  @type target :: %{
          adapter_id: Ecto.UUID.t(),
          collection_external_ref: String.t(),
          system: String.t() | nil,
          path: String.t() | nil
        }

  @typedoc "Run variables: each variable's name, with its value."
  @type variables :: %{required(String.t()) => String.t()}

  @typedoc """
  A session of a stage's run, as `c:type_settings/1` reads it: `level`, the run's access
  level; `entry`, the stage's entry of the session, a workflow entry or a loop; and
  `loop_entry`, the index of the session's entry in its loop's body, nil outside a loop.
  """
  @type session_facts :: %{
          level: :read | :write_no_push | :write,
          entry: map,
          loop_entry: non_neg_integer | nil
        }

  @doc """
  The address of the target a run's labels name, by the domain's labelling rule:
  `{:ok, %{system:, path:}}`, or `:none` when the labels name none, or name one that
  cannot be a target's (`Apiary.Runs.Target.label/1`). `labels` is untrusted: any map, of
  any values.
  """
  @callback target(labels :: map) :: {:ok, address} | :none

  @doc """
  The labels that name a target by the domain's labelling rule, the system's first and
  then the path's: what a page shows first among a run's labels, and links to the target.
  """
  @callback target_labels() :: [String.t()]

  @doc """
  The label, the plural of the path's, that Qory may add beside `target_labels/0` to a
  run: its value is the run's path first, then the other paths in its system that the run
  also reads, joined with commas. It names no target. A domain without it gives a run no
  such label.
  """
  # Qory adds it to a run a claim registers, with the `factory` feature: the other paths
  # are those its target's runs also read (`Apiary.Targets.further_repositories/1`).
  @callback paths_label() :: String.t()

  @optional_callbacks paths_label: 0

  @doc """
  The domain's name: what a workspace of the domain stores, and the GNU `@modifier` of its
  locales (`software` of `en@software`).
  """
  @callback name() :: String.t()

  @doc """
  The domain's label: "Software workspace". No core page shows it: the workspace's
  settings show the type's name (`c:type_name/0`), as its kind card does. Translated in
  the locale of the caller's process.
  """
  @callback label() :: String.t()

  @doc """
  One line under `c:label/0` that says what work a workspace of the domain is for and what
  Qory reads there. Translated in the locale of the caller's process.
  """
  @callback description() :: String.t()

  @doc """
  The domain's name as a type of workspace: the title of its kind card, on the empty
  organisation overview `/:org` and on `/:org/workspaces/new`, the name a workspace
  created from that card gets, and of its line where a person picks a new workspace's
  type from a list (`ApiaryWeb.WorkspaceComponents.type_field/1`), and the type the
  workspace's settings and its Name step show: "Software factory".
  Translated in the locale of the caller's process.
  """
  @callback type_name() :: String.t()

  @doc """
  The line beside `c:type_name/0` in that list: what work a workspace of the domain is
  for. Translated in the locale of the caller's process.
  """
  @callback type_line() :: String.t()

  @doc """
  Whether a work item of the domain needs a target: true where Take in refuses a ticket
  that has no target, neither the ticket's nor its collection's.
  """
  @callback target_required?() :: boolean

  @doc """
  Whether a target, its address or its lack of one, keeps the domain's rules: `:ok`, or
  `{:error, :target_invalid}`. Take in asks it of a ticket's target before a work item
  is made of it.
  """
  @callback check_target(target) :: :ok | {:error, :target_invalid}

  @doc """
  The run variables of a run whose target has the address `address`, with `picked` the
  further paths in its system that the run also reads, in order: `{:ok, variables}`,
  `{:ok, nil}` for a domain that gives a run none, or `{:error, reason}` for an address
  or a list that breaks the domain's rules. A claim asks it again of the target of the
  run it registers. A run whose target has no address gets none
  (`run_variables/3`).
  """
  @callback run_variables(address, picked :: [String.t()]) ::
              {:ok, variables | nil} | {:error, atom}

  @doc """
  Whether the environment of a collection of the domain is prebuilt: a prebuild is
  queued only for a collection assigned to a workspace whose domain has prebuilds.
  """
  @callback prebuilds?() :: boolean

  @doc """
  Whether a target of the domain may have a harness file, a `qory.yaml` or `harness.yaml`
  of qory's format at its root. False means that a target of the domain has no harness
  file, so a run of the domain takes its harness document from the workspace's settings
  alone.
  """
  @callback harness_file?() :: boolean

  @doc """
  Whether a run of the domain that writes pushes its changes when it ends, as a
  repository's run does: the line of a cancel of such a run lists what it pushed.
  """
  @callback pushes?() :: boolean

  @doc """
  The word for a target in the English texts that a stage stores about why a run stopped:
  "repository" in the software domain.
  """
  @callback target_noun() :: String.t()

  @doc """
  The word for the copy of the target that a run writes to, in the English texts that a
  stage stores about why a run stopped: "checkout" in the software domain.
  """
  @callback copy_noun() :: String.t()

  @doc """
  The definition of the workspace type the domain is (`Apiary.Lingo.Domain.Definition`):
  its key, which a workspace of the domain stores in `workspaces.type`, who provides it,
  and the harness a workspace of the type starts with.
  """
  @callback definition() :: Definition.t()

  @doc """
  The type settings of a session of a stage's run (`t:session_facts/0`): the
  `type_settings` of the run documents and of the next-session answer, or nil for a
  domain whose runs have none, so `type_settings` is absent from the documents and the
  answer.
  """
  @callback type_settings(session_facts) :: %{String.t() => term} | nil

  @doc """
  Every value `c:type_settings/1` can return but nil: what a save of a process checks
  against the schema of type settings that the process registers. Empty for a domain
  whose runs have none.
  """
  @callback type_settings_values() :: [%{String.t() => term}]

  @doc "The domains there are, by name."
  @spec domains() :: %{String.t() => module}
  def domains, do: @domains

  @doc "The names of the domains there are, sorted: what a workspace's domain may be."
  @spec names() :: [String.t()]
  def names, do: @domains |> Map.keys() |> Enum.sort()

  @doc """
  The default domain, `Apiary.Lingo.Domain.Software`: a new workspace's, and the one read
  outside any workspace.
  """
  @spec default() :: module
  def default, do: @default

  @doc """
  The domains a person picks a new workspace's type from, in the order a form offers them:
  the default first, then the others by name.
  """
  @spec choices() :: [module]
  def choices,
    do: [@default | for(name <- names(), (domain = @domains[name]) != @default, do: domain)]

  @doc """
  The domain of a workspace, through `domains/0`, by the name its struct carries: the
  caller loads the workspace, and nothing here reads the database. Without a workspace,
  or for one whose stored name no domain has any more, it is `default/0`.
  """
  @spec for_workspace(%Workspace{} | nil) :: module
  def for_workspace(%Workspace{domain: name}), do: Map.get(@domains, name, @default)
  def for_workspace(nil), do: @default

  @doc """
  The name of a workspace's domain: `c:name/0` of the domain `for_workspace/1` reads, so a
  stored name no domain has any more reads as the default's.
  """
  @spec name(%Workspace{} | nil) :: String.t()
  def name(workspace), do: for_workspace(workspace).name()

  @doc """
  The definition of the workspace type `domain` is, one of the modules of `domains/0`:
  its `c:definition/0`.
  """
  @spec definition(module) :: Definition.t()
  def definition(domain) when is_atom(domain), do: domain.definition()

  @doc """
  Whether `key` is the key of a workspace type (`c:definition/0`) of a domain of
  `domains/0`, such as `qory.software`.
  """
  @spec known_type?(String.t()) :: boolean
  def known_type?(key),
    do: Enum.any?(@domains, fn {_name, domain} -> definition(domain).key == key end)

  @doc """
  The domain of `domains/0` whose workspace type (`c:definition/0`) has the key `key`, such
  as `qory.software`; nil for a key no domain has.
  """
  @spec for_type(String.t()) :: module | nil
  def for_type(key), do: Enum.find(choices(), &(definition(&1).key == key))

  @doc """
  The address of the target a run's labels name in the workspace: `target/1` of the
  workspace's domain.
  """
  @spec target(%Workspace{} | nil, term) :: {:ok, address} | :none
  def target(workspace, %{} = labels), do: for_workspace(workspace).target(labels)
  def target(_workspace, _labels), do: :none

  @doc "The labels that name a target in the workspace: `target_labels/0` of its domain."
  @spec target_labels(%Workspace{} | nil) :: [String.t()]
  def target_labels(workspace), do: for_workspace(workspace).target_labels()

  @doc """
  The label of a run's paths in the workspace: `paths_label/0` of its domain, or nil for a
  domain without one.
  """
  @spec paths_label(%Workspace{} | nil) :: String.t() | nil
  def paths_label(workspace) do
    domain = for_workspace(workspace)

    if Code.ensure_loaded?(domain) and function_exported?(domain, :paths_label, 0),
      do: domain.paths_label()
  end

  @doc "Whether a work item of the workspace needs a target: `c:target_required?/0` of its domain."
  @spec target_required?(%Workspace{} | nil) :: boolean
  def target_required?(workspace), do: for_workspace(workspace).target_required?()

  @doc """
  Whether a work item of the workspace may have `target`, a target or nil for none:
  `:ok`; `{:error, :no_target}` for none where the workspace's domain needs one
  (`c:target_required?/0`); or `{:error, :target_invalid}` for a target that breaks its
  domain's rules (`c:check_target/1`), with or without an address.
  """
  @spec check_target(%Workspace{} | nil, target | nil) ::
          :ok | {:error, :no_target | :target_invalid}
  def check_target(workspace, nil), do: check_no_target(for_workspace(workspace))

  def check_target(workspace, %{collection_external_ref: ref} = target) when is_binary(ref),
    do: for_workspace(workspace).check_target(target)

  # The `else` branch runs for a domain that needs no target, such as the tests' example
  # domain. The helper takes any domain module: through `for_workspace/1`, with Software
  # the only domain outside the tests, the compile warns that the `else` branch never runs.
  defp check_no_target(domain),
    do: if(domain.target_required?(), do: {:error, :no_target}, else: :ok)

  @doc """
  The run variables of a run of the workspace whose target is `target`, nil for none, with
  `picked` the further paths it also reads: `{:ok, nil}` without a target or for a target
  without an address, so such a run gets no `QORY_RUN_SYSTEM`; else `c:run_variables/2`
  of the workspace's domain, of the target's address.
  """
  @spec run_variables(%Workspace{} | nil, target | nil, [String.t()]) ::
          {:ok, variables | nil} | {:error, atom}
  def run_variables(_workspace, nil, _picked), do: {:ok, nil}
  def run_variables(_workspace, %{system: nil, path: nil}, _picked), do: {:ok, nil}

  def run_variables(workspace, %{system: system, path: path}, picked) when is_list(picked),
    do: for_workspace(workspace).run_variables(%{system: system, path: path}, picked)

  @doc "Whether the workspace's collections are prebuilt: `c:prebuilds?/0` of its domain."
  @spec prebuilds?(%Workspace{} | nil) :: boolean
  def prebuilds?(workspace), do: for_workspace(workspace).prebuilds?()

  @doc "Whether the workspace's targets may have a harness file: `c:harness_file?/0` of its domain."
  @spec harness_file?(%Workspace{} | nil) :: boolean
  def harness_file?(workspace), do: for_workspace(workspace).harness_file?()

  @doc "Whether a run of the workspace that writes pushes: `c:pushes?/0` of its domain."
  @spec pushes?(%Workspace{} | nil) :: boolean
  def pushes?(workspace), do: for_workspace(workspace).pushes?()

  @doc "The word for a target in the workspace: `c:target_noun/0` of its domain."
  @spec target_noun(%Workspace{} | nil) :: String.t()
  def target_noun(workspace), do: for_workspace(workspace).target_noun()

  @doc "The word for a target's copy in the workspace: `c:copy_noun/0` of its domain."
  @spec copy_noun(%Workspace{} | nil) :: String.t()
  def copy_noun(workspace), do: for_workspace(workspace).copy_noun()

  @doc """
  The type settings of a session of a stage's run in the workspace: `c:type_settings/1`
  of its domain, nil for a domain whose runs have none.
  """
  @spec type_settings(%Workspace{} | nil, session_facts) :: %{String.t() => term} | nil
  def type_settings(workspace, %{level: _, entry: _, loop_entry: _} = facts),
    do: for_workspace(workspace).type_settings(facts)

  @doc """
  Every type settings value a run of `domain`, one of the modules of `domains/0`, can
  have: its `c:type_settings_values/0`.
  """
  @spec type_settings_values(module) :: [%{String.t() => term}]
  def type_settings_values(domain) when is_atom(domain), do: domain.type_settings_values()

  @doc """
  Whether an adapter that lists `domains` in its description, nil for none, serves the
  workspace: one that lists none serves every domain, and one that lists some serves a
  workspace whose domain is among them. A person who assigns a collection to a workspace
  picks only among the adapters that serve it.
  """
  @spec serves?([String.t()] | nil, %Workspace{} | nil) :: boolean
  def serves?(nil, _workspace), do: true

  def serves?(domains, workspace) when is_list(domains),
    do: for_workspace(workspace).name() in domains

  @doc """
  Whether `system` is a host name, as a target's system is in every domain: 1 to 253 of
  a-z, 0-9, dot and dash, with no empty label: no dot first or last, and no two dots
  together. The database holds every work item's target to the same.
  """
  @spec host?(term) :: boolean
  def host?(system) when is_binary(system),
    do:
      Regex.match?(~r/\A[a-z0-9.-]{1,253}\z/, system) and not String.starts_with?(system, ".") and
        not String.ends_with?(system, ".") and not String.contains?(system, "..")

  def host?(_system), do: false
end
