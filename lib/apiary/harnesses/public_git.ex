defmodule Apiary.Harnesses.PublicGit do
  # Reads a file of a public git repository the way anyone may: git's smart-HTTP protocol
  # over HTTPS, with no credential and no adapter, through `Apiary.Integrations.Fetch`,
  # which connects only to public addresses, pinned, at the port the address has. A run's
  # harness walk (`Apiary.Harnesses.Walk`) and Workspace settings › Workflow
  # (`Apiary.Stacks.Sources`) read a harness source no link reaches with it.
  #
  # ## The requests
  #
  #   1. `GET <address>/info/refs?service=git-upload-pack`, with `Git-Protocol:
  #      version=2`: a repository is public when its host serves the ref advertisement
  #      (`Content-Type: application/x-git-upload-pack-advertisement`). A `401`, `403` or
  #      `404` is a repository that is not public, or does not exist. Only this request
  #      follows redirects, at most 5, each checked again, as git's
  #      `http.followRedirects=initial`; the later requests go to the address it ended at.
  #      The host's answer picks the protocol: version 2 where it advertises it, else
  #      version 0, whose ref list is in this answer.
  #   2. Version 2 only, for a branch, a tag or `HEAD`: `POST git-upload-pack` with
  #      `ls-refs`. A full commit id needs no ref.
  #   3. `POST git-upload-pack` with `fetch`, `want <commit>`, `deepen 1`, and, where the
  #      host offers `filter`, `filter blob:none`: the commit and its trees. Then one
  #      `fetch` of each file read, by its blob id. Any other host, and every version 0
  #      host, gets one fetch of the whole commit, at depth 1 where it offers `shallow`.
  #
  # A request carries only `Host`, `User-Agent`, `Git-Protocol`, and, on a `POST`,
  # `Content-Type` and `Accept`: no credential, configuration or prompt.
  #
  # ## The ref
  #
  # As qory resolves one: a full commit id as it is; `HEAD`, the default branch; a ref
  # under `refs/` as written; any other name `refs/tags/<name>`, peeled, before
  # `refs/heads/<name>`. A name the host does not list is `:version_not_found`.
  #
  # ## Limits
  #
  #   * every request within the time the session's `budget` gives it, at most 10
  #     seconds, and counted by it;
  #   * the ref advertisement and the ref list 1 MiB each; the trees' pack 4 MiB; a
  #     file's pack 320 KiB and the file 256 KiB, the adapters' document cap; the whole
  #     commit 8 MiB;
  #   * 16 MiB inflated per repository in one session, every pack together, and the pack
  #     reader's limits (`Apiary.Harnesses.PublicGit.Pack`);
  #   * a file is UTF-8 text without a NUL character, else `:not_text`.
  #
  # Within one session each repository's advertisement, each ref and each commit's trees
  # are read once. Across sessions, a file read at a commit is kept in
  # `Apiary.Harnesses.PublicGit.Cache`; the advertisement and the ref are read again by
  # every session, so a repository that is no longer public is not read.
  @moduledoc false

  alias Apiary.Harnesses.PublicGit.{Cache, Pack}
  alias Apiary.Integrations.Fetch

  @request_time 10_000
  @refs_bytes 1_048_576
  @tree_bytes 4 * 1_048_576
  @file_bytes 262_144
  @file_pack_bytes @file_bytes + 65_536
  @full_bytes 8 * 1_048_576
  @inflated 16 * 1_048_576
  @max_redirects 5
  @user_agent "git/2.0 (qory-apiary)"
  @advertisement "application/x-git-upload-pack-advertisement"
  @result "application/x-git-upload-pack-result"
  @service "/info/refs?service=git-upload-pack"
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @name ~r/\A[A-Za-z0-9._\/-]{1,255}\z/

  @typedoc """
  Why a read failed:

    * `:not_found`: the host answered `401`, `403` or `404`, a repository that is not
      public or does not exist;
    * `:not_allowed`: the host is a refused name, or resolves to an address that is not
      public, on any hop (`Apiary.Integrations.Fetch.Address`);
    * `{:unreachable, seconds}`: no address, no connection, no answer within `seconds`,
      or a `502`, `503` or `504`;
    * `:late`: the session's budget gave no time for another request;
    * `:too_large`: an answer, a file or the inflated packs over a limit;
    * `:failed`: the host did not serve a git repository by the protocol;
    * `:version_not_found`: a ref the host does not list, or a commit it does not have;
    * `:not_text`: a file that is not UTF-8 text without a NUL character.
  """
  @type cause ::
          :not_found
          | :not_allowed
          | {:unreachable, pos_integer}
          | :late
          | :too_large
          | :failed
          | :version_not_found
          | :not_text

  @typedoc "Each request's time: `{:ok, milliseconds}`, or `{:error, :late}` for none left."
  @type budget :: (-> {:ok, pos_integer} | {:error, :late})

  @doc false
  # file_bytes/0 is the most bytes of a file a read takes.
  @spec file_bytes() :: pos_integer
  def file_bytes, do: @file_bytes

  @doc false
  # request_seconds/0 is the most seconds one request takes.
  @spec request_seconds() :: pos_integer
  def request_seconds, do: div(@request_time, 1000)

  @doc false
  # session/2 runs `fun` with a session: the requests it makes take their time from
  # `budget`, and what they read is kept for the session alone. A session inside another
  # has the inner one's.
  @spec session(budget, (-> result)) :: result when result: term
  def session(budget, fun) when is_function(budget, 0) and is_function(fun, 0) do
    previous = Process.get(__MODULE__)
    Process.put(__MODULE__, %{budget: budget, memo: %{}, inflated: %{}})

    try do
      fun.()
    after
      if previous,
        do: Process.put(__MODULE__, previous),
        else: Process.delete(__MODULE__)
    end
  end

  @doc false
  # public/1 is `:ok` where `git`'s host serves it to anyone (the moduledoc's first
  # request), else `{:error, cause}`.
  @spec public(String.t()) :: :ok | {:error, cause}
  def public(git) when is_binary(git) do
    with {:ok, _repository} <- repository(git), do: :ok
  end

  @doc false
  # read/3 is the file at `path` of `git` at `at`: `{:ok, content, commit}`, content nil
  # for a commit that has no file there, `commit` the full id `at` resolved to; else
  # `{:error, cause}`.
  @spec read(String.t(), String.t(), String.t()) ::
          {:ok, binary | nil, String.t()} | {:error, cause}
  def read(git, at, path) when is_binary(git) and is_binary(at) and is_binary(path) do
    with {:ok, parts} <- parts(path),
         {:ok, repository} <- repository(git),
         {:ok, commit, given} <- resolve(repository, at),
         {:ok, content} <- file(repository, commit, given, path, parts) do
      {:ok, content, commit}
    end
  end

  @doc false
  # address/1 is the host of `git` and its port, as a failure shows them.
  @spec address(String.t()) :: {String.t(), pos_integer}
  def address(git) do
    uri = URI.parse(git)
    {String.downcase(uri.host || ""), uri.port || 443}
  end

  ## The repository

  defp repository(git) do
    memo({:repository, git}, fn ->
      with {:ok, answer} <- request(:get, base(git) <> @service, nil, @refs_bytes),
           :ok <- served(answer, @advertisement),
           {:ok, base} <- redirected(answer.url),
           {:ok, repository} <- advertisement(answer.body) do
        {:ok, Map.merge(repository, %{git: git, base: base})}
      end
    end)
  end

  # The address with no final `/`, its host in lower case, its port kept.
  defp base(git) do
    uri = URI.parse(git)
    port = if uri.port in [nil, 443], do: "", else: ":#{uri.port}"

    "https://#{String.downcase(uri.host || "")}#{port}#{String.trim_trailing(uri.path || "", "/")}"
  end

  # The address the first request ended at, without the service: git refuses a
  # redirect that changes that part.
  defp redirected(url) do
    if String.ends_with?(url, @service),
      do: {:ok, String.replace_suffix(url, @service, "")},
      else: {:error, :failed}
  end

  defp served(%{content_type: type}, expected) when is_binary(type) do
    if type |> String.split(";") |> hd() |> String.trim() |> String.downcase() == expected,
      do: :ok,
      else: {:error, :failed}
  end

  defp served(_answer, _expected), do: {:error, :failed}

  defp advertisement(body) do
    with {:ok, lines} <- lines(body) do
      case lines do
        [{:data, "# service=git-upload-pack\n"}, :flush | rest] -> advertised(rest)
        rest -> advertised(rest)
      end
    end
  end

  defp advertised([{:data, "version 2\n"} | rest]) do
    capabilities =
      rest
      |> Enum.take_while(&match?({:data, _}, &1))
      |> Map.new(fn {:data, line} ->
        case String.split(String.trim_trailing(line, "\n"), "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    features = capabilities |> Map.get("fetch", "") |> String.split(" ", trim: true)

    with {:ok, hash} <- hash(capabilities["object-format"]),
         true <- Map.has_key?(capabilities, "fetch") and Map.has_key?(capabilities, "ls-refs") do
      {:ok,
       %{
         version: 2,
         hash: hash,
         object_format: Map.has_key?(capabilities, "object-format"),
         filter: "filter" in features,
         shallow: "shallow" in features
       }}
    else
      _invalid -> {:error, :failed}
    end
  end

  defp advertised([{:data, "version 1\n"} | rest]), do: version_0(rest)
  defp advertised(rest), do: version_0(rest)

  # The ref list of version 0: the first line with the capabilities after a NUL.
  defp version_0([{:data, first} | rest]) do
    with [ref, capabilities] <- String.split(first, <<0>>, parts: 2),
         capabilities =
           capabilities |> String.trim_trailing("\n") |> String.split(" ", trim: true),
         format = Enum.find_value(capabilities, &format/1),
         {:ok, hash} <- hash(format),
         {:ok, refs} <- refs([{:data, ref} | rest], hash, %{}) do
      {:ok,
       %{
         version: 0,
         hash: hash,
         capabilities: capabilities,
         shallow: "shallow" in capabilities,
         refs: refs
       }}
    else
      _invalid -> {:error, :failed}
    end
  end

  defp version_0(_lines), do: {:error, :failed}

  defp format("object-format=" <> format), do: format
  defp format(_capability), do: nil

  defp hash(nil), do: {:ok, :sha}
  defp hash("sha1"), do: {:ok, :sha}
  defp hash("sha256"), do: {:ok, :sha256}
  defp hash(_other), do: {:error, :failed}

  # Version 0's refs, `name => {id, peeled}`, to the flush; the line of an empty
  # repository, `capabilities^{}`, has none.
  defp refs([:flush], _hash, refs), do: {:ok, refs}

  defp refs([{:data, line} | rest], hash, refs) do
    with [id, name] <- String.split(String.trim_trailing(line, "\n"), " ", parts: 2),
         true <- id?(id, hash) do
      refs =
        case name do
          "capabilities^{}" ->
            refs

          name ->
            case String.split(name, "^{}") do
              [tag, ""] -> Map.update(refs, tag, {nil, id}, fn {tagged, _} -> {tagged, id} end)
              [name] -> Map.update(refs, name, {id, nil}, fn {_, peeled} -> {id, peeled} end)
              _other -> refs
            end
        end

      refs(rest, hash, refs)
    else
      _invalid -> {:error, :failed}
    end
  end

  defp refs(_lines, _hash, _refs), do: {:error, :failed}

  defp id?(id, :sha), do: byte_size(id) == 40 and Regex.match?(@commit, id)
  defp id?(id, :sha256), do: byte_size(id) == 64 and Regex.match?(@commit, id)

  ## The ref

  # `{:ok, commit, given}`: `given` true for a full commit id the reader gave.
  defp resolve(repository, at) do
    cond do
      Regex.match?(@commit, at) ->
        if id?(at, repository.hash),
          do: {:ok, at, true},
          else: {:error, :version_not_found}

      not Regex.match?(@name, at) ->
        {:error, :version_not_found}

      true ->
        memo({:ref, repository.git, at}, fn -> named(repository, at) end)
    end
  end

  defp named(repository, at) do
    names =
      case at do
        "HEAD" -> ["HEAD"]
        "refs/" <> _ -> [at]
        name -> ["refs/tags/" <> name, "refs/heads/" <> name]
      end

    with {:ok, refs} <- listed(repository, names) do
      case Enum.find_value(names, &Map.get(refs, &1)) do
        {id, peeled} when is_binary(id) -> {:ok, peeled || id, false}
        _none -> {:error, :version_not_found}
      end
    end
  end

  defp listed(%{version: 0, refs: refs}, _names), do: {:ok, refs}

  defp listed(repository, names) do
    body =
      IO.iodata_to_binary([
        pkt("command=ls-refs\n"),
        object_format(repository),
        "0001",
        pkt("peel\n"),
        pkt("symrefs\n"),
        Enum.map(names, &pkt("ref-prefix #{&1}\n")),
        "0000"
      ])

    with {:ok, answer} <- post(repository, body, @refs_bytes),
         {:ok, lines} <- lines(answer.body) do
      ls_refs(lines, repository.hash, %{})
    end
  end

  defp ls_refs([:flush], _hash, refs), do: {:ok, refs}

  defp ls_refs([{:data, "ERR " <> _message} | _rest], _hash, _refs), do: {:error, :failed}

  defp ls_refs([{:data, line} | rest], hash, refs) do
    case String.split(String.trim_trailing(line, "\n"), " ") do
      ["unborn" | _attributes] ->
        ls_refs(rest, hash, refs)

      [id, name | attributes] ->
        peeled = Enum.find_value(attributes, &peeled/1)

        if id?(id, hash) and (peeled == nil or id?(peeled, hash)),
          do: ls_refs(rest, hash, Map.put(refs, name, {id, peeled})),
          else: {:error, :failed}

      _invalid ->
        {:error, :failed}
    end
  end

  defp ls_refs(_lines, _hash, _refs), do: {:error, :failed}

  defp peeled("peeled:" <> id), do: id
  defp peeled(_attribute), do: nil

  ## The file

  # A path's parts: none empty, `.` or `..`.
  defp parts(path) do
    parts = String.split(path, "/")

    if Enum.any?(parts, &(&1 in ["", ".", ".."])),
      do: {:error, :failed},
      else: {:ok, parts}
  end

  defp file(repository, commit, given, path, parts) do
    key = {repository.git, commit, path}

    case Cache.get(key) do
      {:ok, content} ->
        {:ok, content}

      :miss ->
        with {:ok, content} <- fetch_file(repository, commit, given, parts) do
          Cache.put(key, content)
          {:ok, content}
        end
    end
  end

  defp fetch_file(repository, commit, given, parts) do
    with {:ok, snapshot} <- snapshot(repository, commit, given),
         {:ok, entry} <- entry(snapshot, snapshot.root, parts, repository) do
      case entry do
        nil -> {:ok, nil}
        id -> blob(repository, snapshot, id)
      end
    end
  end

  # The commit's objects: its trees alone where the host filters blobs, else every
  # object; and its root tree.
  defp snapshot(repository, commit, given) do
    memo({:snapshot, repository.git, commit}, fn ->
      trees? = repository.version == 2 and repository.filter

      fetched =
        fetch(repository, commit,
          deepen: repository.shallow,
          filter: trees?,
          max_bytes: if(trees?, do: @tree_bytes, else: @full_bytes)
        )

      with {:ok, objects} <- objects(repository, fetched, given),
           {:commit, data} <- Map.get(objects, Base.decode16!(commit, case: :lower)),
           {:ok, root} <- tree_of(data, repository) do
        {:ok, %{objects: objects, root: root, blobs: not trees?}}
      else
        {:error, cause} -> {:error, cause}
        _no_commit -> {:error, :failed}
      end
    end)
  end

  defp tree_of(data, repository) do
    case Pack.commit_tree(data, Pack.id_size(repository.hash)) do
      {:ok, root} -> {:ok, root}
      :invalid -> {:error, :failed}
    end
  end

  # The blob id at `parts` under the tree `tree`; nil for none, a folder, a link or a
  # submodule.
  defp entry(snapshot, tree, [part | rest], repository) do
    with {:tree, data} <- Map.get(snapshot.objects, tree) do
      case Pack.tree_entry(data, part, Pack.id_size(repository.hash)) do
        {:ok, "40000", id} when rest != [] -> entry(snapshot, id, rest, repository)
        {:ok, "100" <> _mode, id} when rest == [] -> {:ok, id}
        {:ok, _mode, _id} -> {:ok, nil}
        :none -> {:ok, nil}
        :invalid -> {:error, :failed}
      end
    else
      _missing -> {:error, :failed}
    end
  end

  defp blob(_repository, %{blobs: true} = snapshot, id), do: text(Map.get(snapshot.objects, id))

  defp blob(repository, _snapshot, id) do
    hex = Base.encode16(id, case: :lower)

    with {:ok, objects} <-
           objects(repository, fetch(repository, hex, max_bytes: @file_pack_bytes), false) do
      text(Map.get(objects, id))
    end
  end

  defp text({:blob, content}) do
    cond do
      byte_size(content) > @file_bytes -> {:error, :too_large}
      not String.valid?(content) or String.contains?(content, <<0>>) -> {:error, :not_text}
      true -> {:ok, content}
    end
  end

  defp text(_missing), do: {:error, :failed}

  # The objects of a pack fetched, within the repository's inflated bytes; a refusal of
  # a commit the reader gave is a version the host does not have.
  defp objects(repository, {:ok, pack}, _given) do
    used = Map.get(state().inflated, repository.git, 0)

    case Pack.read(pack, hash: repository.hash, budget: @inflated - used) do
      {:ok, %{objects: objects, inflated: inflated}} ->
        update(fn state ->
          %{state | inflated: Map.put(state.inflated, repository.git, used + inflated)}
        end)

        {:ok, objects}

      {:error, :too_large} ->
        {:error, :too_large}

      {:error, :invalid} ->
        {:error, :failed}
    end
  end

  defp objects(_repository, {:error, :refused}, true), do: {:error, :version_not_found}
  defp objects(_repository, {:error, :refused}, false), do: {:error, :failed}
  defp objects(_repository, {:error, cause}, _given), do: {:error, cause}

  ## Fetching

  # One fetch of `want`, a hex id: the pack, or `{:error, :refused}` for a host's
  # `ERR` line.
  defp fetch(%{version: 2} = repository, want, opts) do
    body =
      IO.iodata_to_binary([
        pkt("command=fetch\n"),
        object_format(repository),
        "0001",
        pkt("want #{want}\n"),
        if(opts[:deepen], do: pkt("deepen 1\n"), else: []),
        if(opts[:filter], do: pkt("filter blob:none\n"), else: []),
        pkt("no-progress\n"),
        pkt("ofs-delta\n"),
        pkt("done\n"),
        "0000"
      ])

    with {:ok, answer} <- post(repository, body, Keyword.fetch!(opts, :max_bytes)) do
      sections(answer.body)
    end
  end

  defp fetch(%{version: 0} = repository, want, opts) do
    offered = repository.capabilities

    band =
      cond do
        "side-band-64k" in offered -> ["side-band-64k"]
        "side-band" in offered -> ["side-band"]
        true -> []
      end

    capabilities =
      band ++ Enum.filter(["ofs-delta", "no-progress", "shallow"], &(&1 in offered))

    body =
      IO.iodata_to_binary([
        pkt("want #{want} #{Enum.join(capabilities, " ")}\n"),
        if(opts[:deepen], do: pkt("deepen 1\n"), else: []),
        "0000",
        pkt("done\n")
      ])

    with {:ok, answer} <- post(repository, body, Keyword.fetch!(opts, :max_bytes)) do
      version_0_pack(answer.body, band != [])
    end
  end

  defp object_format(%{object_format: true, hash: :sha256}), do: pkt("object-format=sha256\n")
  defp object_format(%{object_format: true}), do: pkt("object-format=sha1\n")
  defp object_format(_repository), do: []

  # Version 2's answer: sections to the `packfile` section, whose side band has the pack.
  defp sections(body) do
    case next(body) do
      {:data, "ERR " <> _message, _rest} ->
        {:error, :refused}

      {:data, "packfile\n", rest} ->
        band(rest, [])

      {:data, section, rest}
      when section in ["acknowledgments\n", "shallow-info\n", "wanted-refs\n"] ->
        skip(rest)

      _other ->
        {:error, :failed}
    end
  end

  # The lines of a section to the delimiter, then the next section.
  defp skip(body) do
    case next(body) do
      {:data, "ERR " <> _message, _rest} -> {:error, :refused}
      {:data, _line, rest} -> skip(rest)
      {:delim, rest} -> sections(rest)
      _other -> {:error, :failed}
    end
  end

  # Version 0's answer: `shallow` lines and a flush, then `NAK`, then the pack, in the
  # side band where one was asked for.
  defp version_0_pack(body, band?) do
    case next(body) do
      {:data, "ERR " <> _message, _rest} -> {:error, :refused}
      {:data, "shallow " <> _id, rest} -> version_0_pack(rest, band?)
      {:flush, rest} -> version_0_pack(rest, band?)
      {:data, "NAK\n", rest} when band? -> band(rest, [])
      {:data, "NAK\n", rest} -> {:ok, rest}
      _other -> {:error, :failed}
    end
  end

  # The side band to its flush: band 1 the pack, 2 progress, 3 an error.
  defp band(body, pack) do
    case next(body) do
      {:data, <<1, data::binary>>, rest} -> band(rest, [pack | data])
      {:data, <<2, _progress::binary>>, rest} -> band(rest, pack)
      {:data, <<3, _message::binary>>, _rest} -> {:error, :refused}
      {:flush, _rest} -> {:ok, IO.iodata_to_binary(pack)}
      _other -> {:error, :failed}
    end
  end

  ## Requests

  defp post(repository, body, max_bytes) do
    with {:ok, answer} <- request(:post, repository.base <> "/git-upload-pack", body, max_bytes),
         :ok <- served(answer, @result) do
      {:ok, answer}
    end
  end

  # One request, its time from the session's budget; only the first `GET` follows
  # redirects.
  defp request(method, url, body, max_bytes) do
    with {:ok, time} <- state().budget.() do
      time = min(time, @request_time)

      headers =
        case method do
          :get ->
            [{"git-protocol", "version=2"}]

          :post ->
            [
              {"git-protocol", "version=2"},
              {"content-type", "application/x-git-upload-pack-request"},
              {"accept", @result}
            ]
        end

      opts = [
        headers: headers,
        user_agent: @user_agent,
        any_port: true,
        max_bytes: max_bytes,
        timeout: time,
        max_redirects: if(method == :get, do: @max_redirects, else: 0)
      ]

      opts = if body, do: Keyword.put(opts, :body, body), else: opts

      opts =
        case Application.get_env(:apiary, __MODULE__, [])[:req_options] do
          nil -> opts
          req_options -> Keyword.put(opts, :req_options, req_options)
        end

      case Fetch.request(method, url, opts) do
        {:ok, answer} -> {:ok, answer}
        {:error, :unreachable} -> {:error, {:unreachable, max(div(time + 999, 1000), 1)}}
        {:error, failure} -> {:error, failure}
      end
    end
  end

  ## Lines

  defp pkt(line) do
    length = byte_size(line) + 4
    [length |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"), line]
  end

  # Every pkt-line of `body` to its end.
  defp lines(body), do: lines(body, [])

  defp lines(<<>>, lines), do: {:ok, Enum.reverse(lines)}

  defp lines(body, lines) do
    case next(body) do
      {:data, line, rest} -> lines(rest, [{:data, line} | lines])
      {:flush, rest} -> lines(rest, [:flush | lines])
      {:delim, rest} -> lines(rest, [:delim | lines])
      _invalid -> {:error, :failed}
    end
  end

  # The next pkt-line: 4 hex digits of length, the length counted in, at most 65,520.
  defp next(<<length::binary-size(4), rest::binary>>) do
    with {:ok, <<n::16>>} <- Base.decode16(length, case: :mixed) do
      case n do
        0 -> {:flush, rest}
        1 -> {:delim, rest}
        2 -> {:end, rest}
        n when n >= 4 and n <= 65_520 and n - 4 <= byte_size(rest) -> data(rest, n - 4)
        _invalid -> :invalid
      end
    else
      _invalid -> :invalid
    end
  end

  defp next(_body), do: :invalid

  defp data(rest, size) do
    <<line::binary-size(^size), rest::binary>> = rest
    {:data, line, rest}
  end

  ## The session

  @default_budget %{budget: &__MODULE__.no_budget/0, memo: %{}, inflated: %{}}

  @doc false
  # no_budget/0 is the budget outside a session: each request its full time.
  @spec no_budget() :: {:ok, pos_integer}
  def no_budget, do: {:ok, @request_time}

  defp state, do: Process.get(__MODULE__) || @default_budget

  defp update(fun) do
    if state = Process.get(__MODULE__), do: Process.put(__MODULE__, fun.(state))
  end

  defp memo(key, fun) do
    case Map.fetch(state().memo, key) do
      {:ok, value} ->
        value

      :error ->
        value = fun.()
        update(fn state -> %{state | memo: Map.put(state.memo, key, value)} end)
        value
    end
  end
end
