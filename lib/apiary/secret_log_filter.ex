defmodule Apiary.SecretLogFilter do
  @moduledoc """
  SecretLogFilter keeps an access key's secret out of every log line: a primary filter of
  Erlang's `:logger`, installed at boot (`install/0`), which replaces each run of `qak_`
  (in any case) and the base64url characters after it with `[FILTERED]` in a line's
  message, before any handler sees it.

  Apiary never has a key's secret: a key made in a browser sends its public half alone
  (`ApiaryWeb.NodeLive.AccessKey`). But a line can still carry what a client sent, such as
  the parameters of a LiveView event, which `Phoenix.LiveView.Logger` logs at debug
  before the page refuses an event holding a secret. Phoenix filters parameters by their
  names (`:filter_parameters`), not by their values, so this filter takes the value: the
  runner contract's secret format, `qak_` and the 32-byte seed in base64url, the same
  rule the page refuses by.

  A message given as a string, or as a format and its arguments, is read; a report is
  left as it is: Apiary's own reports carry no value a client sent.
  """

  @id :apiary_access_key_secrets

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
  filter/2 is the log event with each secret in its message replaced by `[FILTERED]`, or
  the event as it came when its message holds none.
  """
  @spec filter(:logger.log_event(), term) :: :logger.log_event()
  def filter(%{msg: msg} = event, _extra) do
    case text(msg) do
      {:ok, text} ->
        if Regex.match?(~r/qak_/i, text),
          do: %{
            event
            | msg: {:string, Regex.replace(~r/qak_[A-Za-z0-9_-]*/i, text, "[FILTERED]")}
          },
          else: event

      :none ->
        event
    end
  end

  def filter(event, _extra), do: event

  defp text({:string, chardata}), do: chardata_text(chardata)

  defp text({format, args}) when (is_list(format) or is_binary(format)) and is_list(args) do
    format |> :io_lib.format(args) |> chardata_text()
  rescue
    _not_formatted -> :none
  end

  defp text(_report), do: :none

  defp chardata_text(chardata) do
    {:ok, IO.chardata_to_string(chardata)}
  rescue
    _not_text -> :none
  end
end
