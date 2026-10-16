defmodule Apiary.SecretLogFilter do
  @moduledoc """
  SecretLogFilter keeps an access key's secret, and an enrolment code, out of what a log
  handler writes: a primary filter of Erlang's `:logger`, installed at boot (`install/0`),
  which replaces each run of `qak_` or of an enrolment code's prefix (in any case) and the
  base64url characters after it with `[FILTERED]`, in a log event's message and in its
  metadata, before any handler sees the event.

  Qory Apiary never has a key's secret: a key made in a browser sends its public half alone
  (`ApiaryWeb.NodeLive.AccessKey`). But an event can still carry what a client sent: the
  parameters of a LiveView event, which `Phoenix.LiveView.Logger` logs at debug before the
  page refuses an event holding a secret, or the arguments and the last message that a
  crash report prints when a process fails on them. Phoenix filters parameters by their
  names (`:filter_parameters`), not by their values, so this filter takes the value: the
  Forager contract's secret format, `qak_` and the 32-byte seed in base64url, the same rule
  the page refuses by.

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

  **A crash of a LiveView's process.** What a browser sends a LiveView comes in a frame of
  its socket, and a crafted frame can make the process fail on it, before any page reads
  it (an event's value that is not text, a payload without the keys LiveView reads, a
  `"meta"` or a `"cid"` of the wrong kind) or inside a page. Its crash report would print
  what the frame carried where no page can reach it: in the last message, in the
  exception's terms (a `MatchError`'s term, a `FunctionClauseError`'s arguments), in the
  arguments of a call in the stacktrace, and, at debug, in the state, a page's assigns
  among them. So the crash report of a LiveView's process, a channel's or the socket's (a
  process whose label is `{Phoenix.LiveView, view, topic}`, `{Phoenix.Channel, channel,
  topic}` or `{Phoenix.Socket, handler, id}`, or, before the label is set, whose initial
  call is a LiveView's or a channel's) keeps:

    * the exception's module, and its message made from its terms with each binary,
      list and map in them replaced by `[FILTERED]` (atoms and numbers stay). A
      `FunctionClauseError` names its function and arity, without the arguments; an
      Erlang error is made the Elixir exception it stands for first. An exception whose
      message is stored as text (a `RuntimeError`'s, an `ArgumentError`'s, an
      `Ecto.CastError`'s) has `[FILTERED]` in its place, as that text may hold the terms;
    * the stacktrace, each call with its arity in place of its arguments;
    * the process's name and label, and the client's name and stacktrace.

  The last message's payload is `[FILTERED]` (another message keeps its atoms alone), and
  so is the state. Any other event of such a process has the terms of its `:crash_reason`
  metadata replaced the same way. OTP's crash report of the process (`{:proc_lib, :crash}`,
  which Logger drops unless `:handle_sasl_reports` is set) keeps its exception, its
  stacktrace and its messages the same way, and of its process dictionary the entries
  that OTP and Logger read. Should such a crash report defeat the filter, its message is
  `[FILTERED]`. A crash report of any other process keeps its terms, a secret and a
  token in them replaced as above.

  Any other event without a secret is passed on exactly as it came. The filter never
  stops an event and never raises: should a term defeat it, the event is passed on as it
  came, or with the message `[FILTERED]` when it is a crash report of a LiveView's
  process, a channel's or the socket's.

  What it does not cover: a secret split across the parts of a term (two binaries, or an
  iolist's pieces inside a report or inside a message that cannot be read as text, each
  holding part of `qak_` or of a code's prefix); a secret or a code in an atom, a
  pid or a function's captured values; and output written without `:logger` (straight to
  standard output or standard error). A crash report made text before the filter reads
  it, and the report of a task a LiveView starts, are scrubbed of a secret and a token
  alone. A public key whose base64url happens to hold `qak_`
  or a code's prefix is filtered from a log line as a secret would be. A link's token
  anywhere else is not recognised: in another parameter of a query, or alone as a parameter's value,
  which `:filter_parameters` masks by the names `token` and `invitation`. A path that holds one of those paths after
  another segment (`/acme/users/password/…`, `https://…/docs/setup/…`) is another
  route's, and is left whole.
  """

  alias Apiary.AccessKeys.EnrolmentCode

  @id :apiary_access_key_secrets

  # The prefixes taken: a secret's, `qak_`, and an enrolment code's, every kind's
  # (`EnrolmentCode.prefixes/0`, an adapter's among them) and, more broadly, `qec`, a
  # letter or none, and `_`. A code's `_` may be URL-encoded, `%5F`.
  @code_stems EnrolmentCode.prefixes()
              |> Map.values()
              |> Enum.map(&String.trim_trailing(&1, "_"))
  @prefix_source "(?i)(?:qak_|(?:qec[a-z]?|" <>
                   Enum.map_join(@code_stems, "|", &Regex.escape/1) <>
                   ")(?:_|%5F))[A-Za-z0-9_-]*"

  # Each prefix's letters in any case, without what may follow: what `:binary.match/2`
  # looks for before the regex is run, which then says whether a prefix is there.
  @prefix_marks ["qak", "qec" | @code_stems]
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
  # replaces a token's 43 base64url characters.
  @query_marks ["invitation=", "invitation%3D", "invitation%3d"]
  @query_source "((?:^|[?&;]|%3[Ff]|%26)invitation(?:=|%3[Dd]))[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"

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

  # A crash report of a LiveView's process, a channel's or the socket's, with what the
  # process was sent taken out; any other event as it came. Should the report defeat it,
  # its message is `[FILTERED]`, and its crash reason goes.
  defp strip_crash(%{msg: msg, meta: meta} = event) do
    if crash_of_channel?(msg, meta) do
      try do
        %{event | msg: strip_msg(msg), meta: strip_meta(meta)}
      catch
        _kind, _defeated ->
          %{event | msg: {:string, @filtered}, meta: Map.delete(meta, :crash_reason)}
      end
    else
      event
    end
  end

  defp strip_crash(event), do: event

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

  defp strip_msg({:report, %{label: {:gen_server, :terminate}} = report}) do
    report =
      :maps.map(
        fn
          key, value when key in [:label, :name, :process_label] -> value
          :reason, reason -> strip_reason(reason)
          :client_info, client -> strip_client(client)
          :last_message, message -> strip_message(message)
          :log, _log -> []
          _key, _value -> @filtered
        end,
        report
      )

    {:report, report}
  end

  defp strip_msg({:report, %{label: {:proc_lib, :crash}, report: [crashed | linked]} = report}) do
    {:report, %{report | report: [Enum.map(crashed, &strip_crashed/1) | linked]}}
  end

  defp strip_msg(msg), do: msg

  # An entry of OTP's crash report of the process.
  defp strip_crashed({:error_info, {:error, reason, stack}}) do
    {reason, stack} = strip_reason({reason, stack})
    {:error_info, {:error, reason, stack}}
  end

  defp strip_crashed({:error_info, {kind, reason, stack}}) when is_list(stack),
    do: {:error_info, {kind, redact(reason), strip_stack(stack)}}

  defp strip_crashed({:messages, messages}) when is_list(messages),
    do: {:messages, Enum.map(messages, &strip_message/1)}

  defp strip_crashed({:dictionary, dictionary}) when is_list(dictionary),
    do: {:dictionary, Enum.filter(dictionary, &match?({key, _} when key in @dictionary_keys, &1))}

  defp strip_crashed({:current_stacktrace, stack}) when is_list(stack),
    do: {:current_stacktrace, strip_stack(stack)}

  defp strip_crashed({key, _value} = entry)
       when key in [
              :initial_call,
              :pid,
              :registered_name,
              :process_label,
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

  defp strip_crashed({key, _value}), do: {key, @filtered}

  defp strip_meta(%{crash_reason: reason} = meta),
    do: %{meta | crash_reason: strip_reason(reason)}

  defp strip_meta(meta), do: meta

  # A message a socket carries keeps its topic, event and reference; any other keeps its
  # atoms alone.
  defp strip_message(%{__struct__: _, payload: _} = message), do: %{message | payload: @filtered}
  defp strip_message(message), do: redact(message)

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

  defp strip_exception(exception) do
    :maps.map(
      fn
        key, value when key in [:__struct__, :__exception__] -> value
        :args, args when is_list(args) -> Enum.map(args, fn _arg -> @filtered end)
        _key, value -> redact(value)
      end,
      exception
    )
  end

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

  # A term with its atoms, numbers, pids, ports, references and functions kept (inspect
  # writes none of a function's captured values), a tuple's elements and an exception's
  # terms each taken the same way, and anything else replaced by `[FILTERED]`.
  defp redact(term)
       when is_atom(term) or is_number(term) or is_pid(term) or is_port(term) or
              is_reference(term) or is_function(term),
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

  defp replace(binary) do
    binary =
      if :binary.match(binary, @prefix_marks) == :nomatch,
        do: binary,
        else: Regex.replace(regex(:prefix, @prefix_source), binary, "[FILTERED]")

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
