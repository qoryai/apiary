defmodule Apiary.SecretLogFilter do
  @moduledoc """
  SecretLogFilter keeps an access key's secret out of what a log handler writes: a primary
  filter of Erlang's `:logger`, installed at boot (`install/0`), which replaces each run of
  `qak_` (in any case) and the base64url characters after it with `[FILTERED]`, in a log
  event's message and in its metadata, before any handler sees the event.

  Apiary never has a key's secret: a key made in a browser sends its public half alone
  (`ApiaryWeb.NodeLive.AccessKey`). But an event can still carry what a client sent: the
  parameters of a LiveView event, which `Phoenix.LiveView.Logger` logs at debug before the
  page refuses an event holding a secret, or the arguments and the last message that a
  crash report prints when a process fails on them. Phoenix filters parameters by their
  names (`:filter_parameters`), not by their values, so this filter takes the value: the
  runner contract's secret format, `qak_` and the 32-byte seed in base64url, the same rule
  the page refuses by.

  It runs before Elixir's `:logger_translator`, which turns a report (a crash report among
  them) into text and puts the crash in the `:crash_reason` metadata: `:logger` runs the
  primary filter added last first, and adding a translator moves `:logger_translator` to
  the end. So it scrubs the terms that text is made from, and the metadata as well, which
  holds should the translator ever run first:

    * A message given as a string, or as a format and its arguments, is read as text, and
      a secret in it is replaced (the message becomes that text).
    * A report (`{:report, report}`) has each secret replaced in its terms: in every
      binary and every printable charlist in it, at any depth, map keys included. The
      translator, or the handler's `report_cb`, then formats the scrubbed report.
    * Each metadata value is scrubbed the same way: `:crash_reason` (the exception, the
      arguments it holds and the stacktrace's), a `Plug.Conn`, and anything else there.

  An event without a secret is passed on exactly as it came. The filter never stops an
  event and never raises: should a term defeat it, the event is passed on as it came.

  What it does not cover: a secret split across the parts of a term (two binaries, or an
  iolist's pieces inside a report, each holding part of `qak_`); a secret in an atom, a
  pid or a function's captured values; and output written without `:logger` (straight to
  standard output or standard error). A public key whose base64url happens to hold `qak_`
  is filtered from a log line as a secret would be.
  """

  @id :apiary_access_key_secrets

  # `qak_` in any case: what `:binary.match/2` looks for, before the regex replaces.
  @prefixes for q <- ~w(q Q), a <- ~w(a A), k <- ~w(k K), do: q <> a <> k <> "_"

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
  def filter(%{msg: msg, meta: meta} = event, _extra) when is_map(meta) do
    %{event | msg: scrub_msg(msg), meta: scrub(meta)}
  catch
    _kind, _defeated -> event
  end

  def filter(event, _extra), do: event

  defp scrub_msg({:string, chardata} = msg) do
    case chardata_text(chardata) do
      {:ok, text} -> if secret?(text), do: {:string, replace(text)}, else: msg
      :none -> msg
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
      {:ok, text} -> if secret?(text), do: text |> replace() |> String.to_charlist(), else: list
      :none -> replace_in_list(list)
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
      :none -> list_holds?(list)
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

  defp secret?(binary), do: :binary.match(binary, @prefixes) != :nomatch

  defp replace(binary), do: Regex.replace(~r/qak_[A-Za-z0-9_-]*/i, binary, "[FILTERED]")
end
