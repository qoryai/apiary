defmodule ApiaryWeb.PauseWords do
  @moduledoc false

  # The line of a paused run (`Apiary.Dispatches.Pause`), as the run page and the work
  # item's pages show it, in rich text (`ApiaryWeb.RichText`): why it paused, and the run
  # that continues it, its number a link to its page at `path`, where a run continues it.
  # While every key of its provider is in cooldown, at `now`, the line has the end of the
  # cooldown, in the reader's time zone, as the waiting line shows it
  # (`ApiaryWeb.PreparationComponents.cooldown_time/2`); once that time has passed, or
  # with no such time, or with no run that continues it, the line shows that a key reached
  # its limit. A provider deleted since has no name, and the line is about a model key. The
  # provider's name came from a person and is shown as a text an external system sent.

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText, only: [rich_gettext: 2]

  alias Apiary.ExternalText
  alias ApiaryWeb.PreparationComponents

  @spec line(Apiary.Dispatches.Pause.t(), String.t() | nil, DateTime.t()) :: list
  def line(pause, path, now \\ DateTime.utc_now())

  def line(%{provider: nil, number: nil}, _path, _now),
    do: rich_gettext("Paused: a model key reached its limit.", [])

  def line(%{provider: nil, number: number}, path, _now) do
    rich_gettext("Paused: a model key reached its limit. It continues in run %{number}.",
      number: number(number, path)
    )
  end

  def line(%{provider: provider, number: nil}, _path, _now) do
    rich_gettext("Paused: a key of %{provider} reached its limit.",
      provider: {:bdi, ExternalText.line(provider)}
    )
  end

  def line(%{provider: provider, until: %DateTime{} = until, number: number} = pause, path, now) do
    if DateTime.compare(until, now) == :gt do
      rich_gettext(
        "Paused: every key of %{provider} is in cooldown until %{time}. It continues in run %{number}.",
        provider: {:bdi, ExternalText.line(provider)},
        time: PreparationComponents.cooldown_time(until, now),
        number: number(number, path)
      )
    else
      line(%{pause | until: nil}, path, now)
    end
  end

  def line(%{provider: provider, number: number}, path, _now) do
    rich_gettext("Paused: a key of %{provider} reached its limit. It continues in run %{number}.",
      provider: {:bdi, ExternalText.line(provider)},
      number: number(number, path)
    )
  end

  defp number(number, nil), do: Integer.to_string(number)
  defp number(number, path), do: {:link, path, Integer.to_string(number)}
end
