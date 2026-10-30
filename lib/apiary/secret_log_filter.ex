defmodule Apiary.SecretLogFilter do
  @moduledoc """
  SecretLogFilter keeps an access key's secret, and an enrolment code, out of what a log
  handler writes: a primary filter of Erlang's `:logger`, installed at boot (`install/0`),
  which replaces each run of `qak_`, of `qrk_` or of an enrolment code's prefix (in any
  case) and the base64url characters after it with `[FILTERED]`, in a log event's message
  and in its metadata, before any handler sees the event. `filter_text/1` replaces them in
  any text the same way.

  Qory Apiary never has a key's secret: a key made in a browser sends its public half alone
  (`ApiaryWeb.NodeLive.AccessKey`). But an event can still carry what a client sent: the
  parameters of a request or of a socket's connection, which Phoenix logs, or the
  arguments and the last message that a crash report prints when a process fails on them.
  Phoenix filters parameters by their names (`:filter_parameters`), not by their values,
  so this filter takes the value: the
  Forager contract's secret format, `qak_` and the 32-byte seed in base64url, the same rule
  the page refuses by.

  A run key (`Apiary.Runs.RunKey`), `qrk_`, its payload, `.` and its signature, is a
  credential of one run, and is taken whole, the `.` and the signature with it.

  An enrolment code (the prefix of its node's kind,
  `#{Apiary.AccessKeys.EnrolmentCode.prefix(:node)}` for a node,
  `#{Apiary.AccessKeys.EnrolmentCode.prefix(:pool)}` for a node pool and
  `#{Apiary.AccessKeys.EnrolmentCode.prefix(:gateway)}` for a gateway, then 26 characters of
  Crockford base32, which a person may type in groups split by `-`) is a credential too,
  for the 15 minutes it works: a machine that sends it gets a key on the node. Qory Apiary
  shows it once, inside the command, and logs it nowhere; the filter takes it as it takes
  a secret, should a client send it back in an event's parameters, or a crash print it. A
  code's prefix is taken broadly, `qec`, a letter or none, and `_`, in any case, and with
  its `_` URL-encoded as `%5F` too, so a prefix that is no kind's is taken as well. The fingerprint after it in the command (`.` and the
  server key's fingerprint) is public, and stays.

  It runs before Elixir's `:logger_translator`, which turns a report (a crash report among
  them) into text and puts the crash in the `:crash_reason` metadata: `:logger` runs the
  primary filter added last first, and adding a translator moves `:logger_translator` to
  the end. So it scrubs the terms that text is made from, and the metadata as well, which
  holds should the translator ever run first:

    * A message given as a string, or as a format and its arguments, is read as text, and
      a secret in it is replaced (the message becomes that text). One that cannot be read
      as text (a part that is not valid UTF-8, or a format its arguments do not fit) keeps
      its shape, and its parts, or the format's arguments, are scrubbed as a report's
      terms are.
    * A report (`{:report, report}`) has each secret replaced in its terms: in every
      binary and every printable charlist in it, at any depth, map keys included. The
      translator, or the handler's `report_cb`, then formats the scrubbed report.
    * Each metadata value is scrubbed the same way: `:crash_reason` (the exception, the
      arguments it holds and the stacktrace's), a `Plug.Conn`, and anything else there.

  **A link's token.** Seven routes carry a bearer token in the path, or the instance's
  set-up code (`token_routes/0`): an invitation and its next step, a log-in link, an
  email change, a password link, the set-up link and the test link of Instance settings ›
  Mail. Whoever reads one from a log could sign in, set a password, join an organisation
  or set the instance up with it. So in every string the filter reads, a message's, a
  report's or the metadata's, such a path's token segment is replaced by `:token` (`:code`
  for the set-up link), as `redact_path/1` replaces it in the request log
  (`ApiaryWeb.RequestLog`): a bare path (`GET /users/password/…`, which Phoenix logs in
  development, or a `Plug.Conn`'s `request_path`, which the production formatter writes
  for a request that crashed) and one inside a whole URL (a LiveView's join payload,
  printed when it crashes), a doubled slash too; and a list of a path's segments (a
  `Plug.Conn`'s `path_info`). The line that prints the set-up link (`Apiary.Setup`) is the one that
  writes it whole: the event that carries the metadata `setup_link: true` keeps its
  message as it came, its metadata scrubbed.

  An invitation's token travels in a query too: its page sends a person to sign up at
  `/users/register?invitation=<token>`. So in every string the filter reads, the value of
  an `invitation` parameter that is a token (43 base64url characters, the 32 bytes every
  token is) is replaced by `:token`: after `?`, `&` or `;`, or at the start of the string
  (a `Plug.Conn`'s `query_string`), and in its URL-encoded form (`%3Finvitation%3D…`, a
  return path inside another parameter). A value of another shape, an invitation's id
  among them (`invitation=<uuid>` in a line the app writes), is left as it is.

  A token, in a path or in a query, is replaced before a secret's prefix is replaced. A
  token that contains `qak_` or a code's prefix, as a random one now and then does, so
  becomes `:token` whole, and a secret or a code in a route's token segment becomes
  `:token` too. When a secret's prefix is replaced, the tokens are looked for again, so a
  token in a path, or a query's token without a prefix in it, becomes `:token` as well
  when a secret is glued to it.

  **A page's lines at debug.** The lines a LiveView logs as it mounts, as it handles the
  parameters of its URL and as it handles an event (`MOUNT`, `HANDLE PARAMS` and
  `HANDLE EVENT`) are `ApiaryWeb.LiveViewLog`'s, in place of `Phoenix.LiveView.Logger`'s:
  every value of the parameters, and of the session the page mounts with (the token a
  person is signed in with, and the socket's id), is written as `[FILTERED]`, and the
  keys, the page's module, the component's and the event's name (when it is text) are
  kept. This filter then scrubs those lines as it scrubs any other.

  **A crash of a LiveView's process.** What a browser sends a LiveView comes in a frame of
  its socket, and a crafted frame can make the process fail on it, before any page reads
  it (a join's payload of the wrong kind, an event's value that is not text, a payload
  without the keys LiveView reads, a `"meta"` or a `"cid"` of the wrong kind) or inside a
  page. Its crash report would print what the frame carried where no page can reach it:
  in the last message, in the exception's terms (a `MatchError`'s term, a
  `FunctionClauseError`'s arguments), in the arguments of a call in the stacktrace, and,
  at debug, in the state, a page's assigns among them. So the crash report of a
  LiveView's process, a channel's or the socket's (a process whose label is
  `{Phoenix.LiveView, view, topic}`, `{Phoenix.Channel, channel, topic}` or
  `{Phoenix.Socket, handler, id}`, or, before the label is set, whose initial call is a
  LiveView's or a channel's) keeps:

    * the exception's module, and its message made from its terms, in which atoms, pids,
      ports, references, functions and an arity stay, and every number, binary, list and
      map is replaced by `[FILTERED]`. A `FunctionClauseError` names its function and
      arity, without the arguments; an Erlang error is made the Elixir exception it
      stands for first. A `Protocol.UndefinedError` keeps its protocol, its description
      and the type of its value, which becomes one of that type holding nothing sent:
      `[FILTERED]` for text, `["[FILTERED]"]` for a list, `%{"[FILTERED]" => "[FILTERED]"}`
      for a map, `0` for a number, the struct with its fields replaced for a struct, and an
      atom, a pid, a port, a reference or a function as it is. An
      exception whose message is stored as text (a `RuntimeError`'s, an
      `ArgumentError`'s, an `Ecto.CastError`'s) has `[FILTERED]` in its place, as that
      text may hold the terms;
    * the stacktrace, each call with its arity in place of its arguments;
    * the process's name and label (with `[FILTERED]` for a channel's topic, which a
      client chose, and for a socket's id, which names the session it was opened with),
      and the client's name and stacktrace.

  The state is `[FILTERED]`. The last message, when a client sent it on the socket, keeps
  its topic only when it is the LiveView's, which its join verified, and its event only
  when Phoenix or LiveView names it; its payload, its references, and a topic or an event
  a client chose, are `[FILTERED]`. Phoenix's broadcast keeps its event, and Phoenix's
  reply its status when it is an atom; each keeps its topic only when it is the LiveView's
  verified one (a broadcast's topic may name a session); its payload, a reply's
  references, and a reply's status that is not an atom, are `[FILTERED]`. Any other last
  message keeps its atoms, pids, ports, references and functions, a tuple's elements and
  an exception taken as above, and has every other term (a number, a binary, a list, a
  map, any other struct) replaced by `[FILTERED]`. Any other event of such a process has
  the terms of its `:crash_reason` metadata replaced the same way.

  OTP's crash report of the process (`{:proc_lib, :crash}`, which Logger drops unless
  `:handle_sasl_reports` is set) keeps its exception, or its exit's reason, and its
  stacktraces as above, its label as above, each of its messages as a last message is
  kept, its pid, name, initial call, ancestors and links, the figures OTP writes of the
  process (its status, whether it traps exits, the length of its queue, its sizes and its
  reductions), and of its process dictionary the entries that OTP and Logger read: the
  initial call, the ancestors, the callers, the label taken as above, Logger's metadata,
  and whether Logger is on. The dictionary's other entries are left out, and any other
  entry of the report is `[FILTERED]`. Should such a crash report defeat the filter, its
  message is `[FILTERED]`. A crash report of any other process keeps its terms, a secret
  and a token in them replaced as above.

  A line of text a client's terms reach is written as `[FILTERED]`, its level and its
  metadata kept, so the `:mfa` still says where it was logged:

    * any process's line from a call of Phoenix's or LiveView's that writes what a client
      sent: Phoenix's join of a channel (a join whose LiveView's process crashed: it
      writes the process's exit, with the arguments of its calls), `Phoenix.Socket`'s
      handling of a frame (a topic no route takes, a channel joined twice, the limit of
      channels), and LiveView's mount (a mount without a session), its check of a
      navigation's URL, and its handling of a message the LiveView does not handle;
    * a line a LiveView's process, a channel's or the socket's logs at error or above, or
      with a `:crash_reason`, but for a line of the app's code (a module of `Apiary` or
      `ApiaryWeb`), which is kept as written. The app's lines at error that such a process
      can log write ids, whether a data key is a workspace's or an organisation's, the
      name of the setting `APIARY_ENCRYPTION_SECRET`, an exception's module, and, for a
      run configuration the contract refuses, the hosts and paths it holds.

  Any other event without a secret is passed on exactly as it came. The filter never
  stops an event and never raises: should a term defeat it, the event is passed on as it
  came, or with the message `[FILTERED]` when it is a crash report of a LiveView's
  process, a channel's or the socket's, or when reading where it comes from fails.

  What it does not cover: a secret split across the parts of a term (two binaries, or an
  iolist's pieces inside a report or inside a message that cannot be read as text, each
  holding part of `qak_` or of a code's prefix); a secret or a code in an atom, a
  pid or a function's captured values; and output written without `:logger` (straight to
  standard output or standard error). The report of a task a LiveView starts, a line
  of another process that writes a crash as text, the lines Phoenix writes of a request
  and of a socket's connection (their parameters, which `:filter_parameters` masks by
  their names), and the lines Ecto writes of a query at debug (its parameters, the token
  a person is signed in with among them) are scrubbed of a secret and a token alone. A
  public key whose base64url happens to hold `qak_` or a code's prefix is filtered from a
  log line as a secret would be. A link's token anywhere else is not recognised: in
  another parameter of a query, or alone as a parameter's value, which
  `:filter_parameters` masks by the names `token` and `invitation`. A path that holds one
  of those paths after another segment (`/acme/users/password/…`,
  `https://…/docs/setup/…`) is another route's, and is left whole. A query's token that
  contains `qak_` or a code's prefix, with a secret glued after it, keeps its characters
  before that prefix: the prefix's regex replaces the prefix, the rest of the token and the
  secret with one `[FILTERED]`, and what is left of the token is under 43 characters.
  """

  alias Apiary.AccessKeys.EnrolmentCode

  @id :apiary_access_key_secrets

  # The prefixes taken: a secret's, `qak_`, a run key's, `qrk_`, and an enrolment code's,
  # every kind's (`EnrolmentCode.prefixes/0`, an adapter's among them) and, more broadly,
  # `qec`, a letter or none, and `_`. A code's `_` may be URL-encoded, `%5F`. A run key is
  # its payload, `.` and its signature (`Apiary.Runs.RunKey`): the `.` and the base64url
  # characters after it are taken with it.
  @code_stems EnrolmentCode.prefixes()
              |> Map.values()
              |> Enum.map(&String.trim_trailing(&1, "_"))
  @prefix_source "(?i)(?:qrk_[A-Za-z0-9_-]*(?:\\.[A-Za-z0-9_-]+)?|(?:qak_|(?:qec[a-z]?|" <>
                   Enum.map_join(@code_stems, "|", &Regex.escape/1) <>
                   ")(?:_|%5F))[A-Za-z0-9_-]*)"

  # Each prefix's letters in any case, without what may follow: what `:binary.match/2`
  # looks for before the regex is run, which then says whether a prefix is there.
  @prefix_marks ["qak", "qrk", "qec" | @code_stems]
                |> Enum.flat_map(fn stem ->
                  stem
                  |> String.graphemes()
                  |> Enum.reduce([""], fn char, marks ->
                    for mark <- marks,
                        variant <- Enum.uniq([String.downcase(char), String.upcase(char)]),
                        do: mark <> variant
                  end)
                end)
                |> Enum.uniq()

  # The routes that carry a bearer token, or the set-up code, in the path: their segments,
  # the token's named. The one list `redact_path/1`, the request log's, and the filter
  # read.
  @token_routes [
    ~w(invitations :token),
    ~w(invitations :token continue),
    ~w(users log-in :token),
    ~w(users settings confirm-email :token),
    ~w(users password :token),
    ~w(setup :code),
    ~w(instance mail confirm :token)
  ]

  # Each route's segments before its token, and the token's name.
  @token_prefixes @token_routes
                  |> Enum.map(fn route ->
                    {before, [name | _]} =
                      Enum.split_while(route, &(not String.starts_with?(&1, ":")))

                    {before, name}
                  end)
                  |> Enum.uniq()

  # What `:binary.match/2` looks for, before the regex replaces: the segment just before a
  # token, and its slash.
  @path_marks @token_prefixes
              |> Enum.map(fn {before, _name} -> List.last(before) <> "/" end)
              |> Enum.uniq()

  # A token's path, bare or after a URL's `//host`: what comes before it is kept, and the
  # token, its base64url characters (every token and the code are base64url), is
  # replaced, so a full stop or a query after it stays. A path starts the
  # string, or follows a character that is not part of a path's segment, so a file's path
  # that merely holds `setup/` is left alone. Slashes may be doubled, as the router reads
  # them.
  @path_source "(?<![\\w.~%/-])((?://[^/\\s\"'<>]*)?)(/+(?:" <>
                 Enum.map_join(@token_prefixes, "|", fn {before, _name} ->
                   Enum.map_join(before, "/+", &Regex.escape/1)
                 end) <> ")/+)([A-Za-z0-9_%-]+)"

  # An invitation's token as a query parameter's value, bare or URL-encoded: what
  # `:binary.match/2` looks for, and the regex that keeps the parameter's name and
  # replaces a token's 43 base64url characters. When they end in `qec`, or `qec` and a
  # letter, and `%5F` follows, they end in a code's prefix, URL-encoded: the regex does not
  # match, and the prefix's regex replaces the prefix and the code's body.
  @query_marks ["invitation=", "invitation%3D", "invitation%3d"]
  @query_source "((?:^|[?&;]|%3[Ff]|%26)invitation(?:=|%3[Dd]))[A-Za-z0-9_-]{43}" <>
                  "(?![A-Za-z0-9_-])(?!(?<=(?i:qec|qec[a-z]))%5[Ff])"

  @doc """
  token_routes/0 is the routes that carry a bearer token, or the instance's set-up code,
  in the path: each its segments, the token's named `:token` (`:code`).
  """
  @spec token_routes() :: [[String.t()]]
  def token_routes, do: @token_routes

  @doc """
  redact_path/1 is a request's path with the token segment of a route of
  `token_routes/0` replaced by its name, `:token` or `:code`; any other path as it is.
  Empty segments are dropped the way the router drops them, so a doubled or trailing
  slash does not get a token past it.
  """
  @spec redact_path(term) :: term
  def redact_path(path) when is_binary(path) do
    case path |> String.split("/", trim: true) |> token_route() do
      nil -> path
      route -> "/" <> Enum.join(route, "/")
    end
  end

  def redact_path(path), do: path

  @doc """
  filter_text/1 is `text` with each secret in it replaced, as the filter replaces it in a
  log event's message: `qak_`, `qrk_` and an enrolment code's prefix, in any case, with
  the characters after them, by `[FILTERED]`, and a link's token in a path or a query by
  its name. Any other text is returned as it is. For text Qory Apiary shows that is not a
  log line: the pool's release reason on the run page, in its header
  (`ApiaryWeb.RunComponents`) and in its Prepare machine section
  (`Apiary.Runs.Preparation`). A run's diagnostics keep every text as stored.
  """
  @spec filter_text(String.t()) :: String.t()
  def filter_text(text) when is_binary(text),
    do: if(secret?(text), do: replace(text), else: text)

  # The route of `token_routes/0` the segments are, or nil: a proper list of binaries
  # alone matches one.
  defp token_route(segments), do: Enum.find(@token_routes, &route?(&1, segments))

  defp route?([":" <> _name | route], [segment | segments]) when is_binary(segment),
    do: route?(route, segments)

  defp route?([literal | route], [literal | segments]), do: route?(route, segments)
  defp route?([], []), do: true
  defp route?(_route, _segments), do: false

  @doc """
  install/0 adds the filter to `:logger`'s primary filters, once: installing it again
  changes nothing.
  """
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@id, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, @id}} -> :ok
    end
  end

  @doc """
  filter/2 is the log event with each secret in its message and its metadata replaced by
  `[FILTERED]`, and, in a crash report of a LiveView's process, a channel's or the
  socket's, what the process was sent replaced by `[FILTERED]` as well; or the event as
  it came when it holds neither.
  """
  @spec filter(:logger.log_event(), term) :: :logger.log_event()
  # The set-up link's line writes its link whole (`Apiary.Setup`).
  def filter(%{meta: %{setup_link: true} = meta} = event, _extra) do
    %{event | meta: scrub(meta)}
  catch
    _kind, _defeated -> event
  end

  def filter(%{meta: meta} = event, _extra) when is_map(meta) do
    event = strip_crash(event)

    try do
      %{event | msg: scrub_msg(event.msg), meta: scrub(event.meta)}
    catch
      _kind, _defeated -> event
    end
  end

  def filter(event, _extra), do: event

  # What replaces a term.
  @filtered "[FILTERED]"

  # The labels Phoenix gives a LiveView's process, a channel's and a socket's, and the
  # modules a LiveView's and a channel's process start in, before the label is set.
  @channel_labels [Phoenix.LiveView, Phoenix.Channel, Phoenix.Socket]
  @channel_modules [Phoenix.LiveView.Channel, Phoenix.Channel.Server]

  # The entries of a process dictionary that OTP and Logger read in a crash report.
  @dictionary_keys [
    :"$initial_call",
    :"$ancestors",
    :"$callers",
    :"$process_label",
    :"$logger_metadata$",
    :logger_enabled
  ]

  # The calls of Phoenix and LiveView that write what a client sent into a line of text:
  # a join whose process crashed (its exit, with the arguments of its calls), a topic no
  # route takes, a mount without a session, a navigation's URL, a message a LiveView does
  # not handle. Any process's line from one of them is written as `[FILTERED]`.
  @client_text_calls [
    {Phoenix.Channel.Server, :join},
    {Phoenix.Socket, :handle_in},
    {Phoenix.LiveView.Channel, :mount},
    {Phoenix.LiveView.Channel, :authorize_session},
    {Phoenix.LiveView.Channel, :view_handle_info}
  ]

  # The events Phoenix and LiveView name; any other a client chose.
  @socket_events ~w(phx_join phx_leave heartbeat event live_patch progress allow_upload
                    cids_will_destroy cids_destroyed chunk)

  # A crash report of a LiveView's process, a channel's or the socket's, with what the
  # process was sent taken out; a line of text such a process logs at error, or of a
  # crash, or from a call that writes what a client sent, as `[FILTERED]`; any other event
  # as it came. Should the report defeat it, its message is `[FILTERED]`, and its crash
  # reason goes.
  defp strip_crash(%{msg: msg, meta: meta} = event) do
    cond do
      client_text?(event) ->
        %{event | msg: {:string, @filtered}, meta: strip_meta(meta)}

      crash_of_channel?(msg, meta) ->
        try do
          %{event | msg: strip_msg(msg, meta), meta: strip_meta(meta)}
        catch
          _kind, _defeated ->
            %{event | msg: {:string, @filtered}, meta: Map.delete(meta, :crash_reason)}
        end

      true ->
        event
    end
  catch
    _kind, _defeated ->
      %{event | msg: {:string, @filtered}, meta: Map.delete(meta, :crash_reason)}
  end

  defp strip_crash(event), do: event

  # A line of text, or a format and its arguments, that a call of `@client_text_calls`
  # logs, or that a LiveView's process, a channel's or the socket's logs at error or above
  # or with a crash reason, but for a line of the app's code, which is kept as written.
  defp client_text?(%{msg: msg, meta: meta} = event) do
    text?(msg) and
      (client_text_call?(Map.get(meta, :mfa)) or
         (channel_process?(nil, nil, meta) and not app_call?(Map.get(meta, :mfa)) and
            (is_map_key(meta, :crash_reason) or error?(Map.get(event, :level)))))
  end

  defp text?({:string, _chardata}), do: true

  defp text?({format, args}) when (is_list(format) or is_binary(format)) and is_list(args),
    do: true

  defp text?(_msg), do: false

  defp client_text_call?({module, function, _arity}), do: {module, function} in @client_text_calls
  defp client_text_call?(_mfa), do: false

  defp app_call?({module, _function, _arity}) when is_atom(module) do
    case Module.split(module) do
      [app | _] when app in ["Apiary", "ApiaryWeb"] -> true
      _other -> false
    end
  rescue
    _not_elixir -> false
  end

  defp app_call?(_mfa), do: false

  defp error?(level) when is_atom(level), do: :logger.compare_levels(level, :error) in [:gt, :eq]
  defp error?(_level), do: false

  defp crash_of_channel?({:report, %{label: {:gen_server, :terminate}} = report}, meta),
    do: channel_process?(Map.get(report, :process_label), nil, meta)

  defp crash_of_channel?({:report, %{label: {:proc_lib, :crash}, report: [crashed | _]}}, meta)
       when is_list(crashed) do
    channel_process?(entry(crashed, :process_label), entry(crashed, :initial_call), meta)
  end

  defp crash_of_channel?(_msg, %{crash_reason: _} = meta), do: channel_process?(nil, nil, meta)
  defp crash_of_channel?(_msg, _meta), do: false

  # A keyword's value, read up to an improper tail.
  defp entry([{key, value} | _rest], key), do: value
  defp entry([_entry | rest], key), do: entry(rest, key)
  defp entry(_tail, _key), do: nil

  # The report's label or initial call, or else, for an event the process logs itself,
  # the process's.
  defp channel_process?(label, initial_call, meta) do
    channel_label?(label) or channel_call?(initial_call) or
      (Map.get(meta, :pid) == self() and
         (channel_label?(Process.get(:"$process_label")) or
            channel_call?(Process.get(:"$initial_call"))))
  end

  defp channel_label?({kind, _module, _id}) when kind in @channel_labels, do: true
  defp channel_label?(_label), do: false

  defp channel_call?({module, :init, _args}) when module in @channel_modules, do: true
  defp channel_call?(_call), do: false

  defp strip_msg({:report, %{label: {:gen_server, :terminate}} = report}, meta) do
    label = Map.get(report, :process_label) || own_label(meta)

    report =
      :maps.map(
        fn
          key, value when key in [:label, :name] -> value
          :process_label, label -> strip_label(label)
          :reason, reason -> strip_reason(reason)
          :client_info, client -> strip_client(client)
          :last_message, message -> strip_message(message, label)
          :log, _log -> []
          _key, _value -> @filtered
        end,
        report
      )

    {:report, report}
  end

  defp strip_msg(
         {:report, %{label: {:proc_lib, :crash}, report: [crashed | linked]} = report},
         _meta
       ) do
    label = entry(crashed, :process_label)
    {:report, %{report | report: [Enum.map(crashed, &strip_crashed(&1, label)) | linked]}}
  end

  defp strip_msg(msg, _meta), do: msg

  # The label of the process that logs the event.
  defp own_label(meta),
    do: if(Map.get(meta, :pid) == self(), do: Process.get(:"$process_label"))

  # A channel's label holds the topic a client joined, and a socket's its id, which names
  # the session it was opened with; a LiveView's holds the topic its join verified.
  defp strip_label({Phoenix.Channel, channel, _topic}), do: {Phoenix.Channel, channel, @filtered}
  defp strip_label({Phoenix.Socket, handler, id}), do: {Phoenix.Socket, handler, redact(id)}
  defp strip_label(label), do: label

  # An entry of OTP's crash report of the process.
  defp strip_crashed({:error_info, {:error, reason, stack}}, _label) do
    {reason, stack} = strip_reason({reason, stack})
    {:error_info, {:error, reason, stack}}
  end

  defp strip_crashed({:error_info, {kind, reason, stack}}, _label) when is_list(stack),
    do: {:error_info, {kind, redact(reason), strip_stack(stack)}}

  defp strip_crashed({:messages, messages}, label) when is_list(messages),
    do: {:messages, Enum.map(messages, &strip_message(&1, label))}

  defp strip_crashed({:process_label, label}, _label), do: {:process_label, strip_label(label)}

  defp strip_crashed({:dictionary, dictionary}, _label) when is_list(dictionary) do
    entries =
      for {key, value} <- dictionary, key in @dictionary_keys do
        if key == :"$process_label", do: {key, strip_label(value)}, else: {key, value}
      end

    {:dictionary, entries}
  end

  defp strip_crashed({:current_stacktrace, stack}, _label) when is_list(stack),
    do: {:current_stacktrace, strip_stack(stack)}

  defp strip_crashed({key, _value} = entry, _label)
       when key in [
              :initial_call,
              :pid,
              :registered_name,
              :ancestors,
              :message_queue_len,
              :links,
              :trap_exit,
              :status,
              :heap_size,
              :stack_size,
              :reductions
            ],
       do: entry

  defp strip_crashed({key, _value}, _label), do: {key, @filtered}

  defp strip_meta(%{crash_reason: reason} = meta),
    do: %{meta | crash_reason: strip_reason(reason)}

  defp strip_meta(meta), do: meta

  # A message a client sent on a socket keeps its topic when it is the one the LiveView's
  # join verified, and its event when Phoenix or LiveView names it; its payload and its
  # references are `[FILTERED]`. A broadcast or a reply, which the server makes, keeps its
  # event, or its status when it is an atom, and its topic only when it is the verified one
  # (a broadcast's topic may name a session); its payload and its references are
  # `[FILTERED]`. Any other message, any other struct with a payload included, is redacted.
  defp strip_message(%Phoenix.Socket.Message{} = message, label) do
    %{
      message
      | topic: if(verified_topic?(message.topic, label), do: message.topic, else: @filtered),
        event: if(message.event in @socket_events, do: message.event, else: @filtered),
        ref: redact(message.ref),
        join_ref: redact(message.join_ref),
        payload: @filtered
    }
  end

  defp strip_message(%Phoenix.Socket.Broadcast{} = broadcast, label) do
    %{broadcast | topic: verified_topic(broadcast.topic, label), payload: @filtered}
  end

  defp strip_message(%Phoenix.Socket.Reply{} = reply, label) do
    %{
      reply
      | topic: verified_topic(reply.topic, label),
        status: if(is_atom(reply.status), do: reply.status, else: @filtered),
        ref: redact(reply.ref),
        join_ref: redact(reply.join_ref),
        payload: @filtered
    }
  end

  defp strip_message(message, _label), do: redact(message)

  defp verified_topic(topic, label),
    do: if(verified_topic?(topic, label), do: topic, else: @filtered)

  defp verified_topic?(topic, {Phoenix.LiveView, _view, topic}) when is_binary(topic), do: true
  defp verified_topic?(_topic, _label), do: false

  # A crash's reason: the error and its stacktrace, or else an exit's reason.
  defp strip_reason({error, stack} = reason) when is_list(stack) do
    if stacktrace?(stack) do
      stack = strip_stack(stack)
      {strip_error(error, stack), stack}
    else
      redact(reason)
    end
  end

  defp strip_reason(reason), do: redact(reason)

  defp strip_client({client, {name, stack}}) when is_list(stack),
    do: {client, {name, strip_stack(stack)}}

  defp strip_client(client), do: redact(client)

  # An Erlang error is made the exception it stands for, read from the stacktrace without
  # its arguments; one that stands for none is an exit's reason, its atoms kept.
  defp strip_error(error, _stack) when is_exception(error), do: strip_exception(error)

  defp strip_error(error, stack) do
    case Exception.normalize(:error, error, stack) do
      %ErlangError{} -> redact(error)
      exception -> strip_exception(exception)
    end
  end

  defp strip_exception(%FunctionClauseError{} = exception),
    do: %{exception | args: nil, clauses: nil}

  # Its message names the type of its value: the value is one of the same type that holds
  # nothing the client sent. Its description is the protocol's code's.
  defp strip_exception(%Protocol.UndefinedError{value: value} = exception),
    do: %{exception | value: same_type(value)}

  defp strip_exception(exception) do
    :maps.map(
      fn
        key, value when key in [:__struct__, :__exception__] -> value
        :arity, arity when is_integer(arity) -> arity
        :args, args when is_list(args) -> Enum.map(args, fn _arg -> @filtered end)
        _key, value -> redact(value)
      end,
      exception
    )
  end

  defp same_type(%{__struct__: _} = struct),
    do:
      :maps.map(
        fn key, value -> if key == :__struct__, do: value, else: redact(value) end,
        struct
      )

  defp same_type(map) when is_map(map), do: %{@filtered => @filtered}
  defp same_type(list) when is_list(list), do: [@filtered]
  defp same_type(integer) when is_integer(integer), do: 0
  defp same_type(float) when is_float(float), do: 0.0
  defp same_type(bitstring) when is_bitstring(bitstring), do: @filtered
  defp same_type(term), do: redact(term)

  # Each call with its arity in place of its arguments.
  defp strip_stack(stack), do: Enum.map(stack, &strip_call/1)

  defp strip_call({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp strip_call({fun, args, location}) when is_list(args), do: {fun, length(args), location}
  defp strip_call(call), do: call

  defp stacktrace?([call | stack]), do: call?(call) and stacktrace?(stack)
  defp stacktrace?([]), do: true
  defp stacktrace?(_tail), do: false

  defp call?({module, function, args, location})
       when is_atom(module) and is_atom(function) and (is_list(args) or is_integer(args)) and
              is_list(location),
       do: true

  defp call?({fun, args, location})
       when is_function(fun) and (is_list(args) or is_integer(args)) and is_list(location),
       do: true

  defp call?(_call), do: false

  # A term with its atoms, pids, ports, references and functions kept (inspect writes none
  # of a function's captured values), a tuple's elements and an exception's terms each
  # taken the same way, and anything else, a number among them, replaced by `[FILTERED]`.
  defp redact(term)
       when is_atom(term) or is_pid(term) or is_port(term) or is_reference(term) or
              is_function(term),
       do: term

  defp redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  defp redact(exception) when is_exception(exception), do: strip_exception(exception)
  defp redact(_term), do: @filtered

  defp scrub_msg({:string, chardata} = msg) do
    case chardata_text(chardata) do
      {:ok, text} -> if secret?(text), do: {:string, replace(text)}, else: msg
      :none -> {:string, scrub(chardata)}
    end
  end

  defp scrub_msg({:report, report} = msg),
    do: if(holds?(report), do: {:report, replace_in(report)}, else: msg)

  defp scrub_msg({format, args} = msg)
       when (is_list(format) or is_binary(format)) and is_list(args) do
    case formatted(format, args) do
      {:ok, text} -> if secret?(text), do: {:string, replace(text)}, else: msg
      :none -> {format, scrub(args)}
    end
  end

  defp scrub_msg(msg), do: msg

  defp formatted(format, args) do
    format |> :io_lib.format(args) |> chardata_text()
  rescue
    _not_formatted -> :none
  end

  defp chardata_text(chardata) do
    {:ok, IO.chardata_to_string(chardata)}
  rescue
    _not_text -> :none
  end

  # A term with each secret in it replaced; the term itself when it holds none.
  defp scrub(term), do: if(holds?(term), do: replace_in(term), else: term)

  defp replace_in(binary) when is_binary(binary),
    do: if(secret?(binary), do: replace(binary), else: binary)

  defp replace_in(list) when is_list(list) do
    case printable(list) do
      {:ok, text} ->
        if secret?(text), do: text |> replace() |> String.to_charlist(), else: list

      :none ->
        # A path's segments, a `Plug.Conn`'s `path_info`, the token's named.
        case token_route(list) do
          nil -> replace_in_list(list)
          route -> route
        end
    end
  end

  defp replace_in(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&replace_in/1) |> List.to_tuple()

  # A struct too: `:maps` reads it as the map it is, `__struct__` kept.
  defp replace_in(map) when is_map(map),
    do: map |> :maps.to_list() |> Enum.map(&replace_in/1) |> :maps.from_list()

  defp replace_in(other), do: other

  # Element by element, an improper list's tail too.
  defp replace_in_list([head | tail]), do: [replace_in(head) | replace_in_list(tail)]
  defp replace_in_list([]), do: []
  defp replace_in_list(tail), do: replace_in(tail)

  # Whether a secret's prefix is anywhere in the term, building nothing but a charlist's
  # text.
  defp holds?(binary) when is_binary(binary), do: secret?(binary)

  defp holds?(list) when is_list(list) do
    case printable(list) do
      {:ok, text} -> secret?(text)
      :none -> token_route(list) != nil or list_holds?(list)
    end
  end

  defp holds?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> list_holds?()

  defp holds?(map) when is_map(map),
    do: :maps.fold(fn key, value, found -> found or holds?(key) or holds?(value) end, false, map)

  defp holds?(_other), do: false

  defp list_holds?([head | tail]), do: holds?(head) or list_holds?(tail)
  defp list_holds?([]), do: false
  defp list_holds?(tail), do: holds?(tail)

  # A non-empty charlist, as text; any other list is read element by element.
  defp printable([_ | _] = list) do
    if :io_lib.printable_unicode_list(list), do: {:ok, List.to_string(list)}, else: :none
  end

  defp printable(_list), do: :none

  defp secret?(binary) do
    (:binary.match(binary, @prefix_marks) != :nomatch and
       Regex.match?(regex(:prefix, @prefix_source), binary)) or
      :binary.match(binary, @path_marks ++ @query_marks) != :nomatch
  end

  # Tokens first: a random token contains `qak_` or a code's prefix now and then, and with
  # the prefix replaced first, a query's token kept its characters before the prefix (a
  # path's token became `:token[FILTERED]`, or `[FILTERED]` when it started with the
  # prefix). Tokens again after a replaced prefix: a secret glued to a token's path or
  # query stops the token's regex from matching until the secret is replaced.
  defp replace(binary) do
    binary = replace_tokens(binary)

    if :binary.match(binary, @prefix_marks) == :nomatch do
      binary
    else
      filtered = Regex.replace(regex(:prefix, @prefix_source), binary, "[FILTERED]")
      if filtered == binary, do: binary, else: replace_tokens(filtered)
    end
  end

  # A token's path, then an invitation's token in a query. `:token`, `:code` and
  # `[FILTERED]` start with a character outside a token's, so a second run keeps them.
  defp replace_tokens(binary) do
    binary =
      if :binary.match(binary, @path_marks) == :nomatch,
        do: binary,
        else: Regex.replace(regex(:path, @path_source), binary, &redact_token/4)

    if :binary.match(binary, @query_marks) == :nomatch,
      do: binary,
      else: Regex.replace(regex(:query, @query_source), binary, "\\1:token")
  end

  # A regex compiled once and kept in `:persistent_term`: a compiled regex cannot be a
  # module attribute.
  defp regex(name, source) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        regex = Regex.compile!(source)
        :persistent_term.put({__MODULE__, name}, regex)
        regex

      regex ->
        regex
    end
  end

  # The path up to the token kept, and the token replaced by its name.
  defp redact_token(_path, host, before, _token) do
    segments = String.split(before, "/", trim: true)
    {_before, name} = List.keyfind(@token_prefixes, segments, 0)
    host <> before <> name
  end
end
