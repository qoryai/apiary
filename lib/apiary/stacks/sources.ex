defmodule Apiary.Stacks.Sources do
  # The harness sources Workspace settings › Workflow offers a workspace
  # (`ApiaryWeb.WorkflowLive`), the stacks each has, the workflows each stack lists, and
  # the save of the workspace's document. Every read goes through the adapters' calls
  # (`Apiary.Adapters.Calls`: `resolve`, `read` and `read-public`), as a run's walk reads
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
  # adapter with a `call_url`, in the order of their names, as a run's walk resolves it:
  # the first result under a live grant of a connected connection that the rule allows
  # (`Apiary.Harnesses.allowed?/3`) is its link; with none, the first result with
  # `public`, true, makes it public, read at that result's `public_ref` (`read-public`),
  # with no grant and no link. Neither is `:not_covered`, and a run's walk could not read
  # it either. A source with `stack` is that export of its root harness file, one with
  # `path` the `qory-stack.yaml` in that folder, and a root the stacks its harness file
  # exports or its `qory-stack.yaml`, as for a linked collection.
  #
  # ## Limits
  #
  # A person's reads are counted in a fixed window of a minute, by the person's account
  # (`Apiary.Runs.RateLimit.reserve/3`): at most 2 listings (`linked/1`) and 10 reads of
  # a source (`read/2`), else `{:error, {:limited, seconds}}`, the seconds until the
  # window ends. `RateLimit` counts on each node, so on a cluster a person gets these
  # limits on each node. Each resolve of an address may make the adapter call the system
  # it reaches under credentials every organisation shares, so a person's reads stay a
  # few. A listing reads at most 100 linked collections, the first by title, and leaves
  # out the rest, counted; its reads take at most 60 seconds together, and a collection
  # whose reads do not end by then is counted as not read. So one listing makes at most 2
  # resolves per adapter and 300 reads. A read of a source makes one resolve per adapter
  # and at most 3 reads to find its stacks, then reads the first 20 stacks it has, in the
  # order its harness file exports them; its calls take at most 30 seconds together, and
  # one past that makes the source not read.
  #
  # ## The save
  #
  # `save/3` is `harness.save` (owners and admins): the workspace-level document that
  # extends the chosen stack, `Apiary.Stacks.put_stack/3` at the workspace with the
  # workflow, under `Apiary.Stacks.Document`'s save rules. In the same transaction it
  # removes the workspace's rows of other workflows with no target, since a run takes the
  # workflow of the one row with a workflow at its places (`Apiary.Stacks.workflow/2`).
  # Saves of one workspace take turns on a transaction-level advisory lock keyed by the
  # workspace, so two at the same time leave one row.
  # It writes no audit entry, as `put_stack/3` writes none.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Access, Harnesses, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Calls, CallWire, Collection, Connection, Grant, Grants}
  alias Apiary.Harnesses.{Assignment, Reader}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.RateLimit
  alias Apiary.Stacks.{Document, Stack}

  @head "HEAD"
  @stack_file "qory-stack.yaml"
  # How many linked collections are read at once.
  @concurrency 4
  # A person's listings and reads of a source in a window of a minute (the moduledoc).
  @listings_a_minute 2
  @reads_a_minute 10
  @minute 60_000
  # The most linked collections a listing reads, and the time all its reads may take.
  @max_listed 100
  @listing_time 60_000
  # The most stacks a read of a source reads, and the time all its calls may take.
  @max_stacks 20
  @read_time 30_000
  # The time of one call, `Apiary.Adapters.Calls`' default.
  @call_time 10_000

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
  @type reason :: :not_covered | :no_stack | :unreadable | {:limited, pos_integer}

  @typedoc """
  A listing of the linked collections: those with a stack, how many could not be read,
  and how many were past the most a listing reads.
  """
  @type listing :: %{sources: [source], unread: non_neg_integer, left_out: non_neg_integer}

  ## The sources

  @doc false
  # linked/1 is the organisation's linked collections that have a stack, by title:
  # `{:ok, listing}` (the moduledoc), or `{:error, {:limited, seconds}}` for a person
  # past their listings of the minute. It calls the adapters, so a page runs it outside
  # its process.
  @spec linked(Scope.t()) :: {:ok, listing} | {:error, {:limited, pos_integer}}
  def linked(%Scope{organisation: %Organisation{} = organisation} = scope) do
    with :ok <- spend(scope, :linked, @listings_a_minute),
         do: {:ok, list_linked(organisation)}
  end

  defp list_linked(organisation) do
    deadline = now() + @listing_time
    {listed, left_out} = Enum.split(collections(organisation), @max_listed)

    {located, unresolved} =
      listed
      |> Enum.group_by(fn {_collection, adapter} -> adapter.id end)
      |> Enum.reduce({[], 0}, fn {_id, [{_collection, adapter} | _] = pairs}, {located, failed} ->
        {here, failed_here} =
          locate_collections(organisation, adapter, Enum.map(pairs, &elem(&1, 0)), deadline)

        {located ++ here, failed + failed_here}
      end)

    results =
      located
      |> Task.async_stream(
        fn {collection, location} ->
          {collection, location, stacks_at(location, @head, deadline)}
        end,
        max_concurrency: @concurrency,
        timeout: @listing_time + @call_time,
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

    %{
      sources: Enum.sort_by(sources, &String.downcase(&1.label)),
      unread: unresolved + unread,
      left_out: length(left_out)
    }
  end

  @doc false
  # limit/1 is a number the page states: the most linked collections a listing reads.
  @spec limit(:listed) :: pos_integer
  def limit(:listed), do: @max_listed

  # One of the person's reads of `kind` in the window of a minute, `limit` at most.
  defp spend(%Scope{user: %{id: user_id}}, kind, limit) do
    case RateLimit.reserve({__MODULE__, kind, user_id}, limit, @minute) do
      {:ok, _started_at} -> :ok
      {:error, seconds} -> {:error, {:limited, seconds}}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # A call's options: its time, cut to what is left before `deadline`; nil once none is.
  defp call_opts(deadline) do
    case deadline - now() do
      left when left > 0 -> [total: min(left, @call_time)]
      _none -> nil
    end
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
  defp locate_collections(organisation, adapter, collections, deadline) do
    {covered, failed} =
      collections
      |> Enum.map(& &1.url)
      |> Enum.uniq()
      |> Enum.chunk_every(64)
      |> Enum.reduce({%{}, MapSet.new()}, fn chunk, {covered, failed} ->
        with opts when is_list(opts) <- call_opts(deadline),
             {:ok, results} <- Calls.resolve(adapter, chunk, opts) do
          {Map.merge(covered, covered_here(organisation, adapter, results)), failed}
        else
          _failed_or_late -> {covered, MapSet.union(failed, MapSet.new(chunk))}
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
        label: repository(source["git"]),
        git: source["git"],
        ref: source["ref"],
        narrowing: narrowing,
        location: nil,
        version: nil,
        stacks: nil
      }
    end)
    |> distinguish()
  end

  # The repository path of an address, such as `example-org/team-harness` for
  # `https://github.com/example-org/team-harness.git`; else the address as an error shows
  # one.
  defp repository(git) do
    with %URI{host: host, path: "/" <> _ = path} when is_binary(host) and host != "" <-
           URI.parse(git),
         trimmed when trimmed != "" <-
           path |> String.trim("/") |> String.replace_suffix(".git", "") do
      trimmed
    else
      _other -> Document.shown(git)
    end
  end

  # Assignments whose labels are the same get their ref, where the refs differ, and the
  # stack or folder they narrow to, where those differ, after a `·`; with neither, their
  # addresses.
  defp distinguish(sources) do
    same_label = Enum.group_by(sources, & &1.label)

    Enum.map(sources, fn source ->
      case same_label[source.label] do
        [_one] -> source
        same -> %{source | label: told_apart(source, same)}
      end
    end)
  end

  defp told_apart(source, same) do
    refs? = differ?(same, & &1.ref)
    narrowed? = differ?(same, & &1.narrowing)

    if refs? or narrowed? do
      [
        source.label,
        refs? && source.ref,
        narrowed? && (source.narrowing["stack"] || source.narrowing["path"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")
    else
      Document.shown(source.git)
    end
  end

  defp differ?(sources, field), do: sources |> Enum.uniq_by(field) |> length() > 1

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
  # order of their names: `{:ok, stacks}`, or `{:error, reason}`, `{:limited, seconds}`
  # for a person past their reads of the minute. It calls the adapters, so a page runs it
  # outside its process.
  @spec read(Scope.t(), source) :: {:ok, [stack]} | {:error, reason}
  def read(%Scope{organisation: %Organisation{} = organisation} = scope, %{} = source) do
    deadline = now() + @read_time

    with :ok <- spend(scope, :read, @reads_a_minute),
         {:ok, location, version, stacks} <- stacks_of(organisation, source, deadline) do
      stacks
      |> Enum.take(@max_stacks)
      |> Enum.reduce_while([], fn stack, read ->
        case workflows(location, stack.file, version, deadline) do
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

  defp stacks_of(_organisation, %{kind: :linked} = source, _deadline),
    do: {:ok, source.location, source.version, source.stacks}

  defp stacks_of(organisation, source, deadline) do
    harness_source = Map.merge(source.narrowing, %{"git" => source.git, "ref" => source.ref})

    with {:ok, location} <- locate(organisation, harness_source, deadline) do
      case source.narrowing do
        %{"stack" => name} ->
          with {:ok, version, stacks} <- stacks_at(location, source.ref, deadline) do
            case Enum.filter(stacks, &(&1.name == name)) do
              [] -> {:error, :no_stack}
              exported -> {:ok, location, version, exported}
            end
          end

        %{"path" => path} ->
          {:ok, location, source.ref, [%{name: nil, file: in_folder(path, @stack_file)}]}

        _root ->
          with {:ok, version, stacks} <- stacks_at(location, source.ref, deadline),
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

  # Where `harness_source` is read: its link, the first result of an adapter, in the order
  # of their names, under a live grant of a connected connection that the rule allows;
  # else the first public result, with no grant.
  defp locate(%Organisation{id: organisation_id}, %{"git" => git} = harness_source, deadline) do
    if CallWire.address?(git),
      do: locate_at(adapters(), organisation_id, git, harness_source, deadline),
      else: {:error, :unreadable}
  end

  defp adapters do
    Repo.all(
      from a in Node,
        where: a.kind == :adapter and is_nil(a.deleted_at) and not is_nil(a.call_url),
        order_by: [asc: a.name, asc: a.id]
    )
  end

  # An adapter whose resolve fails is passed over. A link at a later adapter comes before
  # a public result at an earlier one, as in a run's walk. With neither, the source is
  # `:unreadable` when any resolve failed, since that adapter may have covered it.
  defp locate_at(adapters, organisation_id, git, harness_source, deadline) do
    adapters
    |> Enum.reduce_while(%{public: nil, failed: false}, fn adapter, found ->
      with opts when is_list(opts) <- call_opts(deadline) || {:error, :late},
           {:ok, [%{} = result]} <- Calls.resolve(adapter, [git], opts) do
        case linked(adapter, result, organisation_id, harness_source) do
          %{} = link -> {:halt, {:ok, link}}
          nil -> {:cont, %{found | public: found.public || public(adapter, result)}}
        end
      else
        {:error, _failure} -> {:cont, %{found | failed: true}}
        _other -> {:cont, found}
      end
    end)
    |> case do
      {:ok, link} -> {:ok, link}
      %{public: %{} = public} -> {:ok, public}
      %{failed: true} -> {:error, :unreadable}
      _none -> {:error, :not_covered}
    end
  end

  # The link of a covered result under a live grant the rule allows; nil for none.
  defp linked(
         adapter,
         %{grant_ref: grant_ref, resource_ref: resource_ref},
         organisation_id,
         source
       ) do
    with %Grant{} = grant <- live_grant(adapter, grant_ref),
         true <- Harnesses.allowed?(organisation_id, grant.organisation_id, source),
         do: location(adapter, grant_ref, resource_ref),
         else: (_not_allowed -> nil)
  end

  defp linked(_adapter, _result, _organisation_id, _source), do: nil

  # A public result's location, with no grant, at its `public_ref`: a covered result's
  # `resource_ref` may be a ref only its grant's organisation may use, so it is never read
  # with no grant. Nil for a result that is not public.
  defp public(adapter, %{public: true, public_ref: public_ref}),
    do: location(adapter, nil, public_ref)

  defp public(_adapter, _result), do: nil

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
  defp stacks_at(location, at, deadline) do
    with {:ok, harness, version} <- read_file(location, "harness.yaml", at, deadline),
         {:ok, qory, _version} <- read_file(location, "qory.yaml", version, deadline) do
      case {harness, qory} do
        {nil, nil} -> root_stack(location, version, deadline)
        {content, nil} -> exported(location, content, version, deadline)
        {nil, content} -> exported(location, content, version, deadline)
        _both -> {:error, :unreadable}
      end
    end
  end

  defp exported(location, content, version, deadline) do
    case Reader.exports(content) do
      {:ok, %{stacks: [_ | _] = names} = exports} ->
        stacks =
          for name <- names,
              file <- [Reader.stack_file(exports, name)],
              CallWire.document_path?(file),
              do: %{name: name, file: file}

        {:ok, version, stacks}

      {:ok, _no_stacks} ->
        root_stack(location, version, deadline)

      :none ->
        root_stack(location, version, deadline)

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp root_stack(location, version, deadline) do
    case read_file(location, @stack_file, version, deadline) do
      {:ok, nil, _version} -> {:ok, version, []}
      {:ok, _content, _version} -> {:ok, version, [%{name: nil, file: @stack_file}]}
      {:error, reason} -> {:error, reason}
    end
  end

  # The workflows of the stack file `file` at `location`, read at `at`, by name.
  defp workflows(location, file, at, deadline) do
    case read_file(location, file, at, deadline) do
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

  # The document at `path` at `location`, read at `at` before `deadline`, with no grant
  # for a public source's location (`read-public`): `{:ok, content | nil, resolved_at}`,
  # or `{:error, :unreadable}` for a path a read does not take, a call that failed, or no
  # time left.
  defp read_file(location, path, at, deadline) do
    request = %{
      grant_ref: location.grant_ref,
      resource_ref: location.resource_ref,
      path: path,
      at: at
    }

    opts = call_opts(deadline)

    if CallWire.document_path?(path) and CallWire.version_ref?(at) and is_list(opts) do
      case Calls.read_at(location.adapter, request, opts) do
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
        lock_saves(workspace)

        replaced =
          Repo.all(
            from s in Stack,
              where: s.organisation_id == ^workspace.organisation_id,
              where: s.workspace_id == ^workspace.id and is_nil(s.target_id),
              where: not is_nil(s.workflow) and s.workflow != ^workflow,
              select: s.workflow
          )

        # A save before this one may have removed one already.
        for other <- replaced do
          case Stacks.delete_stack({:workspace, workspace, other}) do
            {:ok, _stack} -> :ok
            {:error, :not_found} -> :ok
          end
        end

        Stacks.put_stack(scope, {:workspace, workspace, workflow}, document(base))
      end)
    else
      false -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Saves of one workspace take turns: the second waits for the first's transaction, then
  # sees its row and replaces it, so the workspace keeps one workflow.
  defp lock_saves(%Workspace{id: workspace_id}) do
    {:ok, uuid} = Ecto.UUID.dump(workspace_id)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('apiary:workflow-save:' || $1::uuid::text, 0))",
      [uuid]
    )
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
