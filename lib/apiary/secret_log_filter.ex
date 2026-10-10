defmodule Apiary.SecretLogFilter do
  @moduledoc """
  SecretLogFilter keeps an access key's secret, and an enrolment code, out of what a log
  handler writes: a primary filter of Erlang's `:logger`, installed at boot (`install/0`),
  which replaces each run of `qak_` or `qec_` (in any case) and the base64url characters
  after it with `[FILTERED]`, in a log event's message and in its metadata, before any
  handler sees the event.

  Apiary never has a key's secret: a key made in a browser sends its public half alone
  (`ApiaryWeb.NodeLive.AccessKey`). But an event can still carry what a client sent: the
  parameters of a LiveView event, which `Phoenix.LiveView.Logger` logs at debug before the
  page refuses an event holding a secret, or the arguments and the last message that a
  crash report prints when a process fails on them. Phoenix filters parameters by their
  names (`:filter_parameters`), not by their values, so this filter takes the value: the
  Forager contract's secret format, `qak_` and the 32-byte seed in base64url, the same rule
  the page refuses by.

  An enrolment code (`qec_` and 26 characters of Crockford base32, which a person may type
  in groups split by `-`) is a credential too, for the 15 minutes it works: a machine that
  sends it gets a key on the node. Apiary shows it once, inside the command, and logs it
  nowhere; the filter takes it as it takes a secret, should a client send it back in an
  event's parameters, or a crash print it. The fingerprint after it in the command (`.`
  and the server key's fingerprint) is public, and stays.

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
  `Plug.Conn`'s `path_info`). The set-up link's own line (`Apiary.Setup`) is the one that
  writes it whole: the event that carries the metadata `setup_link: true` keeps its
  message as it came, its metadata scrubbed.

  An event without a secret is passed on exactly as it came. The filter never stops an
  event and never raises: should a term defeat it, the event is passed on as it came.

  What it does not cover: a secret split across the parts of a term (two binaries, or an
  iolist's pieces inside a report or inside a message that cannot be read as text, each
  holding part of `qak_` or `qec_`); a secret or a code in an atom, a
  pid or a function's captured values; and output written without `:logger` (straight to
  standard output or standard error). A public key whose base64url happens to hold `qak_`
  or `qec_` is filtered from a log line as a secret would be. A link's token outside such a
  path (percent-encoded in a query, or alone in a parameter, which `:filter_parameters`
  masks by the name `token`) is not recognised. A path that holds one of those paths after
  a segment of its own (`/acme/users/password/…`, `https://…/docs/setup/…`) is another
  route's, and is left whole.
  """

  @id :apiary_access_key_secrets

  # `qak_` and `qec_` in any case: what `:binary.match/2` looks for, before the regex
  # replaces.
  @prefixes for q <- ~w(q Q),
                {seconds, thirds} <- [{~w(a A), ~w(k K)}, {~w(e E), ~w(c C)}],
                a <- seconds,
                k <- thirds,
                do: q <> a <> k <> "_"

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
  `[FILTERED]`, or the event as it came when it holds none.
  """
  @spec filter(:logger.log_event(), term) :: :logger.log_event()
  # The set-up link's line writes its link whole (`Apiary.Setup`).
  def filter(%{meta: %{setup_link: true} = meta} = event, _extra) do
    %{event | meta: scrub(meta)}
  catch
    _kind, _defeated -> event
  end

  def filter(%{msg: msg, meta: meta} = event, _extra) when is_map(meta) do
    %{event | msg: scrub_msg(msg), meta: scrub(meta)}
  catch
    _kind, _defeated -> event
  end

  def filter(event, _extra), do: event

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

  defp secret?(binary), do: :binary.match(binary, @prefixes ++ @path_marks) != :nomatch

  defp replace(binary) do
    binary = Regex.replace(~r/q(ak|ec)_[A-Za-z0-9_-]*/i, binary, "[FILTERED]")

    if :binary.match(binary, @path_marks) == :nomatch,
      do: binary,
      else: Regex.replace(path_regex(), binary, &redact_token/4)
  end

  # The path's regex, compiled once and kept in `:persistent_term`: a compiled regex cannot
  # be a module attribute.
  defp path_regex do
    case :persistent_term.get({__MODULE__, :path_regex}, nil) do
      nil ->
        regex = Regex.compile!(@path_source)
        :persistent_term.put({__MODULE__, :path_regex}, regex)
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
