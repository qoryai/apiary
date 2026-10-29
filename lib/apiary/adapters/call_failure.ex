defmodule Apiary.Adapters.CallFailure do
  # Why a call of Qory Apiary to an adapter failed (`Apiary.Adapters.Calls`): the adapter,
  # by its id, public id and name, the call's path, and the cause:
  #
  #   * `:no_address`: the adapter declares no `call_url`;
  #   * `:not_allowed`: its `call_url`, or an address its host resolves to, is one Qory
  #     Apiary does not call (`Apiary.Adapters.CallAddress`); `refusal` is why, as
  #     `CallAddress.check/2` returns it: `:form`, `:public_host` or `{:address, ip,
  #     kind}`. A run's row keeps the cause alone (`Apiary.Adapters.Calls.record_failure/3`),
  #     so `refusal` reaches only a caller that reads the failure itself;
  #   * `:unreachable`: the host resolved to no address, or the lookup of the host crashed,
  #     or no connection was made, or it broke before an answer, or a proxy answered 502,
  #     503 or 504 unsigned;
  #   * `:timeout`: no answer within the call's time, the lookup of the host still ran
  #     when that time ended, or the call's time ended before its `time` came within 60
  #     seconds of the clock (`Apiary.Adapters.CallClock`);
  #   * `:refused`: the adapter answered a signed refusal, its code in `code` and its
  #     status in `status`, or an unsigned 401;
  #   * `:invalid_answer`: an answer that is unsigned, signed under no key of the adapter,
  #     bound to another call, larger than the limit, or outside its schema;
  #   * `:too_large`: the call's body is over the limit, and the call was not sent.
  #
  # It holds no body and no header value: a log line or an error may show all of it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  @enforce_keys [:adapter_id, :adapter_public_id, :adapter_name, :path, :cause]
  defstruct [
    :adapter_id,
    :adapter_public_id,
    :adapter_name,
    :path,
    :cause,
    :code,
    :status,
    :refusal
  ]

  @typedoc "Why a call failed."
  @type cause ::
          :no_address
          | :not_allowed
          | :unreachable
          | :timeout
          | :refused
          | :invalid_answer
          | :too_large

  @type t :: %__MODULE__{
          adapter_id: Ecto.UUID.t(),
          adapter_public_id: String.t(),
          adapter_name: String.t(),
          path: String.t(),
          cause: cause,
          code: String.t() | nil,
          status: 100..599 | nil,
          refusal: Apiary.Adapters.CallAddress.not_allowed() | nil
        }

  @doc false
  @spec causes() :: [cause]
  def causes,
    do: [:no_address, :not_allowed, :unreachable, :timeout, :refused, :invalid_answer, :too_large]
end
