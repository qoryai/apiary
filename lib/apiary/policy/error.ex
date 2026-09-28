defmodule Apiary.Policy.Error do
  @moduledoc """
  Why the policy refused something, fit for the page: `reason` for code to match on,
  `message` a sentence to show as it is, `field` the input it is about when there is one
  (`:host`, `:paths`, `:name`, `:argument`, `:mode`).
  """

  @type reason ::
          :forbidden
          | :invalid
          | :not_found
          | :locked
          | :conflict
          | :invalid_document
          | :unmanaged
          | :not_implemented

  @type t :: %__MODULE__{reason: reason, message: String.t(), field: atom | nil}

  @enforce_keys [:reason, :message]
  defstruct [:reason, :message, :field]

  @doc false
  def new(reason, message, field \\ nil),
    do: %__MODULE__{reason: reason, message: message, field: field}
end
