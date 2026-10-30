defmodule Apiary.Stacks.Sources do
  # The harness sources Workspace settings › Workflow offers a workspace
  # (`ApiaryWeb.WorkflowLive`), the stacks each has, the workflows each stack lists, and
  # the save of the workspace's document. Every read goes through the adapters' calls
  # (`Apiary.Adapters.Calls`: `resolve`, `read` and `read-public`), as a run's walk reads
  # (`Apiary.Harnesses.Walk`), and writes nothing.
  #
  # ## The sources
  #
  #   * Connected repositories (`repositories/1`): the address of each live collection of
  #     a connected connection of the organisation whose address passes the save rules of
  #     a document's source (`Apiary.Stacks.Document.source_error/2`), once per address,
  #     by name. The list is built from Qory Apiary's records with no call. A document
  #     extends one at `ref: HEAD`, so each run reads the commit the head is at when its
  #     walk runs.
  #   * Assigned (`assigned/1`): each instance assignment of the organisation, or of every
  #     organisation (`Apiary.Harnesses.Assignment`), but an assignment of a module. A
  #     document extends it at the assignment's `ref`, the only one the assignment covers.
  #   * An address (`address/1`) a person types: a harness source's address with no user
  #     name or password, checked as a document's source address is, at `HEAD`.
  #
  # ## Reading a source's stacks
  #
  # `exports/2` reads the stacks one source's root `harness.yaml` or `qory.yaml` lists in
  # its `exports`, none among the answers. `read/2` reads the stacks of one source and the
  # workflows each lists, the names of its `qory-stack.yaml`'s `workflows`. A source is
  # resolved at every adapter with a `call_url`, in the order of their names, as a run's
  # walk resolves it:
  # the first result under a live grant of a connected connection that the rule allows
  # (`Apiary.Harnesses.allowed?/3`) is its link; with none, the first result with
  # `public`, true, makes it public, read at that result's `public_ref` (`read-public`),
  # with no grant and no link. Neither is `:not_covered`, and a run's walk could not read
  # it either. A source with `stack` is that export of its root harness file, one with
  # `path` the `qory-stack.yaml` in that folder, and a root the stacks its harness file
  # exports, else its `qory-stack.yaml`.
  #
  # ## Limits
  #
  # A person's reads are counted in a fixed window of a minute, by the person's account
  # (`Apiary.Runs.RateLimit.reserve/3`): at most 10 reads of a source (`exports/2`,
  # `read/2` and the reads of a save), else `{:error, {:limited, seconds}}`, the seconds
  # until the window ends. `RateLimit` counts on each node, so on a cluster a person gets
  # these limits on each node. Each resolve of an address may make the adapter call the
  # system it reaches under credentials every organisation shares, so a person's reads
  # stay a few. A read of a source makes one resolve per adapter and at most 3 reads to
  # find its stacks, then, for `read/2`, reads the first 20 stacks it has, in the order
  # its harness file exports them; its calls take at most 30 seconds together, and one
  # past that makes the source not read.
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
  # ## The harness choices
  #
  # A harness is a repository, a stack it exports, and a version (`Apiary.Stacks.Stack`).
  # `choose/3`, `choose_target/3` and `save/3` are `harness.save` on the scope's
  # workspace, under the same lock. `choose/3` saves the workspace's harness choice
  # (`Apiary.Stacks`) at the workspace with no workflow; with `shared: true`, it saves the
  # harness the organisation shares with every workspace instead, at the organisation's
  # row, and removes the workspace's choice in the same transaction, so the workspace
  # takes the shared one. Shares of one organisation take turns on a transaction-level
  # advisory lock keyed by the organisation. A harness repository shared while the
  # organisation shares the Qory harness replaces that row; any other share while the
  # organisation shares a harness is refused. Two shares at the same time leave one row.
  # `reuse_shared/1` removes the workspace's choice while the organisation shares a
  # harness, so the workspace takes the shared one, under both locks. `choose_target/3`
  # saves the stack chosen for one destination of the workspace at the target's row, and
  # creates the target's row where the workspace has none.
  #
  # The Qory harness reads nothing: its version is the newest the release ships
  # (`:latest`), or a name the release lists, checked against that list. A harness
  # repository, or a stack of one, is read as a run's walk reads the base of a document
  # (`Apiary.Harnesses.Walk.pin_base/3`), at the branch, tag or commit the person gave,
  # within the time of a read of a source and counted as one of the person's reads; a
  # walk that failed is the refusal, a name the read does not find among them. The row
  # stores the stack and the version as the person gave it: a branch by its name, whose
  # newest commit each run reads, a tag by its name, and a commit by its full id. A
  # choice with no version, a harness repository's root or a stack of a source with a
  # branch or tag, is saved pinned at the commit the walk read. A stack of an assigned source keeps the assignment's
  # `ref`, the only one the assignment covers, and is read the same way.
  #
  # A target's stack of the workspace's harness (`{:workspace, stack}`) stores the
  # repository and the stack, and the version `:workspace`: each run reads it at the
  # version of the workspace's harness (`Apiary.Stacks.version_ref/3`). When a save
  # changes the repository of a workspace's harness, the choice of the workspace or the
  # shared harness it takes, each such target row of the workspace keeps its repository
  # and stack and stores the version it followed until then. `chosen/1` is the
  # workspace's choice as a page shows it, and `targets_chosen/1` the stacks chosen for
  # its targets.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Access, Harnesses, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{CallAddress, CallFailure, Calls, CallWire, Collection, Connection, Grant}
  alias Apiary.Harnesses.{Assignment, Reader, Walk}
  alias Apiary.Lingo.Domain
  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{RateLimit, Target}
  alias Apiary.Stacks.{Document, Stack}

  @head "HEAD"
  @stack_file "qory-stack.yaml"
  # A person's reads of a source in a window of a minute (the moduledoc).
  @reads_a_minute 10
  @minute 60_000
  # The most stacks a read of a source reads, and the time all its calls may take.
  @max_stacks 20
  @read_time 30_000
  # The time of one call, `Apiary.Adapters.Calls`' default.
  @call_time 10_000

  @typedoc """
  A source the page offers: its id on the page, its kind, its label, its `git` and `ref`,
  and the key that narrows it to a stack (`path` or `stack`, or none for a root).
  `location`, `version` and `stacks` are nil: a source is read when it is chosen.
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

  @typedoc """
  A call to an adapter that failed, as a page shows it: the adapter's shown name
  (`Apiary.Adapters.title/1`) and the cause, with no address, host or IP of the
  instance's set-up, which a person who is not an instance admin sees:

    * `:timeout`: no answer within `seconds`, the time the call had;
    * `:late`: no time left of the read's `seconds` before every file was read;
    * `:unreachable`: no connection was made, the host resolved to no address, or a
      proxy answered 502, 503 or 504 (`Apiary.Adapters.CallFailure`'s `:unreachable`);
    * `:no_address`: as `Apiary.Adapters.CallFailure` has it;
    * `:not_allowed`: as `Apiary.Adapters.CallFailure` has it, with `refusal`, why:
      `:form`, `:public_host`, or `{:address, kind}`, the kind of the address the host
      resolves to (`Apiary.Adapters.CallAddress`), without the address;
    * `:unauthorized`: an unsigned 401;
    * `:refused`: any other refusal, with its code in `code`;
    * `:invalid_answer` and `:too_large`: as `Apiary.Adapters.CallFailure` has them.
  """
  @type call :: %{
          adapter: String.t(),
          cause:
            :timeout
            | :late
            | :unreachable
            | :no_address
            | :not_allowed
            | :unauthorized
            | :refused
            | :invalid_answer
            | :too_large,
          code: String.t() | nil,
          seconds: pos_integer | nil,
          refusal: :form | :public_host | {:address, CallAddress.kind()} | nil
        }

  @typedoc """
  Why a source's stacks were not read:

    * `:not_covered`: no adapter links the source to the organisation and none reads it
      in public, or an adapter refused a read `grant_unknown`, `resource_not_covered` or
      `resource_not_public`, as for a run's walk;
    * `:no_stack`: a root with no stack in a harness file's `exports` and no
      `qory-stack.yaml`;
    * `{:no_stack_file, file}`: no `file`, the `qory-stack.yaml` of a stack a root
      harness file lists, or of the folder a source is narrowed to;
    * `{:no_export, name}`: a source narrowed to the stack `name`, which its root harness
      file does not export;
    * `{:stack_path, file, name, path}`: the root harness file `file` lists the stack
      `name` at `path`, a path a read does not take;
    * `{:call, call}`: a call to an adapter that failed (`t:call/0`);
    * `:no_commit`: an adapter refused a read at `HEAD`, `version_not_found`: a
      repository with no commit;
    * `{:no_version, ref}`: an adapter refused a read at any other `ref`,
      `version_not_found`;
    * `{:not_text, path}`: an adapter refused the read of `path`, `document_not_text`;
    * `{:invalid_section, file, section}`: a file whose `exports` (`:exports`) or stack
      section (`:stack`) is not valid;
    * `{:invalid, file, rule}`: any other file the reader refuses, with the walk's rule for
      it (`Apiary.Harnesses.Walk.yaml_rule/2`), or both root harness files, with the
      walk's `both_files` rule, given for `harness.yaml`;
    * `{:unreadable, :address}`, `{:unreadable, :path, path}` and `{:unreadable,
      :version, ref}`: an address, a path or a version a read does not take;
    * `{:limited, seconds}`.
  """
  @type reason ::
          :not_covered
          | :no_stack
          | {:no_stack_file, String.t()}
          | {:no_export, String.t()}
          | {:stack_path, String.t(), String.t(), String.t()}
          | {:call, call}
          | :no_commit
          | {:no_version, String.t()}
          | {:not_text, String.t()}
          | {:invalid_section, String.t(), :exports | :stack}
          | {:invalid, String.t(), map}
          | {:unreadable, :address}
          | {:unreadable, :path | :version, String.t()}
          | {:limited, pos_integer}

  ## The sources

  @doc false
  # repositories/1 is the organisation's connected repositories, by name (the moduledoc),
  # each a source of the kind `:linked` at `HEAD`. It makes no call.
  @spec repositories(Scope.t()) :: [source]
  def repositories(%Scope{organisation: %Organisation{} = organisation}) do
    organisation
    |> collections()
    |> Enum.uniq_by(fn {collection, _adapter} -> collection.url end)
    |> Enum.map(fn {collection, _adapter} ->
      %{
        id: "linked:" <> collection.public_id,
        kind: :linked,
        label: collection.title || Document.shown(collection.url),
        git: collection.url,
        ref: @head,
        narrowing: %{},
        location: nil,
        version: nil,
        stacks: nil
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.label))
  end

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
  # call address Qory Apiary calls, checked without a lookup
  # (`Apiary.Adapters.CallAddress.placed?/1`), with an address a document's source may
  # have, by title.
  defp collections(%Organisation{} = organisation),
    do:
      organisation
      |> connected()
      |> Enum.filter(fn {_c, adapter} -> CallAddress.placed?(adapter) end)

  # The organisation's live collections of a connected connection and their adapters,
  # with an address a document's source may have, by title.
  defp connected(%Organisation{id: organisation_id}) do
    Repo.all(
      from c in Collection,
        join: n in Connection,
        on: n.id == c.connection_id,
        join: a in Node,
        on: a.id == c.adapter_id,
        where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
        where: n.state == :connected,
        where: a.kind == :adapter and is_nil(a.deleted_at),
        order_by: [asc: c.title, asc: c.id],
        select: {c, a}
    )
    |> Enum.filter(fn {collection, _adapter} -> address_error(collection.url) == nil end)
  end

  @typedoc """
  An adapter of connected repositories whose call address Qory Apiary does not call: its
  public id, its shown name, and why: `:no_address` for none, `:no_instance_host` where the instance's
  public address (`PUBLIC_URL`) has no host name, `:not_placed` for an address that is
  not an https address at the adapter's host (`Apiary.Adapters.CallAddress.host_for/1`).
  It has no address or host, which a person who is not an instance admin sees.
  """
  @type unplaced :: %{
          id: String.t(),
          adapter: String.t(),
          cause: :no_address | :no_instance_host | :not_placed
        }

  @doc false
  # unplaced/1 is each adapter of the organisation's connected repositories whose call
  # address Qory Apiary does not call, checked without a lookup
  # (`Apiary.Adapters.CallAddress.placed?/1`), by its shown name (`t:unplaced/0`). The
  # repositories of such an adapter are not in `repositories/1`. It makes no call.
  # `:instance_host` in `opts` replaces the host of `PUBLIC_URL`, for a test: with none,
  # no adapter is called, as `placed?/1` has it.
  @spec unplaced(Scope.t(), keyword) :: [unplaced]
  def unplaced(%Scope{organisation: %Organisation{} = organisation}, opts \\ []) do
    host = Keyword.get_lazy(opts, :instance_host, &CallAddress.instance_host/0)

    organisation
    |> connected()
    |> Enum.map(fn {_collection, adapter} -> adapter end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(host not in [nil, ""] and CallAddress.placed?(&1)))
    |> Enum.map(
      &%{id: &1.public_id, adapter: Apiary.Adapters.title(&1), cause: unplaced_cause(&1, host)}
    )
    |> Enum.sort_by(&String.downcase(&1.adapter))
  end

  defp unplaced_cause(%Node{call_url: nil}, _host), do: :no_address
  defp unplaced_cause(%Node{}, host) when host in [nil, ""], do: :no_instance_host
  defp unplaced_cause(%Node{}, _host), do: :not_placed

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
  # exports/2 is the names of the stacks `source`'s root `harness.yaml` or `qory.yaml`
  # lists in its `exports`, read at the source's `ref`, in the file's order: `{:ok,
  # names}`, `[]` for a source with neither file or with no `exports`; `{:error,
  # reason}`, `{:invalid, file, rule}` or `{:invalid_section, file}` for both files or
  # `exports` that do not read, and `{:limited, seconds}` for a person past their reads
  # of the minute. It calls the adapters, so a page runs it outside its process.
  @spec exports(Scope.t(), source) :: {:ok, [String.t()]} | {:error, reason}
  def exports(%Scope{organisation: %Organisation{} = organisation} = scope, %{} = source) do
    deadline = now() + @read_time
    harness_source = Map.merge(source.narrowing, %{"git" => source.git, "ref" => source.ref})

    with :ok <- spend(scope, :read, @reads_a_minute),
         {:ok, location} <- locate(organisation, harness_source, deadline),
         {:ok, harness, version} <- read_file(location, "harness.yaml", source.ref, deadline),
         {:ok, qory, _version} <- read_file(location, "qory.yaml", version, deadline) do
      case {harness, qory} do
        {nil, nil} -> {:ok, []}
        {content, nil} -> export_names("harness.yaml", content)
        {nil, content} -> export_names("qory.yaml", content)
        _both -> {:error, both_files()}
      end
    end
  end

  defp export_names(file, content) do
    case Reader.exports(content) do
      {:ok, %{stacks: names}} -> {:ok, names}
      :none -> {:ok, []}
      {:error, reason} -> {:error, refused_file(file, reason)}
    end
  end

  # A file the reader refuses for `reason`.
  defp refused_file(file, :invalid_exports), do: {:invalid_section, file, :exports}
  defp refused_file(file, :invalid_stack), do: {:invalid_section, file, :stack}

  defp refused_file(file, reason), do: {:invalid, file, Walk.yaml_rule(file, reason)}

  # Both root harness files: the walk's `both_files` rule, given for `harness.yaml`.
  defp both_files, do: {:invalid, "harness.yaml", %{"rule" => "both_files", "values" => %{}}}

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

  defp stacks_of(organisation, source, deadline) do
    harness_source = Map.merge(source.narrowing, %{"git" => source.git, "ref" => source.ref})

    with {:ok, location} <- locate(organisation, harness_source, deadline) do
      case source.narrowing do
        %{"stack" => name} ->
          with {:ok, version, stacks} <- stacks_at(location, source.ref, deadline) do
            case Enum.filter(stacks, &(&1.name == name)) do
              [] -> {:error, {:no_export, name}}
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
      else: {:error, {:unreadable, :address}}
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
  # not read for the first adapter whose resolve failed (`call_failure/4`), since that
  # adapter may have covered it.
  defp locate_at(adapters, organisation_id, git, harness_source, deadline) do
    adapters
    |> Enum.reduce_while(%{public: nil, failed: nil}, fn adapter, found ->
      opts = call_opts(deadline)

      with opts when is_list(opts) <- opts || {:error, :late},
           {:ok, [%{} = result]} <- Calls.resolve(adapter, [git], opts) do
        case linked(adapter, result, organisation_id, harness_source) do
          %{} = link -> {:halt, {:ok, link}}
          nil -> {:cont, %{found | public: found.public || public(adapter, result)}}
        end
      else
        {:error, failure} ->
          {:cont, %{found | failed: found.failed || {adapter, failure, opts}}}

        _other ->
          {:cont, found}
      end
    end)
    |> case do
      {:ok, link} -> {:ok, link}
      %{public: %{} = public} -> {:ok, public}
      %{failed: {adapter, failure, opts}} -> {:error, call_failure(adapter, failure, opts, %{})}
      _none -> {:error, :not_covered}
    end
  end

  # A call to `adapter` that failed, with the options it had, nil for none (`:late`), as
  # a read's reason: an adapter's refusal that a run's walk takes as a source not covered,
  # a version not found or a document that is not text, as those (`t:reason/0`, the
  # read's `at` and `path` in `read`); any other failure as `{:call, call}` (`call/3`).
  defp call_failure(_adapter, %CallFailure{cause: :refused, code: code}, _opts, _read)
       when code in ["grant_unknown", "resource_not_covered", "resource_not_public"],
       do: :not_covered

  defp call_failure(_adapter, %CallFailure{cause: :refused, code: "version_not_found"}, _opts, %{
         at: at
       }),
       do: if(at == @head, do: :no_commit, else: {:no_version, at})

  defp call_failure(_adapter, %CallFailure{cause: :refused, code: "document_not_text"}, _opts, %{
         path: path
       }),
       do: {:not_text, path}

  defp call_failure(adapter, failure, opts, _read),
    do: {:call, call(adapter, failure, seconds(opts))}

  # The whole seconds a call had, at least 1; the read's for none.
  defp seconds(opts) when is_list(opts),
    do: max(div(Keyword.fetch!(opts, :total) + 999, 1000), 1)

  defp seconds(nil), do: div(@read_time, 1000)

  @doc false
  # call/3 is the call to `adapter`, a node, that failed with `failure`, a
  # `Apiary.Adapters.CallFailure`, its cause `:timeout` or `:unreachable` alone, or
  # `:late` for no time left of the read, as a page shows it (`t:call/0`), with the
  # seconds the call had, or the read's for `:late`.
  @spec call(Node.t(), CallFailure.t() | :timeout | :unreachable | :late, pos_integer) :: call
  def call(%Node{} = adapter, failure, seconds) do
    {cause, code} =
      case failure do
        :late -> {:late, nil}
        cause when cause in [:timeout, :unreachable] -> {cause, nil}
        %CallFailure{cause: :refused, code: "unauthorized", status: 401} -> {:unauthorized, nil}
        %CallFailure{cause: :refused, code: code} -> {:refused, code}
        %CallFailure{cause: cause} -> {cause, nil}
      end

    %{
      adapter: Apiary.Adapters.title(adapter),
      cause: cause,
      code: code,
      seconds: if(cause in [:timeout, :late], do: seconds),
      refusal: refusal(failure)
    }
  end

  # Why Qory Apiary does not call an adapter, without the address its host resolves to:
  # a page that is not an instance admin's shows no IP of the instance's set-up.
  defp refusal(%CallFailure{cause: :not_allowed, refusal: {:address, _ip, kind}}),
    do: {:address, kind}

  defp refusal(%CallFailure{cause: :not_allowed, refusal: refusal})
       when refusal in [:form, :public_host],
       do: refusal

  defp refusal(_failure), do: nil

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
  # `%{name, file}`, `[]` for none; `{:error, reason}` for a read that failed;
  # `{:invalid, file, rule}` or `{:invalid_section, file}` for both root harness files or
  # a harness file whose `exports` do not read; and `:no_stack_file` for stacks listed at
  # no path a read takes.
  defp stacks_at(location, at, deadline) do
    with {:ok, harness, version} <- read_file(location, "harness.yaml", at, deadline),
         {:ok, qory, _version} <- read_file(location, "qory.yaml", version, deadline) do
      case {harness, qory} do
        {nil, nil} -> root_stack(location, version, deadline)
        {content, nil} -> exported(location, "harness.yaml", content, version, deadline)
        {nil, content} -> exported(location, "qory.yaml", content, version, deadline)
        _both -> {:error, both_files()}
      end
    end
  end

  defp exported(location, file, content, version, deadline) do
    case Reader.exports(content) do
      {:ok, %{stacks: [_ | _] = names} = exports} ->
        stacks =
          for name <- names,
              file <- [Reader.stack_file(exports, name)],
              CallWire.document_path?(file),
              do: %{name: name, file: file}

        # Stacks listed whose files are at no path a read takes: the first of them.
        if stacks == [] do
          name = hd(names)
          {:error, {:stack_path, file, name, Reader.stack_file(exports, name)}}
        else
          {:ok, version, stacks}
        end

      {:ok, _no_stacks} ->
        root_stack(location, version, deadline)

      :none ->
        root_stack(location, version, deadline)

      {:error, reason} ->
        {:error, refused_file(file, reason)}
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
        {:error, {:no_stack_file, file}}

      {:ok, content, _version} ->
        case Reader.stack(content) do
          {:ok, %{workflows: workflows}} -> {:ok, workflows |> Map.keys() |> Enum.sort()}
          {:error, reason} -> {:error, refused_file(file, reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The document at `path` at `location`, read at `at` before `deadline`, with no grant
  # for a public source's location (`read-public`): `{:ok, content | nil, resolved_at}`;
  # `{:error, {:unreadable, :path | :version, value}}` for a path or a version a read does
  # not take; or the call's failure (`call_failure/4`).
  defp read_file(location, path, at, deadline) do
    request = %{
      grant_ref: location.grant_ref,
      resource_ref: location.resource_ref,
      path: path,
      at: at
    }

    cond do
      not CallWire.document_path?(path) ->
        {:error, {:unreadable, :path, path}}

      not CallWire.version_ref?(at) ->
        {:error, {:unreadable, :version, at}}

      opts = call_opts(deadline) ->
        case Calls.read_at(location.adapter, request, opts) do
          {:ok, %{found: true, content: content, resolved_at: version}} ->
            {:ok, content, version}

          {:ok, %{found: false, resolved_at: version}} ->
            {:ok, nil, version}

          {:error, failure} ->
            {:error, call_failure(location.adapter, failure, opts, %{at: at, path: path})}
        end

      true ->
        {:error, call_failure(location.adapter, :late, nil, %{})}
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

  @typedoc """
  The version of a harness repository to save: the newest commit of a branch when each
  run starts (`:branch`), with its name; or a fixed version, a tag by its name (`:tag`)
  or a commit by its full id (`:commit`).
  """
  @type version :: {:branch, String.t()} | {:tag, String.t()} | {:commit, String.t()}

  @typedoc """
  A harness choice to save: the Qory harness at the newest version the release ships
  (`:qory` or `{:qory, :latest}`) or at a named version (`{:qory, name}`); a stack of a
  harness repository at a version (`{:repository, source, stack, version}`); or a
  harness repository's root at a branch or tag, pinned at the commit the walk read, with
  no version (`{:repository, source, ref}`).
  """
  @type choice ::
          :qory
          | {:qory, :latest | String.t()}
          | {:repository, source, String.t(), version}
          | {:repository, source, String.t()}

  @typedoc """
  The version of a saved choice: `:latest` or `{:named, name}` for the Qory harness;
  `{:branch, name}`, `{:tag, name}` or `{:commit, id}` for a harness
  repository; `:workspace` for a target's stack that takes the version of the
  workspace's harness; nil for a row saved with no version, read at its pin.
  """
  @type chosen_version ::
          :latest
          | {:named, String.t()}
          | {:branch, String.t()}
          | {:tag, String.t()}
          | {:commit, String.t()}
          | :workspace
          | nil

  @typedoc """
  A workspace's harness choice as a page shows it: the choice, the address of its
  harness, the stack, the version (`t:chosen_version/0`), the `ref` a run reads it at
  now (`pin`: a full commit id, or the name of a branch or tag), whether it is saved,
  and whether it is the harness the organisation shares. A workspace without a choice
  shows the organisation's shared harness, else the Qory harness at `:latest`, not saved.
  """
  @type chosen :: %{
          choice: :qory | :repository,
          git: String.t() | nil,
          stack: String.t() | nil,
          version: chosen_version,
          pin: String.t() | nil,
          saved: boolean,
          shared: boolean
        }

  @doc false
  # chosen/1 is the harness choice of `workspace` (`t:chosen/0`).
  @spec chosen(Workspace.t()) :: chosen
  def chosen(%Workspace{} = workspace) do
    case Stacks.choice(workspace) do
      %Stack{} = row ->
        Map.put(chosen_row(row), :shared, false)

      nil ->
        case shared(%Organisation{id: workspace.organisation_id}) do
          %{} = shared ->
            shared

          nil ->
            harness = qory_harness(workspace)

            %{
              choice: :qory,
              git: harness["git"],
              stack: harness["stack"],
              version: :latest,
              pin: harness["ref"],
              saved: false,
              shared: false
            }
        end
    end
  end

  @doc false
  # shared/1 is the harness `organisation` shares, as `chosen/1` shows it to a workspace
  # that reuses it (`t:chosen/0`, `shared: true`); nil for none.
  @spec shared(Organisation.t()) :: chosen | nil
  def shared(%Organisation{} = organisation) do
    case Stacks.shared(organisation) do
      %Stack{} = row -> Map.put(chosen_row(row), :shared, true)
      nil -> nil
    end
  end

  # A workspace's or an organisation's row, whose version is never `:workspace`.
  defp chosen_row(%Stack{choice: choice, harness: harness} = row) do
    base = extended(harness)

    %{
      choice: choice,
      git: base["git"],
      stack: base["stack"],
      version: version_of(row),
      pin: pin(row, nil, nil),
      saved: true
    }
  end

  # The version of `row` as a page shows it (`t:chosen_version/0`).
  defp version_of(%Stack{version_kind: nil}), do: nil
  defp version_of(%Stack{version_kind: :latest}), do: :latest
  defp version_of(%Stack{version_kind: :workspace}), do: :workspace

  defp version_of(%Stack{version_kind: kind, version_name: name}), do: {kind, name}

  # The `ref` a run reads `row` at now (`Apiary.Stacks.version_ref/3`), nil for a named
  # version the release no longer ships. `workspace` and `organisation` are read only
  # for the version `:workspace`.
  defp pin(row, workspace, organisation) do
    case Stacks.version_ref(row, workspace, organisation) do
      ref when is_binary(ref) -> ref
      _missing -> nil
    end
  end

  # The base the document `harness` extends, `%{}` for none.
  defp extended(harness) do
    case is_binary(harness) && Reader.document(harness) do
      {:ok, %{"extends" => %{} = base}} -> base
      _other -> %{}
    end
  end

  @doc false
  # choose/3 saves `choice` as the harness choice of the scope's workspace, or, with
  # `shared: true` in `opts`, as the harness the organisation shares (the moduledoc).
  # `{:ok, stack}`; `{:error, :forbidden}` or `{:error, :not_found}` from the access
  # check, asked first; `{:error, :shared}` for a share while the organisation shares a
  # harness repository, and for a share of the Qory harness while it shares the Qory
  # harness; `{:error, {:limited, seconds}}` for a person past their reads of the minute;
  # `{:error, {:walk, failure}}` for a harness repository the walk could not read
  # (`t:Apiary.Harnesses.Walk.failure/0`), a branch or tag it does not find among them;
  # `{:error, :invalid}` for a harness repository without a source, a stack or a version,
  # and for a named version the release does not ship; or `{:error, changeset}`.
  @spec choose(Scope.t(), choice, keyword) ::
          {:ok, Stack.t()}
          | {:error,
             Ecto.Changeset.t()
             | Access.reason()
             | :invalid
             | :shared
             | {:limited, pos_integer}
             | {:walk, Walk.failure()}}
  def choose(%Scope{workspace: %Workspace{} = workspace} = scope, choice, opts \\ []) do
    with :ok <- Access.authorize(scope, :"harness.save", workspace),
         {:ok, chosen, harness, version} <- choice_document(scope, choice) do
      if Keyword.get(opts, :shared, false),
        do: share(scope, chosen, harness, version),
        else:
          Repo.transact(fn ->
            lock_saves(workspace)
            before = Stacks.choice(workspace) || Stacks.shared(scope.organisation)

            with {:ok, stack} <-
                   Stacks.put_stack(scope, {:workspace, workspace}, harness,
                     choice: chosen,
                     version: version
                   ) do
              keep_followed(workspace, before, stack)
              {:ok, stack}
            end
          end)
    end
  end

  # The organisation's shared harness, saved where the organisation shares none, or in
  # place of a shared Qory harness where `chosen` is a harness repository, with the
  # workspace's choice removed. Each workspace of the organisation with no choice, and
  # the scope's workspace, takes the shared harness from then on.
  defp share(
         %Scope{organisation: organisation, workspace: workspace} = scope,
         chosen,
         harness,
         version
       ) do
    Repo.transact(fn ->
      lock_shares(organisation)
      lock_saves(workspace)

      replaced = Stacks.shared(organisation)

      if replaces?(replaced, chosen) do
        before = Stacks.choice(workspace) || replaced
        without_choice = workspaces_without_choice(organisation, workspace)

        with {:ok, stack} <-
               Stacks.put_stack(scope, {:organisation, organisation}, harness,
                 choice: chosen,
                 version: version
               ) do
          delete_choice(workspace)
          keep_followed(workspace, before, stack)
          for other <- without_choice, do: keep_followed(other, replaced, stack)
          {:ok, stack}
        end
      else
        {:error, :shared}
      end
    end)
  end

  # Whether a share of `chosen` is saved while the organisation's shared row is `shared`:
  # true for none, and for a harness repository in place of the Qory harness.
  defp replaces?(nil = _shared, _chosen), do: true
  defp replaces?(%Stack{choice: :qory} = _shared, :repository), do: true
  defp replaces?(%Stack{} = _shared, _chosen), do: false

  # The workspaces of `organisation` other than `workspace` with no harness choice.
  defp workspaces_without_choice(%Organisation{id: organisation_id}, %Workspace{id: id}) do
    Repo.all(
      from w in Workspace,
        as: :workspace,
        where: w.organisation_id == ^organisation_id and w.id != ^id,
        where:
          not exists(
            from s in Stack,
              where: s.workspace_id == parent_as(:workspace).id,
              where: is_nil(s.target_id) and is_nil(s.workflow) and not is_nil(s.choice)
          )
    )
  end

  @doc false
  # reuse_shared/1 removes the harness choice of the scope's workspace while its
  # organisation shares a harness, so the workspace takes the shared one. `{:ok, stack}`,
  # the organisation's row; `{:error, :forbidden}` or `{:error, :not_found}` from the
  # access check (`harness.save`), asked first; `{:error, :not_shared}` while the
  # organisation shares none, with nothing removed.
  @spec reuse_shared(Scope.t()) :: {:ok, Stack.t()} | {:error, Access.reason() | :not_shared}
  def reuse_shared(%Scope{workspace: %Workspace{} = workspace} = scope) do
    organisation = %Organisation{id: workspace.organisation_id}

    with :ok <- Access.authorize(scope, :"harness.save", workspace) do
      Repo.transact(fn ->
        lock_shares(organisation)
        lock_saves(workspace)

        case Stacks.shared(organisation) do
          %Stack{} = stack ->
            keep_followed(workspace, Stacks.choice(workspace) || stack, stack)
            delete_choice(workspace)
            {:ok, stack}

          nil ->
            {:error, :not_shared}
        end
      end)
    end
  end

  # Removes the workspace's harness choice, if it has one. A delete here, not
  # `Stacks.delete_stack/1`: its refusal of a place with no row would roll the caller's
  # transaction back.
  defp delete_choice(%Workspace{} = workspace) do
    Repo.delete_all(
      from s in Stack,
        where: s.organisation_id == ^workspace.organisation_id,
        where: s.workspace_id == ^workspace.id,
        where: is_nil(s.target_id) and is_nil(s.workflow)
    )
  end

  # Where the workspace's harness moves from the row `before` to the row `now`, nil for
  # the Qory harness at `:latest`, and its repository changes, each target row of
  # `workspace` with the version `:workspace`, by its choice and address:
  #
  #   * those of `before`: keeps its repository and stack and stores the version it
  #     followed, that of `before`, its document at the `ref` of `before`;
  #   * those of `now`: is left as it is, and follows `now`;
  #   * any other, a row a save wrote while the workspace changed harness: stores no
  #     version, its document as written.
  defp keep_followed(%Workspace{} = workspace, before, now) do
    if harness_repository(before) != harness_repository(now) do
      Repo.all(
        from s in Stack,
          where: s.organisation_id == ^workspace.organisation_id,
          where: s.workspace_id == ^workspace.id and not is_nil(s.target_id),
          where: is_nil(s.workflow) and s.version_kind == :workspace,
          lock: "FOR UPDATE"
      )
      |> Enum.each(&keep_followed(&1, before, now, harness_repository(&1)))
    end

    :ok
  end

  defp keep_followed(%Stack{} = row, before, now, repository) do
    cond do
      repository == harness_repository(before) ->
        {kind, name} = followed(before)
        ref = pin(before || %Stack{version_kind: :latest}, nil, nil)
        harness = row.harness |> extended() |> Map.put("ref", ref) |> document()
        update_followed!(row, harness: harness, version_kind: kind, version_name: name)

      repository == harness_repository(now) ->
        :ok

      true ->
        update_followed!(row, version_kind: nil, version_name: nil)
    end
  end

  defp update_followed!(%Stack{} = row, changes) do
    row
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.check_constraint(:version_kind, name: :stacks_version_check)
    |> Repo.update!()
  end

  # The choice and the address of a workspace's harness row, the Qory harness for none.
  defp harness_repository(nil), do: {:qory, Definition.qory_harness().git}

  defp harness_repository(%Stack{choice: choice, harness: harness}),
    do: {choice, extended(harness)["git"]}

  defp choice_of(nil), do: :qory
  defp choice_of(%Stack{choice: choice}), do: choice

  # The version columns of the row `before`, `:latest` for none.
  defp followed(nil), do: {:latest, nil}
  defp followed(%Stack{} = row), do: {row.version_kind, row.version_name}

  # `{:ok, choice, document, version}` for `choice`, the version as `Apiary.Stacks.put_stack/4`
  # takes it; `{:error, reason}` as `choose/3` gives.
  defp choice_document(scope, :qory), do: choice_document(scope, {:qory, :latest})

  defp choice_document(scope, {:qory, :latest}) do
    base = qory_harness(scope.workspace)
    {:ok, :qory, document(base), {:latest, nil}}
  end

  defp choice_document(scope, {:qory, name}) when is_binary(name) do
    case Definition.qory_commit(name) do
      commit when is_binary(commit) ->
        base = %{qory_harness(scope.workspace) | "ref" => commit}
        {:ok, :qory, document(base), {:named, name}}

      nil ->
        {:error, :invalid}
    end
  end

  defp choice_document(scope, {:repository, %{git: git}, stack, version})
       when is_binary(git) and is_binary(stack) and stack != "" do
    with {kind, name} when kind in [:branch, :tag, :commit] and is_binary(name) <- version,
         name = String.trim(name),
         true <- name != "" and (kind != :commit or commit?(name)),
         base = %{"git" => git, "stack" => stack, "ref" => name},
         {:ok, _pin} <- checked(scope, base) do
      {:ok, :repository, document(base), {kind, name}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid}
    end
  end

  defp choice_document(scope, {:repository, %{git: git}, ref})
       when is_binary(git) and is_binary(ref) do
    with {:ok, pinned} <- pinned(scope, %{"git" => git, "ref" => String.trim(ref)}),
         do: {:ok, :repository, document(pinned), nil}
  end

  defp choice_document(_scope, _choice), do: {:error, :invalid}

  # `base` at the commit a run's walk reads it at (`Apiary.Harnesses.Walk.pin_base/3`),
  # counted as one of the person's reads.
  defp pinned(scope, base) do
    with {:ok, pin} <- checked(scope, base), do: {:ok, %{base | "ref" => pin}}
  end

  # A full commit id: 40 lower-case hex digits for SHA-1, 64 for SHA-256.
  defp commit?(ref), do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, ref)

  # The commit a run's walk reads `base` at, counted as one of the person's reads.
  defp checked(scope, base) do
    with :ok <- spend(scope, :read, @reads_a_minute) do
      case Walk.pin_base(scope.organisation, base, time_limit: @read_time) do
        {:ok, pin} -> {:ok, pin}
        {_failed_or_retry, failure} -> {:error, {:walk, with_call(failure)}}
      end
    end
  end

  # A walk's failure at a call to an adapter, with `call`, the call as a page shows it
  # (`call/3`): a walk's call has at most `@call_time`, and a walk out of time had the
  # read's time. A failure at no call is as the walk gave it.
  defp with_call(%{failure: :adapter_failed, call_failure: %CallFailure{} = failure} = walk),
    do: Map.put(walk, :call, call(walk_adapter(walk), failure, div(@call_time, 1000)))

  defp with_call(%{failure: :adapter_unavailable} = walk) do
    {failure, seconds} =
      case walk[:call_cause] do
        :late -> {:late, div(@read_time, 1000)}
        :unreachable -> {:unreachable, div(@call_time, 1000)}
        _timeout -> {:timeout, div(@call_time, 1000)}
      end

    Map.put(walk, :call, call(walk_adapter(walk), failure, seconds))
  end

  defp with_call(walk), do: walk

  # The adapter of a walk's failure, else a node with its name and no call address.
  defp walk_adapter(%{adapter_id: id, adapter: name}) do
    (is_binary(id) && Repo.get(Node, id)) || %Node{kind: :adapter, name: name}
  end

  @typedoc """
  A stack to choose for a target:
    * `:default`: none, so the target takes the workspace's harness, with the target's
      harness file first;
    * `{:workspace, stack}`: a stack of the workspace's harness, at its version
      (the moduledoc);
    * `:qory` or `{:qory, :latest | name}`, and `{:repository, source, stack, version}`:
      as for `t:choice/0`;
    * `{:stack, source, stack, ref}`: a stack of `read/2` of a source of
      `repositories/1`, `assigned/1` or `address/1`, with a branch or tag, saved with no
      version: a stack of an assigned source at the assignment's `ref`, any other pinned
      at the commit the walk read.
  """
  @type target_choice ::
          :default
          | :qory
          | {:qory, :latest | String.t()}
          | {:workspace, String.t()}
          | {:repository, source, String.t(), version}
          | {:stack, source, stack, String.t()}

  @doc false
  # choose_target/3 saves `choice` as the stack chosen for `target`, a `%{system, path}`
  # of a destination of the scope's workspace (the moduledoc): `:default` removes the
  # target's choice. `{:ok, stack}`, `{:ok, nil}` for `:default`; `{:error, :forbidden}`
  # or `{:error, :not_found}` from the access check, asked first; `{:error, :not_found}`
  # for a target no destination of the workspace has; `{:error, {:limited, seconds}}`,
  # `{:error, {:walk, failure}}`, `{:error, :invalid}` or `{:error, changeset}`, as for
  # `choose/3`; `{:error, :invalid}` also for a stack of the workspace's harness that the
  # Qory harness does not export.
  @spec choose_target(Scope.t(), %{system: String.t(), path: String.t()}, target_choice) ::
          {:ok, Stack.t() | nil}
          | {:error,
             Ecto.Changeset.t()
             | Access.reason()
             | :invalid
             | {:limited, pos_integer}
             | {:walk, Walk.failure()}}
  def choose_target(
        %Scope{workspace: %Workspace{} = workspace} = scope,
        %{system: system, path: path},
        choice
      ) do
    target = %{system: system, path: path}

    with :ok <- Access.authorize(scope, :"harness.save", workspace),
         true <- destination?(workspace, target) || {:error, :not_found},
         {:ok, chosen, harness, version} <- target_document(scope, choice) do
      Repo.transact(fn ->
        lock_saves(workspace)
        save_target(scope, workspace, target, chosen, harness, version)
      end)
    end
  end

  def choose_target(%Scope{}, _target, _choice), do: {:error, :not_found}

  defp save_target(_scope, workspace, target, :default, nil, nil) do
    case Stacks.target_choice(workspace, target) do
      %Stack{target_id: target_id} ->
        {:ok, _removed} = Stacks.delete_stack({:target, Repo.get!(Target, target_id)})
        {:ok, nil}

      nil ->
        {:ok, nil}
    end
  end

  defp save_target(scope, workspace, target, chosen, harness, version) do
    :ok = Target.insert_new(workspace.organisation_id, workspace.id, [target])

    row =
      Repo.get_by!(Target,
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        system: target.system,
        path: target.path
      )

    Stacks.put_stack(scope, {:target, row}, harness, choice: chosen, version: version)
  end

  defp target_document(_scope, :default), do: {:ok, :default, nil, nil}

  defp target_document(scope, {:workspace, stack}) when is_binary(stack),
    do: followed_document(scope, stack)

  defp target_document(scope, {:stack, source, stack, ref}),
    do: stack_document(scope, {:stack, source, stack, ref})

  defp target_document(scope, choice), do: choice_document(scope, choice)

  # A stack of the workspace's harness, at the `ref` of its version: under the Qory
  # harness, a stack the release lists, with no read; under a harness repository, read as
  # a run's walk reads it.
  defp followed_document(%Scope{workspace: workspace} = scope, stack) do
    harness = Stacks.workspace_harness(workspace, scope.organisation)
    ref = pin(harness || %Stack{version_kind: :latest}, nil, nil)

    case {choice_of(harness), ref} do
      {_choice, nil} ->
        {:error, :invalid}

      {:qory, ref} ->
        if stack in Definition.qory_harness().stacks,
          do:
            {:ok, :qory, document(%{qory_harness(workspace) | "stack" => stack, "ref" => ref}),
             {:workspace, nil}},
          else: {:error, :invalid}

      {:repository, ref} ->
        base = %{"git" => extended(harness.harness)["git"], "stack" => stack, "ref" => ref}

        with {:ok, _pin} <- checked(scope, base),
             do: {:ok, :repository, document(base), {:workspace, nil}}
    end
  end

  # A stack of an assigned source at the assignment's `ref`, checked and not pinned.
  defp stack_document(scope, {:stack, %{kind: :assigned, git: git, ref: ref}, stack, _ref})
       when is_binary(git) and is_binary(ref) do
    with {:ok, base} <- stack_base(git, stack),
         base = Map.put(base, "ref", ref),
         {:ok, _pin} <- checked(scope, base),
         do: {:ok, :repository, document(base), nil}
  end

  defp stack_document(scope, {:stack, %{git: git}, stack, ref})
       when is_binary(git) and is_binary(ref) do
    with {:ok, base} <- stack_base(git, stack),
         {:ok, pinned} <- pinned(scope, Map.put(base, "ref", String.trim(ref))),
         do: {:ok, :repository, document(pinned), nil}
  end

  defp stack_document(_scope, _choice), do: {:error, :invalid}

  # The base of `stack` of a read (`read/2`) at the address `git`, with no `ref`.
  defp stack_base(git, %{base: %{} = base}),
    do: {:ok, base |> Map.take(["path", "stack"]) |> Map.put("git", git)}

  defp stack_base(_git, _stack), do: {:error, :invalid}

  # Whether a live collection of a connected connection, assigned to `workspace`, has
  # `target`: a destination of the workspace, as the set-up's Destinations list has one
  # (`Apiary.WorkspaceSetup.collections/3`).
  defp destination?(%Workspace{} = workspace, %{system: system, path: path}) do
    Repo.exists?(
      from c in Collection,
        join: k in Connection,
        on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
        join: n in Node,
        on: n.id == c.adapter_id,
        where: c.organisation_id == ^workspace.organisation_id,
        where: c.workspace_id == ^workspace.id and is_nil(c.ended_at),
        where: c.target_system == ^system and c.target_path == ^path,
        where: k.state == :connected and is_nil(k.ended_at),
        where: n.kind == :adapter and is_nil(n.deleted_at) and n.targets == true
    )
  end

  @typedoc """
  A stack chosen for a target as a page shows it: the choice, the address of its harness,
  the key that narrows it to a stack (`path` or `stack`, or none for a root), the stack,
  the version (`t:chosen_version/0`), and the `ref` a run reads it at now (`pin`).
  """
  @type target_chosen :: %{
          choice: :qory | :repository,
          git: String.t() | nil,
          narrowing: %{optional(String.t()) => String.t()},
          stack: String.t() | nil,
          version: chosen_version,
          pin: String.t() | nil
        }

  @doc false
  # targets_chosen/1 is the stacks chosen for the targets of `workspace`, by `{system,
  # path}` (`t:target_chosen/0`). Read without a lock.
  @spec targets_chosen(Workspace.t()) :: %{{String.t(), String.t()} => target_chosen}
  def targets_chosen(%Workspace{id: id, organisation_id: organisation_id} = workspace) do
    organisation = %Organisation{id: organisation_id}

    Repo.all(
      from s in Stack,
        join: t in Target,
        on: t.id == s.target_id,
        where: s.organisation_id == ^organisation_id and s.workspace_id == ^id,
        where: is_nil(s.workflow) and not is_nil(s.choice),
        select: {t.system, t.path, s}
    )
    |> Map.new(fn {system, path, %Stack{choice: choice, harness: harness} = row} ->
      base = extended(harness)

      {{system, path},
       %{
         choice: choice,
         git: base["git"],
         narrowing: Map.take(base, ["path", "stack"]),
         stack: base["stack"],
         version: version_of(row),
         pin: pin(row, workspace, organisation)
       }}
    end)
  end

  # The base of the Qory harness of `workspace`'s type, at the newest version the release
  # ships (`Apiary.Lingo.Domain`).
  defp qory_harness(workspace),
    do: workspace |> Domain.for_workspace() |> Domain.definition() |> Map.fetch!(:harness)

  # Saves of one workspace take turns: the second waits for the first's transaction, then
  # sees its row and replaces it, so the workspace keeps one workflow.
  defp lock_saves(%Workspace{id: workspace_id}) do
    {:ok, uuid} = Ecto.UUID.dump(workspace_id)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('apiary:workflow-save:' || $1::uuid::text, 0))",
      [uuid]
    )
  end

  # Shares of one organisation take turns: the second waits for the first's transaction,
  # then reads its row and replaces it or is refused (`share/4`), so the organisation
  # keeps one shared harness.
  defp lock_shares(%Organisation{id: organisation_id}) do
    {:ok, uuid} = Ecto.UUID.dump(organisation_id)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('apiary:harness-share:' || $1::uuid::text, 0))",
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
