defmodule Apiary.Policy.Error do
  @moduledoc """
  Why the policy refused something, fit for the page: `reason` for code to match on,
  `message` a sentence to show as it is, `field` the input it is about when there is one
  (`:host`, `:paths`, `:kind`, `:action`, `:mode`). `:fixed` is the mode under a level
  above the workspace that requires `enforce` (`Apiary.Policy.Above`).

  `:integration_host` refuses a deny rule whose host is a host that an integration
  reaching the place requires, a model provider's API endpoints included
  (`Apiary.Policy.check_deny/3`). Its `details` are
  `%{connection: %{id:, public_id:, name:}, host: host}`.
  """

  @type reason ::
          :forbidden
          | :invalid
          | :not_found
          | :locked
          | :fixed
          | :conflict
          | :invalid_document
          | :unmanaged
          | :not_implemented
          | :integration_host

  @type t :: %__MODULE__{
          reason: reason,
          message: String.t(),
          field: atom | nil,
          details: map | nil
        }

  @enforce_keys [:reason, :message]
  defstruct [:reason, :message, :field, :details]

  @doc false
  def new(reason, message, field \\ nil),
    do: %__MODULE__{reason: reason, message: message, field: field}
end
