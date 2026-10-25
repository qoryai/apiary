defmodule Apiary.Adapters.RunCredential do
  # A credential an adapter gave for one run (`Apiary.Adapters.Calls.run_credential/3`):
  # `document`, the Forager contract's credential document as the adapter's answer
  # contains it, with its access token, and `expires_at`, nil where it does not expire.
  # Nothing here writes it to the database or a log. `inspect` shows `expires_at` alone,
  # so no log line, error or crash report contains the token.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  @derive {Inspect, only: [:expires_at]}
  @enforce_keys [:document]
  defstruct [:document, :expires_at]

  @type t :: %__MODULE__{document: map, expires_at: DateTime.t() | nil}

  @doc false
  # new/1 wraps a credential document that `Apiary.Adapters.CallWire.answer/4` read.
  @spec new(map) :: t
  def new(%{} = document) do
    expires_at =
      case document do
        %{"expires_at" => value} ->
          {:ok, time, _offset} = DateTime.from_iso8601(String.upcase(value))
          time

        %{} ->
          nil
      end

    %__MODULE__{document: document, expires_at: expires_at}
  end
end
