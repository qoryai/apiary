defmodule Apiary.Stages.DeliveryUnreadable do
  # Raised when a gate `none` approves a stage (`Apiary.Stages`, `approve_none!/4`) and the
  # store cannot read the file of a version that the approval sends to an adapter
  # (`Apiary.Artifacts.Delivery.approved/2`), so the approval is not stored without its
  # send. At a run's end it is handled as `Apiary.Stages.VerdictUnreadable` is: the end
  # rolls back and is tried again later. A member's accept or approval gets
  # `{:error, :store_unavailable}`.
  @moduledoc false

  defexception message: "a version that the approval sends cannot be read"
end
