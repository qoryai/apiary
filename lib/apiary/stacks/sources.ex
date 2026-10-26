defmodule Apiary.Stacks.Sources do
  # The harness sources Workspace settings › Workflow offers a workspace
  # (`ApiaryWeb.WorkflowLive`), the stacks each has, the workflows each stack lists, and
  # the save of the workspace's document. Every read goes through the adapters' calls
  # (`Apiary.Adapters.Calls`: `resolve` and `read`), as a run's walk reads
  # (`Apiary.Harnesses.Walk`), and writes nothing.
  #
  # ## The sources
  #
  #   * Linked (`linked/1`): each live collection of a connected connection of the
  #     organisation whose address passes the save rules of a
  #     document's source (`Apiary.Stacks.Document.source_error/2`) and that has a stack.
  #     Its adapter resolves the address under a live grant of the organisation, then the
  #     collection's root harness file is read at `HEAD`, as the walk reads a target's: it
  #     has a stack for each stack its `exports` lists, or, with no `exports`, where its
  #     root has a `qory-stack.yaml`. A document extends it at `ref: HEAD`, so each run
  #     reads the commit the head is at when its walk runs. A collection whose reads fail is
  #     left out and counted.
  #   * Assigned (`assigned/1`): each instance assignment of the organisation, or of every
  #     organisation (`Apiary.Harnesses.Assignment`), but an assignment of a module. A
  #     document extends it at the assignment's `ref`, the only one the assignment covers.
  #   * An address (`address/1`) a person types: a harness source's address with no user
  #     name or password, checked as a document's source address is, at `HEAD`.
  #
  # ## Reading a source's stacks
  #
  # `read/2` reads the stacks of one source and the workflows each lists, the names of its
  # `qory-stack.yaml`'s `workflows`. An assigned source or an address is resolved at every
  # adapter with a `call_url`, in the order of their names, and the first result under a
  # live grant of a connected connection that the rule allows
  # (`Apiary.Harnesses.allowed?/3`) is its link. None is `:not_covered`: Qory Apiary reads
  # a harness source only through a link, and a run's walk could not read it either. A
  # source with `stack` is that export of its root harness file, one with `path` the
  # `qory-stack.yaml` in that folder, and a root the stacks its harness file exports or
  # its `qory-stack.yaml`, as for a linked collection.
  #
  # ## The save
  #
  # `save/3` is `harness.save` (owners and admins): the workspace-level document that
  # extends the chosen stack, `Apiary.Stacks.put_stack/3` at the workspace with the
  # workflow, under `Apiary.Stacks.Document`'s save rules. In the same transaction it
  # removes the workspace's rows of other workflows with no target, since a run takes the
  # workflow of the one row with a workflow at its places (`Apiary.Stacks.workflow/2`).
  # It writes no audit entry, as `put_stack/3` writes none.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Access, Harnesses, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Calls, CallWire, Collection, Connection, Grant, Grants}
  alias Apiary.Harnesses.{Assignment, Reader}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Stacks.{Document, Stack}

  @head "HEAD"
  @stack_file "qory-stack.yaml"
  # How many linked collections are read at once, and how long the reads of one may take.
  @concurrency 4
  @collection_time 30_000

  @typedoc """
  A source the page offers: its id on the page, its kind, its label, its `git` and `ref`,
  the key that narrows it to a stack (`path` or `stack`, or none for a root), and, for a
  linked collection, its link, its version and its stacks, read already.
  """
  @type source :: %{
          id: String.t(),
          kind: :linked | :assigned | :address,
          label: String.t(),
          git: String.t(),
          ref: String.t(),
          narrowing: %{optional(String.t()) => String.t()},
          location: map | nil,
          version: String.t() | nil,
          stacks: [map] | nil
        }

  @typedoc "A stack of a source: its export name, nil for none, the base a document extends, and its workflows."
  @type stack :: %{name: String.t() | nil, base: map, workflows: [String.t()]}

  @typedoc "Why a source's stacks were not read."
  @type reason :: :not_covered | :no_stack | :unreadable

  ## The sources

  @doc false
  # linked/1 is the organisation's linked collections that have a stack, by title, and
  # how many could not be read: `{sources, unread}` (the moduledoc). It calls the
  # adapters, so a page runs it outside its process.
  @spec linked(Scope.t()) :: {[source], non_neg_integer}
  def linked(%Scope{organisation: %Organisation{} = organisation}) do
    {located, unresolved} =
      organisation
      |> collections()
      |> Enum.group_by(fn {_collection, adapter} -> adapter.id end)
      |> Enum.reduce({[], 0}, fn {_id, [{_collection, adapter} | _] = pairs}, {located, failed} ->
        {here, failed_here} =
          locate_collections(organisation, adapter, Enum.map(pairs, &elem(&1, 0)))

        {located ++ here, failed + failed_here}
      end)

    results =
      located
      |> Task.async_stream(
        fn {collection, location} -> {collection, location, stacks_at(location, @head)} end,
        max_concurrency: @concurrency,
        timeout: @collection_time,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    sources =
      for {:ok, {collection, location, {:ok, version, [_ | _] = stacks}}} <- results do
        %{
          id: "linked:" <> collection.public_id,
          kind: :linked,
          label: collection.title || Document.shown(collection.url),
          git: collection.url,
          ref: @head,
          narrowing: %{},
          location: location,
          version: version,
          stacks: stacks
        }
      end

    unread = Enum.count(results, &(not match?({:ok, {_c, _l, {:ok, _v, _s}}}, &1)))
    {Enum.sort_by(sources, &String.downcase(&1.label)), unresolved + unread}
  end

  # The organisation's live collections of a connected connection, whose adapter has a
  # call address, with an address a document's source may have. Their adapter's resolve
  # names the grant each is under.
  defp collections(%Organisation{id: organisation_id}) do
    Repo.all(
      from c in Collection,
        join: n in Connection,
        on: n.id == c.connection_id,
        join: a in Node,
        on: a.id == c.adapter_id,
        where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
        where: n.state == :connected,
        where: is_nil(a.deleted_at) and not is_nil(a.call_url),
        order_by: [asc: c.title, asc: c.id],
        select: {c, a}
    )
    |> Enum.filter(fn {collection, _adapter} -> address_error(collection.url) == nil end)
  end

  # Each collection with its link at `adapter`, under a live grant of the organisation,
  # and how many collections a resolve that failed left out; one the adapter does not
  # cover is left out uncounted.
  defp locate_collections(organisation, adapter, collections) do
    {covered, failed} =
      collections
      |> Enum.map(& &1.url)
      |> Enum.uniq()
      |> Enum.chunk_every(64)
      |> Enum.reduce({%{}, MapSet.new()}, fn chunk, {covered, failed} ->
        case Calls.resolve(adapter, chunk) do
          {:ok, results} ->
            {Map.merge(covered, covered_here(organisation, adapter, results)), failed}

          {:error, _failure} ->
            {covered, MapSet.union(failed, MapSet.new(chunk))}
        end
      end)

    located =
      for collection <- collections,
          location <- [covered[collection.url]],
          location,
          do: {collection, location}

    {located, Enum.count(collections, &MapSet.member?(failed, &1.url))}
  end

  defp covered_here(organisation, adapter, results) do
    for %{address: address, grant_ref: grant_ref, resource_ref: resource_ref} <- results,
        Grants.live_for_organisation(adapter.id, grant_ref, organisation.id),
        into: %{},
        do: {address, location(adapter, grant_ref, resource_ref)}
  end

  @doc false
  # assigned/1 is the instance's assignments of the organisation and of every
  # organisation, each a source, but an assignment of a module, oldest first.
  @spec assigned(Scope.t()) :: [source]
  def assigned(%Scope{organisation: %Organisation{id: organisation_id}}) do
    Repo.all(
      from a in Assignment,
        where: a.every_organisation or a.organisation_id == ^organisation_id,
        order_by: [asc: a.inserted_at, asc: a.id]
    )
    |> Enum.reject(&Map.has_key?(&1.source, "module"))
    |> Enum.map(fn %Assignment{id: id, source: source} ->
      narrowing = Map.take(source, ["path", "stack"])

      %{
        id: "assigned:" <> id,
        kind: :assigned,
        label: label(source["git"], source["ref"], narrowing),
        git: source["git"],
        ref: source["ref"],
        narrowing: narrowing,
        location: nil,
        version: nil,
        stacks: nil
      }
    end)
  end

  # An assignment's label: its address as an error shows one, its ref, and the stack or
  # the folder it narrows to.
  defp label(git, ref, narrowing) do
    narrowed =
      case narrowing do
        %{"stack" => name} -> " " <> name
        %{"path" => path} -> " " <> path
        _root -> ""
      end

    Document.shown(git) <> " @ " <> ref <> narrowed
  end

  @doc false
  # address/1 is the source at the address `text`, trimmed: `{:ok, source}`, or
  # `{:error, {message, values}}` for an address with a user name or password, or one a
  # document's source may not have, in the save rules' words.
  @spec address(String.t()) :: {:ok, source} | {:error, Document.error()}
  def address(text) when is_binary(text) do
    git = String.trim(text)

    case address_error(git) do
      nil ->
        {:ok,
         %{
           id: "address",
           kind: :address,
           label: Document.shown(git),
           git: git,
           ref: @head,
           narrowing: %{},
           location: nil,
           version: nil,
           stacks: nil
         }}

      error ->
        {:error, error}
    end
  end

  # The save rules' refusal of `git` as a base's address at `HEAD`, nil for none.
  defp address_error(git) do
    cond do
      not is_binary(git) or git == "" ->
        {"can't be blank", []}

      Document.user_information?(git) ->
        {"remove the user name and password from %{source}: " <>
           "a harness source address may not contain a credential", source: Document.shown(git)}

      error = Document.source_error(%{"git" => git, "ref" => @head}, :base) ->
        error

      not CallWire.address?(git) ->
        {"write %{source} as https://, a host, an optional port and an optional path: " <>
           "Qory Apiary fetches harness sources over https only", source: Document.shown(git)}

      true ->
        nil
    end
  end

  ## Reading

  @doc false
  # read/2 is the stacks of `source` and the workflows each lists (the moduledoc), in the
  # order of their names: `{:ok, stacks}`, or `{:error, reason}`. It calls the adapters,
  # so a page runs it outside its process.
  @spec read(Scope.t(), source) :: {:ok, [stack]} | {:error, reason}
  def read(%Scope{organisation: %Organisation{} = organisation}, %{} = source) do
    with {:ok, location, version, stacks} <- stacks_of(organisation, source) do
      stacks
      |> Enum.reduce_while([], fn stack, read ->
        case workflows(location, stack.file, version) do
          {:ok, workflows} ->
            {:cont, [%{name: stack.name, base: base(source, stack), workflows: workflows} | read]}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} -> {:error, reason}
        [] -> {:error, :no_stack}
        read -> {:ok, Enum.sort_by(read, &(&1.name || ""))}
      end
    end
  end

  # The base a document extends for `stack` of `source`.
  defp base(source, stack) do
    narrowing =
      case stack.name do
        nil -> source.narrowing
        name -> %{"stack" => name}
      end

    Map.merge(narrowing, %{"git" => source.git, "ref" => source.ref})
  end

  defp stacks_of(_organisation, %{kind: :linked} = source),
    do: {:ok, source.location, source.version, source.stacks}

  defp stacks_of(organisation, source) do
    harness_source = Map.merge(source.narrowing, %{"git" => source.git, "ref" => source.ref})

    with {:ok, location} <- locate(organisation, harness_source) do
      case source.narrowing do
        %{"stack" => name} ->
          with {:ok, version, stacks} <- stacks_at(location, source.ref) do
            case Enum.filter(stacks, &(&1.name == name)) do
              [] -> {:error, :no_stack}
              exported -> {:ok, location, version, exported}
            end
          end

        %{"path" => path} ->
          {:ok, location, source.ref, [%{name: nil, file: in_folder(path, @stack_file)}]}

        _root ->
          with {:ok, version, stacks} <- stacks_at(location, source.ref),
               do: {:ok, location, version, stacks}
      end
    end
  end

  # `file` in the folder `path`, without its empty and `.` parts.
  defp in_folder(path, file) do
    (String.split(path, "/") ++ [file])
    |> Enum.reject(&(&1 in ["", "."]))
    |> Enum.join("/")
  end

  # The link of `harness_source`: the first result of an adapter, in the order of their
  # names, under a live grant of a connected connection that the rule allows.
  defp locate(%Organisation{id: organisation_id}, %{"git" => git} = harness_source) do
    if CallWire.address?(git),
      do: locate_at(adapters(), organisation_id, git, harness_source),
      else: {:error, :unreadable}
  end

  defp adapters do
    Repo.all(
      from a in Node,
        where: a.kind == :adapter and is_nil(a.deleted_at) and not is_nil(a.call_url),
        order_by: [asc: a.name, asc: a.id]
    )
  end

  defp locate_at(adapters, organisation_id, git, harness_source) do
    Enum.reduce_while(adapters, {:error, :not_covered}, fn adapter, not_found ->
      with {:ok, [%{grant_ref: grant_ref, resource_ref: resource_ref}]} <-
             Calls.resolve(adapter, [git]),
           %Grant{} = grant <- live_grant(adapter, grant_ref),
           true <- Harnesses.allowed?(organisation_id, grant.organisation_id, harness_source) do
        {:halt, {:ok, location(adapter, grant_ref, resource_ref)}}
      else
        {:error, _failure} -> {:halt, {:error, :unreadable}}
        _not_allowed -> {:cont, not_found}
      end
    end)
  end

  # The live grant of `adapter` with `grant_ref`, of a connected connection, whatever its
  # organisation; nil for none.
  defp live_grant(adapter, grant_ref) do
    Repo.one(
      from g in Grant,
        join: c in Connection,
        on: c.id == g.connection_id,
        where: g.adapter_id == ^adapter.id and g.grant_ref == ^grant_ref,
        where: is_nil(g.ended_at) and c.state == :connected
    )
  end

  defp location(adapter, grant_ref, resource_ref),
    do: %{adapter: adapter, grant_ref: grant_ref, resource_ref: resource_ref}

  # The stacks of the root at `location`, read at `at`: `{:ok, version, stacks}`, each
  # `%{name, file}`, `[]` for none; `{:error, :unreadable}` for a read that failed, both
  # root harness files, or a harness file whose `exports` do not read.
  defp stacks_at(location, at) do
    with {:ok, harness, version} <- read_file(location, "harness.yaml", at),
         {:ok, qory, _version} <- read_file(location, "qory.yaml", version) do
      case {harness, qory} do
        {nil, nil} -> root_stack(location, version)
        {content, nil} -> exported(location, content, version)
        {nil, content} -> exported(location, content, version)
        _both -> {:error, :unreadable}
      end
    end
  end

  defp exported(location, content, version) do
    case Reader.exports(content) do
      {:ok, %{stacks: [_ | _] = names} = exports} ->
        stacks =
          for name <- names,
              file <- [Reader.stack_file(exports, name)],
              CallWire.document_path?(file),
              do: %{name: name, file: file}

        {:ok, version, stacks}

      {:ok, _no_stacks} ->
        root_stack(location, version)

      :none ->
        root_stack(location, version)

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp root_stack(location, version) do
    case read_file(location, @stack_file, version) do
      {:ok, nil, _version} -> {:ok, version, []}
      {:ok, _content, _version} -> {:ok, version, [%{name: nil, file: @stack_file}]}
      {:error, reason} -> {:error, reason}
    end
  end

  # The workflows of the stack file `file` at `location`, read at `at`, by name.
  defp workflows(location, file, at) do
    case read_file(location, file, at) do
      {:ok, nil, _version} ->
        {:error, :no_stack}

      {:ok, content, _version} ->
        case Reader.stack(content) do
          {:ok, %{workflows: workflows}} -> {:ok, workflows |> Map.keys() |> Enum.sort()}
          {:error, _reason} -> {:error, :unreadable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The document at `path` at `location`, read at `at`: `{:ok, content | nil,
  # resolved_at}`, or `{:error, :unreadable}` for a path a read does not take or a call
  # that failed.
  defp read_file(location, path, at) do
    request = %{
      grant_ref: location.grant_ref,
      resource_ref: location.resource_ref,
      path: path,
      at: at
    }

    if CallWire.document_path?(path) and CallWire.version_ref?(at) do
      case Calls.read_document(location.adapter, request) do
        {:ok, %{found: true, content: content, resolved_at: version}} -> {:ok, content, version}
        {:ok, %{found: false, resolved_at: version}} -> {:ok, nil, version}
        {:error, _failure} -> {:error, :unreadable}
      end
    else
      {:error, :unreadable}
    end
  end

  ## The workspace's document

  @doc false
  # current/1 is the workflow the workspace's runs take at the workspace level and the
  # base its document there extends: `%{workflow, base}`, `base` nil for a document with
  # no `extends`; nil where the workspace has no such row, or more than one.
  @spec current(Workspace.t()) :: %{workflow: String.t(), base: map | nil} | nil
  def current(%Workspace{id: id, organisation_id: organisation_id}) do
    Repo.all(
      from s in Stack,
        where: s.organisation_id == ^organisation_id and s.workspace_id == ^id,
        where: is_nil(s.target_id) and not is_nil(s.workflow),
        limit: 2
    )
    |> case do
      [%Stack{workflow: workflow, harness: harness}] ->
        base =
          case is_binary(harness) && Reader.document(harness) do
            {:ok, %{"extends" => %{} = base}} -> base
            _none -> nil
          end

        %{workflow: workflow, base: base}

      _none_or_several ->
        nil
    end
  end

  @doc false
  # save/3 stores the workspace-level document of the scope's workspace that extends
  # `base`, with `workflow` (`harness.save`; the moduledoc). `{:ok, stack}`; `{:error,
  # :forbidden}` or `{:error, :not_found}` from the access check, asked first; `{:error,
  # :invalid}` for no base or no workflow; or `{:error, changeset}` from the save rules.
  @spec save(Scope.t(), map | nil, String.t() | nil) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :invalid}
  def save(%Scope{workspace: %Workspace{} = workspace} = scope, base, workflow) do
    with :ok <- Access.authorize(scope, :"harness.save", workspace),
         true <- is_map(base) and is_binary(workflow) do
      Repo.transact(fn ->
        replaced =
          Repo.all(
            from s in Stack,
              where: s.organisation_id == ^workspace.organisation_id,
              where: s.workspace_id == ^workspace.id and is_nil(s.target_id),
              where: not is_nil(s.workflow) and s.workflow != ^workflow,
              select: s.workflow
          )

        for other <- replaced,
            do: {:ok, _stack} = Stacks.delete_stack({:workspace, workspace, other})

        Stacks.put_stack(scope, {:workspace, workspace, workflow}, document(base))
      end)
    else
      false -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  # The document that extends `base`, its values as YAML's double-quoted texts, which
  # JSON's are.
  defp document(base) do
    lines =
      for key <- ~w(git ref path stack),
          value <- [base[key]],
          is_binary(value),
          do: "  #{key}: #{Jason.encode!(value)}\n"

    IO.iodata_to_binary(["extends:\n" | lines])
  end
end
