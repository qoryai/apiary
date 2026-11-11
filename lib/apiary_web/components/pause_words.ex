defmodule ApiaryWeb.PauseWords do
  @moduledoc false

  # The line of a paused run (`Apiary.Dispatches.Pause`), as the run page and the work
  # item's pages show it, in rich text (`ApiaryWeb.RichText`): why it paused, and the run
  # that continues it, its number a link to its page at `path`. The provider's name came
  # from a person and is shown as a text an external system sent; the end of the cooldown
  # is in the reader's time zone, as the waiting line shows it
  # (`ApiaryWeb.PreparationComponents.cooldown_time/1`).

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText, only: [rich_gettext: 2]

  alias Apiary.ExternalText
  alias ApiaryWeb.PreparationComponents

  @spec line(Apiary.Dispatches.Pause.t(), String.t() | nil) :: list
  def line(%{provider: provider, until: %DateTime{} = until, number: number}, path) do
    rich_gettext(
      "Paused: every key of %{provider} is in cooldown until %{time}. It continues in run %{number}.",
      provider: {:bdi, ExternalText.line(provider)},
      time: PreparationComponents.cooldown_time(until),
      number: number(number, path)
    )
  end

  def line(%{provider: provider, number: number}, path) do
    rich_gettext("Paused: a key of %{provider} reached its limit. It continues in run %{number}.",
      provider: {:bdi, ExternalText.line(provider)},
      number: number(number, path)
    )
  end

  defp number(number, nil), do: Integer.to_string(number)
  defp number(number, path), do: {:link, path, Integer.to_string(number)}
end
