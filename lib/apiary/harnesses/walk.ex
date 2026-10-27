defmodule Apiary.Harnesses.Walk do
  # The harness walk of an explore run (`Apiary.Harnesses.WalkJob`): which harness the run
  # composes, the version of its target, each remote source's version, and the links the
  # run reads its harness sources through. It reads through the adapters' calls
  # (`Apiary.Adapters.Calls`: `resolve`, `read` and `read-public`) and writes nothing; the
  # job stores what `run/2` returns (`Apiary.Harnesses`). A test work item's run is not
  # walked: it gets the built-in harness when it is queued (`Apiary.Harnesses.Builtin`).
  # The walk has no case for that harness's source: in any document it walks, the source
  # is looked up as any other.
  #
  # ## The target's harness file
  #
  # In a workspace whose domain has harness files (`Apiary.Lingo.Domain.harness_file?/1`),
  # for a run with a target that a live collection of the workspace has, whose connection
  # is connected: the collection's address is resolved at its adapter, under a grant of a
  # connection of the run's organisation, else the walk fails `not_covered`. Then
  # `harness.yaml` is read at the target's head (`HEAD`), and `qory.yaml` at the version
  # that read returned, which is the run's `target_version`. Both found fail `invalid`.
  # A file whose harness section has `extends`, or has no `extends` and lists modules,
  # applies, origin `:file`. Any other case, a file with no harness section, one with the
  # machine's keys alone, one whose section has neither `extends` nor modules, or no
  # file, takes the stacks' document. A target no collection has, or a domain without
  # harness files, is not read and has no `target_version`.
  #
  # ## The stacks' document
  #
  # The harness document of the most specific level for the run's workflow
  # (`Apiary.Stacks.resolve_for/4`), origin `:setting`: none fails `no_harness`. It is
  # read once and checked again by the save rules (`Apiary.Stacks.Document.check/1`),
  # else `invalid`.
  #
  # ## The sources, two levels
  #
  # Level 1 is the document's `extends` and its modules' sources. Level 2 is the git
  # sources of the modules the base lists. Nothing is followed further: a base never
  # extends another, and a module lists no sources. A section without `extends` has
  # level 1 alone, its modules' sources. Before any call, each remote source
  # (one with `git`) is checked, in this order: the form `<user>@<host>:<path>` fails
  # `scp_form`; an address with a user name fails `credential_in_address`; then
  # `invalid` for the save rules of a source (`Apiary.Stacks.Document.source_error/2`),
  # among them its `ref`, linked or public (`Apiary.Stacks.Document.ref_error/1`: a
  # `ref` under `refs/` that is no branch or tag, a short name in one of the other
  # namespaces it lists, such as `pull/1/head`, or a `ref` with an empty part or a part
  # that starts with `.`), a host with a percent-encoding, an address longer than a call
  # takes, a `ref` that is no version a read takes, a host that is an IP address in any
  # notation or a local name (`localhost`, `*.localhost`, each also with final dots), and
  # a `path` that is absolute, leads out of its source with `..`, or has a `\` or a `%`,
  # which could spell `..` another way. Every other `path` the walk reads is checked the
  # same way: a local path of the target's file, an export's stack file, and a local
  # module of a level-2 base's `qory-stack.yaml`, which is read from the stack file's
  # folder, so only a path that leaves the base's repository from there fails. A file's
  # base given by name alone, `{stack: <name>}`, fails `invalid` with the save rule's
  # words.
  #
  # Each level's addresses are resolved at every adapter with a `call_url`, in the order
  # of their names. A covered result counts under a live grant of a connected connection:
  # its owner is that connection's organisation. Each source takes the first of these, in
  # this order:
  #
  #   1. a result under a grant of the run's organisation: the source's link;
  #   2. a result under another grant the rule allows (`Apiary.Harnesses.allowed?/3`),
  #      such as a grant of the instance's organisation with an assignment: the link;
  #   3. a result with `public`, true, the first in the adapters' order, with or without
  #      a grant: the source is public;
  #   4. a source a grant of the instance's organisation covers fails `not_allowed`;
  #   5. a `ref` that is a full commit id (40 or 64 lower-case hex digits): no link, and
  #      the source is not read;
  #   6. any other source, one no grant covers or one only other organisations' grants
  #      cover, fails `not_covered`.
  #
  # The run learns nothing of another organisation's grants; only a grant of the
  # instance's organisation shows, as `not_allowed`. A source with a full commit id and no
  # link has its `ref` as its pin, so its host is in the run's `stack_hosts`, and qory
  # fetches it with no credential: a private one fails when qory composes the harness.
  # Such a base's `qory-stack.yaml` is not followed, so its modules' sources are not
  # checked, pinned or linked.
  #
  # A public source is read through the adapter that answered `public`, at the result's
  # `public_ref` (`read-public`, with no grant), by the rules of a linked source: its
  # version pinned, its base's `qory-stack.yaml` followed, its modules' sources checked,
  # and the level its workflows declare read. It is no link: it counts toward no limit of
  # links, and the run gets no credential for it. Its pin puts its host in the run's
  # `stack_hosts`, and qory fetches it with no credential.
  #
  # Then the base is read through its link, or as public, at its `ref`:
  # `<path>/qory-stack.yaml` for a `path`; the root's harness file's `exports` and the
  # export's `qory-stack.yaml` for a `stack`; and for the root, its `qory-stack.yaml`. As
  # qory reads a base, a folder without `qory-stack.yaml` fails `invalid`: the harness
  # section of the root's harness file is no stack. A base of the target's file with
  # `path` and no `git` is read the same way in the target, at `target_version`. Every
  # other remote source's repository has its root `harness.yaml` read once, at its `ref`,
  # for its version. Each later read of a repository is at the version the first
  # returned, its pin.
  #
  # The links: one per grant, with the resources the walk resolved under it, read only.
  # More than `max_links/0` (5: the 8 credentials of a run, less the model key, the
  # registry credential and the work credential) fails `too_many`.
  #
  # ## The access level
  #
  # What the run may do on its target, `:read` or `:write`, with `:read` < `:write`. The
  # walk never raises a level. Whether the target's harness file or the stacks' document
  # applies, it is the lower of two levels:
  #
  #   * declared: `workflows.<workflow>.access`, read for the run's workflow
  #     (`Apiary.Harnesses.Reader.workflow_access/2`), of the base's `qory-stack.yaml`
  #     for a section with `extends`, and of the section's `workflows` for one without.
  #     A value other than `write`, an absent key, an absent `workflows` entry, and a
  #     base that is not read, one with no link that is not public, declare `:read`. A
  #     public base has no link, is read, and its value counts;
  #   * recorded: the access level of the stack row with the run's workflow
  #     (`Apiary.Stacks.recorded_access/3`). Nil lowers nothing.
  #
  # ## Limits
  #
  # At most 60 seconds and 24 calls per walk. A call that times out or reaches no one,
  # or a walk out of time, is `{:retry, failure}`, for the job to try again. A refusal is
  # final: `grant_unknown`, `resource_not_covered` and `resource_not_public` fail
  # `not_covered`; `version_not_found` and `document_not_text` fail `invalid`; any other
  # failure of a call fails `adapter_failed`, with the call's failure.
  #
  # ## What a failure shows
  #
  # The source as `Apiary.Stacks.Document.shown/1` writes it, with no user name, password
  # or query; nil for the stacks' document and for every source of a hidden harness.
  # The target's address shows for a failure of the target's file. The rule of a hidden
  # harness has no path, ref or stack name.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query

  alias Apiary.{Edition, Harnesses, Repo, Stacks}
  alias Apiary.Adapters.{CallFailure, Calls, CallWire, Collection, Connection, Grant, Grants}
  alias Apiary.Harnesses.Reader
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Stacks.{Document, Resolution}

  @time_limit 60_000
  @max_calls 24
  # The most bytes of a document as stored (`run_harnesses_document_check`).
  @max_document 65_536
  @max_links 5
  @call_total 10_000
  @head "HEAD"
  @stack_file "qory-stack.yaml"
  @failures [
    :no_harness,
    :invalid,
    :not_covered,
    :not_allowed,
    :scp_form,
    :credential_in_address,
    :too_many,
    :adapter_unavailable,
    :adapter_failed,
    :walk_error
  ]

  # The form `<user>@<host>:<path>`: no scheme, a user, a host, a colon.
  @scp ~r/\A[^\/:@\s]+@[^\/:@\s]+:/
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @typedoc "What a walk reads: the run's organisation, workspace, target and workflow."
  @type input :: %{
          organisation: Organisation.t(),
          workspace: Workspace.t(),
          target: %{system: String.t(), path: String.t()} | nil,
          workflow: String.t()
        }

  @typedoc "A walk that resolved."
  @type walked :: %{
          origin: :file | :setting,
          access_level: :read | :write,
          target_version: String.t() | nil,
          document: map | nil,
          stack_id: Ecto.UUID.t() | nil,
          owner_organisation_id: Ecto.UUID.t() | nil,
          harness_hidden: boolean,
          pins: [map],
          harness_links: [map]
        }

  @typedoc """
  A walk that failed: the code, the source as shown (nil for none or hidden), the rule an
  `invalid` source breaks, the adapter's name for a call, and the call's failure.
  """
  @type failure :: %{
          failure: atom,
          source: String.t() | nil,
          rule: map | nil,
          adapter: String.t() | nil,
          call_failure: CallFailure.t() | nil
        }

  @doc false
  # failures/0 is the codes a walk fails with.
  @spec failures() :: [atom]
  def failures, do: @failures

  @doc false
  # max_links/0 is the most links a run reads its harness sources through.
  @spec max_links() :: pos_integer
  def max_links, do: @max_links

  @doc false
  # max_calls/0 is the most calls one walk makes.
  @spec max_calls() :: pos_integer
  def max_calls, do: @max_calls

  @doc false
  # run/2 walks `input`'s harness (the moduledoc). `opts`: `time_limit` and `max_calls`,
  # and `call_opts`, merged into each call's options. `{:ok, walked}`, `{:failed,
  # failure}`, or `{:retry, failure}` for a call that timed out or reached no one.
  @spec run(input, keyword) :: {:ok, walked} | {:failed, failure} | {:retry, failure}
  def run(%{} = input, opts \\ []) do
    Process.put(__MODULE__, %{
      deadline: now() + Keyword.get(opts, :time_limit, @time_limit),
      calls: Keyword.get(opts, :max_calls, @max_calls),
      call_opts: Keyword.get(opts, :call_opts, []),
      hidden: false,
      label: nil,
      workflow: input.workflow,
      declared: :read,
      pins: %{},
      links: %{}
    })

    try do
      {:ok, walk(input)}
    catch
      {__MODULE__, :retry, failure} -> {:retry, failure}
      {__MODULE__, :failed, failure} -> {:failed, failure}
    after
      Process.delete(__MODULE__)
    end
  end

  defp walk(input) do
    case target(input) do
      {version, {:file, section, target}} ->
        put(:hidden, Edition.operated?(input.organisation))
        sources(section, input.organisation, target)

        walked(%{
          origin: :file,
          access_level: access_level(input),
          target_version: version,
          document: nil,
          stack_id: nil,
          owner_organisation_id: input.organisation.id
        })

      {version, :absent} ->
        put(:label, nil)
        setting(input, version)
    end
  end

  defp walked(fields) do
    state = Process.get(__MODULE__)

    Map.merge(fields, %{
      harness_hidden: state.hidden,
      pins:
        state.pins
        |> Enum.sort()
        |> Enum.map(fn {{git, ref}, at} -> %{"git" => git, "ref" => ref, "at" => at} end),
      harness_links: state.links |> Map.values() |> Enum.sort_by(& &1["grant_id"])
    })
  end

  defp setting(input, version) do
    case Stacks.resolve_for(input.organisation, input.workspace, input.target, input.workflow) do
      :none ->
        fail(:no_harness)

      {:ok, %Resolution{} = resolution} ->
        put(:hidden, resolution.harness_hidden)

        # One read: a second read of a document near the reader's budget could refuse
        # what the first took.
        section =
          case Document.check(resolution.harness) do
            {:ok, section} -> section
            {:error, {message, values}} -> fail(:invalid, nil, message(message, values))
          end

        if stored_bytes(section) > @max_document,
          do: fail(:invalid, nil, rule("size", n: @max_document))

        sources(section, input.organisation, nil)

        walked(%{
          origin: :setting,
          access_level: access_level(input),
          target_version: version,
          document: section,
          stack_id: resolution.stack_id,
          owner_organisation_id: resolution.owner
        })
    end
  end

  # The run's access level, once the sources are walked (the moduledoc).
  defp access_level(input) do
    recorded = Stacks.recorded_access(input.workspace, input.target, input.workflow)
    lower(get(:declared), recorded)
  end

  # The lower of the declared level and the recorded one, nil for none recorded.
  defp lower(:write, recorded) when recorded in [nil, :write], do: :write
  defp lower(_declared, _recorded), do: :read

  # The bytes of `section` as the row stores it, JSON in Postgres' text form, which has
  # more spaces than the YAML it came from may have.
  defp stored_bytes(section) do
    %{rows: [[bytes]]} = Repo.query!("SELECT octet_length($1::jsonb::text)", [section])
    bytes
  end

  ## The target

  # `{target_version, :absent | {:file, section, location}}`.
  defp target(%{workspace: workspace, organisation: organisation, target: %{} = target}) do
    with true <- Domain.harness_file?(workspace),
         {%Collection{} = collection, %Node{} = adapter} <- collection(workspace, target) do
      location = target_location(organisation, collection, adapter)
      {version, found} = harness_file(location, @head)

      case found do
        nil ->
          {version, :absent}

        {file, content} ->
          case Reader.harness(content) do
            {:ok, %{"extends" => _base} = section} ->
              {version, {:file, section, Map.put(location, :version, version)}}

            # A section that defines a stack, with no base.
            {:ok, %{"modules" => [_ | _]} = section} ->
              {version, {:file, section, Map.put(location, :version, version)}}

            {:ok, _no_base} ->
              {version, :absent}

            :none ->
              {version, :absent}

            {:error, reason} ->
              fail(:invalid, {:shown, location.label}, yaml(file, reason))
          end
      end
    else
      _none -> {nil, :absent}
    end
  end

  defp target(_input), do: {nil, :absent}

  # The live collection of `workspace` with `target`, of a connected connection, and its
  # adapter, which has a `call_url`; the first by when it was made. Nil for none.
  defp collection(%Workspace{id: workspace_id}, %{system: system, path: path}) do
    Repo.one(
      from c in Collection,
        join: n in Connection,
        on: n.id == c.connection_id,
        join: a in Node,
        on: a.id == c.adapter_id,
        where: c.workspace_id == ^workspace_id and is_nil(c.ended_at),
        where: c.target_system == ^system and c.target_path == ^path,
        where: n.state == :connected and is_nil(a.deleted_at) and not is_nil(a.call_url),
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: 1,
        select: {c, a}
    )
  end

  # The target's resource under a grant of the run's organisation, else `not_covered`.
  defp target_location(organisation, collection, adapter) do
    label = Document.shown(collection.url)
    shown = {:shown, label}
    put(:label, shown)

    unless CallWire.address?(collection.url), do: fail(:not_covered, shown)

    case resolve_at(adapter, [collection.url]) do
      [%{grant_ref: grant_ref, resource_ref: resource_ref}] ->
        if Grants.live_for_organisation(adapter.id, grant_ref, organisation.id),
          do: location(adapter, grant_ref, resource_ref, label, [], shown),
          else: fail(:not_covered, shown)

      _not_covered ->
        fail(:not_covered, shown)
    end
  end

  defp location(adapter, grant_ref, resource_ref, label, prefix, source) do
    %{
      adapter: adapter,
      grant_ref: grant_ref,
      resource_ref: resource_ref,
      label: label,
      prefix: prefix,
      source: source
    }
  end

  ## The sources

  # Level 1, the section's base and its modules' sources, then level 2, the git sources
  # of the modules the base lists. `target` is the target's location for a file's
  # section, nil for a setting's. A section without `extends` defines a stack: it
  # declares the run's level in its `workflows`, and has no level 2.
  defp sources(section, organisation, target) do
    base = Map.get(section, "extends")
    modules = module_sources(section)

    based =
      case Map.fetch(section, "extends") do
        {:ok, base} ->
          remote(base, :base, target)

        :error ->
          put(:declared, Reader.workflow_access(section_workflows(section), get(:workflow)))
          []
      end

    remote = based ++ Enum.flat_map(modules, &remote(&1, :module, target))
    allowed = authorise(remote, organisation)

    {{listed, folder}, listed_by} =
      case {base, allowed} do
        # A base with no link that is not public is pinned at its commit and not read:
        # the walk does not follow its `qory-stack.yaml`, so its modules are neither
        # checked nor pinned. A public base has an adapter and is read below.
        {%{"git" => _git}, [{_source, %{adapter: nil}} | _]} ->
          put_pin(base["git"], base["ref"], base["ref"])
          {{[], []}, nil}

        {%{"git" => _git}, [{_source, base_location} | _]} ->
          {base_modules(base, base_location, base["ref"]), base_location.source}

        {%{"path" => path} = base, _allowed} when is_binary(path) ->
          location = %{target | prefix: inside!(path, target)}
          {base_modules(base, location, target_version(target)), location.source}

        _none ->
          {{[], []}, nil}
      end

    for {source, location} <- tl_or_all(base, allowed), do: pin(source, location)

    # A local module of the base's stack is read from the stack file's folder, so only a
    # path that leaves the base's repository from there is refused.
    for %{"path" => path} = module <- listed, is_binary(path), not is_map_key(module, "git") do
      if refusal = path_refusal(path, folder), do: fail(:invalid, listed_by, refusal)
    end

    second = Enum.flat_map(listed, &remote(&1, :module, nil))
    for {source, location} <- authorise(second, organisation), do: pin(source, location)
  end

  defp module_sources(section) do
    case Map.get(section, "modules") do
      modules when is_list(modules) -> for %{"source" => %{} = source} <- modules, do: source
      _none -> []
    end
  end

  defp section_workflows(%{"workflows" => %{} = workflows}), do: workflows
  defp section_workflows(_section), do: %{}

  # The allowed sources other than a remote base, which `base_modules/3` read and pinned.
  defp tl_or_all(%{"git" => _git}, [_base | rest]), do: rest
  defp tl_or_all(_base, allowed), do: allowed

  defp target_version(%{version: version}), do: version

  # `[source]` for a remote source, checked; `[]` for a local one, checked where it is a
  # file's, or a module's source that is neither; `invalid` for a base that is neither.
  defp remote(%{"git" => _git} = source, kind, _target) do
    check!(source, kind)
    [source]
  end

  defp remote(%{"stack" => name} = base, :base, target)
       when is_binary(name) and not is_map_key(base, "path") do
    fail(
      :invalid,
      label(target),
      message(
        "give the base %{name} as a git source and an export: " <>
          "extends: {git: <https address>, ref: <ref>, stack: %{name}}",
        name: name
      )
    )
  end

  defp remote(%{"path" => path}, _kind, %{} = target) when is_binary(path) do
    inside!(path, target)
    []
  end

  defp remote(base, :base, target) when is_map(base) do
    case Document.source_error(base, :base) do
      {message, values} -> fail(:invalid, label(target), message(message, values))
      nil -> []
    end
  end

  defp remote(_base, :base, target), do: fail(:invalid, label(target), rule("extends"))

  defp remote(_source, :module, _target), do: []

  defp label(nil), do: nil
  defp label(%{label: label}), do: {:shown, label}

  # The checks of a remote source before any call (the moduledoc).
  defp check!(%{"git" => git} = source, kind) do
    shown = if is_binary(git), do: Document.shown(git), else: nil

    cond do
      is_binary(git) and Regex.match?(@scp, git) and not String.contains?(git, "://") ->
        fail(:scp_form, shown)

      is_binary(git) and Document.user_information?(git) ->
        fail(:credential_in_address, shown)

      error = Document.source_error(source, kind) ->
        {message, values} = error
        fail(:invalid, shown, message(message, values))

      is_binary(git) and String.contains?(host(git), "%") ->
        fail(:invalid, shown, rule("host_encoded"))

      not CallWire.address?(git) ->
        fail(
          :invalid,
          shown,
          message(
            "write %{source} as https://, a host, an optional port and an optional path: " <>
              "Qory Apiary fetches harness sources over https only",
            source: shown
          )
        )

      not CallWire.version_ref?(source["ref"]) ->
        fail(:invalid, shown, rule("ref", ref: source["ref"]))

      local_host?(git) ->
        fail(:invalid, shown, rule("host"))

      refusal = is_binary(source["path"]) && path_refusal(source["path"]) ->
        fail(:invalid, shown, refusal)

      true ->
        :ok
    end
  end

  # The host of `git` as written, percent-encodings kept; "" for none.
  defp host(git), do: git |> URI.parse() |> Map.get(:host) |> to_string()

  # A host that is an IP address in any notation, such as `[::1]`, `127.0.0.1`, `127.1`
  # or `0x7f.1`, or a local name, with or without final dots, such as `localhost.`.
  # A host with a percent-encoding never gets here: decoded, a fullwidth letter or digit
  # can map to `localhost` or `127.0.0.1`.
  defp local_host?(git) do
    host = git |> host() |> String.downcase() |> String.trim_trailing(".")
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")

    match?({:ok, _address}, :inet.parse_address(String.to_charlist(bare))) or
      Regex.match?(~r/\A(?:0x[0-9a-f]*|[0-9]+)(?:\.(?:0x[0-9a-f]*|[0-9]+))*\.?\z/, host) or
      host == "localhost" or String.ends_with?(host, ".localhost") or host == ""
  end

  # The parts of `path` inside its source, `..` taken back; `:form` for a path with a
  # `\` or a `%`, and `:leaves` for one that is absolute or leads out with `..`.
  defp parts(path) when is_binary(path) do
    cond do
      String.contains?(path, ["\\", "%"]) -> :form
      String.starts_with?(path, "/") -> :leaves
      true -> inside(path)
    end
  end

  defp inside(path) do
    path
    |> String.split("/")
    |> Enum.reduce_while([], fn
      part, parts when part in ["", "."] -> {:cont, parts}
      "..", [] -> {:halt, :leaves}
      "..", [_part | parts] -> {:cont, parts}
      part, parts -> {:cont, [part | parts]}
    end)
    |> case do
      :leaves -> :leaves
      parts -> Enum.reverse(parts)
    end
  end

  # The rule `path` breaks, read from the folder `folder` of its source, nil for a path
  # that stays inside its source.
  defp path_refusal(path, folder \\ []) do
    refused =
      case parts(path) do
        # `..` that leaves the folder may stay in the repository; an absolute path never.
        :leaves when folder != [] ->
          if String.starts_with?(path, "/"),
            do: :leaves,
            else: inside(Enum.join(folder ++ [path], "/"))

        parts ->
          parts
      end

    case refused do
      :form -> rule("path_form", path: path)
      :leaves -> rule("path", path: path)
      _parts -> nil
    end
  end

  # The parts of a local `path` of the target's file, which must stay in the target.
  defp inside!(path, target) do
    case parts(path) do
      parts when is_list(parts) -> parts
      _refused -> fail(:invalid, label(target), path_refusal(path))
    end
  end

  ## Resolving and the rule

  # Each source with its link, by the rule (the moduledoc), in order.
  defp authorise([], _organisation), do: []

  defp authorise(sources, %Organisation{id: organisation_id}) do
    {covered, public} = resolve(sources |> Enum.map(& &1["git"]) |> Enum.uniq())
    instance = Edition.instance_organisation_id()

    allowed =
      Enum.map(sources, fn source ->
        candidates = Map.get(covered, source["git"], [])
        shown = Document.shown(source["git"])

        case allowed(candidates, organisation_id, source) do
          {adapter, grant, resource_ref} ->
            link(adapter, grant, resource_ref)
            {source, location(adapter, grant.grant_ref, resource_ref, shown, [], shown)}

          nil ->
            cond do
              # Read with no grant, so with no link.
              is_map_key(public, source["git"]) ->
                {adapter, resource_ref} = Map.fetch!(public, source["git"])
                {source, location(adapter, nil, resource_ref, shown, [], shown)}

              Enum.any?(candidates, fn {_a, grant, _r} -> grant.organisation_id == instance end) ->
                fail(:not_allowed, shown)

              # No grant, or only other organisations' grants: one result for both.
              commit?(source["ref"]) ->
                {source, location(nil, nil, nil, shown, [], shown)}

              true ->
                fail(:not_covered, shown)
            end
        end
      end)

    if map_size(get(:links)) > @max_links, do: fail(:too_many)
    allowed
  end

  # The first candidate under a grant of the run's organisation, else the first under a
  # grant the rule allows; nil for none.
  defp allowed(candidates, organisation_id, source) do
    Enum.find(candidates, fn {_adapter, grant, _ref} ->
      grant.organisation_id == organisation_id
    end) ||
      Enum.find(candidates, fn {_adapter, grant, _ref} ->
        Harnesses.allowed?(organisation_id, grant.organisation_id, source)
      end)
  end

  # A full commit id, as `Apiary.Dispatches.Built` takes one: 40 lower-case hex digits
  # for SHA-1, 64 for SHA-256. A branch, a tag or a short id is none.
  defp commit?(ref), do: is_binary(ref) and Regex.match?(@commit, ref)

  # The results of `addresses` at every adapter with a `call_url`, two maps by address:
  # the covered ones, `{adapter, grant, resource_ref}` under a live grant of a connected
  # connection, and the first public one, `{adapter, resource_ref}`, whatever its grant.
  defp resolve(addresses) do
    adapters =
      Repo.all(
        from a in Node,
          where: a.kind == :adapter and is_nil(a.deleted_at) and not is_nil(a.call_url),
          order_by: [asc: a.name, asc: a.id]
      )

    for adapter <- adapters,
        chunk <- Enum.chunk_every(addresses, 64),
        result <- resolve_at(adapter, chunk),
        reduce: {%{}, %{}} do
      {covered, public} -> {covered(covered, adapter, result), public(public, adapter, result)}
    end
  end

  defp covered(covered, adapter, %{grant_ref: grant_ref, resource_ref: resource_ref} = result) do
    case live_grant(adapter, grant_ref) do
      %Grant{} = grant ->
        Map.update(
          covered,
          result.address,
          [{adapter, grant, resource_ref}],
          &(&1 ++ [{adapter, grant, resource_ref}])
        )

      nil ->
        covered
    end
  end

  defp covered(covered, _adapter, _result), do: covered

  defp public(public, adapter, %{public: true, address: address} = result),
    do: Map.put_new(public, address, {adapter, public_ref(result)})

  defp public(public, _adapter, _result), do: public

  # The resource a public result's `read-public` calls read, its `public_ref`: every
  # public read takes it from here. A covered result's `resource_ref` may be a ref only
  # its grant's organisation may use, so it never reaches `read-public`.
  defp public_ref(%{public: true, public_ref: public_ref}), do: public_ref

  defp resolve_at(adapter, addresses) do
    case call(adapter, &Calls.resolve(&1, addresses, &2)) do
      {:ok, results} -> results
      {:error, %CallFailure{} = failure} -> call_failed(failure, nil)
    end
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

  defp link(adapter, %Grant{} = grant, resource_ref) do
    modify(:links, fn links ->
      Map.update(
        links,
        grant.id,
        %{
          "grant_id" => grant.id,
          "adapter_id" => adapter.id,
          "grant_ref" => grant.grant_ref,
          "resources" => [resource_ref]
        },
        fn entry -> Map.update!(entry, "resources", &Enum.uniq(&1 ++ [resource_ref])) end
      )
    end)
  end

  ## Reading

  # The version of a remote source's repository: its pin, or its root `harness.yaml`
  # read once at its `ref`, through its link or as public; for a source with no link
  # that is not public, its `ref`, a full commit id.
  defp pin(%{"git" => git, "ref" => ref}, %{adapter: nil}), do: put_pin(git, ref, ref)

  defp pin(%{"git" => git, "ref" => ref}, location) do
    unless Map.has_key?(get(:pins), {git, ref}) do
      {_content, version} = read(location, ["harness.yaml"], ref)
      put_pin(git, ref, version)
    end

    :ok
  end

  defp put_pin(git, ref, version),
    do: modify(:pins, &Map.put_new(&1, {git, ref}, version))

  # The modules the base lists, read at `location` from `at`, its source's version, and
  # the folder of the file that lists them, as parts of the path from the repository's
  # root.
  defp base_modules(base, location, at) do
    {version, modules, folder} =
      cond do
        is_binary(base["stack"]) ->
          exported(location, base["stack"], at)

        is_binary(base["path"]) and is_map_key(base, "git") ->
          stack_at(location, inside!(base["path"], nil), at)

        # A base of the target's file by `path`, read from its `path` in the target, or
        # the root of a remote source.
        true ->
          stack_at(location, [], at)
      end

    if is_binary(base["git"]), do: put_pin(base["git"], base["ref"], version)

    {for(%{"source" => %{} = source} <- modules, do: source), folder}
  end

  # The modules of the stack `name` the source at `location` exports.
  defp exported(location, name, at) do
    {version, found} = harness_file(location, at)

    exports =
      case found do
        nil ->
          fail(:invalid, location.source, rule("no_export", name: name))

        {file, content} ->
          case Reader.exports(content) do
            {:ok, exports} -> exports
            :none -> fail(:invalid, location.source, rule("no_export", name: name))
            {:error, reason} -> fail(:invalid, location.source, yaml(file, reason))
          end
      end

    unless name in exports.stacks,
      do: fail(:invalid, location.source, rule("no_export", name: name))

    path = Reader.stack_file(exports, name)

    case parts(path) do
      parts when is_list(parts) ->
        {_version, modules, folder} = stack_at(location, Enum.drop(parts, -1), version)
        {version, modules, folder}

      _refused ->
        fail(:invalid, location.source, path_refusal(path))
    end
  end

  # The modules of the `qory-stack.yaml` in the folder `parts` at `location`, and that
  # folder from the repository's root.
  defp stack_at(location, parts, at) do
    case read(location, parts ++ [@stack_file], at) do
      {nil, _version} ->
        path = Enum.join(location.prefix ++ parts ++ [@stack_file], "/")
        fail(:invalid, location.source, rule("no_stack_file", path: path))

      {content, version} ->
        {version, stack_modules(location, content), location.prefix ++ parts}
    end
  end

  # The modules of the base's stack file, and the level it declares for the run's
  # workflow.
  defp stack_modules(location, content) do
    case Reader.stack(content) do
      {:ok, %{modules: modules, workflows: workflows}} ->
        put(:declared, Reader.workflow_access(workflows, get(:workflow)))
        modules

      {:error, reason} ->
        fail(:invalid, location.source, yaml(@stack_file, reason))
    end
  end

  # `harness.yaml` at `at`, then `qory.yaml` at the version that read returned:
  # `{version, nil | {file, content}}`; both found fail `invalid`.
  defp harness_file(location, at) do
    {harness, version} = read(location, ["harness.yaml"], at)
    {qory, _version} = read(location, ["qory.yaml"], version)

    case {harness, qory} do
      {nil, nil} -> {version, nil}
      {content, nil} -> {version, {"harness.yaml", content}}
      {nil, content} -> {version, {"qory.yaml", content}}
      _both -> fail(:invalid, location.source, rule("both_files"))
    end
  end

  # The document at `parts` under the location's folder, at `at`: `{content | nil,
  # resolved_at}`. A location with no grant is a public source's (`read-public`).
  defp read(location, parts, at) do
    path = Enum.join(location.prefix ++ parts, "/")

    request = %{
      grant_ref: location.grant_ref,
      resource_ref: location.resource_ref,
      path: path,
      at: at
    }

    case call(location.adapter, &Calls.read_at(&1, request, &2)) do
      {:ok, %{found: true, content: content, resolved_at: version}} -> {content, version}
      {:ok, %{found: false, resolved_at: version}} -> {nil, version}
      {:error, %CallFailure{} = failure} -> call_failed(failure, location)
    end
  end

  ## Calls and time

  # A call within the walk's time and calls: one more than `max_calls/0` fails `invalid`
  # with the harness's label, the target's address while its file is read or applies and
  # none for the stacks' document; a walk out of time is `{:retry, failure}`.
  defp call(adapter, fun) do
    state = Process.get(__MODULE__)
    left = state.deadline - now()

    cond do
      state.calls <= 0 ->
        fail(:invalid, state.label, rule("calls", n: @max_calls))

      left <= 0 ->
        retry(adapter)

      true ->
        put(:calls, state.calls - 1)
        total = min(left, Keyword.get(state.call_opts, :total, @call_total))
        fun.(adapter, Keyword.put(state.call_opts, :total, total))
    end
  end

  defp call_failed(%CallFailure{cause: cause} = failure, _location)
       when cause in [:timeout, :unreachable],
       do: retry(%{name: failure.adapter_name})

  defp call_failed(%CallFailure{cause: :refused, code: code}, %{} = location)
       when code in ["grant_unknown", "resource_not_covered", "resource_not_public"],
       do: fail(:not_covered, location.source)

  defp call_failed(%CallFailure{cause: :refused, code: "version_not_found"}, %{} = location),
    do: fail(:invalid, location.source, rule("version"))

  defp call_failed(%CallFailure{cause: :refused, code: "document_not_text"}, %{} = location),
    do: fail(:invalid, location.source, rule("not_text"))

  defp call_failed(%CallFailure{} = failure, location) do
    throw(
      {__MODULE__, :failed,
       %{
         failure: :adapter_failed,
         source: shown(location && location.source),
         rule: nil,
         adapter: failure.adapter_name,
         call_failure: failure
       }}
    )
  end

  defp retry(%{name: name}) do
    throw(
      {__MODULE__, :retry,
       %{failure: :adapter_unavailable, source: nil, rule: nil, adapter: name, call_failure: nil}}
    )
  end

  ## Failures

  defp fail(code), do: fail(code, nil, nil)
  defp fail(code, source), do: fail(code, source, nil)

  defp fail(code, source, rule) do
    throw(
      {__MODULE__, :failed,
       %{failure: code, source: shown(source), rule: rule, adapter: nil, call_failure: nil}}
    )
  end

  # The source a failure shows: the target's address always, any other source only
  # while the harness is not hidden; at most 512 code points, as the row's check counts.
  defp shown({:shown, label}) when is_binary(label), do: cut(label)
  defp shown(label) when is_binary(label), do: unless(get(:hidden), do: cut(label))
  defp shown(_none), do: nil

  defp cut(label), do: label |> String.to_charlist() |> Enum.take(512) |> List.to_string()

  # A rule of the walk, by its name, which the run's page words. A hidden harness's rule
  # has no path, ref or stack name in its values.
  defp rule(name, values \\ []) do
    values = if get(:hidden), do: Keyword.drop(values, [:path, :ref, :name]), else: values
    %{"rule" => name, "values" => Map.new(values, fn {k, v} -> {to_string(k), v} end)}
  end

  # A rule of the save check, in its words. A hidden harness shows no source in it, and
  # no name, key, place or schema rule (`hidden/2`).
  defp message(message, values) do
    {message, values} = hidden(message, values)

    values =
      Map.new(values, fn
        {:source, _source} -> {"source", if(get(:hidden), do: nil, else: values[:source])}
        {key, value} -> {to_string(key), to_string(value)}
      end)

    %{"message" => message, "values" => values}
  end

  # A save check's message with a value that is part of a hidden harness, the base's
  # stack name, a key, a source's ref, or the place in the document and the rule there:
  # in words without the value, for a hidden harness.
  @hidden_values [:name, :key, :place, :rule, :ref]
  @hidden_messages %{
    ("give the base %{name} as a git source and an export: " <>
       "extends: {git: <https address>, ref: <ref>, stack: %{name}}") =>
      "give the base as a git source and an export: " <>
        "extends: {git: <https address>, ref: <ref>, stack: <name>}",
    ("may not contain %{key}: a harness document takes name, description, extends, " <>
       "modules, bind, extensions and workflows") =>
      "may not contain one of its keys: a harness document takes name, description, " <>
        "extends, modules, bind, extensions and workflows",
    "repeats the key %{key}" => "repeats a key",
    ("write the ref %{ref} as HEAD, a branch or tag name, refs/heads/<name>, " <>
       "refs/tags/<name> or a full commit id: people without write access can change " <>
       "other refs, such as a pull request's") =>
      "write the ref as HEAD, a branch or tag name, refs/heads/<name>, refs/tags/<name> " <>
        "or a full commit id: people without write access can change other refs, such as " <>
        "a pull request's"
  }
  # The words of any other such message, the schema's among them.
  @hidden_message "has a value the harness format does not take"

  defp hidden(message, values) do
    if get(:hidden) and Enum.any?(@hidden_values, &Keyword.has_key?(values, &1)),
      do:
        {Map.get(@hidden_messages, message, @hidden_message),
         Keyword.drop(values, @hidden_values)},
      else: {message, values}
  end

  # A file that the reader refuses: its name, and the save check's words for why.
  defp yaml(file, reason) do
    {message, values} = Document.unreadable(reason)
    {message, values} = hidden(message, values)

    %{
      "rule" => "yaml",
      "values" => %{"file" => file},
      "message" => message,
      "message_values" => Map.new(values, fn {k, v} -> {to_string(k), to_string(v)} end)
    }
  end

  defp get(key), do: Map.fetch!(Process.get(__MODULE__), key)
  defp put(key, value), do: Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, value))
  defp modify(key, fun), do: put(key, fun.(get(key)))

  defp now, do: System.monotonic_time(:millisecond)
end
